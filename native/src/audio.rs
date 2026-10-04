//! 采集侧基础设施：无锁环形缓冲、带抗混叠的流式重采样、帧级特征。
//!
//! 这一层的硬约束是：`AudioRing::push_slice` 运行在 cpal 的**实时音频线程**上，
//! 不允许分配、不允许加锁、不允许阻塞。它只做两件 O(n) 的纯计算：写入环形缓冲、
//! 以及（调用方在进入之前完成的）单声道下混。

use std::sync::atomic::{AtomicU64, Ordering};

pub const ASR_SAMPLE_RATE: u32 = 16_000;

/// 帧级 RMS 能量。
pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

/// 帧级绝对值峰值（0..1 量级，用于电平表）。
pub fn peak(samples: &[f32]) -> f32 {
    samples.iter().fold(0.0f32, |m, &s| m.max(s.abs()))
}

// ---------------------------------------------------------------- SPSC 环形缓冲

/// 单生产者 / 单消费者无锁环形缓冲（f32）。
///
/// - 生产者：实时音频回调线程，只写 `head`
/// - 消费者：front-end 线程，只写 `tail`
///
/// **溢出策略是"丢最新"而不是"丢最旧"**，这是刻意的：让生产者去推进 `tail` 才能实现
/// 丢最旧，但那会让两个线程同时写同一个原子量，产生竞态窗口。丢最新的代价只是消费者
/// 多处理一段稍旧但连续的音频（处理速度远快于实时，很快就能追上）；换来的是**完全
/// 无竞态**——每个原子量都只有一个写入方。丢样数量记在 `dropped()` 里，可观测。
pub struct AudioRing {
    /// 缓冲区**裸指针**（`Box::into_raw` 得到，`Drop` 时用 `Box::from_raw` 还原）。
    ///
    /// 刻意不用 `UnsafeCell<Box<[f32]>>`：那样 push/pop 各自会从 `UnsafeCell` 造出
    /// 覆盖**整个缓冲区**的 `&mut [f32]`。两段字节区间不相交因而**不是数据竞争**，
    /// 但两个 `&mut` 同时存活按 Stacked/Tree Borrows 是无效引用，LLVM 的 `noalias`
    /// 有理论优化风险。裸指针 + `ptr::copy_nonoverlapping` 不构造任何这种引用。
    ptr: *mut f32,
    /// 缓冲区长度（已向上取整到 2 的幂）
    cap: usize,
    /// capacity - 1，capacity 必须是 2 的幂
    mask: u64,
    /// 生产者：已写入的样本总数（单调递增，不取模）
    head: AtomicU64,
    /// 消费者：已读出的样本总数（单调递增，不取模）
    tail: AtomicU64,
    dropped: AtomicU64,
}

impl AudioRing {
    /// `capacity` 会向上取整到 2 的幂。
    pub fn new(capacity: usize) -> Self {
        let cap = capacity.next_power_of_two().max(1024);
        let boxed: Box<[f32]> = vec![0.0; cap].into_boxed_slice();
        Self {
            // 所有权交给裸指针，生命周期由下面的 Drop 负责
            ptr: Box::into_raw(boxed) as *mut f32,
            cap,
            mask: (cap as u64) - 1,
            head: AtomicU64::new(0),
            tail: AtomicU64::new(0),
            dropped: AtomicU64::new(0),
        }
    }

    pub fn capacity(&self) -> usize {
        self.cap
    }

    /// 当前可读样本数。
    pub fn len(&self) -> usize {
        let h = self.head.load(Ordering::Acquire);
        let t = self.tail.load(Ordering::Relaxed);
        h.wrapping_sub(t).min(self.mask + 1) as usize
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// 累计因缓冲已满而丢弃的样本数。
    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }

    /// 生产者侧写入。缓冲满时丢弃写不下的部分并计数，绝不阻塞。
    pub fn push_slice(&self, data: &[f32]) {
        if data.is_empty() {
            return;
        }
        // 只有生产者写 head，Relaxed 读取自己的值即可
        let h = self.head.load(Ordering::Relaxed);
        // 需要看到消费者最新的 tail
        let t = self.tail.load(Ordering::Acquire);
        // 保留一个空槽以区分"满"和"空"
        let used = h.wrapping_sub(t);
        let space = self.mask.saturating_sub(used) as usize;
        let n = data.len().min(space);
        if n == 0 {
            self.dropped.fetch_add(data.len() as u64, Ordering::Relaxed);
            return;
        }
        let start = (h & self.mask) as usize;
        // 环形写入：可能跨越末尾，拆成两段。裸指针直接拷，不构造 &mut [f32]。
        // SAFETY: 生产者只写 [head, head+n) 这段槽位，消费者只读 [tail, head)，
        // 两者按 head/tail 的 acquire/release 协议永不相交；且 start + n <= cap
        // （n <= space <= mask - used，由上面的 space 计算保证）。
        unsafe {
            let first = n.min(self.cap - start);
            std::ptr::copy_nonoverlapping(data.as_ptr(), self.ptr.add(start), first);
            if first < n {
                std::ptr::copy_nonoverlapping(data.as_ptr().add(first), self.ptr, n - first);
            }
        }
        // Release：确保上面写入的样本对消费者可见
        self.head.store(h.wrapping_add(n as u64), Ordering::Release);
        if n < data.len() {
            self.dropped
                .fetch_add((data.len() - n) as u64, Ordering::Relaxed);
        }
    }

    /// 消费者侧读出，返回实际读到的样本数。
    pub fn pop_slice(&self, out: &mut [f32]) -> usize {
        if out.is_empty() {
            return 0;
        }
        // 只有消费者写 tail，Relaxed 读取自己的值即可
        let t = self.tail.load(Ordering::Relaxed);
        // 需要看到生产者最新的 head（Acquire 保证样本数据可见）
        let h = self.head.load(Ordering::Acquire);
        let avail = h.wrapping_sub(t).min(self.mask + 1) as usize;
        let n = avail.min(out.len());
        if n == 0 {
            return 0;
        }
        let start = (t & self.mask) as usize;
        // SAFETY: 与 push_slice 对偶——消费者只读 [tail, tail+n) 这段槽位，
        // 生产者只写 [head, ...)；且 start + n <= cap。
        unsafe {
            let first = n.min(self.cap - start);
            std::ptr::copy_nonoverlapping(
                self.ptr.add(start) as *const f32,
                out.as_mut_ptr(),
                first,
            );
            if first < n {
                std::ptr::copy_nonoverlapping(
                    self.ptr as *const f32,
                    out.as_mut_ptr().add(first),
                    n - first,
                );
            }
        }
        // Release：告知生产者这些槽可以复用了
        self.tail.store(t.wrapping_add(n as u64), Ordering::Release);
        n
    }
}

impl Drop for AudioRing {
    fn drop(&mut self) {
        // SAFETY: ptr 来自 new() 的 Box::into_raw，且此 Drop 只会执行一次；
        // 还原成 Box<[f32]> 后由 Box 自己释放。
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                self.ptr, self.cap,
            )));
        }
    }
}

// 裸指针本身不是 Send/Sync，这里的承诺是：跨线程安全完全由上面描述的 head/tail
// 协议建立（生产者只写 head 之后、消费者只读 tail 之前，同一槽位不会被两个线程
// 同时访问）。除这两个原子量外没有别的共享可变状态。
unsafe impl Send for AudioRing {}
unsafe impl Sync for AudioRing {}

// ---------------------------------------------------------------- 流式重采样

/// 设计一个线性相位低通 FIR（Hamming 窗），`fc` 为归一化截止频率（1.0 = 采样率）。
fn design_lowpass(taps: usize, fc: f64) -> Vec<f32> {
    let m = (taps - 1) as f64;
    let mut h: Vec<f32> = (0..taps)
        .map(|i| {
            let n = i as f64 - m / 2.0;
            let sinc = if n.abs() < 1e-9 {
                2.0 * fc
            } else {
                (2.0 * std::f64::consts::PI * fc * n).sin() / (std::f64::consts::PI * n)
            };
            let w = if m > 0.0 {
                0.54 - 0.46 * (2.0 * std::f64::consts::PI * i as f64 / m).cos()
            } else {
                1.0
            };
            (sinc * w) as f32
        })
        .collect();
    // 直流增益归一化，保证通带电平不变
    let sum: f32 = h.iter().sum();
    if sum.abs() > 1e-9 {
        for v in &mut h {
            *v /= sum;
        }
    }
    h
}

/// 带抗混叠、且**跨块相位连续**的流式重采样器。
///
/// 与旧实现（每块独立线性插值）的两个关键差别：
/// 1. 降采样前先过低通 FIR。48k→16k 时 8 kHz 以上的能量原本会折返进语音带
///    （键盘声、齿音），线性插值对此毫无抵抗。
/// 2. 相位用 `f64` 累加跨块保持。旧的逐块实现每块都会把小数部分丢掉，
///    44.1 kHz 设备上每 10 ms 就多算一个样本，一小时能漂出几十万个样本
///    （约等于秒级的音频错位）。
pub struct StreamResampler {
    ratio: f64,
    /// 下一个输出样本在"滤波后信号"坐标里的位置（绝对索引，单调递增）
    next_src: f64,
    /// 当前滤波块的第一个样本对应的绝对索引
    origin: i64,
    /// 可读的最低绝对索引（第一块为 0，之后为 origin-1，因为保留了上一块末尾样本）
    valid_from: i64,
    fir: Vec<f32>,
    /// 上块末尾 FIR_LEN-1 个原始样本
    hist: Vec<f32>,
    /// 复用缓冲：hist ++ input
    work: Vec<f32>,
    /// 复用缓冲：滤波后（长度 == 本块 input 长度）
    filt: Vec<f32>,
    /// 上一块滤波结果的最后一个样本，用于跨块线性插值
    prev_last: Option<f32>,
}

impl StreamResampler {
    pub fn new(input_rate: u32, output_rate: u32) -> Self {
        let ratio = input_rate as f64 / output_rate as f64;
        let taps = if ratio > 1.0001 {
            ((8.0 * ratio).round() as usize + 1).clamp(5, 129)
        } else {
            0
        };
        let fir = if taps > 1 {
            // 截止取输出奈奎斯特的 0.9 倍，避免过渡带贴太紧导致通带起伏
            let fc = 0.45 * output_rate as f64 / input_rate as f64;
            design_lowpass(taps, fc.min(0.49))
        } else {
            Vec::new()
        };
        Self {
            ratio,
            next_src: 0.0,
            origin: 0,
            valid_from: 0,
            hist: vec![0.0; fir.len().saturating_sub(1)],
            fir,
            work: Vec::new(),
            filt: Vec::new(),
            prev_last: None,
        }
    }

    pub fn is_passthrough(&self) -> bool {
        (self.ratio - 1.0).abs() < 1e-9
    }

    fn at(&self, abs: i64) -> f32 {
        if abs < self.origin {
            // 只有 origin-1 这一个位置有效，对应上一块的末尾
            self.prev_last.unwrap_or(0.0)
        } else {
            let idx = (abs - self.origin) as usize;
            self.filt.get(idx).copied().unwrap_or(0.0)
        }
    }

    /// 处理一块输入，把产生的输出追加到 `out`。
    pub fn process(&mut self, input: &[f32], out: &mut Vec<f32>) {
        if input.is_empty() {
            return;
        }
        if self.is_passthrough() {
            out.extend_from_slice(input);
            return;
        }

        let k = self.fir.len();
        // ---- 1) FIR 滤波（含历史），滤波后样本数与本块输入样本数相同 ----
        self.work.clear();
        if k > 0 {
            self.work.extend_from_slice(&self.hist);
        }
        self.work.extend_from_slice(input);

        self.filt.clear();
        if k == 0 || self.work.len() < k {
            self.filt.extend_from_slice(&self.work);
        } else {
            self.filt.reserve(self.work.len() - k + 1);
            for i in 0..=(self.work.len() - k) {
                let mut acc = 0.0f32;
                for j in 0..k {
                    acc += self.work[i + j] * self.fir[j];
                }
                self.filt.push(acc);
            }
        }

        // ---- 2) 更新历史（供下一块 FIR 使用）----
        if k > 1 {
            let keep = k - 1;
            self.hist.clear();
            let n = input.len();
            if n >= keep {
                self.hist.extend_from_slice(&input[n - keep..]);
            } else {
                // 极短的块：从 work 尾部补齐
                let need = keep - n;
                let wl = self.work.len();
                self.hist
                    .extend_from_slice(&self.work[wl.saturating_sub(need)..wl]);
                self.hist.extend_from_slice(input);
                if self.hist.len() > keep {
                    let cut = self.hist.len() - keep;
                    self.hist.drain(..cut);
                }
            }
        }

        // ---- 3) 相位连续的分数插值 ----
        let n_filt = self.filt.len() as i64;
        if n_filt == 0 {
            return;
        }
        let last_valid = self.origin + n_filt - 1;
        let approx_out = (input.len() as f64 / self.ratio) as usize + 2;
        out.reserve(approx_out);

        while self.next_src >= self.valid_from as f64
            && self.next_src + 1.0 <= last_valid as f64
        {
            let i = self.next_src.floor();
            let f = (self.next_src - i) as f32;
            let a = self.at(i as i64);
            let b = self.at(i as i64 + 1);
            out.push(a + (b - a) * f);
            self.next_src += self.ratio;
        }

        // ---- 4) 块之间交接 ----
        self.prev_last = self.filt.last().copied();
        self.origin += n_filt;
        self.valid_from = self.origin - 1;
    }
}

/// 一次性重采样（离线工具 / 测试用），内部仍走同一套抗混叠 + 相位连续逻辑。
pub fn resample_all(input: &[f32], input_rate: u32, output_rate: u32) -> Vec<f32> {
    let mut r = StreamResampler::new(input_rate, output_rate);
    let mut out = Vec::with_capacity((input.len() as f64 * output_rate as f64 / input_rate as f64) as usize + 8);
    r.process(input, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(freq: f64, rate: u32, secs: f64) -> Vec<f32> {
        let n = (rate as f64 * secs) as usize;
        (0..n)
            .map(|i| {
                (2.0 * std::f64::consts::PI * freq * i as f64 / rate as f64).sin() as f32 * 0.5
            })
            .collect()
    }

    fn amplitude(signal: &[f32]) -> f32 {
        // 去掉首尾各 10% 的过渡段再取峰值
        let n = signal.len();
        if n < 16 {
            return peak(signal);
        }
        let a = n / 10;
        peak(&signal[a..n - a])
    }

    #[test]
    fn test_rms() {
        let samples = vec![1.0, -1.0, 1.0, -1.0];
        assert!((rms(&samples) - 1.0).abs() < 0.001);
    }

    #[test]
    fn ring_basic_roundtrip() {
        let r = AudioRing::new(1024);
        let data: Vec<f32> = (0..500).map(|i| i as f32).collect();
        r.push_slice(&data);
        assert_eq!(r.len(), 500);
        let mut out = vec![0.0; 1024];
        let n = r.pop_slice(&mut out);
        assert_eq!(n, 500);
        assert_eq!(&out[..n], &data[..]);
        assert_eq!(r.len(), 0);
        assert_eq!(r.dropped(), 0);
    }

    #[test]
    fn ring_wraps_and_preserves_order() {
        let r = AudioRing::new(1024); // 取整后 1024
        let mut out = vec![0.0; 4096];
        let mut expect = Vec::new();
        let mut got = Vec::new();
        // 多次小块写入 + 读出，跨越环的末尾
        for round in 0..40 {
            let block: Vec<f32> = (0..300).map(|i| (round * 300 + i) as f32).collect();
            r.push_slice(&block);
            expect.extend_from_slice(&block);
            let n = r.pop_slice(&mut out);
            got.extend_from_slice(&out[..n]);
        }
        assert_eq!(got, expect);
        assert_eq!(r.dropped(), 0);
    }

    #[test]
    fn ring_overflow_drops_newest_and_counts() {
        let r = AudioRing::new(1024);
        // 容量 1024，保留一个空槽 → 最多存 1023
        let data: Vec<f32> = (0..2000).map(|i| i as f32).collect();
        r.push_slice(&data);
        assert_eq!(r.len(), 1023);
        assert_eq!(r.dropped(), 2000 - 1023);
        // 读出来的应当是**最旧**的那一段（丢最新语义）
        let mut out = vec![0.0; 2000];
        let n = r.pop_slice(&mut out);
        assert_eq!(n, 1023);
        assert_eq!(out[0], 0.0);
        assert_eq!(out[n - 1], 1022.0);
    }

    #[test]
    fn resample_same_rate_is_passthrough() {
        let input = vec![0.5; 100];
        let out = resample_all(&input, 16000, 16000);
        assert_eq!(out.len(), 100);
        assert_eq!(out, input);
    }

    /// 48k → 16k 恰为 3:1，整块处理时样本数应精确为 1/3。
    #[test]
    fn resample_48k_to_16k_exact_ratio() {
        let input = tone(1000.0, 48000, 0.3);
        let out = resample_all(&input, 48000, 16000);
        let expect = input.len() / 3;
        assert!(
            (out.len() as i64 - expect as i64).abs() <= 2,
            "输出 {} 期望约 {}",
            out.len(),
            expect
        );
    }

    /// 关键回归：分块处理时不能丢相位。
    /// 44.1k → 16k 的比值为 2.75625，逐块独立插值会在每块末尾把小数部分丢掉，
    /// 于是每 10 ms 多算一个样本，长时间运行产生系统性漂移。
    #[test]
    fn resample_44100_stream_has_no_drift() {
        let rate = 44100u32;
        let secs = 2.0;
        let input = tone(1000.0, rate, secs);
        let mut r = StreamResampler::new(rate, ASR_SAMPLE_RATE);
        let mut out = Vec::new();
        // 按 10ms（441 样本）分块，模拟真实回调粒度
        for chunk in input.chunks(441) {
            r.process(chunk, &mut out);
        }
        let expect = (input.len() as f64 / (rate as f64 / ASR_SAMPLE_RATE as f64)).round() as i64;
        assert!(
            (out.len() as i64 - expect).abs() <= 2,
            "流式输出 {} 期望 {}（漂移 {}）",
            out.len(),
            expect,
            out.len() as i64 - expect
        );
    }

    /// 抗混叠：12 kHz 以上的能量在 48k→16k 后必须被显著压制，
    /// 否则会折返到 4 kHz 附近污染语音带。旧实现（无滤波）几乎不衰减。
    #[test]
    fn resample_rejects_aliasing_band() {
        let high = resample_all(&tone(15000.0, 48000, 0.5), 48000, 16000);
        let pass = resample_all(&tone(1000.0, 48000, 0.5), 48000, 16000);
        let a_high = amplitude(&high);
        let a_pass = amplitude(&pass);
        let atten_db = 20.0 * (a_high / a_pass.max(1e-9)).log10();
        assert!(
            atten_db < -20.0,
            "15kHz 抑制只有 {atten_db:.1} dB（输入幅度 {a_pass:.4} 输出 {a_high:.4}）"
        );
    }

    /// 通带不能被压掉。
    #[test]
    fn resample_keeps_passband() {
        let input = tone(1000.0, 48000, 0.5);
        let out = resample_all(&input, 48000, 16000);
        let ratio = amplitude(&out) / amplitude(&input).max(1e-9);
        assert!(
            (0.9..1.1).contains(&ratio),
            "通带增益 {ratio:.3} 不在 0.9~1.1"
        );
    }

    /// 4 kHz 仍在 8 kHz 输出奈奎斯特内，应保留。
    #[test]
    fn resample_keeps_4khz() {
        let input = tone(4000.0, 48000, 0.5);
        let out = resample_all(&input, 48000, 16000);
        let ratio = amplitude(&out) / amplitude(&input).max(1e-9);
        assert!(ratio > 0.7, "4kHz 增益只有 {ratio:.3}");
    }
}
