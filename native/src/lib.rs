//! MutsuRelay native —— C API 薄层 + 采集链路装配。
//!
//! 链路结构（P2 起）：
//!
//! ```text
//! [cpal 回调线程 · 实时]
//!    单声道下混到预分配 scratch（零分配、零加锁）
//!    → AudioRing（无锁 SPSC，满则丢最新并计数）
//!
//! [capture 线程]  仅持有 cpal stream 的生命周期（创建与销毁必须在同一线程）
//!
//! [front-end 线程]
//!    AudioRing → 抗混叠 + 相位连续的流式重采样
//!             → 30 ms 分帧 → Segmenter（噪声门 / 分段状态机 / pre-roll 快照）
//!             → 有界段队列（容量 4，溢出丢最旧）
//!
//! [decode 线程 · 常驻]
//!    recognizer 常驻 → 批量 decode_multiple_streams → TextPipeline（清洗/接缝去重/去重）
//!    → 敏感词 → 分句 → 字幕 + 结果队列
//!
//! [Dart · 50 ms 轮询]  一次取走结果队列全部条目
//! ```

pub mod asr;
pub mod audio;
pub mod bilive;
pub mod censor;
pub mod segmenter;
pub mod text;

use std::ffi::{CStr, CString};
use std::io::Read;
use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use audio::{StreamResampler, ASR_SAMPLE_RATE};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{BufferSize, StreamConfig};
use segmenter::{SegmentEvent, Segmenter, SegmenterConfig, VAD_FRAME_SAMPLES};

// ---------------------------------------------------------------- 全局状态

static INITIALIZED: AtomicBool = AtomicBool::new(false);
static IS_RECORDING: AtomicBool = AtomicBool::new(false);
/// 每启动一次录音自增。线程持有自己的 token：token 不匹配即退出，且不再写入任何输出。
static RUN_TOKEN: AtomicU64 = AtomicU64::new(0);
static IN_SPEECH: OnceLock<AtomicBool> = OnceLock::new();
static NOISE_GATE: OnceLock<Mutex<f32>> = OnceLock::new();
static CENSOR_MODE: OnceLock<Mutex<i32>> = OnceLock::new();
static NOISE_SUPPRESS: OnceLock<AtomicBool> = OnceLock::new();
static AUDIO_LEVEL: OnceLock<AtomicU32> = OnceLock::new();
/// **录音链路自己的**错误（与 B 站接口的 LAST_ERROR 分开，互不污染）。
static PIPELINE_ERROR: OnceLock<Mutex<String>> = OnceLock::new();
static MODEL_DIR: OnceLock<Mutex<String>> = OnceLock::new();
static ASR_LANG: OnceLock<Mutex<String>> = OnceLock::new();
/// 段长上限（毫秒），可运行时调整
static SEGMENT_MAX_MS: AtomicU32 = AtomicU32::new(segmenter::DEFAULT_MAX_SEGMENT_MS);
/// 是否启用 interim（实时半句）
static INTERIM_ENABLED: AtomicBool = AtomicBool::new(true);

/// 环形缓冲容量：2 秒 @ 48 kHz。
/// 采集侧一次迭代的实测耗时应 < 5 ms，这里留出 400 倍余量。
const RING_CAPACITY: usize = 48_000 * 2;
/// 回调内单声道下混用的 scratch 大小（样本数）
const CALLBACK_SCRATCH: usize = 16_384;
/// front-end 单次从环形缓冲取出的上限
const FRONTEND_READ: usize = 8_192;
/// interim 节流间隔。
///
/// 1500 ms 太稀疏：用户说完一句话、VAD 退出语音态之后，界面上那条实时预览会先被
/// 清掉，然后才等来正式结果 —— 观感就是"实时停了、电平也降了，过了一会才出字"。
/// 实测解码 3 s 音频只要 73 ms（41× 实时），把间隔压到 800 ms 的代价约 5% 单核，
/// 换来的是预览始终贴着语音走。
const INTERIM_INTERVAL: Duration = Duration::from_millis(800);
/// interim 至少要有这么长的段才值得跑。
/// 500 ms 已经足够出一个词，再长就会漏掉短句的预览。
const INTERIM_MIN_SEGMENT_MS: u64 = 500;
/// 停止录音后多久（期间没有新录音）把 recognizer 卸掉。
///
/// 常驻 recognizer 是"首句近零延迟"的关键，代价是**一直**占约 300 MB
/// （实测：模型文件 228 MB → 加载后 RSS +298 MB）。而重建只要约 1 s，
/// 所以长期不录音时留着并不划算。60 s 足以覆盖"录一段、停一下、接着录"的节奏，
/// 又让"只是开着界面"这种最长时间的占用回落到 Flutter 运行时本身（~200 MB）。
const IDLE_UNLOAD_DELAY: Duration = Duration::from_secs(60);

fn noise_gate() -> &'static Mutex<f32> {
    NOISE_GATE.get_or_init(|| Mutex::new(0.02))
}
fn censor_mode() -> &'static Mutex<i32> {
    CENSOR_MODE.get_or_init(|| Mutex::new(2))
}
fn noise_suppress() -> &'static AtomicBool {
    NOISE_SUPPRESS.get_or_init(|| AtomicBool::new(true))
}
fn in_speech_state() -> &'static AtomicBool {
    IN_SPEECH.get_or_init(|| AtomicBool::new(false))
}
fn audio_level() -> &'static AtomicU32 {
    AUDIO_LEVEL.get_or_init(|| AtomicU32::new(f32::to_bits(0.0)))
}
fn pipeline_error() -> &'static Mutex<String> {
    PIPELINE_ERROR.get_or_init(|| Mutex::new(String::new()))
}
fn model_dir() -> &'static Mutex<String> {
    MODEL_DIR.get_or_init(|| Mutex::new(String::new()))
}
fn asr_lang() -> &'static Mutex<String> {
    ASR_LANG.get_or_init(|| Mutex::new("zh".to_string()))
}

fn current_token() -> u64 {
    RUN_TOKEN.load(Ordering::SeqCst)
}

fn set_pipeline_error(message: impl Into<String>) {
    if let Ok(mut e) = pipeline_error().lock() {
        *e = message.into();
    }
}

fn get_pipeline_error() -> String {
    pipeline_error().lock().map(|e| e.clone()).unwrap_or_default()
}

// ---- 装配给解码线程的回调 ----

fn env_censor_mode() -> i32 {
    censor_mode().lock().map(|m| *m).unwrap_or(0)
}

fn env_on_final_text(text: &str) {
    bilive::write_subtitle_text(text);
}

fn decode_env() -> asr::DecodeEnv {
    asr::DecodeEnv {
        current_token,
        censor_mode: env_censor_mode,
        on_final_text: env_on_final_text,
    }
}

fn engine() -> &'static asr::AsrEngine {
    asr::engine(decode_env())
}

/// 每次主动重建 recognizer 都自增。空闲卸载线程据此判断"这段时间里有没有人动过 ASR"，
/// 否则会出现：用户刚点完"重启 ASR"，卸载线程紧接着把模型丢掉 → 静默失效。
static RELOAD_GEN: AtomicU64 = AtomicU64::new(0);

/// 让解码线程用当前模型目录 / 语言重建（或首次创建）recognizer。
/// 线程常驻，所以"重建"发生在后台，界面不会卡；空闲时即等于预热。
///
/// 目标已经装好、或同一目标已在路上时 `AsrEngine::reload` 会返回 `false`，
/// 此时**不推进 `RELOAD_GEN`**：否则"保存设置"这种高频路径会把空闲卸载的
/// 判定一直顶掉（卸载线程靠代际变化判断"这段时间有没有人动过 ASR"）。
fn trigger_reload() {
    let dir = model_dir().lock().map(|d| d.clone()).unwrap_or_default();
    let lang = asr_lang().lock().map(|l| l.clone()).unwrap_or_default();
    if engine().reload(dir, lang) {
        RELOAD_GEN.fetch_add(1, Ordering::SeqCst);
    }
}

/// 与 [`trigger_reload`] 相同，但跳过"已经装好就是这个目标"的短路。
///
/// 只给"模型文件可能已经变了 / 用户明确要求重来"的路径用（下载完模型、
/// 界面上点"重启 ASR"）。这些场合必须真的重新加载一遍。
fn trigger_reload_forced() {
    let dir = model_dir().lock().map(|d| d.clone()).unwrap_or_default();
    let lang = asr_lang().lock().map(|l| l.clone()).unwrap_or_default();
    if engine().reload_forced(dir, lang) {
        RELOAD_GEN.fetch_add(1, Ordering::SeqCst);
    }
}

/// **只有已经装着 recognizer 时才重建**；从没装过就只更新目标，等首次录音再加载。
///
/// 给启动路径用（`init_asr` / `load_config` / `set_asr_lang`）。这些接口在应用启动时
/// 会被连着调好几次，若它们直接 `trigger_reload`，应用**一打开就常驻 ~300 MB 模型**
/// —— 而多数时间根本没在录音。这正是"内存占用高"的主要来源。
///
/// 已经装载时仍然要重建：换语言 / 换模型是 recognizer 的构造参数，不重建就不生效。
fn trigger_reload_if_loaded() {
    if asr::load_state() == asr::LOAD_READY {
        trigger_reload();
    }
}

// ---------------------------------------------------------------- 采集会话

fn start_session() -> u64 {
    let token = RUN_TOKEN.fetch_add(1, Ordering::SeqCst) + 1;
    let ring = Arc::new(audio::AudioRing::new(RING_CAPACITY));

    // capture 线程负责设备发现 + stream 生命周期（创建与销毁必须同线程）
    let (cfg_tx, cfg_rx) = sync_channel::<Result<(u32, u16), String>>(0);

    {
        let ring = ring.clone();
        let _ = thread::Builder::new()
            .name("mutsurelay-capture".into())
            .spawn(move || capture_owner(token, ring, cfg_tx));
    }
    let _ = thread::Builder::new()
        .name("mutsurelay-frontend".into())
        .spawn(move || frontend_loop(token, ring, cfg_rx));

    asr::stats().sessions.fetch_add(1, Ordering::Relaxed);
    token
}

/// 仅持有 cpal stream 的生命周期；音频数据通过回调写入无锁环形缓冲。
fn capture_owner(
    token: u64,
    ring: Arc<audio::AudioRing>,
    cfg_tx: std::sync::mpsc::SyncSender<Result<(u32, u16), String>>,
) {
    let host = cpal::default_host();

    let devices: Vec<_> = match host.input_devices() {
        Ok(d) => d.collect(),
        Err(e) => {
            let msg = format!("枚举音频输入设备失败: {e}");
            fail_session(token, &msg);
            let _ = cfg_tx.send(Err(msg));
            return;
        }
    };
    if devices.is_empty() {
        let msg = "未检测到可用的音频输入设备".to_string();
        fail_session(token, &msg);
        let _ = cfg_tx.send(Err(msg));
        return;
    }

    // 优先麦克风设备，其次是 PipeWire/PulseAudio 兼容名，最后随便挑一个
    let device = devices
        .iter()
        .find(|d| {
            d.name()
                .map(|n| {
                    let nl = n.to_lowercase();
                    nl.contains("microphone") || nl.contains("mic") || nl.contains("话筒")
                })
                .unwrap_or(false)
        })
        .or_else(|| {
            devices.iter().find(|d| {
                d.name()
                    .map(|n| {
                        let nl = n.to_lowercase();
                        nl == "pulse" || nl == "default" || nl.starts_with("sysdefault")
                    })
                    .unwrap_or(false)
            })
        })
        .or_else(|| devices.first())
        .cloned();

    let Some(device) = device else {
        let msg = "未找到可用的音频输入设备".to_string();
        fail_session(token, &msg);
        let _ = cfg_tx.send(Err(msg));
        return;
    };

    let config = match device.default_input_config() {
        Ok(c) => c,
        Err(e) => {
            let msg = format!("读取设备默认输入格式失败: {e}");
            fail_session(token, &msg);
            let _ = cfg_tx.send(Err(msg));
            return;
        }
    };
    let channels = config.channels();
    let input_rate = config.sample_rate().0;
    log::info!(
        "[rust] input: {}ch {}Hz ({}) token={}",
        channels,
        input_rate,
        device.name().unwrap_or_default(),
        token
    );

    let stream_cfg = StreamConfig {
        channels,
        sample_rate: config.sample_rate(),
        buffer_size: BufferSize::Default,
    };

    // 预先分配下混 scratch：实时回调里不允许分配
    let mut scratch: Vec<f32> = vec![0.0; CALLBACK_SCRATCH];
    let ch = channels as usize;
    let cb_ring = ring.clone();
    let err_token = token;

    let stream = match device.build_input_stream(
        &stream_cfg,
        move |data: &[f32], _: &cpal::InputCallbackInfo| {
            // ---- 实时音频线程：零分配、零加锁 ----
            if !IS_RECORDING.load(Ordering::Relaxed) {
                return;
            }
            let frames = data.len() / ch;
            let n = frames.min(scratch.len());
            if ch == 1 {
                scratch[..n].copy_from_slice(&data[..n]);
            } else {
                for i in 0..n {
                    let mut sum = 0.0f32;
                    for c in 0..ch {
                        sum += data[i * ch + c];
                    }
                    scratch[i] = sum / ch as f32;
                }
            }
            cb_ring.push_slice(&scratch[..n]);
        },
        move |err| {
            set_pipeline_error(format!("音频流错误: {err}"));
            if RUN_TOKEN.load(Ordering::SeqCst) == err_token {
                IS_RECORDING.store(false, Ordering::SeqCst);
            }
        },
        None,
    ) {
        Ok(s) => s,
        Err(e) => {
            let msg = format!("无法打开音频输入流: {e}");
            fail_session(token, &msg);
            let _ = cfg_tx.send(Err(msg));
            return;
        }
    };

    if let Err(e) = stream.play() {
        let msg = format!("启动音频流失败: {e}");
        fail_session(token, &msg);
        let _ = cfg_tx.send(Err(msg));
        return;
    }

    // 把输入格式交给 front-end 线程（配置重采样器）
    if cfg_tx.send(Ok((input_rate, channels))).is_err() {
        return;
    }

    // 只等停止信号，不做任何处理
    while IS_RECORDING.load(Ordering::SeqCst) && RUN_TOKEN.load(Ordering::SeqCst) == token {
        thread::sleep(Duration::from_millis(20));
    }
    drop(stream);
    log::info!("[rust] capture stream closed (token={token})");
}

fn fail_session(token: u64, msg: &str) {
    log::error!("[rust] capture failed: {msg}");
    set_pipeline_error(msg.to_string());
    if RUN_TOKEN.load(Ordering::SeqCst) == token {
        IS_RECORDING.store(false, Ordering::SeqCst);
    }
}

/// front-end 线程：重采样 → 分帧 → 分段 → 投递。
fn frontend_loop(
    token: u64,
    ring: Arc<audio::AudioRing>,
    cfg_rx: Receiver<Result<(u32, u16), String>>,
) {
    let (input_rate, _channels) = match cfg_rx.recv() {
        Ok(Ok(v)) => v,
        // 失败信息已由 capture 线程写入 PIPELINE_ERROR
        Ok(Err(_)) | Err(_) => return,
    };
    log::info!(
        "[rust] front-end started: {}Hz → {}Hz (token={token})",
        input_rate,
        ASR_SAMPLE_RATE
    );

    let mut resampler = StreamResampler::new(input_rate, ASR_SAMPLE_RATE);
    let mut segmenter = Segmenter::new(SegmenterConfig::default());
    let mut raw = vec![0.0f32; FRONTEND_READ];
    let mut resampled: Vec<f32> = Vec::with_capacity(FRONTEND_READ);
    let mut frame: Vec<f32> = Vec::with_capacity(VAD_FRAME_SAMPLES);
    let mut leftover: Vec<f32> = Vec::with_capacity(VAD_FRAME_SAMPLES * 2);
    let mut events: Vec<SegmentEvent> = Vec::with_capacity(8);
    let mut last_interim = Instant::now();
    let mut empty_pops = 0u32;
    segmenter.reset();

    loop {
        let iter_start = Instant::now();
        let stopped = !IS_RECORDING.load(Ordering::SeqCst) || RUN_TOKEN.load(Ordering::SeqCst) != token;

        let got = ring.pop_slice(&mut raw);
        if got == 0 {
            if stopped {
                empty_pops += 1;
                // 连续两次空读才收工，避免漏掉停止瞬间仍在途的最后一块
                if empty_pops >= 2 {
                    break;
                }
            }
            thread::sleep(Duration::from_millis(3));
            continue;
        }
        empty_pops = 0;
        asr::stats().captured_chunks.fetch_add(1, Ordering::Relaxed);

        // ---- 重采样（抗混叠 + 跨块相位连续）----
        resampled.clear();
        resampler.process(&raw[..got], &mut resampled);
        if resampled.is_empty() {
            continue;
        }

        // 运行时可调的参数每轮刷新一次
        {
            let cfg = segmenter.cfg_mut();
            cfg.gate = noise_gate().lock().map(|g| *g).unwrap_or(0.02);
            cfg.suppress = noise_suppress().load(Ordering::Relaxed);
            cfg.max_segment_samples =
                ASR_SAMPLE_RATE as usize * SEGMENT_MAX_MS.load(Ordering::Relaxed) as usize / 1000;
        }

        leftover.extend_from_slice(&resampled);

        while leftover.len() >= VAD_FRAME_SAMPLES {
            frame.clear();
            frame.extend_from_slice(&leftover[..VAD_FRAME_SAMPLES]);
            // 用 copy_within 前移，避免 drain 的 O(n) 分支与重复 memmove
            leftover.copy_within(VAD_FRAME_SAMPLES.., 0);
            leftover.truncate(leftover.len() - VAD_FRAME_SAMPLES);

            events.clear();
            let outcome = segmenter.push_frame(&frame, &mut events);

            for ev in events.drain(..) {
                match ev {
                    SegmentEvent::Emit(seg) => {
                        engine().submit_segment(token, *seg);
                    }
                    SegmentEvent::Reject { .. } => {
                        asr::stats().rejected_segments.fetch_add(1, Ordering::Relaxed);
                    }
                    SegmentEvent::Start { .. } => {}
                }
            }

            audio_level().store(f32::to_bits(outcome.level), Ordering::Relaxed);
            in_speech_state().store(outcome.in_speech, Ordering::Relaxed);
        }

        // ---- interim（实时半句）：仅在解码队列空闲时跑，避免抢 CPU ----
        if INTERIM_ENABLED.load(Ordering::Relaxed)
            && last_interim.elapsed() >= INTERIM_INTERVAL
            && segmenter.current_segment_ms() >= INTERIM_MIN_SEGMENT_MS
            && engine().queue().depth() == 0
        {
            if let Some(snap) = segmenter.interim_snapshot() {
                last_interim = Instant::now();
                asr::submit_interim(token, snap);
            }
        }

        // ---- 采集侧耗时统计：P2 的核心判据 ----
        let elapsed = iter_start.elapsed().as_millis() as u64;
        let s = asr::stats();
        s.frontend.record(elapsed);
        s.frontend_iter_count.fetch_add(1, Ordering::Relaxed);
        s.frontend_iter_max_ms.fetch_max(elapsed, Ordering::Relaxed);
    }

    // ---- 收尾：把进行中的段吐出去，并通知解码线程 ----
    events.clear();
    segmenter.flush(&mut events);
    for ev in events.drain(..) {
        if let SegmentEvent::Emit(seg) = ev {
            engine().submit_segment(token, *seg);
        }
    }
    // 只累积"本次会话真正观察到"的环形缓冲丢样
    asr::stats()
        .dropped_samples
        .fetch_add(ring.dropped(), Ordering::Relaxed);
    audio_level().store(f32::to_bits(0.0), Ordering::Relaxed);
    in_speech_state().store(false, Ordering::Relaxed);
    log::info!("[rust] front-end stopped (token={token})");
}

// ---------------------------------------------------------------- C API

/// C API 版本。**增删/改变任何 `mutsurelay_*` 导出符号时必须 +1。**
///
/// 用途：本仓库是双系统开发（Linux / Windows 各有一份产物），很容易拿着旧平台的
/// `.so`/`.dll` 去跑新绑定。没有这个标记时，缺符号会让 `_bindFunctions()` 抛错、
/// 被 `load()` 吞掉，最后**静默退回 mock 模式**——看起来能跑，其实 ASR 没在工作。
/// 有了版本号，Dart 侧可以明确报"库太旧，请在当前平台重新构建"。
pub const ABI_VERSION: u32 = 2;

#[no_mangle]
pub extern "C" fn mutsurelay_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn mutsurelay_init(model_dir_ptr: *const c_char) -> i32 {
    if INITIALIZED.load(Ordering::SeqCst) {
        return 0;
    }
    let _ = env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info"),
    )
    .try_init();
    _init_internal(model_dir_ptr, false)
}

/// 启动路径：同步模型目录 / 语言 / 配置。**不加载模型**（懒加载，见下）。
///
/// 既不预加载也不强制重建：应用启动时会连着来两次（先是 init_asr，随后 loadSettings →
/// `mutsurelay_load_config`），目标一样就没必要把 229 MB 模型装两遍 —— 而既然要懒加载，
/// 这里一次都不该装。已经装着（例如界面上换过语言）才会真正重建。
#[no_mangle]
pub extern "C" fn mutsurelay_init_asr(model_dir_ptr: *const c_char) -> i32 {
    _init_internal(model_dir_ptr, false)
}

/// 界面上"重启 ASR"按钮：用户明确要求重来，**强制重建**。
#[no_mangle]
pub extern "C" fn mutsurelay_reload_asr(model_dir_ptr: *const c_char) -> i32 {
    _init_internal(model_dir_ptr, true)
}

fn _init_internal(model_dir_ptr: *const c_char, forced: bool) -> i32 {
    let dir = if model_dir_ptr.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(model_dir_ptr) }
            .to_string_lossy()
            .to_string()
    };
    if let Ok(mut m) = model_dir().lock() {
        *m = dir;
    }
    censor::reload_blocklist();
    if let Ok(cfg) = bilive::Config::load() {
        if let Ok(mut g) = noise_gate().lock() {
            *g = cfg.noise_gate;
        }
        if let Ok(mut m) = censor_mode().lock() {
            *m = cfg.censor_mode;
        }
        noise_suppress().store(cfg.noise_suppress, Ordering::SeqCst);
        bilive::init_from_config(&cfg);
        if let Ok(mut a) = asr_lang().lock() {
            *a = bilive::get_language();
        }
    }
    // 解码线程常驻，但**这里不预加载**：加载 = 约 1 s / 约 300 MB 常驻内存，而应用
    // 刚打开时多半并不是要马上录音。"真正的加载"发生在两个地方：
    //   - `mutsurelay_start_recording`（首次开录，与用户开口的时间重叠）
    //   - `mutsurelay_reload_asr`（界面上的"重启 ASR"）
    // 这样"只是开着界面"的常驻占用就从 ~500 MB 回落到 ~200 MB（Flutter 运行时本身）。
    if forced {
        trigger_reload_forced();
    } else {
        trigger_reload_if_loaded();
    }
    INITIALIZED.store(true, Ordering::SeqCst);
    0
}

#[no_mangle]
pub extern "C" fn mutsurelay_shutdown() {
    if !INITIALIZED.load(Ordering::SeqCst) {
        return;
    }
    if IS_RECORDING.load(Ordering::SeqCst) {
        mutsurelay_stop_recording();
    }
    INITIALIZED.store(false, Ordering::SeqCst);
}

#[no_mangle]
pub extern "C" fn mutsurelay_start_recording() -> i32 {
    if IS_RECORDING.load(Ordering::SeqCst) {
        return 0;
    }
    set_pipeline_error(String::new());
    // **懒加载的真正入口**：recognizer 可能是"从没建过"（启动不预加载）或
    // 被"空闲卸载"过，两种情况都在这里补上。这 ~1 s 与用户开口的时间重叠，
    // 不必等到首句语音才加载。加载期间到达的段会排在段队列里（容量 4）等它。
    if asr::load_state() != asr::LOAD_READY {
        trigger_reload();
    }
    IS_RECORDING.store(true, Ordering::SeqCst);
    let token = start_session();
    log::info!("[rust] recording session started (token={token})");
    0
}

#[no_mangle]
pub extern "C" fn mutsurelay_stop_recording() {
    IS_RECORDING.store(false, Ordering::SeqCst);
    schedule_idle_unload();
}

/// 空闲卸载：停止录音后若迟迟没有新录音，就把 recognizer 丢掉，把约 300 MB 还给系统。
///
/// 只起一个一次性计时线程，醒来后核对会话代际：期间只要重新开录（`RUN_TOKEN` 变了）
/// 或仍在录音，就什么都不做。多次起停会留下多个等待中的线程，但它们都会自行退出；
/// 90 s 内起停的次数量级很小，不值得为此引入更复杂的机制。
fn schedule_idle_unload() {
    let token = RUN_TOKEN.load(Ordering::SeqCst);
    let gen = RELOAD_GEN.load(Ordering::SeqCst);
    let _ = thread::Builder::new()
        .name("mutsurelay-idle-unload".into())
        .spawn(move || {
            thread::sleep(IDLE_UNLOAD_DELAY);
            // 又开录了 / 换了会话 / 这段时间里有人主动重建过 ASR（例如用户点了"重启"）
            // —— 任何一种情况都取消本次卸载
            if IS_RECORDING.load(Ordering::SeqCst)
                || RUN_TOKEN.load(Ordering::SeqCst) != token
                || RELOAD_GEN.load(Ordering::SeqCst) != gen
            {
                return;
            }
            if asr::load_state() == asr::LOAD_READY {
                engine().unload();
                log::info!(
                    "[rust] idle for {:?}, recognizer unloaded (~300 MB returned to OS)",
                    IDLE_UNLOAD_DELAY
                );
            }
        });
}

#[no_mangle]
pub extern "C" fn mutsurelay_is_recording() -> i32 {
    IS_RECORDING.load(Ordering::SeqCst) as i32
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_segment_max_ms(ms: u32) {
    SEGMENT_MAX_MS.store(ms.clamp(1000, 30_000), Ordering::SeqCst);
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_segment_max_ms() -> u32 {
    SEGMENT_MAX_MS.load(Ordering::SeqCst)
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_interim(enabled: i32) {
    INTERIM_ENABLED.store(enabled != 0, Ordering::SeqCst);
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_interim() -> i32 {
    INTERIM_ENABLED.load(Ordering::SeqCst) as i32
}

/// recognizer 加载状态：1 = 就绪，0 = 重建中/未尝试，-1 = 加载失败。
/// reload 在后台线程完成，UI 靠这个接口给用户真实反馈。
#[no_mangle]
pub extern "C" fn mutsurelay_asr_state() -> i32 {
    asr::load_state()
}

fn stats_json() -> serde_json::Value {
    let s = asr::stats();
    let q = asr::result_queue();
    serde_json::json!({
        "captured_chunks": s.captured_chunks.load(Ordering::Relaxed),
        "dropped_samples": s.dropped_samples.load(Ordering::Relaxed),
        "dropped_segments": s.dropped_segments.load(Ordering::Relaxed),
        "rejected_segments": s.rejected_segments.load(Ordering::Relaxed),
        "rejected_text": s.rejected_text.load(Ordering::Relaxed),
        "seam_trimmed": s.seam_trimmed.load(Ordering::Relaxed),
        "decoded": s.decoded.load(Ordering::Relaxed),
        "results": s.results.load(Ordering::Relaxed),
        // 注意：这个数由 ResultQueue 自己维护。此前读的是 Stats.dropped_results，
        // 而那个字段从来没被写入过 —— 统计里会永远显示 0（P0 要的"可观测"反而假了）。
        "dropped_results": q.dropped(),
        "interim_runs": s.interim_runs.load(Ordering::Relaxed),
        "interim_results": s.interim_results.load(Ordering::Relaxed),
        // 重建次数的可观测性：`set_asr_lang` 被高频调用时，这里应当**不涨**。
        // 涨了就说明去重失效，用户会立刻感受到 CPU 与出字延迟的退化。
        "asr_reloads": s.asr_reloads.load(Ordering::Relaxed),
        "asr_reload_skipped": s.asr_reload_skipped.load(Ordering::Relaxed),
        "asr_state": asr::load_state(),
        "sessions": s.sessions.load(Ordering::Relaxed),
        "queue_depth": q.len(),
        "seg_queue_depth": s.seg_queue_depth.load(Ordering::Relaxed),
        "seg_queue_max": s.seg_queue_max.load(Ordering::Relaxed),
        "decode_avg_ms": s.decode.avg(),
        "decode_p50_ms": s.decode.percentile(0.5),
        "decode_p95_ms": s.decode.percentile(0.95),
        "decode_max_ms": s.decode.max(),
        "frontend_avg_ms": s.frontend.avg(),
        "frontend_p95_ms": s.frontend.percentile(0.95),
        "frontend_max_ms": s.frontend.max(),
        // P2 的核心判据：旧实现在这里会看到 1.5~4 s（阻塞解码在帧循环里）。
        "frontend_iter_max_ms": s.frontend_iter_max_ms.load(Ordering::Relaxed),
        "frontend_iters": s.frontend_iter_count.load(Ordering::Relaxed),
    })
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_stats() -> *mut c_char {
    CString::new(stats_json().to_string())
        .unwrap_or_default()
        .into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_poll_recording() -> *mut c_char {
    let recording = IS_RECORDING.load(Ordering::SeqCst);
    let level = f32::from_bits(audio_level().load(Ordering::Relaxed)) as f64;
    let results = asr::result_queue().drain();
    let json = serde_json::json!({
        "recording": recording,
        "level": level,
        "in_speech": in_speech_state().load(Ordering::SeqCst),
        "error": get_pipeline_error(),
        "results": results,
        "stats": stats_json(),
    });
    CString::new(json.to_string()).unwrap_or_default().into_raw()
}

// ---- 模型下载 ----

#[no_mangle]
pub extern "C" fn mutsurelay_download_asr_model(
    url: *const c_char,
    dest_dir: *const c_char,
) -> i32 {
    let url_s = if url.is_null() {
        return -1;
    } else {
        unsafe { CStr::from_ptr(url) }.to_string_lossy().to_string()
    };
    let dir_s = if dest_dir.is_null() {
        return -1;
    } else {
        unsafe { CStr::from_ptr(dest_dir) }
            .to_string_lossy()
            .to_string()
    };
    log::info!("Downloading ASR model from {url_s}");

    let body = match ureq::get(&url_s)
        .call()
        .map_err(|e| format!("{e}"))
        .and_then(|r| {
            let mut buf = Vec::new();
            r.into_reader()
                .read_to_end(&mut buf)
                .map(|_| buf)
                .map_err(|e| format!("{e}"))
        }) {
        Ok(b) => {
            log::info!("Downloaded {} bytes", b.len());
            b
        }
        Err(e) => {
            log::error!("Download failed: {e}");
            return -1;
        }
    };

    let bz = bzip2::read::MultiBzDecoder::new(&body[..]);
    let mut archive = tar::Archive::new(bz);
    if let Err(e) = archive.unpack(&dir_s) {
        log::error!("Extract failed: {e}");
        return -1;
    }

    let dir_path = std::path::Path::new(&dir_s);
    let has_model = dir_path.join("model.int8.onnx").exists();
    let has_tokens = dir_path.join("tokens.txt").exists();
    log::info!("Extracted to {dir_s}, model={has_model} tokens={has_tokens}");
    // 新模型就位后让解码线程换上去。这里是**强制**重建：模型文件已经变了，
    // "目标没变就跳过"的短路在这是错的（目录没变，文件变了）。
    trigger_reload_forced();
    0
}

// ---- VAD / 噪声门 ----

#[no_mangle]
pub extern "C" fn mutsurelay_set_noise_gate(gate: f64) {
    if let Ok(mut g) = noise_gate().lock() {
        *g = gate as f32;
    }
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_noise_gate() -> f64 {
    noise_gate().lock().map(|g| *g as f64).unwrap_or(0.02)
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_noise_suppress(enabled: i32) {
    noise_suppress().store(enabled != 0, Ordering::SeqCst);
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_noise_suppress() -> i32 {
    noise_suppress().load(Ordering::SeqCst) as i32
}

// ---- 敏感词 ----

#[no_mangle]
pub extern "C" fn mutsurelay_set_censor_mode(mode: i32) {
    if let Ok(mut m) = censor_mode().lock() {
        *m = mode;
    }
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_censor_mode() -> i32 {
    censor_mode().lock().map(|m| *m).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn mutsurelay_censor_text(input: *const c_char) -> *mut c_char {
    let text = if input.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(input) }.to_string_lossy().to_string()
    };
    let mode = censor_mode().lock().map(|m| *m).unwrap_or(0);
    let result = if mode > 0 {
        censor::censor(&text, mode)
    } else {
        text
    };
    CString::new(result).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}

// ---- B 站 ----

#[no_mangle]
pub extern "C" fn mutsurelay_generate_qrcode() -> *mut c_char {
    CString::new(bilive::generate_qrcode())
        .unwrap_or_default()
        .into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_check_qrcode_status(key: *const c_char) -> *mut c_char {
    let k = if key.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(key) }.to_string_lossy().to_string()
    };
    CString::new(bilive::check_qrcode_status(&k))
        .unwrap_or_default()
        .into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_cookie(cookie: *const c_char) -> i32 {
    let c = if cookie.is_null() {
        return -1;
    } else {
        unsafe { CStr::from_ptr(cookie) }
            .to_string_lossy()
            .to_string()
    };
    bilive::set_cookie(&c)
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_account_info() -> *mut c_char {
    let info = bilive::get_account_info();
    CString::new(serde_json::to_string(&info).unwrap_or_else(|_| "{}".to_string()))
        .unwrap_or_default()
        .into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_cookie_status() -> i32 {
    bilive::get_cookie_status() as i32
}

#[no_mangle]
pub extern "C" fn mutsurelay_logout() {
    bilive::logout();
}

#[no_mangle]
pub extern "C" fn mutsurelay_connect_room(room_id: i64) -> i32 {
    bilive::connect_room(room_id as u64)
}

#[no_mangle]
pub extern "C" fn mutsurelay_disconnect_room() {
    bilive::disconnect_room();
}

#[no_mangle]
pub extern "C" fn mutsurelay_is_connected() -> i32 {
    bilive::is_connected() as i32
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_room_id(room_id: i64) {
    bilive::set_room_id(room_id as u64);
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_my_room_id() -> i64 {
    bilive::get_my_room_id()
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_room_id() -> i64 {
    bilive::get_room_id() as i64
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_asr_lang(lang: *const c_char) {
    let l = if lang.is_null() {
        "auto".to_string()
    } else {
        unsafe { CStr::from_ptr(lang) }.to_string_lossy().to_string()
    };
    let changed = match asr_lang().lock() {
        Ok(mut a) => {
            let changed = *a != l;
            *a = l.clone();
            changed
        }
        // 拿不到锁就当作变了：宁可多重建一次，也不要让语言切换静默失效
        Err(_) => true,
    };
    // **语言没变就不要重建**。这是"保存设置"路径上的高频调用（界面每次调参都会
    // 走一遍），而一次重建 = 229 MB 模型重新加载约 1.4 s，期间解码线程停摆、
    // 待解码的段按容量丢最旧 —— 症状是"只调了下灵敏度，CPU 10%+，说话还不出字"。
    if !changed {
        return;
    }
    // 语言是 recognizer 的构造参数，改了必须重建才生效。但**已经装着才需要重建**：
    // 启动路径（loadSettings → set_asr_lang）在这里不该把模型拉进内存。
    bilive::set_language(&l);
    trigger_reload_if_loaded();
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_asr_lang() -> *mut c_char {
    let s = asr_lang().lock().map(|l| l.clone()).unwrap_or_default();
    CString::new(s).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_close_behavior(behavior: *const c_char) {
    let b = if behavior.is_null() {
        "hide".to_string()
    } else {
        unsafe { CStr::from_ptr(behavior) }
            .to_string_lossy()
            .to_string()
    };
    bilive::set_close_behavior(&b);
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_close_behavior() -> *mut c_char {
    CString::new(bilive::get_close_behavior())
        .unwrap_or_default()
        .into_raw()
}

/// 同步发送（手动发送用；会阻塞调用线程直到 HTTP 往返完成）。
#[no_mangle]
pub extern "C" fn mutsurelay_send_message(text: *const c_char) -> i32 {
    let t = if text.is_null() {
        return -1;
    } else {
        unsafe { CStr::from_ptr(text) }.to_string_lossy().to_string()
    };
    bilive::send_message(&t)
}

/// 异步入队发送（自动发言 / UI 用）。立即返回 job id，结果通过
/// `mutsurelay_poll_send_results` 取回。调用方线程不会被网络阻塞。
#[no_mangle]
pub extern "C" fn mutsurelay_enqueue_message(text: *const c_char) -> i64 {
    let t = if text.is_null() {
        return -1;
    } else {
        unsafe { CStr::from_ptr(text) }.to_string_lossy().to_string()
    };
    bilive::enqueue_message(&t)
}

#[no_mangle]
pub extern "C" fn mutsurelay_poll_send_results() -> *mut c_char {
    let items = bilive::take_send_results();
    CString::new(serde_json::Value::Array(items).to_string())
        .unwrap_or_default()
        .into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_config_dir_path() -> *mut c_char {
    CString::new(bilive::get_storage_dir().to_string_lossy().to_string())
        .unwrap_or_default()
        .into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_last_error() -> *mut c_char {
    CString::new(bilive::get_last_error()).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_subtitle_file_path(path: *const c_char) {
    let p = if path.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(path) }.to_string_lossy().to_string()
    };
    bilive::set_subtitle_file_path(&p);
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_subtitle_file_path() -> *mut c_char {
    CString::new(bilive::get_subtitle_file_path())
        .unwrap_or_default()
        .into_raw()
}

// ---- 配置持久化 ----

#[no_mangle]
pub extern "C" fn mutsurelay_save_config() -> i32 {
    let mut cfg = bilive::Config::load().unwrap_or_default();
    cfg.roomid = bilive::get_room_id();
    cfg.noise_gate = noise_gate().lock().map(|g| *g).unwrap_or(0.02);
    cfg.censor_mode = censor_mode().lock().map(|m| *m).unwrap_or(0);
    cfg.noise_suppress = noise_suppress().load(Ordering::SeqCst);
    cfg.language = bilive::get_language();
    cfg.close_behavior = bilive::get_close_behavior();
    cfg.subtitle_file_path = bilive::get_subtitle_file_path();
    cfg.segment_max_ms = SEGMENT_MAX_MS.load(Ordering::SeqCst);
    cfg.interim = INTERIM_ENABLED.load(Ordering::SeqCst);
    cfg.save().map(|_| 0).unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn mutsurelay_load_config() -> i32 {
    match bilive::Config::load() {
        Ok(cfg) => {
            if let Ok(mut g) = noise_gate().lock() {
                *g = cfg.noise_gate;
            }
            if let Ok(mut m) = censor_mode().lock() {
                *m = cfg.censor_mode;
            }
            noise_suppress().store(cfg.noise_suppress, Ordering::SeqCst);
            bilive::set_language(&cfg.language);
            bilive::set_close_behavior(&cfg.close_behavior);
            if cfg.roomid > 0 {
                bilive::set_room_id(cfg.roomid);
            }
            bilive::set_subtitle_file_path(&cfg.subtitle_file_path);
            // 段长 / interim 只影响后续分段，不需要重建 recognizer（也不要触发它）。
            SEGMENT_MAX_MS.store(cfg.segment_max_ms.clamp(1000, 30_000), Ordering::SeqCst);
            INTERIM_ENABLED.store(cfg.interim, Ordering::SeqCst);
            bilive::init_from_config(&cfg);
            if let Ok(mut a) = asr_lang().lock() {
                *a = bilive::get_language();
            }
            trigger_reload_if_loaded();
            0
        }
        Err(_) => -1,
    }
}
