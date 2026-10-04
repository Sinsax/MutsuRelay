# UI 性能与内存优化方案（探讨稿）

> 状态：**提案，未改代码**（本轮只加了两处 UI 行为改动：右下角提示、灵敏度延迟落盘）。
> 所有数字都是本机实测或按代码结构推算，标注了来源；没标"实测"的就是推算，落地前应当先量。

---

## 〇、先量再谈

| 项 | 实测值 | 来源 |
|---|---|---|
| 模型文件 | 228.5 MB | `mem_probe.py` |
| 加载后 RSS 增量 | **+296 MB**（放大 ≈1.3×），耗时 1.1~1.3 s | `mem_probe.py` |
| 卸载后残留 | **+26.7 MB**（基线 29.3 → 56.0 MB），即 ~270 MB 归还 OS | 同上 |
| 连续 3 轮加载→卸载 | 56.2 → 49.2 → 48.1 MB，**无累积** | 同上 `--cycles 3` |
| 录音期间 `notifyListeners` 频率 | ≈ 1~2 次/秒（interim 间隔 0.8 s + `in_speech` 翻转） | 代码推算 |
| 电平表更新路径 | 独立 `ValueNotifier` + 阈值(>0.002) + `RepaintBoundary` | `mic_button.dart` |
| 句列表 | 上限 **500** 条，`ListView.builder` + 每项 `RepaintBoundary` | `message_list.dart` |
| 单次 `saveSettings` | 5 个 setter + 一次 `config.toml` 全量重写 | 代码 |

**结论：当前没有"明显错误"的性能问题。** 录音轮询只在文本变化时通知、电平走独立通知器且带阈值、
列表是懒构建且已封顶。下面剩下的都是"可做可不做、收益数量级较小"的项。

> 附带修掉一个让数字失真的工具 bug：`mem_probe.py` 原先用 `mutsurelay_init_asr` 触发加载，
> 但第四轮之后它是**懒加载**（只 `trigger_reload_if_loaded()`），于是量出来"模型增量 ≈ 0 MB"，
> 纯属假数据。现在改用 `mutsurelay_reload_asr`（forced，界面"重启 ASR"走的也是它），
> 并加了 `--cycles N` 反复重建检查残留。

---

## 一、UI 性能：按性价比排序

### P1 · 低风险，建议先做

**1. 把 `liveText` 从 `MessageList` 的大 `Selector` 里拆出去**

- 现状：`message_list.dart:82` 一个 `Selector` 同时管 header / 列表 / 实时预览 / 手动输入。
  说话时 interim 每 0.8 s 刷一次 `liveText` → **整个 MessageList 子树**（含 `ListView` 与其可见项、
  编辑控制器同步）跟着重建。
- 方案：抽出 `_LivePreview` 子 widget，用只订阅 `liveText` 的 `Selector`；主 Selector 去掉它。
- 收益：说话期间每 0.8 s 少重建一次列表子树。
- 验证：加一个计数 widget 或临时 `debugPrintRebuildDirtyWidgets`，断言重建次数下降。

**2. `pendingCount` 改成维护计数器**

- 现状：`app_state.dart:484` `pendingCount => _sentenceList.where((s) => s.isPending).length`，
  在 selector 里被求值 → **每次 notify 都 O(n) 扫一遍**（n 可达 500）。
- 方案：`addSentence` / 发送成功 / 失败 / 删除时增量维护 `_pendingCount`。
- 收益：每次 notify 从 O(n) 降为 O(1)。

**3. `Consumer<AppState>` → 窄 `Selector`**

- 现状：`vad_slider` / `mode_toggle` / `toast_overlay` / `qr_login_modal` 用的是 `Consumer<AppState>`，
  **任何** notify 都会重建它们。
- 方案：各自只订阅用到的字段（vad_slider 只需 `noiseGateDisplay`，mode_toggle 只需 `windowMode` …）。
- 收益：每次 notify 少重建 2~4 个 widget（其中 vad_slider 含 `Slider` + 自绘滑块）。

### P2 · 收益更明显，但要动结构 / 需要先量

**4. 圆角裁剪的 `saveLayer` 代价**

`_normalLayout` 的 `Container` 用了 `clipBehavior: Clip.antiAlias`
(`message_list.dart:126`)：每帧为整块列表子树建一个 saveLayer。窗口本身已是
"透明 + 渐变 + 半透明白卡(0x80FFFFFF)"，弱 GPU 上这笔开销不白给。
可 A/B：`Clip.hardEdge`（圆角仍在，仅边缘不抗锯齿）或把裁剪下移到真正需要的小块上。

**5. 透明窗口 / 亚克力效果的取舍**

Windows 走 `flutter_acrylic`，透明窗口要求每帧合成。若 GPU 占用是瓶颈，
可给设置加一个"性能模式"：关亚克力 + 背景改不透明纯色。这条能量化（帧时间），但要真机测。

**6. 不建议动的部分**

`stats` 已经只在设置面板打开时 1 s 刷新；迷你模式是"换 widget"而不是 `AnimatedSwitcher`；
这些都已经是对的做法。

### P3 · 先拿 profile 数据再动手

7. 用 `flutter run --profile` + DevTools timeline 跑一轮录音，确认 P1/P2 里的推断是否命中真实热点。
   上面的收益都是**按代码结构与通知频率推算**的，不是测量值。

---

## 二、内存：实测结论 + 方案

### 2.1 内存都花在哪

| 组成 | 量级 | 说明 |
|---|---|---|
| onnxruntime + 模型 | **+296 MB** | 录音期间的绝对主项，占实测 500 MB 的六成 |
| DLL + 依赖 + 线程 | +5 MB；卸载后残留 ~+27 MB | 可忽略 |
| Flutter 引擎 + Dart VM | ~150~250 MB（**随 debug/release 明显变化**） | 与业务无关的基线 |
| 用户实测总量 | 只开界面 ≈ 200 MB / 录音中 ≈ 500~640 MB | 与上面相加吻合 |

### 2.2 方案（按收益/代价排序）

1. **先确认量的是不是 debug 构建** —— debug 引擎明显更胖。用
   `flutter build windows --release` 跑一遍再量：这条几乎零成本，可能直接消掉几十 MB。
2. **空闲卸载阈值 60 s → 15~30 s**（或"隐藏到托盘 / 窗口失焦 N 分钟后立刻卸载"）。
   实测卸载能归还 ~270 MB，代价是下次开录多等 1.1~1.3 s —— 而那段时间正好与"用户点下录音、
   还没开口"重叠。
3. **加一个"省内存"开关**：录音结束后立即释放模型。适合非直播的偶发使用（写文档、试一下），
   代价是每句话首字多 1 s 左右。
4. **换更小的模型**（唯一能突破 ~300 MB 地板的路）：当前 SenseVoice int8 是 228 MB 的绝对主项。
   若要常驻 < 200 MB，只能换小模型或做"小模型常驻 + 大模型按需"。
   好消息是现在有 `cer_baseline.py`，**换模型的精度代价可以直接量化**（跑一遍对比平均 CER）。
5. **不要继续追 onnxruntime arena**：3 轮加载/卸载无累积（56→49→48 MB），
   说明没有 arena 扣住不放。session 选项那条路已经被实测否掉，省得白花时间。

### 2.3 明确不建议做的

- 把 recognizer 挪到子进程：复杂度高，收益只是"Task Manager 里换个进程名字"。
- 用 `EmptyWorkingSet` 之类 API 硬压 RSS：数字好看，页仍会被换回来，只会掩盖真实用量。

---

## 三、建议的落地顺序

1. **P1 三条**（半小时级、低风险、每条都能加测试）
2. **量一次 release 构建**的内存与帧时间 —— 这会决定后面还要不要做 P2
3. 若要继续省内存：先调卸载阈值 → 再加"省内存"开关 → 最后才考虑换模型（用 CER 基线量化代价）
4. 若要做 P2（裁剪 / 性能模式），先在 `--profile` 下拿数据，别凭感觉改

## 四、怎么复现本文的数字

```sh
python native/tools/mem_probe.py --cycles 3        # 加载/卸载/反复重建的 RSS
python native/tools/cer_baseline.py                # 换模型时的精度代价（平均 CER）
flutter run --profile                              # DevTools timeline：帧时间与重建热点
```
