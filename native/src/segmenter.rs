//! VAD / 分段状态机（纯逻辑，无 IO、无线程，可单测）。
//!
//! 与旧实现的关键差别：
//!
//! 1. **pre-roll 在"语音起点"那一刻快照**，且快照发生在把当前帧写入 pre-roll 缓冲
//!    **之前**。旧实现在推段时取 `ring_buf` 的尾部，而静音切段发生在累计静音之后，
//!    那时 ring 里全是静音——这个 context 等于没有。现在 pre-roll 是真正的"起点之前"，
//!    并且不会把起点那一帧重复算进段首。
//! 2. **单一能量域**。判决与噪声底更新都用**原始（未加抑制增益）**能量，与用户设置的
//!    门限同一口径。旧实现拿降噪后的 RMS 去比原始门限，增益 <1 时等于悄悄抬高了门限。
//! 3. **抑制增益平滑且有下限**。按帧给整帧乘 0.3~1.0 会压掉擦音/轻声，形成 30 ms 尺度
//!    的幅度起伏；现在目标增益限制在 0.6~1.0 并对时间做一阶平滑。
//! 4. **强制切段留下接缝上下文**。段长到上限被切开时，下一段的 pre-roll 天然就是上一段
//!    的尾巴（同一段音频出现在两段里），段上用 `seam_overlap_ms` 标出重叠时长，
//!    交给文本层去重。

use crate::audio::{rms, ASR_SAMPLE_RATE};

pub const VAD_FRAME_MS: u32 = 30;
pub const VAD_FRAME_SAMPLES: usize = ASR_SAMPLE_RATE as usize * VAD_FRAME_MS as usize / 1000;

/// 段长上限：直接决定连续说话时最坏的出字延迟。
pub const DEFAULT_MAX_SEGMENT_MS: u32 = 8_000;
/// 起点之前保留的音频长度（真正的 pre-roll）。
pub const DEFAULT_PRE_ROLL_MS: u32 = 300;
/// interim（实时半句）快照最多回看多长的音频。
///
/// 实时预览只关心"最近在说什么"，没必要每次都把整段（最长 8 s）送进识别器：
/// 那样每次 interim 的解码耗时随段长线性增长，而它会占住解码线程，
/// 让紧随其后的正式段排队 —— 表现为"说完一句话要卡一下才出字"。
pub const DEFAULT_INTERIM_WINDOW_MS: u32 = 3_000;
/// 静音判停门限。
pub const DEFAULT_MIN_SILENCE_MS: u32 = 300;
/// 兜底静音门限：即便语音帧数不足也切段，避免段无限增长。
pub const DEFAULT_MAX_SILENCE_MS: u32 = 2_100;
/// 最少连续语音帧数，低于此值的段视为噪声丢弃。
pub const DEFAULT_MIN_SPEECH_MS: u32 = 90;
/// 段整体 RMS 低于此值视为无有效语音。
pub const DEFAULT_ENERGY_FLOOR: f32 = 0.005;
/// 滞回系数：已进入语音态时门限降低，避免句子中间被切断。
pub const VAD_HYSTERESIS: f32 = 0.5;
/// 语音态**退出**门限相对"段起点前噪声底"的倍数。
///
/// 退出判停不能只看"用户门限的一半"：房间底噪常常正好落在 `gate*0.5` 与 `gate`
/// 之间。那种情况下 `silence_frames` 永远不累加，段只能等 `max_segment_samples`
/// （默认 8 s）强制切段 —— 用户看到的是**"实时预览停住了、电平也降下去了，却迟迟
/// 不出字"**，而且时快时慢（取决于那一刻的底噪是否恰好低于 `gate*0.5`）。
/// 用段起点处的噪声底做参照，判停就与门限松紧解耦，且段内不会被自己的语音污染
/// （进入语音态后噪声底几乎冻结）。
pub const VAD_EXIT_NOISE_RATIO: f32 = 1.5;
/// 只有段的起点电平明显高于噪声底（这个倍数）时，才启用上面的自适应判停。
///
/// 否则（用户把门限压到远低于底噪、或底噪还没测出来）宁可退回原来的
/// `gate*HYSTERESIS`：那说明门限设置本身就有问题，不该由自适应逻辑去"猜"。
const VAD_ADAPTIVE_MIN_SNR: f32 = 3.0;

fn ms_to_samples(ms: u32) -> usize {
    ASR_SAMPLE_RATE as usize * ms as usize / 1000
}

fn samples_to_ms(samples: usize) -> u64 {
    samples as u64 * 1000 / ASR_SAMPLE_RATE as u64
}

#[derive(Clone, Copy, Debug)]
pub struct SegmenterConfig {
    pub frame_samples: usize,
    pub min_speech_frames: u32,
    pub min_silence_frames: u32,
    pub max_silence_frames: u32,
    pub max_segment_samples: usize,
    pub pre_roll_samples: usize,
    /// interim 快照最多回看的音频长度（见 `DEFAULT_INTERIM_WINDOW_MS`）
    pub interim_window_samples: usize,
    pub energy_floor: f32,
    /// 用户设置的噪声门（与原始能量同口径）
    pub gate: f32,
    pub suppress: bool,
}

impl Default for SegmenterConfig {
    fn default() -> Self {
        Self {
            frame_samples: VAD_FRAME_SAMPLES,
            min_speech_frames: (DEFAULT_MIN_SPEECH_MS / VAD_FRAME_MS).max(1),
            min_silence_frames: (DEFAULT_MIN_SILENCE_MS / VAD_FRAME_MS).max(1),
            max_silence_frames: (DEFAULT_MAX_SILENCE_MS / VAD_FRAME_MS).max(1),
            max_segment_samples: ms_to_samples(DEFAULT_MAX_SEGMENT_MS),
            pre_roll_samples: ms_to_samples(DEFAULT_PRE_ROLL_MS),
            interim_window_samples: ms_to_samples(DEFAULT_INTERIM_WINDOW_MS),
            energy_floor: DEFAULT_ENERGY_FLOOR,
            gate: 0.02,
            suppress: true,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RejectReason {
    /// 连续语音帧不足
    TooShort,
    /// 段整体能量低于下限
    TooQuiet,
}

/// 一段待识别的音频。
#[derive(Debug, Clone)]
pub struct Segment {
    pub id: u64,
    /// 语音起点在本次录音中的绝对时间
    pub onset_ms: u64,
    pub duration_ms: u64,
    /// 起点之前的音频（真正的 pre-roll）
    pub pre_roll: Vec<f32>,
    /// 起点到段尾
    pub audio: Vec<f32>,
    /// >0 表示本段起点音频与**上一段结尾**有重叠（强制切段造成），文本层据此去重
    pub seam_overlap_ms: u32,
    /// 这是一段**未完结**的实时快照（interim），只用于界面预览：
    /// 不写字幕文件、不触发自动发言、不参与文本去重、不占用正式段号。
    pub interim: bool,
}

impl Segment {
    /// 交给识别器的完整波形（pre-roll + 本段）。
    pub fn full_audio(&self) -> Vec<f32> {
        let mut v = Vec::with_capacity(self.pre_roll.len() + self.audio.len());
        v.extend_from_slice(&self.pre_roll);
        v.extend_from_slice(&self.audio);
        v
    }
}

#[derive(Debug, Clone)]
pub enum SegmentEvent {
    Start { onset_ms: u64 },
    Emit(Box<Segment>),
    Reject { reason: RejectReason, duration_ms: u64 },
}

/// 帧级判决结果，供 UI / 统计使用。
#[derive(Debug, Clone, Copy)]
pub struct FrameOutcome {
    pub in_speech: bool,
    pub raw_energy: f32,
    pub gain: f32,
    pub level: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CloseReason {
    /// 静音判停
    Silence,
    /// 段长到上限
    ForceCut,
}

pub struct Segmenter {
    cfg: SegmenterConfig,
    in_speech: bool,
    consecutive_speech: u32,
    max_consecutive_speech: u32,
    silence_frames: u32,
    /// pre-roll 环形缓冲（始终保存"最近 pre_roll_samples 个已处理样本"）
    pre_roll: Vec<f32>,
    pre_roll_pos: usize,
    pre_roll_filled: usize,
    /// 当前段：起点前快照
    seg_pre_roll: Vec<f32>,
    /// 当前段：起点到当前（已施加抑制增益）
    seg_audio: Vec<f32>,
    /// 当前段：原始能量的平方和与样本数（用于能量下限判决，与原始能量同口径）
    seg_raw_sq: f64,
    seg_raw_n: u64,
    /// 当前段的起点时间
    seg_onset_ms: u64,
    /// 起点那一帧的原始能量（用于判断"这是不是真语音"，见 `exit_threshold`）
    seg_onset_level: f32,
    /// 起点**之前**（本帧的 EMA 更新之前）的噪声底，退出判停的参照
    seg_noise_floor: f32,
    /// 当前段与上一段的重叠时长（毫秒）
    seg_seam_overlap_ms: u32,
    /// 上一段结尾在时间轴上的位置（样本数），用于精确计算接缝重叠
    last_close_end: Option<u64>,
    /// 自适应噪声底（原始能量域）
    noise_floor: f32,
    gain: f32,
    next_id: u64,
    processed_samples: u64,
    /// 电平表弹道值（**原始 RMS**，与噪声门同一口径）
    meter: f32,
}

impl Segmenter {
    pub fn new(cfg: SegmenterConfig) -> Self {
        let cap = cfg.pre_roll_samples.max(1);
        Self {
            cfg,
            in_speech: false,
            consecutive_speech: 0,
            max_consecutive_speech: 0,
            silence_frames: 0,
            pre_roll: vec![0.0; cap],
            pre_roll_pos: 0,
            pre_roll_filled: 0,
            seg_pre_roll: Vec::new(),
            seg_audio: Vec::with_capacity(cfg.max_segment_samples.min(16000 * 4)),
            seg_raw_sq: 0.0,
            seg_raw_n: 0,
            seg_onset_ms: 0,
            seg_onset_level: 0.0,
            seg_noise_floor: 0.0,
            seg_seam_overlap_ms: 0,
            last_close_end: None,
            noise_floor: 0.01,
            gain: 1.0,
            next_id: 0,
            processed_samples: 0,
            meter: 0.0,
        }
    }

    pub fn cfg(&self) -> &SegmenterConfig {
        &self.cfg
    }

    pub fn cfg_mut(&mut self) -> &mut SegmenterConfig {
        &mut self.cfg
    }

    pub fn in_speech(&self) -> bool {
        self.in_speech
    }

    /// 电平表数值（0~1）。
    ///
    /// **必须与判决同一口径**（原始 RMS × 10），界面上的门限标线也是按
    /// `gate * 10` 画的。此前这里用的是**峰值** × 10，而判决用的是 RMS 比门限：
    /// 同一段话的峰值通常比 RMS 高 3~4 倍，于是"电平条明显越过门线、却一个字都不出"，
    /// 用户看到的就是完全不符合直觉的静默。
    pub fn level(&self) -> f32 {
        (self.meter * 10.0).min(1.0)
    }

    pub fn noise_floor(&self) -> f32 {
        self.noise_floor
    }

    pub fn gain(&self) -> f32 {
        self.gain
    }

    /// 语音态的**退出**门限（原始能量域）。
    ///
    /// 基准是 `gate * VAD_HYSTERESIS`（滞回），但在"起点电平明显高于噪声底"时改用
    /// `噪声底 * VAD_EXIT_NOISE_RATIO`：后者才是"这句话说完了"的正确判据。原因见
    /// [`VAD_EXIT_NOISE_RATIO`] 的注释 —— 只按 `gate*0.5` 判停，底噪恰好落在
    /// `(gate*0.5, gate)` 区间时永远判不出静音，段只能等 8 s 强制切段。
    fn exit_threshold(&self) -> f32 {
        let base = self.cfg.gate * VAD_HYSTERESIS;
        if self.seg_onset_level > self.seg_noise_floor * VAD_ADAPTIVE_MIN_SNR {
            base.max(self.seg_noise_floor * VAD_EXIT_NOISE_RATIO)
        } else {
            base
        }
    }

    pub fn processed_ms(&self) -> u64 {
        samples_to_ms(self.processed_samples as usize)
    }

    /// 当前段的时长（毫秒）。用于 interim 节流判断。
    pub fn current_segment_ms(&self) -> u64 {
        if !self.in_speech {
            return 0;
        }
        samples_to_ms(self.seg_audio.len())
    }

    /// 取当前未完成段的一份快照，用于 interim（实时半句）识别。
    ///
    /// **只取尾部窗口**（`cfg.interim_window_samples`，默认 3 s），而不是整段。
    /// interim 与正式段共用解码线程：若每次都送整段（最长 8 s），解码耗时会随句长
    /// 增长，把紧随其后的正式段挡在后面——用户感受就是"说完一句话要卡一下才出字"。
    /// 实时预览本来也只需要"最近在说什么"，尾部窗口足够。
    pub fn interim_snapshot(&self) -> Option<Segment> {
        if !self.in_speech || self.seg_audio.len() < self.cfg.frame_samples * 4 {
            return None;
        }
        let take = self
            .seg_audio
            .len()
            .min(self.cfg.interim_window_samples.max(self.cfg.frame_samples));
        let start = self.seg_audio.len() - take;
        Some(Segment {
            id: u64::MAX, // interim 不占用正式段号
            // 窗口起点 = 段起点 + 段内偏移
            onset_ms: self.seg_onset_ms + samples_to_ms(start),
            duration_ms: samples_to_ms(take),
            // 尾部窗口自带上下文，不必再补"段起点之前"的 pre-roll
            pre_roll: Vec::new(),
            audio: self.seg_audio[start..].to_vec(),
            // interim 不参与接缝去重
            seam_overlap_ms: 0,
            interim: true,
        })
    }

    /// 清空片段状态。噪声底与增益保留，避免每次开录都要重新收敛。
    pub fn reset(&mut self) {
        self.in_speech = false;
        self.consecutive_speech = 0;
        self.max_consecutive_speech = 0;
        self.silence_frames = 0;
        self.seg_pre_roll.clear();
        self.seg_audio.clear();
        self.seg_raw_sq = 0.0;
        self.seg_raw_n = 0;
        self.seg_seam_overlap_ms = 0;
        self.seg_onset_level = 0.0;
        self.seg_noise_floor = 0.0;
        self.last_close_end = None;
        self.pre_roll_pos = 0;
        self.pre_roll_filled = 0;
        self.pre_roll.iter_mut().for_each(|v| *v = 0.0);
        self.processed_samples = 0;
        self.meter = 0.0;
    }

    fn push_pre_roll(&mut self, gated: &[f32]) {
        let cap = self.pre_roll.len();
        if cap == 0 {
            return;
        }
        for &s in gated {
            self.pre_roll[self.pre_roll_pos] = s;
            self.pre_roll_pos = (self.pre_roll_pos + 1) % cap;
            if self.pre_roll_filled < cap {
                self.pre_roll_filled += 1;
            }
        }
    }

    /// 把 pre-roll 环形缓冲展开成时间序（最旧 → 最新）。
    fn snapshot_pre_roll(&self) -> Vec<f32> {
        let cap = self.pre_roll.len();
        let n = self.pre_roll_filled;
        let mut v = Vec::with_capacity(n);
        if n == 0 {
            return v;
        }
        let start = (self.pre_roll_pos + cap - n) % cap;
        for i in 0..n {
            v.push(self.pre_roll[(start + i) % cap]);
        }
        v
    }

    /// 进入语音态。**必须在把当前帧写进 pre-roll 缓冲之前调用**，
    /// 否则起点那一帧会同时出现在 pre-roll 尾部和段首。
    ///
    /// `onset_level` / `prev_noise_floor` 是起点那一帧的原始能量、以及**该帧 EMA 更新
    /// 之前**的噪声底。两者一起决定本段的退出判停门限（见 [`Self::exit_threshold`]）：
    /// 噪声底必须在更新前取，否则语音起点的能量会污染它，把退出门限抬得过高。
    fn begin_segment(&mut self, onset_level: f32, prev_noise_floor: f32) {
        let onset = self.processed_samples;
        self.seg_onset_ms = samples_to_ms(onset as usize);
        self.seg_onset_level = onset_level;
        self.seg_noise_floor = prev_noise_floor;
        self.seg_pre_roll = self.snapshot_pre_roll();
        // 精确计算与上一段的重叠：pre-roll 覆盖 [onset - len, onset)，
        // 上一段的音频结束于 last_close_end，两者的交叠就是重复时长。
        self.seg_seam_overlap_ms = match self.last_close_end {
            Some(end) if onset > end => {
                let gap = (onset - end) as usize;
                samples_to_ms(self.seg_pre_roll.len().saturating_sub(gap)) as u32
            }
            Some(_) => samples_to_ms(self.seg_pre_roll.len()) as u32,
            None => 0,
        };
        self.seg_audio.clear();
        self.seg_raw_sq = 0.0;
        self.seg_raw_n = 0;
    }

    /// 收尾一个进行中的段。
    ///
    /// `_reason` 目前不参与输出（接缝重叠在 `begin_segment` 里就已定好，与结束原因无关），
    /// 保留参数是为了调试时可读、并为将来按结束原因分桶统计留口子。
    fn close_segment(
        &mut self,
        out: &mut Vec<SegmentEvent>,
        _reason: CloseReason,
        frame_len: usize,
    ) {
        let duration_ms = samples_to_ms(self.seg_audio.len());
        let has_enough_speech = self.max_consecutive_speech >= self.cfg.min_speech_frames;
        let seg_rms = if self.seg_raw_n > 0 {
            (self.seg_raw_sq / self.seg_raw_n as f64).sqrt() as f32
        } else {
            0.0
        };

        if !has_enough_speech {
            out.push(SegmentEvent::Reject {
                reason: RejectReason::TooShort,
                duration_ms,
            });
        } else if seg_rms < self.cfg.energy_floor {
            out.push(SegmentEvent::Reject {
                reason: RejectReason::TooQuiet,
                duration_ms,
            });
        } else if !self.seg_audio.is_empty() {
            let seg = Segment {
                id: self.next_id,
                onset_ms: self.seg_onset_ms,
                duration_ms,
                pre_roll: std::mem::take(&mut self.seg_pre_roll),
                audio: std::mem::take(&mut self.seg_audio),
                // 该字段描述的是**起点**与上一段的重叠（在 begin_segment 里按
                // last_close_end 精确算出），与"本段是怎么结束的"无关。
                seam_overlap_ms: self.seg_seam_overlap_ms,
                interim: false,
            };
            self.next_id += 1;
            out.push(SegmentEvent::Emit(Box::new(seg)));
        }

        // 记录本段音频在时间轴上的结束位置（当前帧已计入 seg_audio）
        self.last_close_end = Some(self.processed_samples + frame_len as u64);

        self.in_speech = false;
        self.consecutive_speech = 0;
        self.max_consecutive_speech = 0;
        self.silence_frames = 0;
        self.seg_pre_roll.clear();
        self.seg_audio.clear();
        self.seg_raw_sq = 0.0;
        self.seg_raw_n = 0;
        self.seg_seam_overlap_ms = 0;
        self.seg_onset_level = 0.0;
        self.seg_noise_floor = 0.0;
    }

    /// 送入一帧音频（长度应为 `cfg.frame_samples`）。
    pub fn push_frame(&mut self, frame: &[f32], out: &mut Vec<SegmentEvent>) -> FrameOutcome {
        let raw_energy = rms(frame);
        // 本帧 EMA 更新**之前**的噪声底。若本帧正好是段的起点，它就是"这句话开始之前
        // 的房间底噪"，退出判停要用它（用更新后的值会被语音起点自己污染）。
        let prev_noise_floor = self.noise_floor;

        // ---- 噪声底：只用原始能量（单一能量域）----
        let rate = if self.in_speech { 0.999 } else { 0.92 };
        self.noise_floor = self.noise_floor * rate + raw_energy * (1.0 - rate);
        self.noise_floor = self.noise_floor.max(1e-5);

        // ---- 抑制增益：目标限制在 0.6~1.0 并对时间平滑 ----
        let target_gain = if !self.cfg.suppress {
            1.0
        } else {
            let snr = raw_energy / (self.noise_floor * 1.5).max(1e-5);
            if snr >= 3.0 {
                1.0
            } else {
                0.6 + 0.4 * (snr / 3.0).clamp(0.0, 1.0)
            }
        };
        self.gain = self.gain * 0.6 + target_gain * 0.4;

        let mut gated_buf = [0.0f32; VAD_FRAME_SAMPLES];
        let n = frame.len().min(gated_buf.len());
        for i in 0..n {
            gated_buf[i] = frame[i] * self.gain;
        }
        let gated = &gated_buf[..n];

        // ---- 判决（原始能量 vs 用户门限）----
        // 退出用自适应门限，进入用用户门限：见 `exit_threshold`。
        let active = if self.in_speech {
            raw_energy >= self.exit_threshold()
        } else {
            raw_energy >= self.cfg.gate
        };

        let mut closed: Option<(CloseReason, usize)> = None;

        if active {
            if !self.in_speech {
                self.in_speech = true;
                self.consecutive_speech = 1;
                // 快照必须在 pre-roll 缓冲吸收本帧之前完成
                self.begin_segment(raw_energy, prev_noise_floor);
                out.push(SegmentEvent::Start {
                    onset_ms: samples_to_ms(self.processed_samples as usize),
                });
            } else {
                self.consecutive_speech += 1;
            }
            self.max_consecutive_speech = self.max_consecutive_speech.max(self.consecutive_speech);
            self.silence_frames = 0;
            self.seg_audio.extend_from_slice(gated);
            self.seg_raw_sq += frame.iter().map(|s| (*s as f64) * (*s as f64)).sum::<f64>();
            self.seg_raw_n += frame.len() as u64;
        } else if self.in_speech {
            self.silence_frames += 1;
            self.max_consecutive_speech = self.max_consecutive_speech.max(self.consecutive_speech);
            self.consecutive_speech = 0;
            self.seg_audio.extend_from_slice(gated);
            self.seg_raw_sq += frame.iter().map(|s| (*s as f64) * (*s as f64)).sum::<f64>();
            self.seg_raw_n += frame.len() as u64;

            let long_enough = self.max_consecutive_speech >= self.cfg.min_speech_frames;
            if self.silence_frames >= self.cfg.min_silence_frames
                && (long_enough || self.silence_frames >= self.cfg.max_silence_frames)
            {
                closed = Some((CloseReason::Silence, n));
            }
        }

        // ---- 段长上限：强制切段 ----
        if closed.is_none() && self.in_speech && self.seg_audio.len() >= self.cfg.max_segment_samples
        {
            let reason = if self.max_consecutive_speech >= self.cfg.min_speech_frames {
                CloseReason::ForceCut
            } else {
                CloseReason::Silence
            };
            closed = Some((reason, n));
        }

        // ---- 本帧收尾：先关段（需要 pre-roll 视野），再把本帧写进 pre-roll 缓冲 ----
        if let Some((reason, frame_len)) = closed {
            self.close_segment(out, reason, frame_len);
        }
        self.push_pre_roll(gated);
        self.processed_samples += frame.len() as u64;
        // 电平表：与噪声门同一口径（原始 RMS），快启慢落
        self.meter = (self.meter * 0.85).max(raw_energy);

        FrameOutcome {
            in_speech: self.in_speech,
            raw_energy,
            gain: self.gain,
            level: self.level(),
        }
    }

    /// 录音结束：把还在进行中的段吐出来。
    pub fn flush(&mut self, out: &mut Vec<SegmentEvent>) {
        if !self.in_speech {
            return;
        }
        self.max_consecutive_speech = self.max_consecutive_speech.max(self.consecutive_speech);
        let reason = if self.max_consecutive_speech >= self.cfg.min_speech_frames
            && self.seg_audio.len() >= self.cfg.max_segment_samples
        {
            CloseReason::ForceCut
        } else {
            CloseReason::Silence
        };
        let frame_len = self.cfg.frame_samples;
        self.close_segment(out, reason, frame_len);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::peak;

    /// 静音底噪
    const SILENCE: f32 = 0.001;
    /// 低于门限(0.02)但明显高于底噪的"轻声"——用于标识起点之前的音频
    const QUIET: f32 = 0.015;
    /// 语音
    const SPEECH: f32 = 0.2;

    fn cfg() -> SegmenterConfig {
        SegmenterConfig {
            gate: 0.02,
            suppress: false, // 单测关掉增益，便于精确构造能量
            ..Default::default()
        }
    }

    /// 用交替正负号构造 RMS 恰好等于 level 的帧
    fn frame_at(level: f32) -> Vec<f32> {
        (0..VAD_FRAME_SAMPLES)
            .map(|i| if i % 2 == 0 { level } else { -level })
            .collect()
    }

    fn frames_at(n: usize, level: f32) -> Vec<Vec<f32>> {
        (0..n).map(|_| frame_at(level)).collect()
    }

    fn push_many(s: &mut Segmenter, frames: &[Vec<f32>], out: &mut Vec<SegmentEvent>) {
        for f in frames {
            s.push_frame(f, out);
        }
    }

    fn emitted(out: &[SegmentEvent]) -> Vec<&Segment> {
        out.iter()
            .filter_map(|e| match e {
                SegmentEvent::Emit(s) => Some(s.as_ref()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn pure_silence_emits_nothing() {
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        push_many(&mut s, &frames_at(100, SILENCE), &mut out);
        assert!(emitted(&out).is_empty(), "静音不应产出任何段");
        assert!(!s.in_speech());
    }

    #[test]
    fn speech_then_silence_emits_one_segment() {
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        let mut frames = frames_at(34, SPEECH); // ~1s 语音
        frames.extend(frames_at(20, SILENCE)); // ~0.6s 静音
        push_many(&mut s, &frames, &mut out);
        let segs = emitted(&out);
        assert_eq!(segs.len(), 1);
        assert!(segs[0].duration_ms > 900, "段长 {}", segs[0].duration_ms);
        assert!(out.iter().any(|e| matches!(e, SegmentEvent::Start { .. })));
    }

    /// 关键回归：pre-roll 必须是"起点之前"的音频。
    ///
    /// 起点前放 300 ms 的 QUIET（低于门限、高于底噪），它应当完整出现在 pre-roll 里。
    /// 旧实现在推段时取 ring 尾部，那时里面全是**段后静音**，拿到的是 SILENCE 而不是 QUIET。
    #[test]
    fn pre_roll_is_snapshotted_at_onset() {
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        let mut frames = frames_at(10, QUIET); // 起点之前 300ms
        frames.extend(frames_at(30, SPEECH));
        frames.extend(frames_at(20, SILENCE));
        push_many(&mut s, &frames, &mut out);

        let segs = emitted(&out);
        assert_eq!(segs.len(), 1);
        let pr = &segs[0].pre_roll;
        assert!(!pr.is_empty(), "pre-roll 不应为空");
        assert!(
            (290..=310).contains(&samples_to_ms(pr.len())),
            "pre-roll 时长 {}ms 应约 300ms",
            samples_to_ms(pr.len())
        );
        let pr_rms = rms(pr);
        assert!(
            (pr_rms - QUIET).abs() < 0.004,
            "pre-roll 应正好是起点之前的轻声 (rms={pr_rms:.4}，期望 {QUIET})，\
             而不是段后静音 ({SILENCE}) 或段内语音 ({SPEECH})"
        );
        // 段尾（含判停累计的静音）应当是静音，与 pre-roll 形成对照
        let audio = &segs[0].audio;
        assert!(rms(&audio[audio.len() - VAD_FRAME_SAMPLES..]) < 0.01);
    }

    /// 起点那一帧不能被重复算两次（pre-roll 尾部 + 段首）。
    #[test]
    fn pre_roll_excludes_onset_frame() {
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        let mut frames = frames_at(10, QUIET);
        frames.extend(frames_at(6, SPEECH)); // 只够刚刚成段
        frames.extend(frames_at(20, SILENCE));
        push_many(&mut s, &frames, &mut out);
        let segs = emitted(&out);
        assert_eq!(segs.len(), 1);
        let pr_max = peak(&segs[0].pre_roll);
        assert!(
            pr_max <= QUIET + 1e-5,
            "pre-roll 里不该出现语音帧的幅度（peak={pr_max}），说明起点帧被重复计入"
        );
    }

    #[test]
    fn too_short_burst_is_rejected() {
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        let mut frames = frames_at(1, SPEECH); // 只有 1 帧，< min_speech_frames(3)
        frames.extend(frames_at(80, SILENCE)); // 足够触发兜底静音判停
        push_many(&mut s, &frames, &mut out);
        assert!(emitted(&out).is_empty());
        assert!(out.iter().any(|e| matches!(
            e,
            SegmentEvent::Reject {
                reason: RejectReason::TooShort,
                ..
            }
        )));
    }

    #[test]
    fn quiet_segment_is_rejected() {
        let mut c = cfg();
        c.gate = 0.001; // 门限调很低，让很轻的声音也能进入语音态
        c.energy_floor = 0.05; // 但整体 RMS 下限抬高
        let mut s = Segmenter::new(c);
        let mut out = Vec::new();
        let mut frames = frames_at(20, 0.01);
        frames.extend(frames_at(20, 0.0001));
        push_many(&mut s, &frames, &mut out);
        assert!(emitted(&out).is_empty());
        assert!(out.iter().any(|e| matches!(
            e,
            SegmentEvent::Reject {
                reason: RejectReason::TooQuiet,
                ..
            }
        )));
    }

    /// 强制切段：段长到上限就切开，且下一段的 pre-roll 接上上一段的尾巴。
    #[test]
    fn force_cut_marks_seam_and_next_segment_gets_tail_as_pre_roll() {
        let mut c = cfg();
        c.max_segment_samples = VAD_FRAME_SAMPLES * 10; // 300ms 就强制切段
        let mut s = Segmenter::new(c);
        let mut out = Vec::new();
        push_many(&mut s, &frames_at(30, SPEECH), &mut out);
        let segs = emitted(&out);
        assert!(segs.len() >= 3, "应被强制切成多段，实际 {}", segs.len());
        for seg in segs.iter().skip(1) {
            assert!(
                (rms(&seg.pre_roll) - SPEECH).abs() < 0.01,
                "强制切段后 pre-roll 应接上上一段尾巴（rms={:.4}）",
                rms(&seg.pre_roll)
            );
            assert!(
                seg.seam_overlap_ms > 0,
                "强制切段产生的段应标记接缝重叠"
            );
        }
        // 静音判停产生的段不应被误标接缝
        let mut s2 = Segmenter::new(cfg());
        let mut out2 = Vec::new();
        let mut f = frames_at(30, SPEECH);
        f.extend(frames_at(20, SILENCE));
        push_many(&mut s2, &f, &mut out2);
        let segs2 = emitted(&out2);
        assert_eq!(segs2.len(), 1);
        assert_eq!(
            segs2[0].seam_overlap_ms, 0,
            "静音判停的段不该带接缝重叠"
        );
    }

    /// 相隔很久的两段之间不应产生接缝标记。
    #[test]
    fn distant_segments_have_no_seam_overlap() {
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        let mut frames = frames_at(20, SPEECH);
        frames.extend(frames_at(30, SILENCE));
        frames.extend(frames_at(20, SPEECH));
        frames.extend(frames_at(20, SILENCE));
        push_many(&mut s, &frames, &mut out);
        let segs = emitted(&out);
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[1].seam_overlap_ms, 0, "间隔 900ms 已超出 pre-roll 窗口");
    }

    /// 回归：底噪落在 `(gate*0.5, gate)` 区间时，段必须**按时**收尾。
    ///
    /// 这是真机上"实时预览停住了、电平也降下去了，却迟迟不出字"的根因：判停只比
    /// `gate*0.5`，而房间底噪（0.015）高于它、又低于门限（0.02）→ `silence_frames`
    /// 永远不累加 → 段只能等 `max_segment_samples`（默认 8 s）强制切段，所以"有时候快
    /// 有时候慢"（取决于那一刻的底噪是否恰好低于 `gate*0.5`）。
    #[test]
    fn segment_closes_when_noise_sits_above_half_gate() {
        const NOISE: f32 = 0.015; // > gate*0.5 (0.01)、< gate (0.02)
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        // 先静置 1 s，让噪声底收敛到真实底噪
        push_many(&mut s, &frames_at(30, NOISE), &mut out);
        assert!(!s.in_speech(), "底噪低于门限，不该进入语音态");
        // 说 0.6 s，然后停下来（停下来的音量仍高于 gate*0.5）
        push_many(&mut s, &frames_at(20, SPEECH), &mut out);
        push_many(&mut s, &frames_at(30, NOISE), &mut out);

        let segs = emitted(&out);
        assert_eq!(segs.len(), 1, "停嘴后应当收出一个段");
        // 20 帧语音 + 10 帧判停静音 = 900 ms。旧口径会一直等到 8 s 强制切段。
        assert!(
            segs[0].duration_ms <= 1100,
            "段长 {}ms 说明判停没有及时收尾（旧口径要等 8 s 强制切段）",
            segs[0].duration_ms
        );
        assert!(!s.in_speech(), "停嘴 0.9 s 后不该还留在语音态里");
    }

    /// 门限被压到远低于底噪时，**不要**启用自适应判停。
    ///
    /// 那种情况下"起点电平 ≈ 噪声底"，自适应会把整段都判成静音、把段切碎。宁可退回
    /// 原来的 `gate*HYSTERESIS`：门限设置本身有问题，该让用户看到原始症状。
    #[test]
    fn adaptive_exit_is_disabled_when_gate_is_below_noise() {
        const NOISE: f32 = 0.01;
        let mut c = cfg();
        c.gate = 0.001; // 远低于底噪
        let mut s = Segmenter::new(c);
        let mut out = Vec::new();
        push_many(&mut s, &frames_at(20, NOISE), &mut out);
        // 底噪高于门限 → 被判成"语音"，这是门限设置问题，不是分段问题
        assert!(s.in_speech());
        assert!(
            s.exit_threshold() < NOISE,
            "起点电平与噪声底同量级时，退出门限 {:?} 不该高于底噪 {NOISE}",
            s.exit_threshold()
        );
    }

    /// 单一能量域的回归：开启抑制时，略高于门限的语音仍要被判为语音。
    /// 旧实现用"降噪后能量 vs 原始门限"，增益 <1 会把这类语音整体判成静音。
    #[test]
    fn suppression_does_not_raise_effective_gate() {
        let mut c = cfg();
        c.suppress = true;
        c.gate = 0.02;
        let mut s = Segmenter::new(c);
        let mut out = Vec::new();
        let mut frames = frames_at(30, 0.03); // 略高于门限
        frames.extend(frames_at(20, 0.0002));
        push_many(&mut s, &frames, &mut out);
        let segs = emitted(&out);
        assert_eq!(segs.len(), 1, "略高于门限的语音不应被增益压成静音");
        let audio_rms = rms(&segs[0].audio[..VAD_FRAME_SAMPLES]);
        assert!(audio_rms > 0.018, "段内音频不应被压到门限以下（{audio_rms:.4}）");
    }

    #[test]
    fn gain_is_smoothed_not_jumpy() {
        let mut c = cfg();
        c.suppress = true;
        let mut s = Segmenter::new(c);
        let mut out = Vec::new();
        let mut prev = 1.0f32;
        let mut max_jump: f32 = 0.0;
        for i in 0..60 {
            let level = if i % 2 == 0 { 0.5 } else { 0.001 };
            let o = s.push_frame(&frame_at(level), &mut out);
            max_jump = max_jump.max((o.gain - prev).abs());
            prev = o.gain;
        }
        assert!(max_jump < 0.25, "增益单帧跳变 {max_jump:.3} 过大");
    }

    #[test]
    fn flush_emits_in_progress_segment() {
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        push_many(&mut s, &frames_at(30, SPEECH), &mut out);
        assert!(emitted(&out).is_empty(), "没有静音不应自行收段");
        let mut fin = Vec::new();
        s.flush(&mut fin);
        assert_eq!(emitted(&fin).len(), 1, "flush 应把进行中的段吐出来");
    }

    #[test]
    fn reset_clears_segment_state() {
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        push_many(&mut s, &frames_at(30, SPEECH), &mut out);
        assert!(s.in_speech());
        s.reset();
        assert!(!s.in_speech());
        assert_eq!(s.current_segment_ms(), 0);
        assert_eq!(s.processed_ms(), 0);
    }

    #[test]
    fn interim_snapshot_only_during_speech() {
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        assert!(s.interim_snapshot().is_none());
        push_many(&mut s, &frames_at(10, SPEECH), &mut out);
        assert!(s.interim_snapshot().is_some());
    }

    /// interim 快照必须打上标记：否则解码层会把它当正式段处理，
    /// 半句就会被写进字幕文件并触发自动发言。
    #[test]
    fn interim_snapshot_is_flagged_and_never_final() {
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        push_many(&mut s, &frames_at(10, SPEECH), &mut out);
        let snap = s.interim_snapshot().expect("应有 interim 快照");
        assert!(snap.interim, "interim 快照必须带 interim 标记");
        assert_eq!(snap.id, u64::MAX, "interim 不应占用正式段号");

        // 正式段必须是 interim = false
        push_many(&mut s, &frames_at(20, SILENCE), &mut out);
        let finals: Vec<_> = out
            .iter()
            .filter_map(|e| match e {
                SegmentEvent::Emit(seg) => Some(seg),
                _ => None,
            })
            .collect();
        assert!(!finals.is_empty(), "静音后应产出一个正式段");
        assert!(finals.iter().all(|s| !s.interim), "正式段不能带 interim 标记");
        assert!(finals.iter().all(|s| s.id != u64::MAX), "正式段应有正常段号");
    }

    /// interim 快照必须**只取尾部窗口**，不能把整段送进识别器。
    /// 它与正式段共用解码线程，送整段会让解码耗时随句长增长，把紧随其后的
    /// 正式段挡在后面 —— 用户感受就是"说完一句话要卡一下才出字"。
    #[test]
    fn interim_snapshot_is_capped_to_tail_window() {
        let mut c = cfg();
        c.interim_window_samples = 16_000; // 1 s 窗口
        let mut s = Segmenter::new(c);
        let mut out = Vec::new();
        // 连续 3 s 语音（远超 1 s 窗口），中间不给静音
        push_many(&mut s, &frames_at(100, SPEECH), &mut out);
        let snap = s.interim_snapshot().expect("应有 interim 快照");
        assert_eq!(
            snap.audio.len(),
            16_000,
            "超过窗口时必须恰好截取尾部一个窗口，实际 {}",
            snap.audio.len()
        );
        assert!(snap.pre_roll.is_empty(), "尾部窗口不该再带段起点前的 pre-roll");
        assert_eq!(snap.duration_ms, 1000, "duration 应反映窗口长度");
    }

    #[test]
    fn meter_has_decay_ballistics() {
        let mut s = Segmenter::new(cfg());
        let mut out = Vec::new();
        s.push_frame(&frame_at(0.05), &mut out);
        let loud = s.level();
        for _ in 0..3 {
            s.push_frame(&frame_at(SILENCE), &mut out);
        }
        let after = s.level();
        assert!(loud > 0.4, "响帧电平 {loud}");
        assert!(after < loud, "电平应衰减：{loud} → {after}");
        assert!(after > 0.0, "不应瞬间归零");
    }

    /// 回归：电平表必须与噪声门**同一口径**（原始 RMS）。
    ///
    /// 旧实现电平 = 峰值 × 10、判决 = RMS vs gate。同一个尖峰，峰值比 RMS 高一个
    /// 数量级，于是电平条打满、门线还稳稳在下面，却一个字都不出 —— 用户的原话是
    /// "明明音量电平对比这么大为什么没有输出"。
    #[test]
    fn meter_uses_the_same_energy_domain_as_gate() {
        let mut c = cfg();
        c.gate = 0.05;
        let mut s = Segmenter::new(c);
        let mut out = Vec::new();
        // 稀疏尖峰帧：峰值 0.5、RMS≈0.046（低于门限），正是"电平看着很满但不触发"的音频
        let mut f = vec![0.0f32; VAD_FRAME_SAMPLES];
        for x in f.iter_mut().take(4) {
            *x = 0.5;
        }
        let o = s.push_frame(&f, &mut out);
        assert!(!o.in_speech, "RMS 低于门限就不该进入语音态");

        let level = s.level();
        assert!(
            (level - 0.456).abs() < 0.01,
            "电平应是 rms*10≈0.46，实际 {level}"
        );
        assert!(
            level < c.gate * 10.0,
            "电平 {level} 应低于门线 {}：与'没出字'的结论一致",
            c.gate * 10.0
        );
        // 旧口径（峰值×10）会把这个电平顶到 1.0，远在门线之上 —— 那正是困惑的来源
        assert!((peak(&f) * 10.0).min(1.0) > c.gate * 10.0);
    }
}
