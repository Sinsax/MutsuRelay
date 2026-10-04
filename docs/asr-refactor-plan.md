# ASR 链路重构规划

> 范围：`native/src/{lib.rs, vad.rs, censor.rs, bilive.rs}` + `lib/{ffi/native_bridge.dart, providers/app_state.dart}`
> 目标：把「采集/分段/解码」串在一根线程上的同步链路，改成 4 段解耦的流水线；同时清掉死代码与假功能。
> 状态：规划稿（未改代码）。所有量化收益需先做 Phase 0 基线测量才能定档。

---

## 一、现状事实核对（本轮的确定结论）

上一轮 review 的结论大部分成立，但有两处需要修正，另有一处新发现的确定性 bug。

### 1.1 修正：`context` 的作用没说准

代码在推段时取 `ring_buf` 尾部 150 ms（lib.rs:382 / 401 / 434）。实际效果分两种情况：

- **静音切段（常态）**：推段发生在累计 450 ms 静音之后（`VAD_MIN_SILENCE_FRAMES=15`），而 `ring_buf` 只保留 300 ms，所以拿到的**全是静音**——不是"段尾回放"。危害不是串音，而是**这个 context 完全没用**：代码意图是 pre-roll（段首之前的声音），拿到的是段后静音，句首弱音没有被补上。
- **30 s 强制切段**：连续说话没有静音，`ring_buf` 尾部**正好是刚推走那段的最后 150 ms**，此时才真的把段尾接到了下一段段头，接缝处可能多出一个字。

结论不变（应改为在语音起点快照 pre-roll），但影响面要按上面两种分开看。

### 1.2 新发现（确定性 bug）：批处理会丢句

`flush_pending_segments` 逐个解码后对每个 stream 调用 `process_stream_result`，而后者是**覆盖写**：

```rust
// lib.rs:565-567
if let Ok(mut r) = recognition_text().lock() {
    *r = json;          // ← 覆盖，不是入队
}
```

`BATCH_MAX_SIZE = 2`，一次 flush 里有 2 段时，**前一段的文本被后一段覆盖，永久丢失**。触发条件恰好是"循环迭代变慢"——也就是阻塞解码期间音频堆积、一次迭代里连推 2 段的时候。即：**越卡越丢句**。

### 1.3 新发现：flush 在帧循环内部

`while leftover.len() >= VAD_FRAME_SAMPLES`（lib.rs:307 开，427 闭）内部就调用了阻塞解码（lib.rs:415-419）。也就是说一次 chunk 的处理过程中可能连续多次发起 1~3 s 的解码，`audio_level`（lib.rs:421）要等全部退出才更新一次——这同时解释了"电平表卡住/闪"和延迟累积。

### 1.4 现状问题总表

| # | 问题 | 位置 | 类别 | 严重度 |
|---|---|---|---|---|
| 1 | 批处理覆盖写 → 丢句 | lib.rs:565 | 使用 | **高** |
| 2 | 解码在采集线程内、且在帧循环内部 | lib.rs:415, 264 | 性能 | **高** |
| 3 | 音频回调内 `to_vec()` + 无界 mpsc | lib.rs:220, 225 | 性能 | **高** |
| 4 | `restartAsr()` 是假功能（不重建 recognizer） | lib.rs:91, 249, 352 | 使用 | **高** |
| 5 | 自动发言在 UI 线程同步发网络请求 | app_state.dart:419, bilive.rs:80, 574 | 性能 | **高** |
| 6 | 段长上限 30 s + 实时结果被注释 → 最长 30 s 才出字 | vad.rs:10, lib.rs:366-370 | 精度/体验 | **高** |
| 7 | 失败全程静默（无设备/无模型/stream 建失败） | lib.rs:186, 204, 231 | 使用 | 中 |
| 8 | context 未在语音起点快照（见 1.1） | lib.rs:382 | 精度 | 中 |
| 9 | 重采样无抗混叠、且无跨 chunk 相位（44.1k 设备会漂） | vad.rs:23-46 | 精度 | 中 |
| 10 | 噪声门能量口径不统一（门限比降噪后，噪声底用降噪前） | lib.rs:305, 314, 330 | 精度 | 中 |
| 11 | 降噪三档增益会压掉弱音节（擦音/轻声） | lib.rs:319-329 | 精度 | 中 |
| 12 | 去重做了两层（Rust 3 s + Dart 2 s） | lib.rs:543, app_state.dart:388 | 精度/体验 | 中 |
| 13 | 快速开关录音会并发出两个 pipeline | lib.rs:118-129 | 使用 | 中 |
| 14 | 电平表无衰减弹道（数值随帧跳变，缺平滑） | lib.rs:421 | 体验 | 低 |
| 15 | `seg_buf.clone()` 最大 1.9 MB/段 | lib.rs:385 | 性能 | 低 |
| 16 | 字幕每条整读整写 `capture.txt` | bilive.rs:610-626 | 性能 | 低 |
| 17 | `ring_buf.drain(..n)` O(n) 前移 | lib.rs:301 | 性能 | 低 |
| 18 | recognizer 建在首次语音上（240 MB 现场加载） | lib.rs:352-364 | 体验 | 中 |
| 19 | 双份语言静态量 `ASR_LANG` / `bilive::LANGUAGE` | lib.rs:25, bilive.rs:13 | 整洁 | 中 |
| 20 | `censor` 的 `dedup()` 实际无效（只按长度排序，相同项不相邻） | censor.rs:157-158 | 精度 | 中 |
| 21 | `censor` mode 2 的「整句=2 字屏蔽词则用全拼」规则不一致 | censor.rs:114-116 | 精度 | 低 |
| 22 | `cargo test` 只覆盖 censor 与 rms/resample，VAD/分段零测试 | test | 整洁 | **高** |
| 23 | censor 用例共享全局 blocklist，**并行执行会互相污染**（原有隐患） | censor.rs tests | 整洁 | 中 |
| 24 | 相邻的屏蔽词会被合并成一个 span（既有语义，非 bug，但影响替换规则判断） | censor.rs:99-111 | 行为 | 低 |

> 二次核对时的更正：**第 14 条原判断有误**。`audio_level` 的写入位于帧循环内部，只在确实处理了完整帧时才执行，
> 因此不会"被写成 0"；实际问题是缺少衰减弹道（数值在帧之间跳变）。已按实际行为改写。

---

## 一·补 实施进度

| 阶段 | 状态 | 说明 |
|---|---|---|
| P0 基线测量 | 部分 | `get_stats()` 已落地并随 poll 返回；**离线回放工具已做**（`native/examples/replay.rs`）；**测试音频集仍未做**（CER 无法实测） |
| P1 正确性止血 | **已完成** | 见第六节 |
| P2 线程与内存 | **已完成** | 见第七节 |
| P3 精度 | **已完成（Rust 侧）** | 见第八节；CER 需测试音频集才能实测 |
| P4 整洁与可测 | **已完成** | 模块拆分 + 死代码 + 单测，见第九节；**复检记录见第十节** |

**验证环境**：`flutter analyze` **实际可以执行**。此前记录的"Windows 侧无 Flutter SDK"是误判——
SDK 装在 `C:\Users\para\flutter\flutter`（3.44.0 stable / Dart 3.12.0），只是没进 PATH，
而 PATH 里那条 `F:\para\Code\flutter\bin` 是失效路径。`.fvm/*` 确实是指向
`/home/para/fvm/versions/stable` 的 Linux 符号链接（`IntxLNK` 残留），但 Windows 侧用的是
上面那套独立 SDK，与 `.fvm` 无关。

实测（2026-09-18，经绝对路径调用）：

| 命令 | 结果 |
|---|---|
| `flutter analyze` | **No issues found**（修掉 1 个 `unnecessary_non_null_assertion` 后） |
| `flutter test` | **All tests passed**（1 个 widget test） |

两个环境坑：
1. `flutter test` 会被本机代理打挂——`HTTP_PROXY/HTTPS_PROXY=127.0.0.1:13605` 同样代理了
   flutter_tester 的 WebSocket，报 `Invalid WebSocket upgrade request`。跑前设
   `NO_PROXY=127.0.0.1,localhost` 或清空代理变量。
2. 任何 `flutter analyze|test|run` 都会重写 `linux|windows/flutter/generated_plugin_registrant.cc`
   与 `generated_plugins.cmake`。内容与仓库一致，但 `core.autocrlf=true` 会让它们显示为
   modified（纯行尾差异）。跑完用 `git checkout --` 还原这 4 个文件。

补充手段：`native/tools/smoke_native.py` —— 用 ctypes 直接加载 DLL 跑 C API 全链路，
在没有 Flutter 运行时的场景（CI、纯 native 改动）依然能端到端验证。

### C API 版本（ABI_VERSION = 2）

P2/P3 新增/改变了 9 个导出符号，这会**破坏与旧产物的兼容**：双系统开发下很容易拿
Linux 侧旧的 `.so` 去跑新绑定，缺符号会让 `_bindFunctions()` 抛错并被 `load()` 吞掉，
最后静默退回 mock 模式（界面能开，ASR 其实没工作）。

因此新增 `mutsurelay_abi_version()`，Dart 侧声明 `expectedAbiVersion = 2` 并**在绑定前校验**；
不符时记入 `NativeBridge.loadError`，由 `main.dart` 在首帧后弹错误 toast。
**以后增删任何 `mutsurelay_*` 符号，必须同时 +1 两处版本号。**

---

## 二、清理任务清单

分三级：**删**（死代码，零风险）、**改**（行为修正）、**建**（新增能力）。

### A. 删除（死代码，可一次性落地）

| 对象 | 位置 | 依据 |
|---|---|---|
| `memorySensitivity` 全链路 | lib.rs:768-775；bilive.rs:18, 78, 639-647；Config 字段；app_state.dart:330-337, 674, 708；native_bridge.dart 对应声明 | 无任何逻辑读取，UI 也不再暴露。Config 里保留字段（`#[serde(default)]`）以兼容旧 config.toml，仅停止读写 |
| `vad::is_speech_active` + `NoiseEstimator` | vad.rs:49-98 | 与 lib.rs:333-337 的另一套阈值逻辑重复，常量还不同（`*0.05` vs 三档增益） |
| `INTERIM_INTERVAL` 及注释块 | vad.rs:11；lib.rs:366-370, 247, 344 | 整块被注释 |
| `mutsurelay_get_recognition_result` | lib.rs:146-153 | 与 `poll_recording` 同为 `mem::take` 语义，两个消费者会互相抢；Dart 未用 |
| `mutsurelay_get_audio_level` | lib.rs:141-144；native_bridge.dart:655；app_state.dart 中未用的 `getAudioLevel` | level 已随 poll 一起返回 |
| Dart `getRecognitionResult()` | native_bridge.dart:657 | 无调用方 |
| `_interim_frame` / `_frame_count` 残留 | lib.rs:247, 255 | 只赋不读 |

预估删除 ≈ 110 行（含注释与 Dart 侧）。

### B. 修正（行为 bug）

| # | 问题 | 改动要点 |
|---|---|---|
| B1 | 批处理丢句（1.2） | 结果通道从「单槽覆盖」改为**队列**，一次 poll 取一批 |
| B2 | 假 `restartAsr` | 引入 `RecognizerCmd::Reload{model_dir, lang}` 命令通道，由解码线程重建 recognizer；`mutsurelay_init_asr` 改为投递该命令（空闲时立即重载并预热，录音中则等当前段解完） |
| B3 | 并发 pipeline | `start_recording` 用 generation 计数 + 保存 `JoinHandle`，start 前先 join 旧线程；或改为「pipeline 常驻、stream 按需开关」（见 3.4） |
| B4 | 失败静默 | 无输入设备 / 无模型 / stream 建失败，一律 `set_last_error(...)`，由 poll 带出到 Dart 弹 toast |
| B5 | 语言双份静态量 | 收敛为单一 `Settings`（`OnceLock<SettingsStore>`），`ASR_LANG` 与 `bilive::LANGUAGE` 都改为读写它 |
| B6 | censor `dedup` 无效 | 改为 `HashSet` 去重再按**字符数**（非字节数）降序排序；`to_*_pinyin` 结果可缓存（当前每段每词都重新转拼音） |
| B7 | censor 全局特例 | 删掉「n==2 且全覆盖 → 全拼」的整句特例，改为**逐 span 规则**：词长 ≤2 用全拼，否则用首字母。这样同一词在任何上下文替换一致 |
| B8 | 电平表抖动 | `max_energy` 在 chunk 级累加（跨帧），只在 chunk 处理完写一次 |
| B9 | 重复去重 | 只保留 Rust 一层；Dart 的 2 s 去重删除（或反之，但需二选一），并把窗口降到 1.5 s |
| B10 | 字幕文件 | 解码线程内维护 20 行内存尾窗，一次 `write` 覆盖（去掉每条 `read_to_string`） |

### C. 新建（支撑能力）

| 对象 | 说明 |
|---|---|
| `replay` 离线回放工具（`native/examples/replay.rs`） | 读 WAV → 跑分段 + 解码 → 输出每段文本与耗时；开关 `--no-denoise`、`--seg-max=8`、`--no-preroll` 做 A/B。**这是后面所有精度结论的前提** |
| 测试音频集 | 5~10 分钟中文：连续说话、长停顿、高低音量、键盘/风扇噪声、含敏感词 |
| `mutsurelay_get_stats()` | 暴露 `dropped_chunks / queue_depth / segments / decode_p50_ms / decode_p95_ms / captured_ms`，让"性能提升"可验证 |
| segmenter 纯函数单测 | 状态机抽成 `FrameFeature + State → Vec<SegmentEvent>`，8~12 个用例覆盖起停、最小语音帧、强制切段、接缝 |

---

## 三、新的整体规划

### 3.1 拆分原则

一条规则：**实时路径上零分配、零阻塞；重活全部搬到自己的线程；线程之间只用有界队列通信。**

### 3.2 线程与数据流

```
[cpal 回调线程 · 实时]
   单声道下混到预分配 scratch（无分配）
   → SPSC 环形缓冲（无锁，溢出丢最旧 + 计数）

[Front-end 线程]
   ring → 带抗混叠的流式重采样（跨 chunk 相位连续）
        → 30 ms 分帧 → 帧特征（rms / 峰值 / ZCR）
        → 自适应噪声底（单一能量域）
        → 分段状态机（纯函数）
        → 段队列  bounded(4)

[Decode 线程]
   recognizer 常驻（懒加载一次，reload 走命令）
   批量 decode_multiple_streams
   → 后处理：清洗 / 接缝合并 / 去重 / 敏感词 / 分句
   → 结果队列（追加，不覆盖）
   → 字幕文件（内存尾窗一次写）
   → 自动发言入队

[Net worker 线程]
   复用全局 tokio Runtime + reqwest Client（连接池 + TLS 复用）
   发送结果写回状态队列，供 UI 显示成功/失败

[Dart · 50 ms 轮询]
   一次取走结果队列全部条目
```

### 3.3 数据契约

```rust
struct Segment {
    id: u64,
    onset_ms: u64,           // 语音起点（绝对时间）
    pre_roll: Vec<f32>,      // 起点之前 150~300 ms（在起点快照）
    audio: Vec<f32>,         // 起点到段尾
    at: Instant,
}

enum SegmentEvent { Start { onset_ms: u64 }, Emit(Segment), Drop { reason: DropReason } }

enum AsrEvent { Interim { id: u64, text: String }, Final { id: u64, text: String } }

struct Stats { captured_ms: u64, dropped_samples: u64, queue_depth: u32,
               segments: u64, decoded: u64, decode_p50_ms: u32, decode_p95_ms: u32 }
```

C API 变更：

- **改**：`mutsurelay_poll_recording()` → `{recording, level, in_speech, error, stats, results:[{id, final, text}]}`
- **加**：`mutsurelay_reload_asr(model_dir, lang)`、`mutsurelay_set_segment_max_ms(u32)`、`mutsurelay_set_interim(i32)`、`mutsurelay_get_stats()`
- **删**：`mutsurelay_get_recognition_result`、`mutsurelay_get_audio_level`、`mutsurelay_set/get_memory_sensitivity`
- **语义**：`mutsurelay_send_message` 拆两个——`..._send_message`（同步，手动发送用）与 `..._enqueue_message`（入队即返回，自动模式用）

### 3.4 生命周期状态机

```
Idle ──start──> Arming ──ok──> Running ──stop──> Idle
                  └──err──> Error(msg) ──start──> Arming
```

- **线程常驻、stream 按需开关**：首次 start 创建线程与 recognizer，之后 stop 只 drop cpal stream + 清段状态，**不销毁线程、不卸载模型**。
- `reload` 是一次状态内事件，不中断录音：解码线程解码完队内剩余段后换 recognizer。
- 好处：彻底消除并发 pipeline、消除每次录音重载 240 MB、消除首次语音时的加载卡顿。

### 3.5 参数建议

| 参数 | 现在 | 建议 | 理由 |
|---|---|---|---|
| `MAX_SEGMENT_SAMPLES` | 30 s | **6~8 s** | 直接决定最坏出字延迟；配 pre-roll 后切段损失很小 |
| `VAD_MIN_SILENCE_FRAMES` | 15（450 ms） | **10（300 ms）** | 直播语速下 450 ms 停顿常被跨过，成段过慢 |
| 实时（interim） | 关闭 | **开启，节流 1.5 s** | 让界面 1.5~2 s 内先出半句；仅在解码队列为空时跑，避免抢 CPU |
| 段队列容量 | 无界 | **4** | 溢出丢最旧 + 计数，宁可丢也不堆延迟 |
| 去重窗口 | Rust 3 s + Dart 2 s | **1.5 s，单层** | 消除"复述同一句被吞" |
| 处理块 | 每 10 ms 一 chunk | **按需拉到 ≥40 ms 一次处理** | 减少锁与分配次数 |

---

## 四、分阶段实施

### Phase 0 · 基线测量（不改行为）
落地 `replay` 工具 + 测试音频 + `get_stats`。产出：CER 基线、首字延迟基线、解码耗时基线。
**没有这一步，后面的收益全是主观。**

### Phase 1 · 正确性止血（低风险，可先合）
B1 结果队列化 → B2 真 `restartAsr` → B3 生命周期 → B4 错误上报 → B9 单层去重。
判定标准：连推 2 段不再丢句；切语言立即生效；拔麦克风有明确报错。

### Phase 2 · 线程与内存（性能主干）
音频回调零分配 + SPSC ring → 解码线程独立 + 有界队列 → `seg_buf` 所有权转移替代 clone → ring 改定长环形 → B8 电平表。
判定标准：`decode_p95` 期间 `captured_ms` 不丢样；采集循环 p95 迭代 < 5 ms。

### Phase 3 · 精度
pre-roll 起点快照 → 抗混叠 + 相位连续重采样 → 单一能量域 + 平滑抑制 → 段长 6~8 s + 恢复 interim → 接缝合并 / B6-B7 censor 修正。
判定标准：`replay` 在固定音频集上 CER 下降且**可复现**。

### Phase 4 · 整洁与可测
拆模块（`lib.rs` 811 行 → `audio.rs` / `segmenter.rs` / `asr.rs` / `text.rs` / `api.rs`）+ 删 A 表全部死代码 + 抽纯函数单测。

### 模块目标结构

```
native/src/
  lib.rs          C API 薄层 + 全局装配（< 200 行）
  audio.rs        cpal 采集 + SPSC ring + 流式重采样
  segmenter.rs    帧特征 + 噪声门 + 分段状态机（纯逻辑，可单测）
  asr.rs          recognizer 生命周期 + 解码线程 + 批处理 + 统计
  text.rs         清洗 / 接缝合并 / 去重 / 分句 / 结果队列
  censor.rs       敏感词（保留，修 B6/B7）
  bilive.rs       直播接口（保留，Global Runtime + Client）
```

---

## 五、预期提升

> 全部为**量级估计**，需 Phase 0 基线确认。测量口径已在 3.3 的 `Stats` 里定义。

### 5.1 性能

| 指标 | 现状 | 预期 | 依据 |
|---|---|---|---|
| 采集线程单次迭代 p95 | 1.5~4 s（阻塞解码，且发生在帧循环内部） | **< 5 ms** | 解码移出 + 帧循环内不再 flush |
| 音频回调堆分配 | 每次回调 1 次 `Vec`（~100/s） | **0** | 预分配 scratch + SPSC ring |
| 采集累计延迟 | 随每个段叠加（越说越滞后） | **不累积**（有界队列，溢出丢最旧并计数） | 队列容量 4 |
| 首句识别延迟 | 0.8~3 s（240 MB 现场加载） | **≈ 0**（常驻 + 预热） | 生命周期改造 |
| 段尾→出字 | 典型 0.6~2 s；连续说话**最坏 ~30 s** | **典型 0.6~1.2 s；最坏 ≈ 8 s；interim ≤ 2 s** | 段长 6~8 s + interim |
| UI 卡顿（自动发言） | 每句一次 TLS 建连，占用 UI isolate | **不占 UI 线程；连接复用** | 全局 Runtime + Client + Net worker |
| CPU | 基线 | **持平 ~ +30%**（interim 开启时上浮） | 段变短带来少量编码开销；换来延迟与响应性 |
| 字幕写盘 | 每条整读整写 | 内存尾窗一次写 | B10 |

### 5.2 精度

| 项 | 影响 | 可验证性 |
|---|---|---|
| 结果队列化 | 消除**批处理 ≥2 段时的必然丢句**（当前是确定性丢失，不是精度） | 单测即可确认 |
| pre-roll 起点快照 | 句首弱音/数字/感叹词更完整；消除 30 s 强制切段处可能多出的字 | replay A/B |
| 抗混叠 + 相位连续 | 44.1 kHz 设备消除 8 kHz 以上折返、消除逐 chunk 取整造成的采样漂移 | replay（44.1k 素材） |
| 单一能量域 | 噪声门滑块行为单调可解释；减少小声说话被整段切掉的概率 | 真机 + 波形回放 |
| 段长 6~8 s + interim | 出字提前，部分纠正**上下文截断**导致的识别错误 | replay |
| 单层去重 + 接缝合并 | 减少"复述同一句被吞" | 交互验证 |
| censor B6/B7 | 同词跨上下文替换一致；去重生效后避免重复全扫描 | 单测 |

**必须说清的一点**：ASR 识别的绝对准确率主要由模型（SenseVoice int8 + greedy）决定，上面这些改动是**去掉自伤**（丢句、截断、混叠、错误门限），不是提升模型能力。预期 CER 改善幅度在**个位数相对百分比**，除非 Phase 0 实测出别的问题。

### 5.3 代码整洁

| 项 | 现状 | 目标 |
|---|---|---|
| `lib.rs` 行数 | 811，混合 C API / 采集 / 分段 / 解码 / 文本 / 配置 | 拆为 5 个模块，单文件 < 250 |
| 死代码 | ~110 行（A 表） | 0 |
| 语言配置源 | 2 处（`ASR_LANG` + `LANGUAGE`） | 1 处 |
| 分段逻辑可测性 | 无（埋在 300 行循环里） | 纯函数 + 8~12 个单测 |
| 测试 | censor + rms/resample（13 个） | 上述 + segmenter 单测 + replay 端到端 |
| 失败可观测性 | 无（`LAST_ERROR` 在录音链路从未写） | 错误 + 7 项统计计数器 |

---

## 六、P1 实施记录（已完成）

### 6.1 Rust：`native/src/lib.rs`

| 改动 | 具体内容 |
|---|---|
| 结果队列化 | `RECOGNITION_TEXT`（单槽覆盖）→ `RESULT_QUEUE: Mutex<VecDeque<Value>>`，上限 64、溢出丢最旧并计数。**修掉"一次 flush 含 2 段必丢 1 段"** |
| 线程 token | 新增 `RUN_TOKEN: AtomicU64`。启动时自增，线程持有自己的 token；不匹配即退出且**不再写任何输出**。修掉"停止后立刻重开会出现两个 pipeline 同时写结果" |
| 真·重启 ASR | 新增 `ASR_RELOAD_PENDING`。`_init_internal` 置位，录音线程在循环顶部丢弃旧 recognizer、重读模型路径，空闲时**立即预热**（顺带消除首句的 240MB 加载卡顿） |
| 失败上报 | `run_recording_pipeline` 由 `Option<()>` 改为 `Result<(), String>`；无设备 / 无输入格式 / 打不开流 / 音频流错误 全部写入 `PIPELINE_ERROR`（与 B 站接口的 `LAST_ERROR` **分开**，互不污染），由 poll 带出 |
| 统计计数器 | 新增 `Stats`（captured_chunks / dropped_chunks / segments / decoded / results / dropped_results / rejected_segments / decode_avg_ms / decode_max_ms / queue_depth），`mutsurelay_get_stats()` 导出 |
| 去重收单层 | Rust 侧窗口 3s → **1.5s**，且比较"去掉标点空白"后的文本（原来只差一个逗号就绕过去重）；Dart 侧 2s 去重删除 |
| 电平表平滑 | `max_energy`（逐 chunk 清零）→ `meter_peak` 跨 chunk 保留并按 0.85 弹道衰减 |
| 死代码 | 删除 `mutsurelay_get_audio_level`、`mutsurelay_get_recognition_result`、`mutsurelay_set/get_memory_sensitivity`、`_frame_count`、`_interim_frame` 及注释块 |

### 6.2 Rust：其他文件

- `bilive.rs`：删除 `MEMORY_SENSITIVITY` 静态量、`Config.memory_sensitivity` 字段、`default_memory_sensitivity`、
  `set/get_memory_sensitivity`，以及 `init_from_config` 里的调用。旧 `config.toml` 含该键仍能正常解析（serde 默认忽略未知键）。
- `vad.rs`：删除 `is_speech_active`、`NoiseEstimator`（与 lib.rs 内联阈值逻辑重复且常量不一致）、`INTERIM_INTERVAL`。
- `censor.rs`：
  - 词表结构改为 `Blocklist { words: Vec<Vec<char>>, by_first: HashMap<char, Vec<usize>> }`，
    **取消"词数 × 文本长度"全扫描**；测试同步改为经 `Blocklist::build` 构造。
  - **修 `dedup` 失效**：原来只按长度排序后 `dedup()`，相同词并不相邻 → 改用 `HashSet` 去重；
    排序键由字节长度改为**字符数**（混入 ASCII 时原来会排错）。
  - **替换规则改为逐片段**：2 字以内用全拼、更长用首字母，删掉"整句恰好等于 2 字屏蔽词"的整句特例。
    ⚠️ **这是用户可见的行为变更**：`"你个傻逼废物"` 这种相邻词会先被合并成一个 4 字 span → `sbfw`（与旧行为一致）；
    但 `"你个废物"` 现在得到 `你个feiwu`（旧为 `你个fw`）。同一词在任何上下文结果一致。
  - 测试：加串行锁修掉**并行污染**（共享全局 blocklist），新增 3 个用例（跨上下文一致性、首字索引、重复词）。
- `lib/ffi/native_bridge.dart`：删除上述已不存在符号的 typedef / 字段 / 绑定 / 方法；
  **未绑定 `mutsurelay_get_stats`**——避免日后回 Linux 侧用旧 `.so` 时因缺符号导致 `load()` 整体抛错（stats 已随 poll 返回）。
- `lib/providers/app_state.dart`：
  - poll 一次取走**整批** `results`（原来只取单条 `text`）；
  - 透出 `error` 并弹 toast；
  - **修"停止时丢失最后一句"**：停止后不再立刻取消轮询，留 60 tick（≈3s）宽限期收 native 侧 flush 出的尾段；
  - 删除 Dart 侧 2s 去重与 `memorySensitivity` 全链路。

### 6.3 验证结果

| 项 | 结果 |
|---|---|
| `cargo check --all-targets` | 通过，无警告 |
| `cargo test` | **18 passed / 0 failed**（原 13 个 → 18 个） |
| `cargo build`（debug） | 通过，DLL 15.9 MB |
| DLL 导出 ↔ Dart 绑定比对 | Dart 需要的 **39 个符号全部存在**；DLL 仅多出 `mutsurelay_get_stats`（有意未绑定） |
| DLL 同步 | 已复制到 `windows/mutsurelay_native/` 与 `build/windows/x64/runner/Debug/` |
| `flutter analyze` | **通过**（No issues found）——原判"无法执行"为误判，见"验证环境"一节 |

**尚未验证**：真机录音链路（需要跑起 Flutter 应用）。P1 的判据"连推 2 段不丢句 / 切语言立即生效 / 拔麦克风有报错"
目前只有静态与单测层面的支撑，需在能跑 Flutter 的环境上实测。

---

## 七、P2 实施记录（线程与内存）

### 7.1 线程模型：从"一根线程全包"到"四段解耦"

```
[cpal 回调线程·实时]  下混到预分配 scratch → AudioRing（无锁 SPSC，溢出丢最新+计数）
        ↓
[frontend 线程]      StreamResampler（抗混叠+相位连续）→ 30ms 分帧 → Segmenter → 有界段队列
        ↓
[decode 线程 · 常驻]  recognizer 常驻（reload 走 Ctl）→ 批量 decode → TextPipeline → 结果队列
        ↓
[net 线程 · 常驻]     全局 tokio Runtime + 复用 reqwest Client → 发送结果队列（节流 300ms）
```

- **`capture_owner`**：只持有 cpal stream 生命周期（创建与销毁必须同线程）。
  回调内**零堆分配**——下混写入 `Arc<AudioRing>`，不再 `to_vec()` + 无界 mpsc。
- **`frontend_loop`**：重采样 / 分帧 / 分段全在这里，从不动解码。
- **`decode_loop`**：常驻线程，recognizer 常驻，批处理 `BATCH_MAX = 4`，控制命令（`Ctl::Reload`）优先。
- **`net_loop`**：发送与 UI 完全解耦。

### 7.2 新增 `native/src/audio.rs`（505 行）

| 对象 | 要点 |
|---|---|
| `AudioRing` | 无锁 SPSC。`UnsafeCell<Box<[f32]>>` + `AtomicU64 head/tail`，acquire/release 配对；生产者只写 head 之后、消费者只读 tail 之前，无数据竞争。**溢出丢最新**并累计 `dropped`。 |
| `StreamResampler` | 抗混叠 FIR（Hamming 窗）+ **跨块相位连续**（f64 累加 `next_src`）。旧实现每 chunk 独立取整，44.1kHz 设备上会持续丢采样（漂移）；现在只保留亚样本相位。 |
| `rms` / `peak` | 供分段器与电平表共用。 |

单测：ring 回绕保持顺序、溢出丢最新且计数、48k→16k 精确整数比、44.1k 无漂移、
混叠带（>8kHz）抑制 >20 dB、通带（4kHz）保留。

### 7.3 有界队列与可观测性

- 段队列 `SEG_QUEUE_CAP = 4`（4 × 8s = 32s 极端积压上限），溢出**丢最旧**并计入 `dropped_segments`。
- 结果队列 `RESULT_QUEUE_MAX = 64`，同样丢最旧。
- 延迟用固定长度直方图 `LatencySampler`，给出 `decode_p50/p95/max` 与 `frontend_p95/max`。
- `frontend_iter_max_ms` 是 P2 的核心判据（旧实现这里是 1.5~4 s 的阻塞解码）。

### 7.4 发送侧（`bilive.rs`）

| 改动 | 内容 |
|---|---|
| Runtime 单例 | `runtime()` 改为 `&'static`，不再每次调用新建 tokio Runtime |
| Client 复用 | 全局 `http_client()`（连接池 + TLS 复用），替换全部 8 处 `reqwest::Client::new()` |
| 异步发送队列 | `enqueue_message()` 立即返回 job id；`net_loop` 独立线程发送，统一节流 300ms；结果写回 `SEND_RESULTS` |
| 字幕写盘 | 内存尾窗（`SUBTITLE_TAIL`，20 行）+ 定长 write，替代每条 `read_to_string` + 全文件重写 |

C API：新增 `mutsurelay_enqueue_message`（返回 i64 job id）、`mutsurelay_poll_send_results`。
`mutsurelay_send_message`（同步阻塞）保留在 Rust 侧作调试用，**Dart 绑定已删除**——
避免以后有人从 UI 线程调用它，把刚挪走的网络阻塞又装回去。

### 7.5 Dart 侧

- `app_state.dart`：自动发言与手动发送都改为 `enqueueMessage()` + `_drainSendResults()` 轮询回收
  （150ms 定时器，队列空了自动停，避免常驻空转）。**UI 线程不再等 HTTP 往返。**
- 新增 `NativeBridge` 绑定：`reloadAsr` / `setSegmentMaxMs` / `getSegmentMaxMs` /
  `setInterim` / `getInterim` / `enqueueMessage` / `pollSendResults` / `getStats` / `asrState` / `abiVersion`。

---

## 八、P3 实施记录（精度）

### 8.1 新增 `native/src/segmenter.rs`（802 行，取代 `vad.rs`）

状态机从 300 行循环里抽成**纯逻辑**，可单测。四项关键修正：

| # | 问题 | 改动 |
|---|---|---|
| 1 | pre-roll 取到的是**段后静音**（1.1 节） | 在 `begin_segment` 里、**把当前帧写入 pre-roll 缓冲之前**快照。所以 pre-roll 是真正的"起点之前"，且不会把起点那一帧重复算进段首 |
| 2 | 能量口径不统一（门限比原始、噪声底用降噪后） | 判决、噪声底、段能量统计**全部用原始能量**，与用户门限同口径。单测 `suppression_does_not_raise_effective_gate` 锁死这一点 |
| 3 | 三档增益整帧乘 0.3 压掉擦音/轻声 | 目标增益限制在 **0.6~1.0** 并对时间做一阶平滑；单测 `gain_is_smoothed_not_jumpy` |
| 4 | 强制切段的接缝没有上下文 | `seam_overlap_ms` 在 `begin_segment` 按 `last_close_end` **精确算出**（描述起点重叠，与"本段如何结束"无关——这是修掉的一个语义错误）；下一段的 pre-roll 天然接上一段尾巴 |

参数按 3.5 节建议落地：段长上限 **8 s**、静音判停 **300 ms**、preroll **300 ms**、最少语音 90 ms。

### 8.2 新增 `native/src/text.rs`（428 行）

`clean` / `chars_only` / `is_repetitive` / `split_sentence` / `trim_seam_overlap` / `TextPipeline` / `ResultQueue`。

- `TextPipeline::accept(raw, seam_overlap_ms, is_final)`：清洗 → 短/重复过滤 → **接缝去重（仅带 seam 标记的段）** → 全局去重（单层 1.5 s）。
- 单测覆盖：接缝去重只在有标记时生效、完全被包含时保留内容、去重窗口、分句、清洗。

### 8.3 interim 的真实语义（本轮修掉的一个缺陷）

P3 要求"开启 interim"。接线后暴露一个问题：interim 段走的是**同一条段队列**，
而 `decode_batch` 一律按正式段处理——于是半句会被写进字幕文件、并触发自动发言。

修法：`Segment` 增加 `interim: bool`；`interim_snapshot()` 置 true 且 id 用 `u64::MAX`；
`decode_batch` 分流——interim 只做清洗+敏感词，投递 `{"final": false, ...}` 给界面预览，
**不写字幕、不触发发言、不碰 `TextPipeline` 的去重状态**（否则半句会污染正式结果的去重窗口）。
Dart 侧据 `final` 字段把半句渲染到实时预览行，不进句列表。
单测 `interim_snapshot_is_flagged_and_never_final` 锁死。

### 8.4 新增 `native/tools/smoke_native.py`（474 行）

本机跑不了 Flutter，于是用 ctypes 直接加载 DLL 把 C API 全链路跑一遍，回答"改完还能不能用"：
导出符号 vs Dart 绑定比对 → ABI 版本比对 → init/poll/censor/设置项往返 → 录音链路
→ 快速起停 ×3（并发 pipeline 回归）。

---

## 九、P4 实施记录（整洁与可测）

### 9.1 模块拆分

| 文件 | 行数 | 职责 |
|---|---|---|
| `lib.rs` | 976 | C API 薄层 + 全局装配 + 采集会话（capture/frontend） |
| `audio.rs` | 505 | SPSC ring + 流式重采样 + rms/peak |
| `segmenter.rs` | 802 | 帧特征 + 噪声门 + 分段状态机（纯逻辑） |
| `asr.rs` | 607 | recognizer 生命周期 + 常驻解码线程 + 批处理 + 统计 |
| `text.rs` | 428 | 清洗 / 接缝合并 / 去重 / 分句 / 结果队列 |
| `censor.rs` | 291 | 敏感词（P1 已修 dedup 与逐 span 规则） |
| `bilive.rs` | 777 | 直播接口（Runtime/Client 单例 + 异步发送队列） |
| `examples/replay.rs` | 458 | 离线回放 + CER（A/B 验证用） |

`vad.rs` 已删除（其职责被 `segmenter.rs` + `audio.rs` 完全接管）。

> `lib.rs` 尚未压到规划里的 "< 200 行"：其中约 500 行是 40 个 `extern "C"` 函数体与
> JSON 组装，属于纯样板。若继续压缩，应把 C API 整体挪到 `api.rs`，而不是再切采集逻辑。

### 9.2 测试

| 范围 | 数量 |
|---|---|
| P1 结束时 | 18 |
| P2/P3/P4 后 | 58（+40：audio 6、segmenter 18、text 12、asr 4） |
| 复检后（第十节） | **59**（+1：`reload` 时序回归） |

新增覆盖：ring 回绕/溢出、重采样抗混叠与相位连续、pre-roll 起点快照语义、单一能量域、
增益平滑、强制切段接缝、interim 标记、接缝去重、结果队列溢出。

### 9.3 验证结果（本轮）

| 项 | 结果 |
|---|---|
| `cargo check --all-targets` | 通过，**无警告** |
| `cargo test` | **58 passed / 0 failed** |
| `cargo build`（debug） | 通过，DLL 15.4 MB |
| DLL 导出 ↔ Dart 绑定 | Dart 声明的 **48 个符号全部存在**（DLL 仅多出 Rust 自带 `bz_internal_error`） |
| ABI 版本比对 | dll=2 / dart=2 一致 |
| `smoke_native.py` | **39 PASS / 0 FAIL / 0 WARN** |
| 其中：`asr_state` | 后台 reload 后达到就绪(1) —— **240 MB 模型确实被常驻解码线程加载成功** |
| 其中：录音链路 | 抓到 USB PnP 麦克风（1ch 48kHz），4 s 内 `captured_chunks=436`，`dropped_samples=0`，电平峰值 0.30 |
| 其中：快速起停 ×3 | 最终回到停止态，无残留 pipeline |
| `flutter analyze` | **通过**（No issues found）；本轮复检时确认 SDK 可用 |

### 9.4 尚未验证 / 遗留

> **以下五项已在本轮（第十四节）逐条处理**，保留原文以便对照当时的判断：
> ①仍待真机实测；②**已完成**（§14.1 测试音频集 + CER 基线）；③**本机侧已完成**（§14.4：源码级
> ABI 校验 + 清理死符号链接；Linux 产物仍需在 Linux 上重建）；④**已完成**（§14.3 段长/ interim
> 接进设置界面并持久化）；⑤仍待实测（§14.1 只量了解码 RTF，未量 CPU 占用）。

1. **真机端到端录音识别**：需要能跑 Flutter 的环境。目前所有"精度提升"只有单测与代码级支撑。
2. **CER / 首字延迟实测**：`replay.rs` 已就绪，但**测试音频集没做**——没有它，5.2 节的精度预期仍是主观判断。
3. **`mutsurelay_abi_version` 的跨平台回归**：Linux 侧的 `.so` 必须重新构建，否则会因为版本不符被明确拒绝（这是设计意图，不是 bug）。
4. **`Segmenter` 段长参数没有 UI**：默认 8 s / interim 开，暂无界面开关。
5. **`interim` 的 CPU 占用未实测**：节流 1.5 s + 仅在段队列空时跑，但真实负载下的影响待测。

---

## 十、复检记录（第二轮 review）

对 P2/P3/P4 的产物做了一次完整复检，**又修掉 3 个问题、补强 1 个测试盲区**，并把仍存在但未改的问题明确列出。

### 10.1 已修

| # | 问题 | 位置 | 修法 |
|---|---|---|---|
| 1 | **4 个生成文件被清空**：`generated_plugin_registrant.cc`（linux/windows）、`generated_plugins.cmake`（linux/windows）里的 `flutter_acrylic` / `screen_retriever` / `tray_manager` / `url_launcher` / `window_manager` 注册**全部被删**。而 `pubspec.yaml` 与 `main.dart` 仍在用这些插件 —— 一旦提交，托盘、窗口管理、亚克力、外链会一起失效 | 工作区 | `git checkout` 还原为 HEAD 版本（生成文件，正确内容由 `flutter pub get` 决定） |
| 2 | **`reload` 的 READY 时序竞态**：`AsrEngine::reload` 只入队，LOAD_STATE 要等解码线程取走 Reload 才变。UI 每 200 ms 轮询 `asr_state`，若解码线程正忙于一条长段，UI 会读到**上一轮遗留的 READY**，从而提前谎报"ASR 已重启" | `asr.rs:337` | 在**调用方线程**先置 `LOAD_IDLE` 再入队；新增回归测试 `reload_clears_ready_state_before_returning` |
| 3 | **`dropped_results` 恒为 0**：`stats_json` 读的是 `Stats.dropped_results`，而这个字段从来没有被写入过（真正的计数在 `ResultQueue` 里）。P0 想要"可观测"，结果给了一个永远 0 的假数 | `lib.rs` / `asr.rs` | 改读 `q.dropped()`；删掉从未写入的 `Stats.dropped_results` 字段 |
| 4 | **冒烟测试的起停回归是假通过**：原断言只有"最终回到停止态"，而"第二轮起不来"（旧 stream 未 drop → 设备被占用 → `fail_session`）同样会回到停止态。现在改为**每轮都断言 `captured_chunks` 真的在增长**，并保留一轮 50 ms 的急速起停检验残留 | `native/tools/smoke_native.py` | 复检后 3 轮起停逐轮确认采到音频（338 → 479 chunks） |

### 10.2 复检确认无误的部分

- 环形缓冲的 SPSC 协议：`space = mask - (head - tail)`、Release/Acquire 配对、丢最新策略下 dropped 计数正确。
- 重采样器相位连续：块 N 的 `filt[0]` 与块 N-1 的 `filt[last]` 在绝对时间轴上恰好相差 1 个样本，无漂移（有 `resample_44100_stream_has_no_drift` 覆盖）。
- `seam_overlap_ms` 的语义（描述**起点**与上一段尾的重叠）与实际计算路径一致。
- 段队列与 ctl 共用一个锁：`try_pop_segment` 重入队时队列长度 ≤ cap-4+1，不会触发二次丢弃。
- interim 与正式段共用有界队列，但 `submit_interim` 前置了 `depth() == 0` 检查 —— 生产者只有 frontend 一个线程，因此 interim 不可能挤掉正在排队的正式段。
- Dart 绑定与 DLL 导出：48 个符号全部存在，ABI 两侧一致。

### 10.3 复检发现但**未改**（有意保留，供后续决策）

| 项 | 说明 | 建议 |
|---|---|---|
| `AudioRing::buffer(&self) -> &mut [f32]` | 两个线程各自从 `UnsafeCell` 构造出**覆盖整个缓冲区**的 `&mut [f32]`。字节区间不相交因而**不是数据竞争**，但按 Stacked/Tree Borrows 属于无效引用（LLVM 的 `noalias` 有理论优化风险）。这是 Rust 音频环的常见写法，实测 39 项冒烟全过 | 改成在构造时存裸指针（`Box::into_raw`）+ `ptr::copy_nonoverlapping`，彻底消掉这个 unsafe 假设。改动集中在 `audio.rs`，ring 的单测可覆盖 |
| 停止 → 快速重启会丢尾段 | 解码前的 `token` 校验会丢弃上一代的段。这是"防止旧音频污染新一轮"的有意代价，但意味着**停止后 ~1–3 s 内重启会丢掉最后一句** | 若在意，可让尾段带一个"允许跨代"标记 |
| `mutsurelay_send_message` | 导出还在，但 Dart 绑定已删、无任何调用方（真正的发送走 `enqueue_message` + net 线程） | 保留（属 ABI 表面）；若删则必须 +1 `ABI_VERSION` |
| `Ctl::Flush` / `AsrEngine::flush` | 只打一行日志，等价空操作 | 要么用它给 UI 一个"队列已清空"信号，要么删掉 |
| `TextPipeline::accept(.., is_final)` | 调用点恒传 `true`（interim 在更早处就分流了） | 删参数，或明确注释它只服务于将来的流式路径 |
| `Stats::frontend_iter_max_ms` / `StreamResampler::group_delay_samples` / `Segmenter::processed_ms` | 写入后从未被读 / 从未被调用 / 仅测试里出现 | 删除或接进 stats 输出 |

### 10.4 复检后的验证数据

| 项 | 结果 |
|---|---|
| `cargo check --all-targets` | 通过，无警告 |
| `cargo test` | **59 passed / 0 failed**（+1：reload 时序回归） |
| DLL 导出 ↔ Dart 绑定 | 48 个符号全部存在 |
| ABI 版本 | dll=2 / dart=2 |
| `smoke_native.py` | **40 PASS / 0 FAIL / 0 WARN**（新 DLL 重跑；录音链路 338–485 chunks、`dropped_samples=0`、电平峰值 0.32–0.71） |
| 其中：**3 轮起停每轮都重新采到音频** | `captured_chunks` 逐轮增长（338 → 479 → …）。**这条是本轮新加的断言**：原先只断言"最终回到停止态"，而"第二轮起不来"（旧 stream 未 drop → 设备被占用）同样会回到停止态，测试会假通过 |
| 其中：急速起停 ×3 | 最终回到停止态，`dropped_segments=0` 无残留 |
| `flutter analyze` | **通过**（No issues found）—— 修正 `unnecessary_non_null_assertion` 之后 |
| `flutter test` | **通过**（All tests passed）—— 注意需 `NO_PROXY=127.0.0.1,localhost` 绕开本机代理 |

> 环境备注：本机的 PowerShell 会话里 `rustc` 不在 PATH（`native/build.ps1` 2 秒即退且无输出）。
> 在本环境重建 DLL 请走 `cd native && cargo build`，再手动同步 `mutsurelay_native.{dll,pdb,lib}`
> 与 4 个依赖 DLL 到 `windows/mutsurelay_native/` 与 `build/windows/x64/runner/Debug/`。

---

## 十一、真机反馈修复（第三轮：用户实测报告）

用户在使用后报了 4 个问题，全部复现并定位到根因。其中 **问题 1 与问题 3 同源**。

### 11.1 识别慢 + 灵敏度调低后 CPU 飙升 —— 同一根因：interim 抢解码线程

**症状**：说一句话后要卡一下才出字；把"灵敏度"调灵敏（= 噪声门调低）后 CPU 飙升。

**根因**（两处叠加）：

1. `Segmenter::interim_snapshot` 把**整段** `seg_audio.clone()` 出去（最长 8 s），而不是一个固定窗口。
   于是每次 interim 的解码耗时**随句长线性增长**：说到 8 s 时，每 1.5 s 就要解一段 8 s 音频。
2. `DecodeQueue::pop` 按 **FIFO** 取段，而 interim 与正式段共用同一个队列、同一条解码线程。
   用户说完话时，正式段往往正好排在一个 interim 后面 → 必须等它解完才轮到正式段。

**灵敏度为何放大它**：噪声门调低 → 环境噪声也被判为语音 → `in_speech` 长期为真 →
`current_segment_ms() >= 1500` 恒成立 → interim **每 1.5 s 跑一次且从不停止**，
每次还是接近 8 s 的音频，CPU 于是被吃满。

**修法**：

| 改动 | 位置 |
|---|---|
| interim 只取**尾部窗口**（`DEFAULT_INTERIM_WINDOW_MS = 3000`），解码成本封顶 | `segmenter.rs`：`interim_snapshot` + 新配置项 `interim_window_samples` |
| 出队**正式段优先**（`pop_prefer_final`），interim 绝不挡在正式段前面 | `asr.rs`：`pop` / `try_pop_segment` |
| 批处理只合并"同代际 **且** 同 interim 属性"的段，不把半句与正式段混一批 | `asr.rs`：`decode_loop` |

回归测试：`interim_snapshot_is_capped_to_tail_window`、`final_segment_is_popped_before_interim`。

### 11.2 敏感词要首字母缩写，不要全拼

**症状**：`妈的` → `made`，期望 `md`。

**根因**：`censor.rs` 对**≤2 字的命中片段**走 `to_full_pinyin`（全拼），3 字以上才走首字母。
这条"2 字全拼"规则既与 `AGENTS.md` 的约定（Mode 2 → pinyin initials）不符，
也让同一个词按长度出现两套风格。

**修法**：mode 2 **一律** `to_initials`；删掉 `to_full_pinyin` 死函数。
于是 `妈的` → `md`、`傻逼` → `sb`、`弱智` → `rz`、`操你妈` → `cnm`。

回归测试：`test_initials_two_char`（"妈的" → "md"）、`test_partial_replacement_keeps_context`。

### 11.3 内存 500 MB —— 量化后定位为模型常驻

用 `native/tools/mem_probe.py`（ctypes 加载 DLL，逐步量 RSS）实测：

| 阶段 | RSS | 增量 |
|---|---|---|
| 进程基线 | 21.9 MB | — |
| 加载 DLL | 24.3 MB | +2.4 |
| 起解码线程 + 环形缓冲（**不含模型**） | 26.9 MB | +2.6 |
| **加载 ASR 模型后** | **325.1 MB** | **+298.2** |
| **卸载模型后** | **49.4 MB** | **−275.7** |

- 模型文件 228 MB，onnxruntime 加载后占 **298 MB**；加载耗时 **997 ms**。
- **卸载后内存确实归还给 OS**（残留仅 +22.5 MB）→ 说明"空闲卸载"方案可行。
- 用户看到的 500 MB ≈ 这 298 MB + Flutter 运行时（引擎 + Dart VM ≈ 200 MB）。**不是泄漏。**

**修法**：新增**空闲卸载**（不增删导出符号，故 ABI 保持 2）：

- `mutsurelay_stop_recording` 起一个一次性计时线程，`IDLE_UNLOAD_DELAY = 90 s`。
- 到期核对三件事，任一不满足即取消：仍在录音 / 会话代际（`RUN_TOKEN`）变了 /
  期间有人主动重建过 ASR（新增 `RELOAD_GEN`）。
- 通过则 `AsrEngine::unload()` → `reload("")` → `create_recognizer` 返回 `None` → 旧 recognizer 被 drop。
- 解码线程把"空目录"记为 `LOAD_IDLE`（**不是** `LOAD_FAILED`，这不是错误）。
- `mutsurelay_start_recording` 若发现状态非 READY，会**立刻后台重建**，让这 ~1 s 与用户开口的时间重叠。

> 第三项检查（`RELOAD_GEN`）是必需的：否则用户刚点完"重启 ASR"、卸载线程紧接着把模型丢掉，会静默失效。

### 11.4 本轮验证

| 项 | 结果 |
|---|---|
| `cargo check --all-targets` | 通过，无警告 |
| `cargo test` | **61 passed / 0 failed**（原 58 → +3） |
| `smoke_native.py` | **40 PASS / 0 FAIL / 0 WARN**，其中 `censor mode 2` 断言已变为 `你这个fw`（首字母生效） |
| ABI | dll=2 / dart=2（本轮**未增删导出符号**，故不 +1） |
| 录音链路 | 3 s 采到 336 chunks、`dropped_samples=0`；3 轮起停累计 471 chunks，每轮都在涨 |

### 11.5 仍待确认的取舍

- interim 窗口取 **3 s**：预览只覆盖"最近在说的一句"。若嫌预览太短可调大
  （`DEFAULT_INTERIM_WINDOW_MS`），代价是每次 interim 解码变慢。
- 空闲卸载阈值 **90 s**：直播中一直在录则永不触发；若希望"不录音就尽快释放"，
  可调小该常量，或改成"启动时根本不预加载"（代价是每次录音第一句前多等约 1 s）。
- 应用**启动时仍会预加载**模型（保证随时开录都快），所以刚打开时仍是 ~500 MB，
  90 s 无录音后才回落。

---

## 十二、真机反馈修复（第四轮：重建风暴 · 电平口径）

用户对照旧版本给了新的实测数据：**旧版 <1% CPU / 约 370 MB / 灵敏度正常**；
新版**没开录音、只调了一下灵敏度**，CPU 就 10%+，过一会才消停；同时"出字还是很慢，
而且不符合直觉：明明音量电平对比这么大却没有输出"。附带日志证据：

```text
[06:58:37] ASR reloaded (dir=asr/model, lang=zh, ok=true, 1412ms)
[06:58:39] ASR reloaded (... 1424ms)
[06:58:40] ASR reloaded (... 1474ms)
... 10 秒内共 8 次 ...
[06:58:49] ASR reloaded (... 1487ms)
```

**这段日志就是全部答案**：那 10 秒里解码线程一直在重新加载 229 MB 的模型。

### 12.1 根因 A：调一个滑块 = 反复重建 recognizer

调用链（每一环单看都"没错"，串起来是灾难）：

```text
Slider.onChanged（拖动时每帧一次）
  → AppState.setNoiseGateFromSlider
    → saveSettings()                     ← 每次拖动都写配置 + 走一遍设置同步
      → NativeBridge.setAsrLang(_asrLang)  ← 语言没变也照调
        → mutsurelay_set_asr_lang
          → trigger_reload()             ← 无条件重建
            → Ctl::Reload → 解码线程 create_recognizer() ≈ 2.0~2.2 s（本机实测）
```

为什么日志不是"一次拖动一次"、而是**稳定的每 ≈1.4 s 一次**：一次重建要 2 s，
比拖动期间两次 `onChanged` 的间隔长得多；等这次重建完成、`PENDING` 记号被清掉之后，
紧接着来的那一拍又会被当成新请求重新发起。于是稳态频率 ≈ 1 个重建周期一次，
与日志（10 s / 8 次）完全自洽。

**为什么表现为"不出字"**：`Ctl` 是控制命令，在队列里**优先于音频段**出队；
重建期间解码线程 100% 在加载模型，段队列（容量 4）只进不出、溢出丢最旧。
用户说话时电平表照常跳动（它由 front-end 线程驱动，与解码无关），
但那段音频很可能已经被丢掉了 —— 这就是"电平这么大却没输出"。

### 12.2 修法：三道闸 + 显式强制

| 闸 | 位置 | 作用 |
|---|---|---|
| ① 幂等 | `lib.rs: mutsurelay_set_asr_lang` | 语言没变直接 return，不进重建路径 |
| ② 在途合并 | `asr.rs: ReloadDedup` + `mark_reload_requested` | 同一目标已入队 → 合并（一次拖动只会落地一次重建） |
| ③ 已装载短路 | `asr.rs: LOADED_TARGET` + `is_loaded` | `READY` 且装的正是这个目标 → 什么都不做 |
| 强制通道 | `AsrEngine::reload_forced` | 只有"用户点重启 ASR""模型下载完成"走它（文件可能已变） |

- 闸 ③ 的 `loaded` 状态由解码线程写回，**只有真的建出 recognizer 才算命中**
  （`recognizer.is_some()`）；加载失败或空闲卸载后写回 `None`，
  否则同目标的请求会被永远跳过 —— 表现成"点了重启 ASR 毫无反应"。
- Dart 侧配套：`setNoiseGateFromSlider` 不再 `saveSettings()`，改由 `Slider.onChangeEnd`
  持久化；拖动过程只改 native 的原子量。
- 可观测性：stats 新增 `asr_reloads` / `asr_reload_skipped`。**调参时前者必须不涨**。

顺带修掉一个启动期的同类问题：应用启动会连着请求两次相同目标
（`init_asr` 之后 `loadSettings() → mutsurelay_load_config`），旧代码会**真的装两遍**
（2 × 2 s、峰值 2 × 298 MB）。现在被闸 ③ 短路。

### 12.3 根因 B：重建瞬间新旧两份模型同时在世

```rust
recognizer = create_recognizer(&model_dir, &lang);   // 旧 session 在新 session 建好之后才 drop
```
`Option` 赋值是"先算右边、再析构左边"，于是重建瞬间 RSS 峰值 = 2 × 298 MB。
改为 `drop(recognizer.take())` 后再创建。

### 12.4 根因 C：电平表与噪声门不是一个能量口径

| | 用的量 | 界面位置 |
|---|---|---|
| 电平条 | **峰值** × 10 | `mic_button.dart: level * width` |
| 门限标线 | `gate * 10` | `mic_button.dart: gateX` |
| **判决** | **RMS** ≥ `gate` | `segmenter.rs: push_frame` |

同一段话的峰值通常比 RMS 高 3~4 倍。于是一段人耳觉得"很响"、但 RMS 低于门限的音频，
电平条能打到 1.0（远在门线之上）而 VAD **永不进入语音态** → 一个字都不出。
用户的原话"明明音量电平对比这么大为什么没有输出"就是这个。

**修法**：电平表改用**原始 RMS** × 10（保留快启慢落弹道），与门线、与判决同口径。
回归测试 `meter_uses_the_same_energy_domain_as_gate` 用一帧稀疏尖峰
（峰值 0.5 / RMS 0.046 < gate 0.05）把这件事钉死：旧口径打满 1.0，新口径 0.46，
落在门线之下 —— 与"没出字"的结论一致。

### 12.5 解码耗时实测：推翻第三轮的假设

新增 `native/examples/bench_decode.rs`（合成类语音音频，模型 228 MB，debug 产物）：

| 音频时长 | 解码中位 | x 实时 | | 批量 | 总耗时 | 摊薄 |
|---|---|---|---|---|---|---|
| 0.5 s | 32 ms | 15.6× | | 1 s × 1 | 36 ms | 36 ms |
| 1 s | 43 ms | 23.3× | | 1 s × 4 | 93 ms | 23 ms |
| 1.5 s | 49 ms | 30.6× | | 3 s × 1 | 68 ms | 68 ms |
| 2 s | 58 ms | 34.5× | | 3 s × 4 | 225 ms | 56 ms |
| 3 s | 73 ms | 41.1× | | | | |
| 4 s | 82 ms | 48.8× | | | | |
| 8 s | 158 ms | 50.6× | | | | |

**结论：解码从来不是瓶颈**（3 s 音频 73 ms）。第三轮把"卡一下才出字"归因于
"interim 送整段导致解码耗时线性增长"，方向对（interim 确实占解码线程）但**量级估错了**
—— 3 s 的 interim 只值 73 ms，不足以解释"很久才出字"。真正的量级来源是**重建堵死解码线程**。
尾部窗口的改动本身无害，保留；但以后碰到"出字慢"应当先看 `asr_reloads` 与
`dropped_segments`，而不是继续压解码耗时。

### 12.6 本轮验证

| 项 | 结果 |
|---|---|
| `cargo check --all-targets` | 通过，无警告 |
| `cargo test` | **65 passed / 0 failed**（64 → +1，本轮共 +4 条新测试） |
| `smoke_native.py` | **44 PASS / 0 FAIL / 0 WARN**，新增 `[6c] 重建去重` 全绿 |
| `flutter analyze` | No issues found |
| ABI | dll=2 / dart=2（**未增删导出符号**，只加了 Stats 字段，故不 +1） |
| 录音链路 | 3 s 采到 336 chunks、`dropped_samples=0`；3 轮起停累计 472 chunks，每轮都在涨 |

新增回归测试：

- `asr::duplicate_reload_requests_are_coalesced`（50 次同目标 → 只放行 1 次）
- `asr::stale_reload_done_does_not_clear_newer_request`（迟到的 done 不能误清新请求）
- `asr::loaded_target_matching_is_strict`（`None` 永不命中，否则失败后不再加载）
- `segmenter::meter_uses_the_same_energy_domain_as_gate`
- `smoke_native.py [6c]`：30 次同值设置不重建 / 启动路径重复请求被短路 / 换语言只重建一次

### 12.7 仍待确认的取舍（第三轮遗留 + 本轮新增）

- 空闲卸载阈值 **90 s**：调小会更快省内存，但每次开录前要多等约 2 s（模型加载实测 2.0~2.2 s）。
- 启动仍预加载 → 刚打开约 500 MB；若要"打开就轻"，可改成完全惰性加载，代价是首句慢 2 s。
- interim 窗口 **3 s**：实测只值 73 ms，可放心保留；间隔 1.5 s 的 CPU 代价约 5%（仅在持续说话时）。

> 以上三条在第四轮已全部落定：卸载阈值 90 s → **60 s**、启动**不再预加载**、
> interim 间隔 1.5 s → **0.8 s**。见第十三节。

## 十三、真机反馈修复（第四轮：关闭卡顿 / 内存 / 双击复制 / 出字延迟）

用户报了 4 项，逐条定位到根因。**其中 4 号（出字延迟）与第三轮的判断不同源**，
是这一轮才找到的真正机制。

### 13.1 关闭窗口"卡住一下才消失"

**根因链**（不是 native 慢，也不是托盘慢）：

1. `windowManager.destroy()` 在 Windows 上**只是 `PostQuitMessage(0)`**
   （`window_manager.cpp` → `WindowManager::Destroy`），它**不销毁窗口**。
2. 窗口要等整个进程收尾走完才会被销毁：消息循环退出 → Flutter engine 关闭并 join
   各渲染/栅格线程 → 各插件 DLL detach → 还有约 300 MB 的 onnxruntime session 要回收。
3. 这段时间里窗口仍挂在屏幕上、但已经不再重绘 —— 用户看到的就是
   **"点了关闭，先卡住一下，然后才消失"**。
4. 附带发现：`setPreventClose` **从未被调用过**，所以 `app.dart` 里的
   `onWindowClose` 一直是**死代码**；Alt+F4 会直接销毁窗口 → 既不经过 native 的
   停止录音，也不删托盘图标（通知区留下"幽灵图标"）。

**修法**：新增 `lib/app_lifecycle.dart: quitApp()`，顺序有意设计为
`hide()` + `setSkipTaskbar(true)` → `NativeBridge.shutdown()` → 删托盘图标 → `destroy()`。
**先让窗口从屏幕上消失，再收尾**，那一段收尾时间就从用户视野里彻底消失了。
三个调用点（顶栏关闭按钮、托盘菜单"退出"、`onWindowClose`）统一走它；
启动时补上 `setPreventClose(true)`，让 Alt+F4 也走同一条路径。

### 13.2 内存 500 MB → 约 200 MB（懒加载）

约 300 MB 是常驻 recognizer（模型文件 228 MB → 加载后 RSS +298 MB）。
旧实现在**启动路径**上就会加载：`init_asr` / `load_config` / `set_asr_lang`
各自都会 `trigger_reload()`，而这三个接口在应用启动时会被连着调好几次 ——
于是"打开就占 500 MB"，而多数时间根本没在录音。

**修法**：新增 `trigger_reload_if_loaded()`（只有**已经装着**才重建），
启动路径改用它；真正的加载入口收敛到 `mutsurelay_start_recording`（首次开录，
与用户开口的时间重叠）。空闲卸载阈值 90 s → **60 s**。

**结果**：只是开着界面 ≈ 200 MB（Flutter 运行时本身 + DLL），录音期间仍是 ~500 MB，
停录 60 s 后回落到 ~200 MB。

### 13.3 双击文字复制到剪贴板

`message_list.dart` 新增 `_copyable()`：`GestureDetector(onDoubleTap)` +
`Tooltip('双击复制')`，套在**消息列表文本**与**实时预览**上，迷你窗口同样生效。
复制的是**完整原文** —— 列表 `maxLines: 2` 会截断显示，双击拿到的仍是整句。
`Tooltip` 显式设 `triggerMode: longPress`：桌面上悬停照样出提示，但轻点不会弹
（轻点是"双击复制"的前半截）。

### 13.4 "实时停了、电平也降了，却迟迟不出字" —— 判停口径错了

**症状**：实时预览停住不再出新字、电平已经降下去，但正式结果要等很久才出来，
而且**时快时慢**。

**根因**：退出语音态的门限是 `gate * VAD_HYSTERESIS = gate*0.5`。
房间底噪常常正好落在 `(gate*0.5, gate)` 区间 —— 高于退出线、低于进入线。
此时：

- `in_speech` 保持为真 → 实时预览停在最后那句话上（没有新字）；
- 电平表已经衰减回底噪（用户看到"电平降了"）；
- `silence_frames` **永远不累加** → 静音判停永不触发 → 段只能等
  `max_segment_samples`（默认 **8 s**）强制切段才能出字。

三个现象被一次解释干净。"时快时慢"则取决于那一刻的底噪是否恰好低于 `gate*0.5`。

**注意 `max_silence_frames` 在这里帮不上忙**（这是很容易看错的一点）：它要求
`silence_frames` 先累加，而累加的前提正是"判不出静音"这件事本身；并且当
`long_enough` 为真时它根本不参与判决。

**修法**：退出判停改用**段起点处的噪声底**做参照，而不是用户门限的固定比例：

```text
exit_threshold = max(gate * VAD_HYSTERESIS, seg_noise_floor * VAD_EXIT_NOISE_RATIO)
```

- 只在"起点电平 > 噪声底 × 3"时启用；否则退回 `gate*HYSTERESIS`。
  门限被压到低于底噪属于**设置问题**，不该由自适应逻辑去猜（否则会把整段判成静音、
  把段切碎）。
- 噪声底取**本帧 EMA 更新之前**的值：语音起点自己的能量若被算进噪声底，会把退出
  门限抬得过高，等于把刚修好的问题换个方式又引回来。

**效果**：停嘴后 300 ms（`min_silence`）收段 + 解码 ~73 ms + Dart 轮询 50 ms
≈ **0.45 s 出字**，且与门限松紧、底噪高低解耦。

### 13.5 本轮验证

| 项 | 结果 |
|---|---|
| `cargo check --all-targets` | 通过，无警告 |
| `cargo test` | **67 passed / 0 failed**（65 → +2） |
| `smoke_native.py` | **51 PASS / 0 FAIL / 0 WARN**，新增 `[6d] 懒加载与空闲卸载` 全绿 |
| `flutter analyze` | No issues found |
| `flutter test` | 通过（新增双击复制的 widget 测试） |
| ABI | dll=2 / dart=2（**未增删导出符号**） |
| 录音链路 | 3 s 采到 481 chunks、`dropped_samples=0`；3 轮起停累计 618 chunks |

新增回归测试：

- `segmenter::segment_closes_when_noise_sits_above_half_gate` —— 底噪落在
  `(gate*0.5, gate)` 时必须在 300 ms 判停收段（旧口径要等 8 s）
- `segmenter::adaptive_exit_is_disabled_when_gate_is_below_noise` —— 门限低于底噪时
  不得启用自适应判停
- `smoke_native.py [3]`：启动路径不预加载模型（`asr_state == 0`）
- `smoke_native.py [6d]`：空目录 = 卸载且状态回 IDLE(0) 而非 FAILED(-1) /
  未录音时同目标空转不重建 / 开始录音时自动加载且只加载一次
- `test/message_list_copy_test.dart`：双击复制完整原文，单击不触发

### 13.6 取舍（本轮已定，前几轮的遗留项一并结清）

- 空闲卸载阈值 **60 s**（原 90 s）。调更小更省内存，代价是每次开录前多等约 1~2 s
  模型加载；那段时间与"用户刚点下录音、还没开口"重叠，段队列容量 4 足以容纳。
- **启动不再预加载**：只是开着界面 ≈ 200 MB；首句延迟转移到"点录音之后"，
  由 `start_recording` 的后台加载覆盖。
- interim 间隔 **0.8 s**、窗口 **3 s**（实测解码 73 ms，CPU 代价约 5%，且仅在持续说话时）。
- 关闭窗口：**先隐藏再收尾**，不再试图让进程"秒退"（进程收尾本身仍要几百毫秒，
  只是用户看不见了）。

---

## 十四、第五轮：清账 + 测试音频集 + 参数接界面

本轮把 §9.4 与 §10.3 挂着的账一次结清，并把"精度只能靠耳朵听"变成可复现的数字。
**本轮没有增删任何 `mutsurelay_*` 导出符号，ABI 保持 2**（只新增了 `Stats` 里一个字段的输出）。

### 14.1 测试音频集 + CER 基线（P0 的最后一块）

`replay.rs` 早就就绪，缺的只是音频集。现在补上，且**全流程可复现**：

| 组件 | 文件 | 说明 |
|---|---|---|
| 参考文本 | `testdata/asr/ref/*.txt` | 6 段中文，逐行一句；入库 |
| TTS 合成 | `native/tools/make_test_audio.ps1` | Windows SAPI（zh-CN），逐行合成 16 kHz 单声道 WAV |
| 拼装 + 噪声 | `native/tools/build_test_audio.py` | 句间静音 / 增益 / 风扇+键盘噪声，固定随机种子（默认 20260918） |
| 基线 | `native/tools/cer_baseline.py` → `docs/asr-baseline.md` | 10 个片段：CER / 段数 / 解码 p50-p95 / RTF |

**为什么逐行合成**：TTS 在句号处的停顿只有几百毫秒且不可控，而"长停顿能否判停"正是分段器的
关键用例。逐行合成 + 可控句间静音（0.15 / 0.45 / 0.9 / 1.5 s）才测得出来。
音频本体（约 6.6 分钟）不入库，`.gitignore` 掉 `testdata/asr/{parts,wav}/`。

**基线数字**（2026-10-05，debug 产物，音频合计 397.8 s，开关 denoise=on/preroll=on/seg_max=8000）：

| 片段 | CER | 段数 | 解码 p50 | RTF |
|---|---|---|---|---|
| 01_continuous（句间 0.15 s） | 2.74% | 19 | 48 ms | 0.016 |
| 02_pauses（句间 1.5 s） | 2.52% | 15 | 40 ms | 0.013 |
| 03_reading | 1.47% | 13 | 47 ms | 0.016 |
| 04_sensitive（含屏蔽词） | 0.00% | 12 | 47 ms | 0.016 |
| 05_fast（rate +6） | 3.03% | 4 | 45 ms | 0.015 |
| 06_slow（rate −4） | 3.12% | 6 | 60 ms | 0.012 |
| **07_quiet（−12 dB）** | **10.29%** | 17 | 37 ms | 0.017 |
| 08_loud（+6 dB，709 样本削顶） | 1.47% | 13 | 47 ms | 0.016 |
| 09_noisy（SNR 18 dB） | 2.52% | 13 | 53 ms | 0.016 |
| 10_very_noisy（SNR 10 dB） | 4.20% | 13 | 59 ms | 0.016 |
| **平均** | **3.14%** | 125 | — | ≈0.015 |

三条结论：

1. **解码依然不是瓶颈**：RTF 0.012~0.017（≈60~80× 实时），与 §12.5 的 bench 结论一致。
   以后遇到"出字慢"，查 `asr_reloads` / `dropped_segments` / 分段判停，别再压解码耗时。
2. **小声说话是真正的短板**：同一段音频、同一份参考文本，−12 dB 之后 CER 从 1.47% 涨到
   **10.29%**。这不是模型能力问题，而是"输入电平低 → 端到端整体劣化"。
   若要继续压 CER，该动的是**电平归一化 / 自动增益**，而不是继续调门限 ——
   门限只能决定"切不切"，补不了电平。
3. **噪声下退化温和**：SNR 10 dB 才 4.20%，且 09/10 分别只有 1 段 / 0 段被判丢。

> 绝对 CER 只是"这台机器 + 这份 TTS 音频集"的刻度，**不是**真实人声准确率；
> 但同一份音频集上的前后对比有效 —— 这才是它的用途。

### 14.2 清掉 §10.3 的六项技术债

| 项 | 处理 |
|---|---|
| `AudioRing::buffer() -> &mut [f32]` 的别名假设 | **改为裸指针**：`Box::into_raw` 持有 + `ptr::copy_nonoverlapping` 读写 + `Drop` 还原成 `Box`。两个线程不再各自构造覆盖整块的 `&mut [f32]`，Stacked/Tree Borrows 下的无效引用消失；代价是显式写 `unsafe impl Send/Sync`（安全性依赖原有的 head/tail 协议，注释里写清了） |
| `Ctl::Flush` 只打一行日志 | **删除**：`Ctl` 变体、`AsrEngine::flush`、解码线程的处理分支、`lib.rs` 的调用点全部移除。收尾路径本来就靠 `segmenter.flush` → `submit_segment` 把尾段交出去，不依赖这个空操作 |
| `TextPipeline::accept(.., is_final)` 恒传 `true` | **删掉参数**，函数默认即 final 语义，并在文档注释里写明"interim 在 `decode_batch` 更早就分流了，绝不能进这里污染去重窗口"。原 `interim_does_not_touch_dedup_state` 测试改为 `final_stage_dedups_within_window` |
| `Stats::frontend_iter_max_ms` 写后不读 | **接进 stats 输出**（`frontend_iter_max_ms`），它正是 P2 的核心判据 |
| `StreamResampler::group_delay_samples` 从未被调用 | 删除 |
| `Segmenter::processed_ms` 只出现在测试里 | 删除（`reset` 的断言已由 `current_segment_ms()==0` 与 `!in_speech()` 覆盖；内部仍用 `processed_samples` 算 onset） |

**有意保留的两项**（§10.3 当时也这么判断，本轮复核后维持）：

- `mutsurelay_send_message`：导出仍在、Dart 不绑定。留着是为了不因为一个死符号动 ABI 版本；
  真正的发送路径是 `enqueue_message` + net 线程。
- 停止 → 1~3 s 内重启会丢上一代尾段：这是"防止旧音频污染新一轮"的有意代价。要改就得给尾段加
  "允许跨代"标记，收益小、风险实在，暂不动。

### 14.3 段长上限 / interim / 运行统计接进设置界面

三样东西 Rust 侧与 Dart 绑定**一直都有**，只是从没接过界面（§9.4 #4）。本轮接上，并补了持久化：

| 改动 | 位置 |
|---|---|
| `config.toml` 新增 `segment_max_ms`（默认 8000）与 `interim`（默认 true），serde 默认值兼容旧配置 | `bilive.rs:Config` |
| `save_config` / `load_config` 读写这两个静态量；**load 路径刻意不触发重建**（它们不影响 recognizer） | `lib.rs` |
| 设置界面新增「单段上限」（4/6/8/12 s）与「实时预览」（开/关）两行 | `settings_modal.dart` |
| 「运行统计」面板：`asr_reloads(省 skipped)` / `dropped_segments` / `dropped_samples` / `decode_p50_ms` / `seg_queue_depth` / `frontend_iter_max_ms` | 同上 + `app_state.dart:refreshStats()` |
| 统计只在设置面板打开期间用 1 s 定时器刷新，关掉即取消（不留常驻定时器） | `app_state.dart:showSettings` |

一个容易踩的坑：**改段长/ interim 不能置 `_asrSettingsDirty`**。那个标志位的唯一作用是"关设置窗时
重载 recognizer"，而重载一次 = 229 MB 模型 + 解码线程停摆 ≈ 2 s。段长只影响后续分段，
所以这两个 setter 只写静态量 + 存配置。

### 14.4 Linux 侧：本机能做的部分

本机没有可用的 WSL 发行版，Linux 产物**无法**在这里重建。能做的都做了：

- **新增源码级 ABI 一致性校验** `native/tools/check_abi.py`：解析 `lib.rs:ABI_VERSION` 与
  `native_bridge.dart:expectedAbiVersion` 并断言相等（不需要编译产物、不需要 DLL），
  当前 `2 / 2 一致`。这是"双系统拿错产物 → 静默退回 mock"的第一道闸。
- **清掉仓库根的死符号链接** `libmutsurelay_native.so`：它指向旧工程
  `/home/para/ntfs/F/para/Code/mutsurelay_flutter/...`，在 Windows 上是断链，在 Linux 上也指错
  项目（真正该用的是 `native/target/{debug,release}/libmutsurelay_native.so`，而
  `_defaultLibraryPath()` 的候选列表里本来就有这两条）。它没有被 git 跟踪（`.gitignore` 里 `*.so`）。
- **仍需在 Linux 上做的**：`bash native/build.sh` 重建 `.so`（ABI=2）。在重建之前，
  Linux 侧跑新绑定会明确报"ABI 不符，请在本平台重新构建" —— 这是设计意图，不是 bug。

### 14.5 本轮验证

| 项 | 结果 |
|---|---|
| `cargo check --all-targets` | 通过，无警告 |
| `cargo test` | **67 passed / 0 failed**（删除/改名各一，总数不变） |
| `check_abi.py` | dll=2 / dart=2 一致 |
| `smoke_native.py` | **55 PASS / 0 FAIL / 0 WARN**（+4：段长上限区间、save 返回 0、段长/interim 往返、还原原设置） |
| `cer_baseline.py` | 10 片段 / 397.8 s / **平均 CER 3.14%**，详见 `docs/asr-baseline.md` |
| `flutter analyze` | No issues found |
| `flutter test` | 2 passed（双击复制 + 主界面渲染） |
| 录音链路（冒烟内） | 3 s 采到 456 chunks、`dropped_samples=0`；3 轮起停累计 597 chunks |
| ABI | dll=2 / dart=2（本轮未增删导出符号） |

### 14.6 仍未完成（明确留给下一轮）

1. **真机端到端**：段长/ interim/ 统计现在有界面了，但"改了之后真机感受如何"必须由用户实测
   （尤其 4 s 段长对延迟的改善、以及 `asr_reloads` 在拖动滑块时是否真的不涨）。
2. **interim 的 CPU 占用**：本轮只量了解码 RTF（0.012~0.017），没有量进程 CPU%。
3. **小声说话（07_quiet 10.29%）**：这是当前 CER 的最大来源，方向应该是输入侧电平归一化。
4. **Linux `.so` 重建 + 真机验证**（需 Linux 环境）。
5. **CI**：**已启用并跑通**。记录一下过程，因为第一次并不是全绿：
   - 改名 `build.yml.disabled` → `build.yml`，顺手修掉 ubuntu-24.04 上已失效的 apt 包名
     （`fuse` / `locate`）——两者其实都不需要；analyze job 增加 `check_abi.py`。
   - **run #15**：analyze 绿、build-windows 绿（Inno Setup 改绝对路径调用后通过），
     **build-linux 红在 `Create AppImage`**。对比历史：2026-06-02 与 2026-09-18 两次失败
     也在 Linux 打包这一步 —— 是接手前就存在的问题。
   - 根因：CI 走的是 `dart run fastforge:main package --platform linux --targets appimage`，
     而仓库本地一直用 `tool/package.dart`（手工拼 AppRun/.desktop/icon → 直接调 appimagetool，
     靠 `APPIMAGE_EXTRACT_AND_RUN=1` 绕开 FUSE）。同一份代码本地能出包、CI 不能，
     差别就在这条路径上。
   - 改法：Linux 打包步骤直接调 `dart run tool/package.dart`，CI 与本地同路径。
   - **run #16：analyze / build-windows / build-linux 三个 job 全绿**，产出四个 artifact：
     Windows ZIP 171 MB + 安装包 164 MB、Linux 便携 ZIP 175 MB + AppImage 166 MB。
   - 附带收益：**Linux 侧的原生库这次由 CI 在 Linux 上真正重建并打进 AppImage**，
     所以 §14.4 那条"需 Linux 环境"的欠账也一笔勾掉了（真机运行仍需你在 Linux 上验一次）。
