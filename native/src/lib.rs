pub mod bilive;
pub mod censor;
pub mod vad;

use std::ffi::{CStr, CString};
use std::io::Read;
use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use vad::{resample_audio, rms, CONTEXT_SAMPLES, INTERIM_INTERVAL, MAX_SEGMENT_SAMPLES, VAD_FRAME_SAMPLES, VAD_MAX_SILENCE_FRAMES, VAD_MIN_SILENCE_FRAMES, VAD_MIN_SPEECH_FRAMES, VAD_HYSTERESIS};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{StreamConfig, BufferSize};

static INITIALIZED: AtomicBool = AtomicBool::new(false);
static IS_RECORDING: AtomicBool = AtomicBool::new(false);
static NOISE_GATE: OnceLock<Mutex<f32>> = OnceLock::new();
static CENSOR_MODE: OnceLock<Mutex<i32>> = OnceLock::new();
static NOISE_SUPPRESS: OnceLock<AtomicBool> = OnceLock::new();
static AUDIO_LEVEL: OnceLock<Mutex<f32>> = OnceLock::new();
static RECOGNITION_TEXT: OnceLock<Mutex<String>> = OnceLock::new();
static MODEL_DIR: OnceLock<Mutex<String>> = OnceLock::new();
static ASR_LANG: OnceLock<Mutex<String>> = OnceLock::new();
static LAST_OUTPUT: OnceLock<Mutex<(String, Instant)>> = OnceLock::new();

fn noise_gate() -> &'static Mutex<f32> {
    NOISE_GATE.get_or_init(|| Mutex::new(0.02))
}
fn censor_mode() -> &'static Mutex<i32> {
    CENSOR_MODE.get_or_init(|| Mutex::new(2))
}
fn noise_suppress() -> &'static AtomicBool {
    NOISE_SUPPRESS.get_or_init(|| AtomicBool::new(true))
}
fn audio_level() -> &'static Mutex<f32> {
    AUDIO_LEVEL.get_or_init(|| Mutex::new(0.0))
}
fn recognition_text() -> &'static Mutex<String> {
    RECOGNITION_TEXT.get_or_init(|| Mutex::new(String::new()))
}
fn model_dir() -> &'static Mutex<String> {
    MODEL_DIR.get_or_init(|| Mutex::new(String::new()))
}
fn asr_lang() -> &'static Mutex<String> {
    ASR_LANG.get_or_init(|| Mutex::new("zh".to_string()))
}
fn last_output() -> &'static Mutex<(String, Instant)> {
    LAST_OUTPUT.get_or_init(|| Mutex::new((String::new(), Instant::now())))
}

const ASR_SAMPLE_RATE: u32 = 16000;

fn find_asr_model() -> Option<(String, String)> {
    let dir = model_dir().lock().ok()?.clone();
    if dir.is_empty() { return None; }
    let model = std::path::Path::new(&dir).join("model.int8.onnx");
    let tokens = std::path::Path::new(&dir).join("tokens.txt");
    if model.exists() && tokens.exists() {
        Some((model.to_string_lossy().to_string(), tokens.to_string_lossy().to_string()))
    } else {
        None
    }
}

// ---- C API ----

#[no_mangle]
pub extern "C" fn mutsurelay_init(model_dir_ptr: *const c_char) -> i32 {
    if INITIALIZED.load(Ordering::SeqCst) { return 0; }
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    _init_internal(model_dir_ptr)
}

/// Reinitialize ASR without restarting the full native library.
/// Called when the user changes the model or ASR language.
#[no_mangle]
pub extern "C" fn mutsurelay_init_asr(model_dir_ptr: *const c_char) -> i32 {
    _init_internal(model_dir_ptr)
}

fn _init_internal(model_dir_ptr: *const c_char) -> i32 {
    let dir = if model_dir_ptr.is_null() { String::new() } else { unsafe { CStr::from_ptr(model_dir_ptr) }.to_string_lossy().to_string() };
    if let Ok(mut m) = model_dir().lock() { *m = dir; }
    censor::reload_blocklist();
    if let Ok(cfg) = bilive::Config::load() {
        if let Ok(mut g) = noise_gate().lock() { *g = cfg.noise_gate; }
        if let Ok(mut m) = censor_mode().lock() { *m = cfg.censor_mode; }
        noise_suppress().store(cfg.noise_suppress, Ordering::SeqCst);
        bilive::init_from_config(&cfg);
        if let Ok(mut a) = asr_lang().lock() { *a = bilive::get_language(); }
    }
    INITIALIZED.store(true, Ordering::SeqCst);
    0
}

#[no_mangle]
pub extern "C" fn mutsurelay_shutdown() {
    if !INITIALIZED.load(Ordering::SeqCst) { return; }
    if IS_RECORDING.load(Ordering::SeqCst) { mutsurelay_stop_recording(); }
    INITIALIZED.store(false, Ordering::SeqCst);
}

#[no_mangle]
pub extern "C" fn mutsurelay_start_recording() -> i32 {
    if IS_RECORDING.load(Ordering::SeqCst) { return 0; }
    IS_RECORDING.store(true, Ordering::SeqCst);
    thread::spawn(move || {
        let ok = std::panic::catch_unwind(|| run_recording_pipeline())
            .ok()
            .and_then(|r| r)
            .is_some();
        if !ok { IS_RECORDING.store(false, Ordering::SeqCst); }
    });
    0
}

#[no_mangle]
pub extern "C" fn mutsurelay_stop_recording() {
    IS_RECORDING.store(false, Ordering::SeqCst);
}

#[no_mangle]
pub extern "C" fn mutsurelay_is_recording() -> i32 {
    IS_RECORDING.load(Ordering::SeqCst) as i32
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_audio_level() -> f64 {
    audio_level().lock().map(|l| *l as f64).unwrap_or(0.0)
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_recognition_result() -> *mut c_char {
    let text = recognition_text()
        .lock()
        .map(|mut t| std::mem::take(&mut *t))
        .unwrap_or_default();
    CString::new(text).unwrap_or_default().into_raw()
}

fn run_recording_pipeline() -> Option<()> {
    println!("[rust] run_recording_pipeline: starting");

    let host = cpal::default_host();
    println!("[rust] host: {:?}", host.id());

    let devices: Vec<_> = host.input_devices().ok()?.collect();
    println!("[rust] input devices: {}", devices.len());
    for d in &devices {
        println!("[rust]   device: {:?}", d.name());
    }

    // Prefer microphone devices, then PulseAudio/PipeWire compat, then hardware ALSA
    let device = devices.iter().find(|d| {
        d.name().map(|n| {
            let nl = n.to_lowercase();
            nl.contains("microphone") || nl.contains("mic") || nl.contains("话筒")
        }).unwrap_or(false)
    }).or_else(|| {
        // "pulse" or "default" works reliably on PipeWire via pulse-to-alsa compat
        devices.iter().find(|d| d.name().map(|n| {
            let nl = n.to_lowercase();
            nl == "pulse" || nl == "default" || nl.starts_with("sysdefault")
        }).unwrap_or(false))
    }).or_else(|| devices.iter().next())?.clone();
    println!("[rust] selected device: {:?}", device.name());

    let config = device.default_input_config().ok()?;
    let channels = config.channels() as usize;
    let input_rate = config.sample_rate().0;
    println!("[rust] default input config: {}ch, {}Hz", channels, input_rate);

    let stream_cfg = StreamConfig {
        channels: config.channels(),
        sample_rate: config.sample_rate(),
        buffer_size: BufferSize::Default,
    };
    println!("[rust] stream config: {}ch, {}Hz, buffer={:?}",
        stream_cfg.channels, stream_cfg.sample_rate.0, stream_cfg.buffer_size);

    let (tx, rx) = std::sync::mpsc::channel::<Vec<f32>>();

    let stream = device.build_input_stream(
        &stream_cfg,
        move |data: &[f32], _: &cpal::InputCallbackInfo| {
            if IS_RECORDING.load(Ordering::SeqCst) { let _ = tx.send(data.to_vec()); }
        },
        |err| println!("[rust] Audio stream error: {err}"),
        None,
    );
    println!("[rust] build_input_stream: {:?}", stream.is_ok());
    let stream = stream.ok()?;

    let play_result = stream.play();
    println!("[rust] stream.play(): {:?}", play_result);
    let _ = play_result;

    let mut ring_buf = Vec::with_capacity(CONTEXT_SAMPLES * 2);
    let mut seg_buf = Vec::with_capacity(MAX_SEGMENT_SAMPLES);
    let mut in_speech = false;
    let mut consecutive_speech: u32 = 0;
    let mut max_consecutive_speech: u32 = 0;
    let mut silence_frames: u32 = 0;
    let mut leftover = Vec::new();
    let mut interim_frame: u32 = 0;
    let mut noise_raw: f32 = 0.01;
    let models = find_asr_model();

    println!("[rust] models found: {:?}", models.is_some());

    let recognizer = models.as_ref().and_then(|(model_path, tokens_path)| {
        let lang = asr_lang().lock().map(|l| l.clone()).unwrap_or_default();
        println!("[rust] creating recognizer, lang={lang}, model={model_path}, tokens={tokens_path}");
        let mut cfg = sherpa_onnx::OfflineRecognizerConfig::default();
        cfg.model_config.sense_voice = sherpa_onnx::OfflineSenseVoiceModelConfig {
            model: Some(model_path.clone()),
            language: Some(if lang.is_empty() { "auto".to_string() } else { lang }),
            use_itn: true,
        };
        cfg.model_config.tokens = Some(tokens_path.clone());
        cfg.decoding_method = Some("greedy_search".to_string());
        let r = sherpa_onnx::OfflineRecognizer::create(&cfg);
        println!("[rust] recognizer created: {:?}", r.is_some());
        r
    });

    let mut frame_count: u64 = 0;
    println!("[rust] entering main loop (CONTEXT_SAMPLES={CONTEXT_SAMPLES})");
    loop {
        if !IS_RECORDING.load(Ordering::SeqCst) { println!("[rust] IS_RECORDING became false, exiting"); break; }

        let chunk: Vec<f32> = match rx.try_recv() {
            Ok(c) => c,
            Err(std::sync::mpsc::TryRecvError::Empty) => {
                thread::sleep(Duration::from_millis(10));
                continue;
            }
            Err(_) => { println!("[rust] channel disconnected, exiting"); break; }
        };

        frame_count += 1;

        // Peak for level meter (scale up for visibility)
        let peak = chunk.iter().fold(0.0_f32, |acc, s| acc.max(s.abs()));
        if let Ok(mut l) = audio_level().lock() { *l = (peak * 2.0).min(1.0); }

        // Convert stereo to mono
        let mono = if channels > 1 {
            let mut m = Vec::with_capacity(chunk.len() / channels);
            for i in 0..chunk.len() / channels {
                let sum: f32 = (0..channels).map(|c| chunk[i * channels + c]).sum();
                m.push(sum / channels as f32);
            }
            m
        } else {
            chunk.clone()
        };

        let resampled = resample_audio(&mono, input_rate, ASR_SAMPLE_RATE);
        if resampled.is_empty() { continue; }

        // Maintain ring buffer (only last CONTEXT_SAMPLES * 2)
        ring_buf.extend_from_slice(&resampled);
        if ring_buf.len() > CONTEXT_SAMPLES * 2 {
            let excess = ring_buf.len() - CONTEXT_SAMPLES * 2;
            ring_buf.drain(..excess);
        }

        leftover.extend_from_slice(&resampled);
        let threshold = noise_gate().lock().map(|g| *g).unwrap_or(0.01);

        while leftover.len() >= VAD_FRAME_SAMPLES {
            let frame: Vec<f32> = leftover.drain(..VAD_FRAME_SAMPLES).collect();
            let raw_energy = rms(&frame);

            // Adaptive noise floor (slower update during speech)
            let noise_rate = if in_speech { 0.999 } else { 0.95 };
            noise_raw = noise_raw * noise_rate + raw_energy * (1.0 - noise_rate);

            // Denoising gain (matches Tauri)
            let signal_ratio = raw_energy / (noise_raw * 1.5).max(0.0001);
            let suppress = noise_suppress().load(Ordering::SeqCst);
            let gain = if !suppress {
                1.0
            } else if signal_ratio < 0.5 {
                0.1 + signal_ratio * 0.3
            } else if signal_ratio < 1.5 {
                0.25 + (signal_ratio - 0.5) * 0.75
            } else {
                1.0
            };
            let denoised: Vec<f32> = frame.iter().map(|s| s * gain).collect();
            let energy = rms(&denoised);

            let audio_active = if in_speech {
                energy >= threshold * VAD_HYSTERESIS
            } else {
                energy >= threshold
            };

            if audio_active {
                if !in_speech {
                    in_speech = true;
                    consecutive_speech = 1;
                    max_consecutive_speech = max_consecutive_speech.max(consecutive_speech);
                    interim_frame = 0;
                } else {
                    consecutive_speech += 1;
                    max_consecutive_speech = max_consecutive_speech.max(consecutive_speech);
                }
                silence_frames = 0;
                seg_buf.extend_from_slice(&denoised);
                interim_frame += 1;
                if interim_frame >= INTERIM_INTERVAL {
                    interim_frame = 0;
                    if let Some(ref r) = recognizer { process_segment(&ring_buf, &seg_buf, r, false); }
                }
            } else if in_speech {
                silence_frames += 1;
                seg_buf.extend_from_slice(&denoised);
                max_consecutive_speech = max_consecutive_speech.max(consecutive_speech);
                consecutive_speech = 0;
                if silence_frames >= VAD_MIN_SILENCE_FRAMES {
                    let push_now = max_consecutive_speech >= VAD_MIN_SPEECH_FRAMES || silence_frames >= VAD_MAX_SILENCE_FRAMES;
                    if push_now {
                        if max_consecutive_speech >= VAD_MIN_SPEECH_FRAMES {
                            if let Some(ref r) = recognizer { process_segment(&ring_buf, &seg_buf, r, true); }
                        }
                        seg_buf.clear();
                        in_speech = false; consecutive_speech = 0; max_consecutive_speech = 0; silence_frames = 0; interim_frame = 0;
                    }
                }
            }

            if seg_buf.len() >= MAX_SEGMENT_SAMPLES && in_speech {
                if max_consecutive_speech >= VAD_MIN_SPEECH_FRAMES {
                    if let Some(ref r) = recognizer { process_segment(&ring_buf, &seg_buf, r, true); }
                }
                seg_buf.clear();
                in_speech = false; consecutive_speech = 0; max_consecutive_speech = 0; silence_frames = 0; interim_frame = 0;
            }

            if frame_count % 100 == 0 {
                println!("[rust] frame {}: in_speech={in_speech}, energy={energy:.4}, threshold={threshold:.4}, noise_floor={:.4}", frame_count, noise_raw * 1.5);
            }
        }
    }

    max_consecutive_speech = max_consecutive_speech.max(consecutive_speech);
    println!("[rust] loop exited, finalizing (in_speech={in_speech}, max_consecutive_speech={max_consecutive_speech})");
    if in_speech && max_consecutive_speech >= VAD_MIN_SPEECH_FRAMES {
        if let Some(ref r) = recognizer { process_segment(&ring_buf, &seg_buf, r, true); }
    }
    Some(())
}

fn is_repetitive(text: &str) -> bool {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() < 4 { return false; }
    let mut max_count = 0u32;
    let mut seen: Vec<(char, u32)> = Vec::new();
    for &c in &chars {
        if let Some(pos) = seen.iter().position(|&(ch, _)| ch == c) {
            seen[pos].1 += 1;
            if seen[pos].1 > max_count { max_count = seen[pos].1; }
        } else {
            seen.push((c, 1));
            if 1 > max_count { max_count = 1; }
        }
    }
    max_count as f32 / chars.len() as f32 > 0.55
}

fn split_sentence(text: &str) -> Vec<String> {
    const SPLIT_MAX_LEN: usize = 15;
    if text.chars().count() <= SPLIT_MAX_LEN {
        return vec![text.to_string()];
    }

    let strong: &[char] = &['。', '！', '？', '\n'];
    let soft: &[char] = &['，', '；', '、', '：', '）', '」', '』', '"'];
    let particles: &[char] = &['的', '了', '在', '是', '我', '有', '和', '就', '不', '人'];

    let chars: Vec<char> = text.chars().collect();
    let mut parts: Vec<String> = Vec::new();
    let mut start = 0;

    while start < chars.len() {
        let remaining = chars.len() - start;
        if remaining <= SPLIT_MAX_LEN {
            parts.push(chars[start..].iter().collect());
            break;
        }

        let search_end = (start + SPLIT_MAX_LEN).min(chars.len());
        let mut best = search_end;

        if let Some(pos) = chars[start..search_end].iter().rposition(|c| strong.contains(c)) {
            best = start + pos + 1;
        } else if let Some(pos) = chars[start..search_end].iter().rposition(|c| soft.contains(c)) {
            best = start + pos + 1;
        } else {
            let third = start + (search_end - start) * 2 / 3;
            if let Some(pos) = chars[third..search_end].iter().rposition(|c| particles.contains(c)) {
                best = third + pos + 1;
            }
        }

        parts.push(chars[start..best].iter().collect());
        start = best;

        while start < chars.len() && (chars[start].is_whitespace() || matches!(chars[start], ' ' | '　' | '、')) {
            start += 1;
        }
    }

    parts
}

fn process_segment(ring_buf: &[f32], seg_buf: &[f32], recognizer: &sherpa_onnx::OfflineRecognizer, is_final: bool) {
    let tag = if is_final { "final" } else { "interim" };
    let stream = recognizer.create_stream();

    // Send only last CONTEXT_SAMPLES as context (matches Tauri)
    let ctx_start = ring_buf.len().saturating_sub(CONTEXT_SAMPLES);
    if ctx_start < ring_buf.len() {
        stream.accept_waveform(ASR_SAMPLE_RATE as i32, &ring_buf[ctx_start..]);
    }
    stream.accept_waveform(ASR_SAMPLE_RATE as i32, seg_buf);

    let mut s = stream; // rebind as mutable
    recognizer.decode(&mut s);
    let text = s.get_result().map(|r| r.text).unwrap_or_default();
    if text.trim().is_empty() { return; }

    // Remove BPE token spaces between CJK characters (matches Tauri cleaning)
    let raw_chars: Vec<char> = text.chars().collect();
    let mut cleaned = String::with_capacity(text.len());
    for i in 0..raw_chars.len() {
        if raw_chars[i] == ' ' && i > 0 && i + 1 < raw_chars.len()
            && raw_chars[i - 1] >= '\u{4e00}' && raw_chars[i - 1] <= '\u{9fff}'
            && raw_chars[i + 1] >= '\u{4e00}' && raw_chars[i + 1] <= '\u{9fff}'
        {
            continue;
        }
        cleaned.push(raw_chars[i]);
    }
    // Trim leading/trailing punctuation
    let final_text = cleaned.trim_matches(|c: char| {
        c == '，' || c == '。' || c == '、' || c == '！' || c == '？'
        || c == '：' || c == '；' || c == '…' || c == '—' || c == '·'
        || c == ' ' || c == '.' || c == ','
    }).to_string();
    if final_text.is_empty() { return; }

    // Quality filtering
    let chars_only: String = final_text.chars().filter(|c| {
        !c.is_ascii_punctuation() && !"。，！？；、：…—·".contains(*c)
    }).collect();
    if !is_final {
        if chars_only.len() < 2 { return; }
        if is_repetitive(&chars_only) { return; }
    } else {
        if chars_only.len() < 2 {
            println!("[rust] recognition filtered (punct only): {final_text}");
            return;
        }
        if is_repetitive(&final_text) {
            println!("[rust] recognition filtered (repetitive): {final_text}");
            return;
        }
        // Dedup: skip identical text within 3 seconds
        {
            let mut last = last_output().lock().unwrap();
            if last.0 == final_text && last.1.elapsed().as_secs() < 3 {
                println!("[rust] recognition dedup skipped: {final_text}");
                return;
            }
            last.0 = final_text.clone();
            last.1 = Instant::now();
        }
    }

    let filtered = {
        let mode = censor_mode().lock().map(|m| *m).unwrap_or(0);
        if mode > 0 { censor::censor(&final_text, mode) } else { final_text.clone() }
    };

    println!("[rust] recognition {tag}: {filtered}");
    if is_final {
        for sentence in split_sentence(&filtered) {
            bilive::write_subtitle_text(&sentence);
        }
    }
    // Send result as JSON with full text (filtered, not split)
    let json = serde_json::json!({"type": tag, "text": filtered}).to_string();
    if let Ok(mut r) = recognition_text().lock() {
        *r = json;
    }
}

// ---- Model download ----

#[no_mangle]
pub extern "C" fn mutsurelay_download_asr_model(url: *const c_char, dest_dir: *const c_char) -> i32 {
    let url_s = if url.is_null() { return -1; } else { unsafe { CStr::from_ptr(url) }.to_string_lossy().to_string() };
    let dir_s = if dest_dir.is_null() { return -1; } else { unsafe { CStr::from_ptr(dest_dir) }.to_string_lossy().to_string() };
    log::info!("Downloading ASR model from {url_s}");

    let body = match ureq::get(&url_s).call().map_err(|e| format!("{e}")).and_then(|r| {
        let mut buf = Vec::new();
        r.into_reader().read_to_end(&mut buf).map(|_| buf).map_err(|e| format!("{e}"))
    }) {
        Ok(b) => { log::info!("Downloaded {} bytes", b.len()); b }
        Err(e) => { log::error!("Download failed: {e}"); return -1; }
    };

    let bz = bzip2::read::MultiBzDecoder::new(&body[..]);
    let mut archive = tar::Archive::new(bz);
    if let Err(e) = archive.unpack(&dir_s) {
        log::error!("Extract failed: {e}");
        return -1;
    }

    // Check that the extracted files exist
    let dir_path = std::path::Path::new(&dir_s);
    let has_model = dir_path.join("model.int8.onnx").exists();
    let has_tokens = dir_path.join("tokens.txt").exists();
    log::info!("Extracted to {dir_s}, model={has_model} tokens={has_tokens}");
    0
}

// ---- VAD / Noise Gate ----

#[no_mangle]
pub extern "C" fn mutsurelay_set_noise_gate(gate: f64) {
    if let Ok(mut g) = noise_gate().lock() { *g = gate as f32; }
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_noise_gate() -> f64 {
    noise_gate().lock().map(|g| *g as f64).unwrap_or(0.01)
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_noise_suppress(enabled: i32) {
    noise_suppress().store(enabled != 0, Ordering::SeqCst);
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_noise_suppress() -> i32 {
    noise_suppress().load(Ordering::SeqCst) as i32
}

// ---- Censor ----

#[no_mangle]
pub extern "C" fn mutsurelay_set_censor_mode(mode: i32) {
    if let Ok(mut m) = censor_mode().lock() { *m = mode; }
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_censor_mode() -> i32 {
    censor_mode().lock().map(|m| *m).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn mutsurelay_censor_text(input: *const c_char) -> *mut c_char {
    let text = if input.is_null() { String::new() } else { unsafe { CStr::from_ptr(input) }.to_string_lossy().to_string() };
    let mode = censor_mode().lock().map(|m| *m).unwrap_or(0);
    let result = if mode > 0 { censor::censor(&text, mode) } else { text };
    CString::new(result).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_free_string(s: *mut c_char) {
    if !s.is_null() { unsafe { drop(CString::from_raw(s)); } }
}

// ---- Bilibili ----

#[no_mangle]
pub extern "C" fn mutsurelay_generate_qrcode() -> *mut c_char {
    CString::new(bilive::generate_qrcode()).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_check_qrcode_status(key: *const c_char) -> *mut c_char {
    let k = if key.is_null() { String::new() } else { unsafe { CStr::from_ptr(key) }.to_string_lossy().to_string() };
    CString::new(bilive::check_qrcode_status(&k)).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_cookie(cookie: *const c_char) -> i32 {
    let c = if cookie.is_null() { return -1; } else { unsafe { CStr::from_ptr(cookie) }.to_string_lossy().to_string() };
    bilive::set_cookie(&c)
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_account_info() -> *mut c_char {
    let info = bilive::get_account_info();
    CString::new(serde_json::to_string(&info).unwrap_or_else(|_| "{}".to_string())).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_cookie_status() -> i32 { bilive::get_cookie_status() as i32 }

#[no_mangle]
pub extern "C" fn mutsurelay_logout() { bilive::logout(); }

#[no_mangle]
pub extern "C" fn mutsurelay_connect_room(room_id: i64) -> i32 { bilive::connect_room(room_id as u64) }

#[no_mangle]
pub extern "C" fn mutsurelay_disconnect_room() { bilive::disconnect_room(); }

#[no_mangle]
pub extern "C" fn mutsurelay_is_connected() -> i32 { bilive::is_connected() as i32 }

#[no_mangle]
pub extern "C" fn mutsurelay_set_room_id(room_id: i64) { bilive::set_room_id(room_id as u64); }

#[no_mangle]
pub extern "C" fn mutsurelay_get_my_room_id() -> i64 { bilive::get_my_room_id() }

#[no_mangle]
pub extern "C" fn mutsurelay_get_room_id() -> i64 { bilive::get_room_id() as i64 }

#[no_mangle]
pub extern "C" fn mutsurelay_set_asr_lang(lang: *const c_char) {
    let l = if lang.is_null() { "auto".to_string() } else { unsafe { CStr::from_ptr(lang) }.to_string_lossy().to_string() };
    if let Ok(mut a) = asr_lang().lock() { *a = l.clone(); }
    bilive::set_language(&l);
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_asr_lang() -> *mut c_char {
    let s = asr_lang().lock().map(|l| l.clone()).unwrap_or_default();
    CString::new(s).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_close_behavior(behavior: *const c_char) {
    let b = if behavior.is_null() { "hide".to_string() } else { unsafe { CStr::from_ptr(behavior) }.to_string_lossy().to_string() };
    bilive::set_close_behavior(&b);
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_close_behavior() -> *mut c_char {
    CString::new(bilive::get_close_behavior()).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_send_message(text: *const c_char) -> i32 {
    let t = if text.is_null() { return -1; } else { unsafe { CStr::from_ptr(text) }.to_string_lossy().to_string() };
    bilive::send_message(&t)
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_config_dir_path() -> *mut c_char {
    CString::new(bilive::get_storage_dir().to_string_lossy().to_string()).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_last_error() -> *mut c_char {
    CString::new(bilive::get_last_error()).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_subtitle_file_path(path: *const c_char) {
    let p = if path.is_null() { String::new() } else { unsafe { CStr::from_ptr(path) }.to_string_lossy().to_string() };
    bilive::set_subtitle_file_path(&p);
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_subtitle_file_path() -> *mut c_char {
    CString::new(bilive::get_subtitle_file_path()).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn mutsurelay_set_memory_sensitivity(val: f64) {
    bilive::set_memory_sensitivity(val as f32);
}

#[no_mangle]
pub extern "C" fn mutsurelay_get_memory_sensitivity() -> f64 {
    bilive::get_memory_sensitivity() as f64
}

// ---- Config persistence ----

#[no_mangle]
pub extern "C" fn mutsurelay_save_config() -> i32 {
    let mut cfg = bilive::Config::load().unwrap_or_default();
    cfg.roomid = bilive::get_room_id();
    cfg.noise_gate = noise_gate().lock().map(|g| *g).unwrap_or(0.01);
    cfg.censor_mode = censor_mode().lock().map(|m| *m).unwrap_or(0);
    cfg.noise_suppress = noise_suppress().load(Ordering::SeqCst);
    cfg.language = bilive::get_language();
    cfg.close_behavior = bilive::get_close_behavior();
    cfg.subtitle_file_path = bilive::get_subtitle_file_path();
    cfg.memory_sensitivity = bilive::get_memory_sensitivity();
    cfg.save().map(|_| 0).unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn mutsurelay_load_config() -> i32 {
    match bilive::Config::load() {
        Ok(cfg) => {
            if let Ok(mut g) = noise_gate().lock() { *g = cfg.noise_gate; }
            if let Ok(mut m) = censor_mode().lock() { *m = cfg.censor_mode; }
            noise_suppress().store(cfg.noise_suppress, Ordering::SeqCst);
            bilive::set_language(&cfg.language);
            bilive::set_close_behavior(&cfg.close_behavior);
            if cfg.roomid > 0 { bilive::set_room_id(cfg.roomid); }
            bilive::set_subtitle_file_path(&cfg.subtitle_file_path);
            bilive::set_memory_sensitivity(cfg.memory_sensitivity);
            bilive::init_from_config(&cfg);
            if let Ok(mut a) = asr_lang().lock() { *a = bilive::get_language(); }
            0
        }
        Err(_) => -1,
    }
}
