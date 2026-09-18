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

**验证环境限制**：本机为 Windows，`flutter analyze` 无法执行——`.fvm/flutter_sdk`、
`.fvm/versions/stable` 都是指向 `/home/para/fvm/versions/stable` 的 Linux 符号链接
（`IntxLNK` 前缀），是双系统切换后的残留，Windows 侧解析不到。因此 Dart 改动通过
"导出符号比对 + 逐段人工复核"验证，未过分析器。

补充手段：`native/tools/smoke_native.py` —— 用 ctypes 直接加载 DLL 跑 C API 全链路，
替代"跑不起来 Flutter 就没法验证"的困境。

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
| `flutter analyze` | **无法执行**（Flutter SDK 在 Windows 侧不可用，见第一节补） |

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
| `flutter analyze` | **仍无法执行**（Flutter SDK 在 Windows 侧不可用） |

### 9.4 尚未验证 / 遗留

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
| `flutter analyze` | 仍无法执行（Windows 侧无 Flutter SDK） |

> 环境备注：本机的 PowerShell 会话里 `rustc` 不在 PATH（`native/build.ps1` 2 秒即退且无输出）。
> 在本环境重建 DLL 请走 `cd native && cargo build`，再手动同步 `mutsurelay_native.{dll,pdb,lib}`
> 与 4 个依赖 DLL 到 `windows/mutsurelay_native/` 与 `build/windows/x64/runner/Debug/`。

