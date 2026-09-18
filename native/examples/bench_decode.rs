//! 解码耗时基准：**单段长度 → 解码耗时**。
//!
//! 存在的理由：interim（实时半句）与正式段**共用同一条解码线程**，所以 interim
//! 送多长的音频，就直接决定了"说完一句话要等多久才轮到正式段"。窗口取 3 s 是不是
//! 太大、间隔 1.5 s 是不是太密，光看代码争不出结论，得用数字说话。
//!
//! 用法：
//! ```sh
//! cargo run --release --example bench_decode -- --model asr/model
//! ```
//!
//! 输出的 `x 实时` 是 `音频时长 / 解码耗时`：> 1 表示比实时快，越大越省 CPU
//! （但它占的是解码线程本身，见上面的说明）。

use std::time::Instant;

use mutsurelay_native::asr::create_recognizer;
use mutsurelay_native::audio::ASR_SAMPLE_RATE;

/// 合成一段"类语音"音频：带包络的多频叠加。
///
/// 合成音频的**文本**没有意义，但解码耗时由时长主导（注意力与卷积的开销都随
/// 帧数走），所以用它量时间是可信的。
fn synth(seconds: f32) -> Vec<f32> {
    let n = (ASR_SAMPLE_RATE as f32 * seconds) as usize;
    (0..n)
        .map(|i| {
            let t = i as f32 / ASR_SAMPLE_RATE as f32;
            let env = 0.5 + 0.5 * (2.0 * std::f32::consts::PI * 3.0 * t).sin();
            let v = (2.0 * std::f32::consts::PI * 180.0 * t).sin()
                + 0.6 * (2.0 * std::f32::consts::PI * 640.0 * t).sin()
                + 0.3 * (2.0 * std::f32::consts::PI * 1700.0 * t).sin();
            (0.18 * env * v / 1.9) as f32
        })
        .collect()
}

fn main() {
    let mut model = "asr/model".to_string();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        if a == "--model" {
            if let Some(v) = args.next() {
                model = v;
            }
        }
    }

    let t0 = Instant::now();
    let rec = create_recognizer(&model, "zh").expect("模型加载失败：检查 --model 目录");
    println!("模型加载: {} ms", t0.elapsed().as_millis());

    let warm = rec.create_stream();
    warm.accept_waveform(ASR_SAMPLE_RATE as i32, &synth(1.0));
    let w0 = Instant::now();
    // sherpa-onnx 只暴露批量解码；单段就是长度为 1 的批
    rec.decode_multiple_streams(&[&warm]);
    println!("首次解码(冷): {} ms\n", w0.elapsed().as_millis());

    println!("{:<10} {:>12} {:>12} {:>10}", "时长", "解码(中位)", "解码(最快)", "x 实时");
    for secs in [0.5f32, 1.0, 1.5, 2.0, 3.0, 4.0, 8.0] {
        let audio = synth(secs);
        let mut samples = Vec::new();
        for _ in 0..5 {
            let st = rec.create_stream();
            st.accept_waveform(ASR_SAMPLE_RATE as i32, &audio);
            let t = Instant::now();
            rec.decode_multiple_streams(&[&st]);
            samples.push(t.elapsed().as_millis() as u64);
        }
        samples.sort_unstable();
        let mid = samples[samples.len() / 2];
        println!(
            "{:<10} {:>10} ms {:>10} ms {:>9.1}x",
            format!("{secs}s"),
            mid,
            samples[0],
            secs * 1000.0 / mid.max(1) as f32
        );
    }

    // 批处理：正式段按 BATCH_MAX=4 成批解码，量一下摊薄后的单段成本
    println!();
    for secs in [1.0f32, 3.0] {
        for batch in [1usize, 4] {
            let audio = synth(secs);
            let streams: Vec<_> = (0..batch)
                .map(|_| {
                    let st = rec.create_stream();
                    st.accept_waveform(ASR_SAMPLE_RATE as i32, &audio);
                    st
                })
                .collect();
            let refs: Vec<&sherpa_onnx::OfflineStream> = streams.iter().collect();
            let t = Instant::now();
            rec.decode_multiple_streams(&refs);
            let total = t.elapsed().as_millis() as u64;
            println!(
                "{:.0}s × {batch} 段批量: 总 {} ms，摊薄 {:.0} ms/段",
                secs,
                total,
                total as f32 / batch as f32
            );
        }
    }
}
