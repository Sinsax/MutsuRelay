//! 离线回放工具：把 WAV 喂进**与线上完全相同**的分段 + 解码链路，
//! 输出每段文本、耗时，并可选计算 CER。
//!
//! 这是后面所有"精度变好了"结论的前提——没有它，调参只能靠耳朵听。
//!
//! 用法：
//! ```sh
//! cargo run --release --example replay -- --model asr/model --wav test.wav --ref ref.txt
//! ```
//!
//! 常用开关：
//!
//! | 开关 | 作用 |
//! |---|---|
//! | `--no-denoise` | 关掉噪声抑制增益，作为对照 |
//! | `--seg-max=8000` | 段长上限（毫秒），默认 8000 |
//! | `--no-preroll` | 丢弃 pre-roll（复现旧行为） |
//! | `--no-seam` | 关掉接缝去重（复现旧行为） |
//! | `--dump-segments=dir` | 把每段导成 16k 单声道 WAV，便于人耳 A/B |
//! | `--text=out.txt` | 把结果写文件 |
//! | `--ref=ref.txt` | 参考文本（逐段/整篇），用于算 CER |
//! | `--json` | 输出机器可读的汇总 JSON |
//! | `--quiet` | 只输出汇总 |

use std::time::Instant;

use mutsurelay_native::asr::create_recognizer;
use mutsurelay_native::audio::{resample_all, ASR_SAMPLE_RATE};
use mutsurelay_native::segmenter::{Segment, SegmentEvent, Segmenter, SegmenterConfig};
use mutsurelay_native::text::{chars_only, split_sentence, TextPipeline};

// ---------------------------------------------------------------- WAV 读写

struct Wav {
    rate: u32,
    channels: u16,
    /// 已下混为单声道
    mono: Vec<f32>,
}

fn read_wav(path: &str) -> Result<Wav, String> {
    let data = std::fs::read(path).map_err(|e| format!("读取 {path} 失败: {e}"))?;
    if data.len() < 44 || &data[0..4] != b"RIFF" || &data[8..12] != b"WAVE" {
        return Err(format!("{path} 不是合法的 RIFF/WAVE 文件"));
    }
    let mut pos = 12usize;
    let mut fmt: Option<(u16, u16, u32, u16)> = None; // format, channels, rate, bits
    let mut pcm: Option<&[u8]> = None;
    while pos + 8 <= data.len() {
        let id = &data[pos..pos + 4];
        let size = u32::from_le_bytes(data[pos + 4..pos + 8].try_into().unwrap()) as usize;
        let body_start = pos + 8;
        let body_end = (body_start + size).min(data.len());
        if id == b"fmt " && size >= 16 {
            let format = u16::from_le_bytes(data[body_start..body_start + 2].try_into().unwrap());
            let channels =
                u16::from_le_bytes(data[body_start + 2..body_start + 4].try_into().unwrap());
            let rate =
                u32::from_le_bytes(data[body_start + 4..body_start + 8].try_into().unwrap());
            let bits =
                u16::from_le_bytes(data[body_start + 14..body_start + 16].try_into().unwrap());
            fmt = Some((format, channels, rate, bits));
        } else if id == b"data" {
            pcm = Some(&data[body_start..body_end]);
        }
        // chunk 按偶数字节对齐
        pos = body_start + size + (size & 1);
    }
    let (format, channels, rate, bits) =
        fmt.ok_or_else(|| format!("{path} 缺少 fmt 块"))?;
    let pcm = pcm.ok_or_else(|| format!("{path} 缺少 data 块"))?;
    let ch = channels.max(1) as usize;

    let frames: Vec<f32> = match (format, bits) {
        (1, 16) => pcm
            .chunks_exact(2)
            .map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0)
            .collect(),
        (1, 32) => pcm
            .chunks_exact(4)
            .map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]) as f32 / 2147483648.0)
            .collect(),
        (1, 8) => pcm.iter().map(|b| (*b as f32 - 128.0) / 128.0).collect(),
        (3, 32) => pcm
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect(),
        // WAVE_FORMAT_EXTENSIBLE：按位数当普通 PCM 处理
        (0xFFFE, 16) => pcm
            .chunks_exact(2)
            .map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0)
            .collect(),
        _ => {
            return Err(format!(
                "{path} 不支持的格式：format={format} bits={bits}（支持 PCM 8/16/32 与 float32）"
            ))
        }
    };

    // 下混
    let mut mono = Vec::with_capacity(frames.len() / ch);
    if ch == 1 {
        mono.extend_from_slice(&frames);
    } else {
        for frame in frames.chunks_exact(ch) {
            mono.push(frame.iter().sum::<f32>() / ch as f32);
        }
    }

    Ok(Wav {
        rate,
        channels,
        mono,
    })
}

fn write_wav16(path: &str, rate: u32, samples: &[f32]) -> Result<(), String> {
    let mut out = Vec::with_capacity(44 + samples.len() * 2);
    let data_len = (samples.len() * 2) as u32;
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        let v = (s.clamp(-1.0, 1.0) * 32767.0) as i16;
        out.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(path, out).map_err(|e| format!("写 {path} 失败: {e}"))
}

// ---------------------------------------------------------------- CER

/// 字符错误率：编辑距离 / 参考长度。文本先去掉标点与空白、统一小写。
pub fn cer(reference: &str, hypothesis: &str) -> f64 {
    let r: Vec<char> = chars_only(reference)
        .to_lowercase()
        .chars()
        .collect();
    let h: Vec<char> = chars_only(hypothesis)
        .to_lowercase()
        .chars()
        .collect();
    if r.is_empty() {
        return if h.is_empty() { 0.0 } else { 1.0 };
    }
    // 滚动数组的 Levenshtein
    let mut prev: Vec<usize> = (0..=h.len()).collect();
    let mut cur = vec![0usize; h.len() + 1];
    for i in 1..=r.len() {
        cur[0] = i;
        for j in 1..=h.len() {
            let cost = if r[i - 1] == h[j - 1] { 0 } else { 1 };
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[h.len()] as f64 / r.len() as f64
}

// ---------------------------------------------------------------- 主流程

struct Args {
    model: String,
    wav: String,
    lang: String,
    seg_max_ms: u32,
    denoise: bool,
    preroll: bool,
    seam: bool,
    dump_dir: Option<String>,
    text_out: Option<String>,
    reference: Option<String>,
    json: bool,
    quiet: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        model: "asr/model".into(),
        wav: String::new(),
        lang: "zh".into(),
        seg_max_ms: mutsurelay_native::segmenter::DEFAULT_MAX_SEGMENT_MS,
        denoise: true,
        preroll: true,
        seam: true,
        dump_dir: None,
        text_out: None,
        reference: None,
        json: false,
        quiet: false,
    };
    for arg in std::env::args().skip(1) {
        let (k, v) = match arg.split_once('=') {
            Some((k, v)) => (k.to_string(), Some(v.to_string())),
            None => (arg.clone(), None),
        };
        let need = |v: &Option<String>| -> Result<String, String> {
            v.clone().ok_or_else(|| format!("{k} 需要一个值，写成 {k}=... 的形式"))
        };
        match k.as_str() {
            "--model" => a.model = need(&v)?,
            "--wav" => a.wav = need(&v)?,
            "--lang" => a.lang = need(&v)?,
            "--seg-max" => {
                a.seg_max_ms = need(&v)?.parse().map_err(|_| "--seg-max 需为整数毫秒")?
            }
            "--no-denoise" => a.denoise = false,
            "--no-preroll" => a.preroll = false,
            "--no-seam" => a.seam = false,
            "--dump-segments" => a.dump_dir = Some(need(&v)?),
            "--text" => a.text_out = Some(need(&v)?),
            "--ref" => a.reference = Some(need(&v)?),
            "--json" => a.json = true,
            "--quiet" => a.quiet = true,
            "-h" | "--help" => {
                println!("{}", include_str!("replay.rs").lines().take(30).collect::<Vec<_>>().join("\n"));
                std::process::exit(0);
            }
            other => return Err(format!("未知参数 {other}")),
        }
    }
    if a.wav.is_empty() {
        return Err("必须指定 --wav=<文件>（--model 默认为 asr/model）".into());
    }
    Ok(a)
}

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("参数错误: {e}");
            std::process::exit(2);
        }
    };

    // ---- 读音频并重采样到 16k ----
    let wav = match read_wav(&args.wav) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    let audio = if wav.rate == ASR_SAMPLE_RATE {
        wav.mono.clone()
    } else {
        resample_all(&wav.mono, wav.rate, ASR_SAMPLE_RATE)
    };
    let audio_ms = audio.len() as u64 * 1000 / ASR_SAMPLE_RATE as u64;
    if !args.quiet {
        println!(
            "输入 {} | {}Hz {}ch {:.1}s → 16k 单声道 {:.1}s",
            args.wav,
            wav.rate,
            wav.channels,
            wav.mono.len() as f64 / wav.rate as f64,
            audio_ms as f64 / 1000.0
        );
    }

    // ---- 分段（与线上同一套 Segmenter）----
    let mut cfg = SegmenterConfig {
        max_segment_samples: ASR_SAMPLE_RATE as usize * args.seg_max_ms as usize / 1000,
        suppress: args.denoise,
        ..Default::default()
    };
    cfg.gate = 0.02;
    let frame = cfg.frame_samples;
    let mut seg = Segmenter::new(cfg);
    let mut events: Vec<SegmentEvent> = Vec::new();
    for f in audio.chunks(frame) {
        // 末尾不足一帧的补零，保证分段状态机看到完整帧
        if f.len() == frame {
            seg.push_frame(f, &mut events);
        } else {
            let mut padded = vec![0.0; frame];
            padded[..f.len()].copy_from_slice(f);
            seg.push_frame(&padded, &mut events);
        }
    }
    seg.flush(&mut events);

    let mut segments: Vec<Segment> = events
        .iter()
        .filter_map(|e| match e {
            SegmentEvent::Emit(s) => Some((**s).clone()),
            _ => None,
        })
        .collect();
    let rejected = events
        .iter()
        .filter(|e| matches!(e, SegmentEvent::Reject { .. }))
        .count();
    if !args.preroll {
        for s in segments.iter_mut() {
            s.pre_roll.clear();
        }
    }

    // ---- 解码 ----
    let recognizer = match create_recognizer(&args.model, &args.lang) {
        Some(r) => r,
        None => {
            eprintln!(
                "无法加载模型（--model={}）：需要目录下有 model.int8.onnx 与 tokens.txt",
                args.model
            );
            std::process::exit(2);
        }
    };

    let mut pipeline = TextPipeline::default();
    let mut texts: Vec<String> = Vec::new();
    let mut decode_ms: Vec<u64> = Vec::new();
    let mut seam_trimmed = 0usize;

    for s in &segments {
        let stream = recognizer.create_stream();
        if !s.pre_roll.is_empty() {
            stream.accept_waveform(ASR_SAMPLE_RATE as i32, &s.pre_roll);
        }
        stream.accept_waveform(ASR_SAMPLE_RATE as i32, &s.audio);

        let started = Instant::now();
        recognizer.decode(&stream);
        let ms = started.elapsed().as_millis() as u64;
        decode_ms.push(ms);

        let raw = stream.get_result().map(|r| r.text).unwrap_or_default();
        let before = pipeline.seam_trimmed;
        let seam = if args.seam { s.seam_overlap_ms } else { 0 };
        let text = pipeline.accept(&raw, seam, true);
        if pipeline.seam_trimmed > before {
            seam_trimmed += 1;
        }

        if let Some(dir) = &args.dump_dir {
            let _ = std::fs::create_dir_all(dir);
            let path = format!("{dir}/seg{:03}.wav", s.id);
            let _ = write_wav16(&path, ASR_SAMPLE_RATE, &s.full_audio());
        }

        match text {
            Some(t) => {
                if !args.quiet {
                    println!(
                        "seg{:03} onset={:>6}ms len={:>5}ms pre={:>4}ms seam={:>4}ms decode={:>5}ms | {}",
                        s.id,
                        s.onset_ms,
                        s.duration_ms,
                        s.pre_roll.len() as u64 * 1000 / ASR_SAMPLE_RATE as u64,
                        s.seam_overlap_ms,
                        ms,
                        t
                    );
                }
                for part in split_sentence(&t) {
                    texts.push(part);
                }
            }
            None => {
                if !args.quiet {
                    println!(
                        "seg{:03} onset={:>6}ms len={:>5}ms decode={:>5}ms | <被文本层过滤> raw={:?}",
                        s.id, s.onset_ms, s.duration_ms, ms, raw
                    );
                }
            }
        }
    }

    let hypothesis = texts.join("\n");
    let total_decode: u64 = decode_ms.iter().sum();
    let mut sorted = decode_ms.clone();
    sorted.sort_unstable();
    let pct = |q: f64| -> u64 {
        if sorted.is_empty() {
            0
        } else {
            sorted[((sorted.len() - 1) as f64 * q).round() as usize]
        }
    };

    // ---- 汇总 ----
    let cer_value = args.reference.as_ref().and_then(|p| {
        std::fs::read_to_string(p)
            .ok()
            .map(|r| cer(&r, &hypothesis))
    });

    if args.json {
        let v = serde_json::json!({
            "wav": args.wav,
            "audio_ms": audio_ms,
            "segments": segments.len(),
            "rejected": rejected,
            "texts": texts.len(),
            "seam_trimmed": seam_trimmed,
            "decode_total_ms": total_decode,
            "decode_p50_ms": pct(0.5),
            "decode_p95_ms": pct(0.95),
            "decode_max_ms": sorted.last().copied().unwrap_or(0),
            "rtf": if audio_ms > 0 { total_decode as f64 / audio_ms as f64 } else { 0.0 },
            "denoise": args.denoise,
            "preroll": args.preroll,
            "seam": args.seam,
            "seg_max_ms": args.seg_max_ms,
            "cer": cer_value,
            "hypothesis": hypothesis,
        });
        println!("{}", serde_json::to_string_pretty(&v).unwrap());
    } else {
        println!("\n================ 汇总 ================");
        println!("音频时长      : {:.1}s", audio_ms as f64 / 1000.0);
        println!("段数 / 判丢   : {} / {}", segments.len(), rejected);
        println!("输出条数      : {}", texts.len());
        println!("接缝去重次数  : {seam_trimmed}");
        println!(
            "解码耗时      : 合计 {}ms  p50 {}ms  p95 {}ms  max {}ms",
            total_decode,
            pct(0.5),
            pct(0.95),
            sorted.last().copied().unwrap_or(0)
        );
        println!(
            "实时率 RTF    : {:.3}（<1 表示快于实时）",
            if audio_ms > 0 {
                total_decode as f64 / audio_ms as f64
            } else {
                0.0
            }
        );
        println!(
            "开关          : denoise={} preroll={} seam={} seg_max={}ms",
            args.denoise, args.preroll, args.seam, args.seg_max_ms
        );
        if let Some(c) = cer_value {
            println!("CER           : {:.2}%", c * 100.0);
        }
    }

    if let Some(p) = &args.text_out {
        if let Err(e) = std::fs::write(p, &hypothesis) {
            eprintln!("写 {p} 失败: {e}");
        } else if !args.quiet {
            println!("结果已写入 {p}");
        }
    }
}
