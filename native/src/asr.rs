//! 识别引擎：常驻解码线程、有界段队列、批处理解码、延迟统计。
//!
//! 设计要点：
//!
//! - **解码不在采集线程上**。采集侧只负责产段并投入有界队列，解码在自己的线程里跑。
//!   旧实现把阻塞解码内联在采集循环的帧循环内部，一次迭代可能连做几次 1~3 秒的解码，
//!   期间音频持续堆积——越说越滞后。
//! - **recognizer 常驻**。只创建一次，换模型/语言走 `Ctl::Reload`，不再每次录音重新
//!   加载 240 MB，也不再等到首句语音才加载（首句延迟从 0.8~3 s 降到 ≈0）。
//! - **队列有界、溢出丢最旧**。段队列容量固定，宁可丢也不让延迟无界增长；丢了多少可观测。
//! - **线程常驻、stream 按需开关**：start/stop 只影响采集侧，解码线程与模型都不动。

use std::collections::VecDeque;
use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::Instant;

use crate::censor;
use crate::segmenter::Segment;
use crate::text::{chars_only, split_sentence, ResultQueue, TextPipeline};

/// 段队列容量。4 段 × 8 s = 32 s 的极端积压上限，超过就丢最旧。
pub const SEG_QUEUE_CAP: usize = 4;
/// 一次批解码最多合并多少段（`decode_multiple_streams` 的批大小）。
pub const BATCH_MAX: usize = 4;
/// 结果队列上限。
pub const RESULT_QUEUE_MAX: usize = 64;
const ASR_SAMPLE_RATE: u32 = 16_000;

// ---------------------------------------------------------------- 延迟采样

/// 固定长度的延迟直方图，用于给出 p50 / p95。
/// 统计接口在 20 Hz 上被调用，256 个样本的排序开销可以忽略。
pub struct LatencySampler {
    samples: Mutex<Vec<u32>>,
    cap: usize,
    count: AtomicU64,
    total: AtomicU64,
    max: AtomicU64,
}

impl LatencySampler {
    pub fn new(cap: usize) -> Self {
        Self {
            samples: Mutex::new(Vec::with_capacity(cap)),
            cap,
            count: AtomicU64::new(0),
            total: AtomicU64::new(0),
            max: AtomicU64::new(0),
        }
    }

    pub fn record(&self, ms: u64) {
        if let Ok(mut s) = self.samples.lock() {
            if s.len() == self.cap {
                s.remove(0);
            }
            s.push(ms as u32);
        }
        self.count.fetch_add(1, Ordering::Relaxed);
        self.total.fetch_add(ms, Ordering::Relaxed);
        self.max.fetch_max(ms, Ordering::Relaxed);
    }

    pub fn avg(&self) -> u64 {
        let c = self.count.load(Ordering::Relaxed);
        if c == 0 {
            0
        } else {
            self.total.load(Ordering::Relaxed) / c
        }
    }

    pub fn max(&self) -> u64 {
        self.max.load(Ordering::Relaxed)
    }

    pub fn count(&self) -> u64 {
        self.count.load(Ordering::Relaxed)
    }

    /// `q` 取值 0.0~1.0
    pub fn percentile(&self, q: f64) -> u64 {
        let mut v = match self.samples.lock() {
            Ok(s) => s.clone(),
            Err(_) => return 0,
        };
        if v.is_empty() {
            return 0;
        }
        v.sort_unstable();
        let idx = ((v.len() - 1) as f64 * q.clamp(0.0, 1.0)).round() as usize;
        v[idx] as u64
    }

    pub fn reset(&self) {
        if let Ok(mut s) = self.samples.lock() {
            s.clear();
        }
        self.count.store(0, Ordering::Relaxed);
        self.total.store(0, Ordering::Relaxed);
        self.max.store(0, Ordering::Relaxed);
    }
}

// ---------------------------------------------------------------- 统计

pub struct Stats {
    /// 从环形缓冲读出的音频块数
    pub captured_chunks: AtomicU64,
    /// 因环形缓冲已满而丢弃的**样本**数（采样率 = 设备输入采样率）
    pub dropped_samples: AtomicU64,
    /// 段队列溢出丢弃的段数
    pub dropped_segments: AtomicU64,
    /// VAD 判丢的段数（太短 / 太轻）
    pub rejected_segments: AtomicU64,
    /// 文本层过滤掉的条数
    pub rejected_text: AtomicU64,
    /// 接缝去重生效次数
    pub seam_trimmed: AtomicU64,
    /// 真正投入解码的段数
    pub decoded: AtomicU64,
    /// 产出并投递到结果队列的条数
    pub results: AtomicU64,
    /// 交互（interim）解码次数
    pub interim_runs: AtomicU64,
    /// interim 结果投递条数（不写字幕、不发言，只给界面预览）
    pub interim_results: AtomicU64,
    /// recognizer **真正**被重建的次数（去重之后实际落地的次数）
    pub asr_reloads: AtomicU64,
    /// 被去重跳过的重建请求数（同一目标已经在路上）
    pub asr_reload_skipped: AtomicU64,
    /// 段队列当前深度 / 历史最大深度
    pub seg_queue_depth: AtomicU64,
    pub seg_queue_max: AtomicU64,
    /// 采集侧一次迭代的最坏耗时（毫秒），P2 的核心判据
    pub frontend_iter_max_ms: AtomicU64,
    pub frontend_iter_count: AtomicU64,
    pub decode: LatencySampler,
    pub frontend: LatencySampler,
    /// 录过多少次（session 数）
    pub sessions: AtomicU64,
}

impl Default for Stats {
    fn default() -> Self {
        Self {
            captured_chunks: AtomicU64::new(0),
            dropped_samples: AtomicU64::new(0),
            dropped_segments: AtomicU64::new(0),
            rejected_segments: AtomicU64::new(0),
            rejected_text: AtomicU64::new(0),
            seam_trimmed: AtomicU64::new(0),
            decoded: AtomicU64::new(0),
            results: AtomicU64::new(0),
            interim_runs: AtomicU64::new(0),
            interim_results: AtomicU64::new(0),
            asr_reloads: AtomicU64::new(0),
            asr_reload_skipped: AtomicU64::new(0),
            seg_queue_depth: AtomicU64::new(0),
            seg_queue_max: AtomicU64::new(0),
            frontend_iter_max_ms: AtomicU64::new(0),
            frontend_iter_count: AtomicU64::new(0),
            decode: LatencySampler::new(256),
            frontend: LatencySampler::new(256),
            sessions: AtomicU64::new(0),
        }
    }
}

static STATS: OnceLock<Stats> = OnceLock::new();

pub fn stats() -> &'static Stats {
    STATS.get_or_init(Stats::default)
}

// ---------------------------------------------------------------- 结果队列

static RESULT_QUEUE: OnceLock<ResultQueue> = OnceLock::new();

pub fn result_queue() -> &'static ResultQueue {
    RESULT_QUEUE.get_or_init(|| ResultQueue::new(RESULT_QUEUE_MAX))
}

// ---------------------------------------------------------------- 队列

pub struct SegmentJob {
    pub token: u64,
    pub seg: Segment,
}

/// 解码线程的控制命令。**不参与丢弃**（体积小、必须可靠）。
#[derive(Debug)]
pub enum Ctl {
    /// 重建 recognizer（换模型 / 换语言）。空闲时即等同预热。
    Reload { model_dir: String, lang: String },
    /// 保证此前提交的段都已被处理（FIFO 顺序即为保证，此处用于计数与后续扩展）。
    Flush { token: u64 },
}

enum Job {
    Ctl(Ctl),
    Seg(SegmentJob),
}

struct QueueInner {
    ctl: VecDeque<Ctl>,
    segs: VecDeque<SegmentJob>,
}

/// 控制命令与音频段共用一个锁 + 条件变量：既能保证控制命令不被丢弃，
/// 又能让段队列按容量丢最旧，还避免了空转轮询。
pub struct DecodeQueue {
    inner: Mutex<QueueInner>,
    cv: Condvar,
}

impl DecodeQueue {
    fn new() -> Self {
        Self {
            inner: Mutex::new(QueueInner {
                ctl: VecDeque::new(),
                segs: VecDeque::new(),
            }),
            cv: Condvar::new(),
        }
    }

    pub fn push_ctl(&self, c: Ctl) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.ctl.push_back(c);
            self.cv.notify_one();
        }
    }

    /// 提交一段音频。队列满时丢**最旧**的段并计数。
    pub fn push_segment(&self, job: SegmentJob) {
        let depth;
        if let Ok(mut inner) = self.inner.lock() {
            inner.segs.push_back(job);
            while inner.segs.len() > SEG_QUEUE_CAP {
                inner.segs.pop_front();
                stats().dropped_segments.fetch_add(1, Ordering::Relaxed);
            }
            depth = inner.segs.len() as u64;
            self.cv.notify_one();
        } else {
            return;
        }
        let s = stats();
        s.seg_queue_depth.store(depth, Ordering::Relaxed);
        s.seg_queue_max.fetch_max(depth, Ordering::Relaxed);
    }

    pub fn depth(&self) -> u64 {
        self.inner.lock().map(|i| i.segs.len() as u64).unwrap_or(0)
    }

    /// 阻塞取一个 job。控制命令优先（保证 Reload 及时生效），其次是**正式段**。
    ///
    /// interim 只是界面预览，绝不能挡在正式段前面：否则用户说完一句话，正式段要等
    /// 一个半句解完才轮到，表现为"卡一下才出字"。
    fn pop(&self) -> Option<Job> {
        let mut inner = self.inner.lock().ok()?;
        loop {
            if let Some(c) = inner.ctl.pop_front() {
                return Some(Job::Ctl(c));
            }
            if let Some(s) = Self::pop_prefer_final(&mut inner) {
                let d = inner.segs.len() as u64;
                drop(inner);
                stats().seg_queue_depth.store(d, Ordering::Relaxed);
                return Some(Job::Seg(s));
            }
            inner = self.cv.wait(inner).ok()?;
        }
    }

    /// 取下一个段：优先非 interim 的正式段。队列容量 ≤ 4，线性查找的开销可忽略。
    fn pop_prefer_final(inner: &mut QueueInner) -> Option<SegmentJob> {
        if let Some(pos) = inner.segs.iter().position(|j| !j.seg.interim) {
            return inner.segs.remove(pos);
        }
        inner.segs.pop_front()
    }

    /// 非阻塞取下一段（用于批处理），不取控制命令。同样优先正式段。
    fn try_pop_segment(&self) -> Option<SegmentJob> {
        let mut inner = self.inner.lock().ok()?;
        let s = Self::pop_prefer_final(&mut inner);
        let d = inner.segs.len() as u64;
        drop(inner);
        stats().seg_queue_depth.store(d, Ordering::Relaxed);
        s
    }
}

// ---------------------------------------------------------------- 引擎

/// 解码线程需要回调外部世界的能力。用函数指针装配，避免 asr 反向依赖 lib 的全局量。
pub struct DecodeEnv {
    /// 当前录音代际；不匹配的段一律丢弃，避免旧线程污染新一轮
    pub current_token: fn() -> u64,
    /// 当前敏感词模式（0 = 关闭）
    pub censor_mode: fn() -> i32,
    /// 最终文本的出路（字幕文件 / 自动发言等），按分句逐条调用
    pub on_final_text: fn(&str),
}

pub struct AsrEngine {
    queue: &'static DecodeQueue,
}

static ENGINE: OnceLock<AsrEngine> = OnceLock::new();
static QUEUE: OnceLock<&'static DecodeQueue> = OnceLock::new();

/// recognizer 的加载状态。reload 现在发生在后台线程上，UI 需要知道
/// "重建中 / 就绪 / 失败"，否则只能盲等。
pub const LOAD_IDLE: i32 = 0;
pub const LOAD_READY: i32 = 1;
pub const LOAD_FAILED: i32 = -1;

static LOAD_STATE: AtomicI32 = AtomicI32::new(LOAD_IDLE);

pub fn load_state() -> i32 {
    LOAD_STATE.load(Ordering::Relaxed)
}

/// "同一目标已在路上就跳过"的去重器。
///
/// 存在的理由：`mutsurelay_set_asr_lang` 挂在"保存设置"路径上，而界面上的灵敏度
/// 滑块每一次 `onChanged` 都会触发一次保存 —— 一次拖动就是几十次语言设置。若每次
/// 都老实重建，就是几十次 229 MB 模型重新加载（实测每次约 1.4 s），期间解码线程
/// 完全停摆、段队列按容量丢最旧。用户看到的是：
/// **"只调了下灵敏度 CPU 就 10%+，之后说话还很慢、甚至明明有声音却不出字。"**
///
/// 抽成独立类型还为了**可单测**：真正的实例是全局的，直接测全局会在并行测试里
/// 互相踩状态，测出来的失败既不可复现也说明不了问题。
#[derive(Default)]
struct ReloadDedup {
    pending: Option<(String, String)>,
}

impl ReloadDedup {
    /// 登记一次请求。返回 `false` 表示同一目标已经在路上，调用方不应重复发起。
    fn request(&mut self, dir: &str, lang: &str) -> bool {
        if self.pending.as_ref().map(|(d, l)| d == dir && l == lang) == Some(true) {
            return false;
        }
        self.pending = Some((dir.to_string(), lang.to_string()));
        true
    }

    /// 解码线程处理完一次重建后调用。
    ///
    /// 只有当它仍然是"最后一次请求"时才清空：期间若又来了一个不同目标的请求，
    /// 清掉它就等于让后面那个同目标请求被误去重。
    fn done(&mut self, dir: &str, lang: &str) {
        if self.pending.as_ref().map(|(d, l)| d == dir && l == lang) == Some(true) {
            self.pending = None;
        }
    }
}

static PENDING_RELOAD: Mutex<ReloadDedup> = Mutex::new(ReloadDedup { pending: None });

/// 解码线程**当前实际装载**的目标；`None` = 没有可用 recognizer（卸载过 / 加载失败）。
///
/// 有它才能回答"这个目标是不是已经装好了"。`LOAD_STATE` 只说明"就绪/重建中/失败"，
/// 不说明装的是谁 —— 少了这一层，"init_asr 装一次 + load_config 又装一次"这类
/// 重复请求会被当成两次真实需求，白白重载 2 s / 300 MB。
static LOADED_TARGET: Mutex<Option<(String, String)>> = Mutex::new(None);

/// 判断"已装载的目标"是否就是这次要的目标。抽成纯函数便于单测
/// （`LOADED_TARGET` 是全局的，直接测会和并行测试抢状态）。
///
/// 注意 `None`（没有 recognizer）**永远不匹配**：加载失败或已卸载之后，
/// 同目标的请求必须能再次真正落地，否则会静默地一直不加载。
fn target_matches(loaded: &Option<(String, String)>, dir: &str, lang: &str) -> bool {
    loaded
        .as_ref()
        .map(|(d, l)| d == dir && l == lang)
        .unwrap_or(false)
}

fn is_loaded(dir: &str, lang: &str) -> bool {
    LOADED_TARGET
        .lock()
        .map(|l| target_matches(&l, dir, lang))
        .unwrap_or(false)
}

/// 解码线程更新"当前装载目标"。
fn set_loaded_target(target: Option<(String, String)>) {
    if let Ok(mut l) = LOADED_TARGET.lock() {
        *l = target;
    }
}

/// 登记一次重建请求。返回 `false` 表示同一目标已在路上。
fn mark_reload_requested(dir: &str, lang: &str) -> bool {
    let Ok(mut p) = PENDING_RELOAD.lock() else {
        // 锁被毒化也不能阻断重建，宁可多建一次
        return true;
    };
    let accepted = p.request(dir, lang);
    if !accepted {
        stats().asr_reload_skipped.fetch_add(1, Ordering::Relaxed);
    }
    accepted
}

/// 解码线程处理完一次重建后调用，让同目标请求可以重新被接受。
fn note_reload_done(dir: &str, lang: &str) {
    if let Ok(mut p) = PENDING_RELOAD.lock() {
        p.done(dir, lang);
    }
}

/// 取（或创建）常驻解码线程。首次调用会创建线程；配合 `reload()` 即完成预热。
pub fn engine(env: DecodeEnv) -> &'static AsrEngine {
    ENGINE.get_or_init(|| {
        let queue: &'static DecodeQueue = Box::leak(Box::new(DecodeQueue::new()));
        QUEUE.set(queue).ok();
        std::thread::Builder::new()
            .name("mutsurelay-decode".into())
            .spawn(move || decode_loop(queue, env))
            .expect("spawn decode thread");
        AsrEngine { queue }
    })
}

impl AsrEngine {
    pub fn queue(&self) -> &'static DecodeQueue {
        self.queue
    }

    pub fn submit_segment(&self, token: u64, seg: Segment) {
        self.queue.push_segment(SegmentJob { token, seg });
    }

    /// 请求重建 recognizer。**返回是否真的发起了重建**。
    ///
    /// 两道短路，都是为了不让"只是调了个参数"变成一次 2 s / 300 MB 的模型重载：
    /// 1. **已经装好就是这个目标**（`LOAD_READY` 且 `is_loaded`）→ 直接返回 `false`；
    /// 2. 目标与"已经在路上的那次"相同 → 合并掉（[`ReloadDedup`]）。
    ///
    /// 需要"无论如何都重来一遍"的场景（用户点"重启 ASR"、刚下载完模型）用
    /// [`AsrEngine::reload_forced`]。
    ///
    /// **先在调用方线程把状态置为 IDLE，再入队**：否则从"入队"到"解码线程真正取走
    /// 这个 Reload"之间，`load_state()` 仍会返回上一轮的 `LOAD_READY`。UI 是轮询这个
    /// 状态的（见 `app_state.restartAsr`），若此刻解码线程正忙于一条长段，UI 会在
    /// 几百毫秒后读到陈旧的 READY，从而**提前谎报"ASR 已重启"**。
    pub fn reload(&self, model_dir: String, lang: String) -> bool {
        self.request_reload(model_dir, lang, false)
    }

    /// 强制重建：跳过"已经装好就是这个目标"的短路。
    ///
    /// 用于**模型文件可能已经变了**或用户明确要求重来的场合。仍然保留"同目标已在
    /// 路上就合并"的第二道短路 —— 那种情况下正在跑的那次已经能满足需求。
    pub fn reload_forced(&self, model_dir: String, lang: String) -> bool {
        self.request_reload(model_dir, lang, true)
    }

    fn request_reload(&self, model_dir: String, lang: String, forced: bool) -> bool {
        if !forced && load_state() == LOAD_READY && is_loaded(&model_dir, &lang) {
            stats().asr_reload_skipped.fetch_add(1, Ordering::Relaxed);
            return false;
        }
        if !mark_reload_requested(&model_dir, &lang) {
            return false;
        }
        LOAD_STATE.store(LOAD_IDLE, Ordering::Relaxed);
        self.queue.push_ctl(Ctl::Reload { model_dir, lang });
        true
    }

    pub fn flush(&self, token: u64) {
        self.queue.push_ctl(Ctl::Flush { token });
    }

    /// 丢弃 recognizer，把内存还给系统；下次 `reload` 会重建。
    ///
    /// 用于"空闲太久"的场景（见 `lib.rs` 的 `IDLE_UNLOAD_DELAY`）：加载约 1 s，
    /// 但常驻约 300 MB，长期不录音时留着不划算。
    /// 传空模型目录 → `create_recognizer` 返回 `None` → 旧 recognizer 被 drop；
    /// 解码线程会把状态记为 `LOAD_IDLE`（**不是** `FAILED`，这不是错误）。
    pub fn unload(&self) {
        let _ = self.reload(String::new(), String::new());
    }
}

/// 按线上完全相同的配置创建 recognizer（replay 回放工具也复用这个函数，
/// 否则 A/B 对比会因为配置不同而失去意义）。
pub fn create_recognizer(model_dir: &str, lang: &str) -> Option<sherpa_onnx::OfflineRecognizer> {
    if model_dir.is_empty() {
        log::warn!("[rust] ASR model dir is empty, recognizer not created");
        return None;
    }
    let dir = std::path::Path::new(model_dir);
    let model = dir.join("model.int8.onnx");
    let tokens = dir.join("tokens.txt");
    if !model.exists() || !tokens.exists() {
        log::error!(
            "[rust] ASR model files missing in {} (model={} tokens={})",
            model_dir,
            model.exists(),
            tokens.exists()
        );
        return None;
    }
    let mut cfg = sherpa_onnx::OfflineRecognizerConfig::default();
    cfg.model_config.sense_voice = sherpa_onnx::OfflineSenseVoiceModelConfig {
        model: Some(model.to_string_lossy().to_string()),
        language: Some(if lang.is_empty() { "auto".into() } else { lang.to_string() }),
        use_itn: true,
    };
    cfg.model_config.tokens = Some(tokens.to_string_lossy().to_string());
    cfg.decoding_method = Some("greedy_search".to_string());
    sherpa_onnx::OfflineRecognizer::create(&cfg)
}

fn decode_loop(queue: &'static DecodeQueue, env: DecodeEnv) {
    let mut recognizer: Option<sherpa_onnx::OfflineRecognizer> = None;
    let mut pipeline = TextPipeline::default();
    let mut loaded_dir = String::new();

    while let Some(job) = queue.pop() {
        match job {
            Job::Ctl(Ctl::Reload { model_dir, lang }) => {
                let started = Instant::now();
                LOAD_STATE.store(LOAD_IDLE, Ordering::Relaxed);
                // **先释放旧的再建新的**。写成 `recognizer = create_recognizer(..)` 时
                // 新 session 会在旧 session 被 drop 之前就建好，两份 229 MB 模型
                // （实测加载后 RSS +298 MB）同时在世，重建瞬间的峰值直接翻倍。
                drop(recognizer.take());
                recognizer = create_recognizer(&model_dir, &lang);
                LOAD_STATE.store(
                    if recognizer.is_some() {
                        LOAD_READY
                    } else if model_dir.is_empty() {
                        // 空目录 = 主动卸载（空闲省内存），不是加载失败
                        LOAD_IDLE
                    } else {
                        LOAD_FAILED
                    },
                    Ordering::Relaxed,
                );
                loaded_dir = model_dir.clone();
                pipeline.reset();
                stats().asr_reloads.fetch_add(1, Ordering::Relaxed);
                // 只有真的建出 recognizer 才算"已装载"：加载失败后同目标的请求
                // 必须还能重新落地，否则会静默地一直不加载。
                set_loaded_target(
                    recognizer
                        .is_some()
                        .then(|| (model_dir.clone(), lang.clone())),
                );
                // 让同目标的重复请求可以重新被接受
                note_reload_done(&model_dir, &lang);
                log::info!(
                    "[rust] ASR reloaded (dir={}, lang={}, ok={}, {}ms)",
                    model_dir,
                    lang,
                    recognizer.is_some(),
                    started.elapsed().as_millis()
                );
            }
            Job::Ctl(Ctl::Flush { token }) => {
                log::debug!("[rust] decode flush for token {token}");
            }
            Job::Seg(first) => {
                // 批量收集：把队列里紧随其后的同代际段一起解，提高吞吐
                let mut batch = vec![first];
                let first_is_interim = batch[0].seg.interim;
                while batch.len() < BATCH_MAX {
                    match queue.try_pop_segment() {
                        // 只合并"同代际 + 同类型"的段：interim 与正式段混在一批里，
                        // 会让正式段的解码被动等半句解完，反而加重出字延迟。
                        Some(next)
                            if next.token == batch[0].token
                                && next.seg.interim == first_is_interim =>
                        {
                            batch.push(next)
                        }
                        Some(next) => {
                            // 代际或类型不同：放回去（顺序会略微错位，但这两类本来就要分别处理）
                            queue.push_segment(next);
                            break;
                        }
                        None => break,
                    }
                }
                if batch[0].token != (env.current_token)() {
                    continue;
                }
                let Some(ref rec) = recognizer else {
                    log::warn!("[rust] segment dropped: recognizer unavailable");
                    stats().rejected_segments.fetch_add(batch.len() as u64, Ordering::Relaxed);
                    continue;
                };
                decode_batch(rec, &batch, &mut pipeline, &env, &loaded_dir);
            }
        }
    }
}

fn decode_batch(
    rec: &sherpa_onnx::OfflineRecognizer,
    batch: &[SegmentJob],
    pipeline: &mut TextPipeline,
    env: &DecodeEnv,
    _loaded_dir: &str,
) {
    let streams: Vec<_> = batch
        .iter()
        .map(|j| {
            let st = rec.create_stream();
            if !j.seg.pre_roll.is_empty() {
                st.accept_waveform(ASR_SAMPLE_RATE as i32, &j.seg.pre_roll);
            }
            st.accept_waveform(ASR_SAMPLE_RATE as i32, &j.seg.audio);
            st
        })
        .collect();

    let started = Instant::now();
    let refs: Vec<&sherpa_onnx::OfflineStream> = streams.iter().collect();
    rec.decode_multiple_streams(&refs);
    let elapsed = started.elapsed().as_millis() as u64;

    let s = stats();
    s.decode.record(elapsed / batch.len().max(1) as u64);
    s.decoded.fetch_add(batch.len() as u64, Ordering::Relaxed);

    for (stream, job) in streams.iter().zip(batch.iter()) {
        if job.token != (env.current_token)() {
            continue;
        }
        let raw = stream.get_result().map(|r| r.text).unwrap_or_default();
        if raw.trim().is_empty() {
            continue;
        }

        // ---- interim（实时半句）：只回给界面预览 ----
        // 不写字幕、不触发自动发言、不碰 TextPipeline 的去重状态，
        // 否则半句会污染正式结果的去重窗口。
        if job.seg.interim {
            let text = chars_only(&raw);
            if text.is_empty() {
                continue;
            }
            let mode = (env.censor_mode)();
            let filtered = if mode > 0 { censor::censor(&text, mode) } else { text };
            s.interim_results.fetch_add(1, Ordering::Relaxed);
            result_queue().push(serde_json::json!({
                "id": job.seg.id,
                "final": false,
                "text": filtered,
                "onset_ms": job.seg.onset_ms,
                "duration_ms": job.seg.duration_ms,
                "seam": false,
            }));
            continue;
        }

        let Some(text) = pipeline.accept(&raw, job.seg.seam_overlap_ms, true) else {
            s.rejected_text.fetch_add(1, Ordering::Relaxed);
            continue;
        };
        if pipeline.seam_trimmed > s.seam_trimmed.load(Ordering::Relaxed) {
            s.seam_trimmed
                .store(pipeline.seam_trimmed, Ordering::Relaxed);
        }
        let mode = (env.censor_mode)();
        let filtered = if mode > 0 {
            censor::censor(&text, mode)
        } else {
            text.clone()
        };
        for sentence in split_sentence(&filtered) {
            (env.on_final_text)(&sentence);
        }
        result_queue().push(serde_json::json!({
            "id": job.seg.id,
            "final": true,
            "text": filtered,
            "onset_ms": job.seg.onset_ms,
            "duration_ms": job.seg.duration_ms,
            "seam": job.seg.seam_overlap_ms > 0,
        }));
        s.results.fetch_add(1, Ordering::Relaxed);
    }
}

/// 提交一段用于 interim（实时半句）识别的音频。
/// 同一把锁的段队列，与正式段共用容量与丢旧策略。
pub fn submit_interim(token: u64, seg: Segment) {
    let Some(engine) = ENGINE.get() else { return };
    stats().interim_runs.fetch_add(1, Ordering::Relaxed);
    engine.queue.push_segment(SegmentJob { token, seg });
}


#[cfg(test)]
mod tests {
    use super::*;

    fn seg(id: u64, ms: u64) -> Segment {
        Segment {
            id,
            onset_ms: 0,
            duration_ms: ms,
            pre_roll: vec![],
            audio: vec![0.0; 160],
            seam_overlap_ms: 0,
            interim: false,
        }
    }

    #[test]
    fn queue_is_bounded_and_drops_oldest() {
        let q = DecodeQueue::new();
        for i in 0..(SEG_QUEUE_CAP as u64 + 3) {
            q.push_segment(SegmentJob {
                token: 1,
                seg: seg(i, 100),
            });
        }
        assert_eq!(q.depth(), SEG_QUEUE_CAP as u64);
        // 最先被取出的应当是"最新挤进来"的那批里最旧的（即 id = 3）
        let mut ids = Vec::new();
        while let Some(s) = q.try_pop_segment() {
            ids.push(s.seg.id);
        }
        assert_eq!(ids, vec![3, 4, 5, 6]);
        assert!(stats().dropped_segments.load(Ordering::Relaxed) >= 3);
    }

    /// 正式段必须优先于 interim 出队。interim 只是界面预览，
    /// 挡在正式段前面会让用户"说完一句话卡一下才出字"。
    #[test]
    fn final_segment_is_popped_before_interim() {
        let q = DecodeQueue::new();
        let mut i_seg = seg(1, 100);
        i_seg.interim = true;
        let f_seg = seg(2, 100); // interim 默认 false
        // 先压 interim，再压正式段：出队顺序必须反过来
        q.push_segment(SegmentJob { token: 1, seg: i_seg });
        q.push_segment(SegmentJob { token: 1, seg: f_seg });

        let first = q.try_pop_segment().expect("应有段可出队");
        assert!(!first.seg.interim, "正式段必须先出队");
        assert_eq!(first.seg.id, 2);
        let second = q.try_pop_segment().expect("应有段可出队");
        assert!(second.seg.interim, "interim 随后出队");
        assert_eq!(second.seg.id, 1);
    }

    #[test]
    fn ctl_is_never_dropped_even_when_segments_flood() {
        let q = DecodeQueue::new();
        q.push_ctl(Ctl::Reload {
            model_dir: "/x".into(),
            lang: "zh".into(),
        });
        for i in 0..20 {
            q.push_segment(SegmentJob {
                token: 1,
                seg: seg(i, 100),
            });
        }
        // 控制命令优先出队
        match q.pop() {
            Some(Job::Ctl(Ctl::Reload { model_dir, .. })) => assert_eq!(model_dir, "/x"),
            other => panic!("期望先取到 Reload，实际 {:?}", other.is_some()),
        }
    }

    #[test]
    fn latency_sampler_reports_percentiles() {
        let s = LatencySampler::new(100);
        for i in 1..=100 {
            s.record(i);
        }
        assert_eq!(s.count(), 100);
        assert_eq!(s.max(), 100);
        assert_eq!(s.avg(), 50);
        assert!((49..=51).contains(&s.percentile(0.5)));
        assert!((94..=96).contains(&s.percentile(0.95)));
    }

    /// reload 必须是**同步**清掉 READY 的：UI 轮询 `load_state()` 判断"重启完成没"，
    /// 若状态要等解码线程取走 Reload 才变，UI 会在解码线程繁忙时读到陈旧的 READY
    /// 而提前报"已重启"。
    #[test]
    fn reload_clears_ready_state_before_returning() {
        LOAD_STATE.store(LOAD_READY, Ordering::Relaxed);
        let q: &'static DecodeQueue = Box::leak(Box::new(DecodeQueue::new()));
        let e = AsrEngine { queue: q };
        e.reload("/x".into(), "zh".into());
        assert_eq!(load_state(), LOAD_IDLE);
    }

    /// 高频重复请求（灵敏度拖动 → 保存设置 → set_asr_lang）只能落地一次重建。
    /// 这是"CPU 10%+ / 说话不出字"那条真机反馈的回归测试。
    #[test]
    fn duplicate_reload_requests_are_coalesced() {
        let mut d = ReloadDedup::default();
        assert!(d.request("/m", "zh"), "首次请求应当真的发起");
        for _ in 0..50 {
            assert!(!d.request("/m", "zh"), "同目标重复请求必须被去重");
        }
        // 目标变了 → 必须放行（换语言要真的生效）
        assert!(d.request("/m", "en"), "目标变化时不应被去重");
        // 解码线程处理完之后，同目标可以再次发起（例如用户又点了一次"重启 ASR"）
        d.done("/m", "en");
        assert!(d.request("/m", "en"), "处理完后同目标应可再次发起");
    }

    /// 迟到的 `done` 不能把后来那个请求的去重记录清掉，否则后续同目标请求会全部
    /// 漏过去重，重建风暴重新出现。
    #[test]
    fn stale_reload_done_does_not_clear_newer_request() {
        let mut d = ReloadDedup::default();
        assert!(d.request("/m", "zh"));
        assert!(d.request("/m", "en"), "目标变化应放行");
        d.done("/m", "zh"); // 旧请求完成（迟到）
        assert!(!d.request("/m", "en"), "新请求仍在路上，同目标应继续被去重");
    }

    /// "已装载即跳过"的判据：只有**装好且目标完全一致**才算命中。
    ///
    /// 尤其是 `None`（加载失败 / 被空闲卸载）绝不能命中 —— 否则同目标的请求会永远
    /// 被跳过，表现成"点了重启 ASR 毫无反应、之后说话也不再加载模型"。
    #[test]
    fn loaded_target_matching_is_strict() {
        let loaded = Some(("asr/model".to_string(), "zh".to_string()));
        assert!(target_matches(&loaded, "asr/model", "zh"));
        assert!(!target_matches(&loaded, "asr/model", "en"), "语言必须参与比较");
        assert!(!target_matches(&loaded, "other/model", "zh"), "目录必须参与比较");
        assert!(
            !target_matches(&None, "asr/model", "zh"),
            "没有 recognizer 时不能算命中（否则失败后永远不再加载）"
        );
        // 空闲卸载写回的是"空目录"，同样不能命中任何真实目标
        let unloaded = Some((String::new(), String::new()));
        assert!(!target_matches(&unloaded, "asr/model", "zh"));
    }

    #[test]
    fn latency_sampler_ring_keeps_recent() {
        let s = LatencySampler::new(10);
        for i in 1..=100 {
            s.record(i);
        }
        // 只保留最近 10 个（91..100）
        assert!((90..=92).contains(&s.percentile(0.0)));
        assert_eq!(s.max(), 100);
    }
}
