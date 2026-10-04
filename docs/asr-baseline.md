# ASR 离线基线（replay）

> 由 `python native/tools/cer_baseline.py` 生成，请勿手改；
> 音频集由 `native/tools/make_test_audio.ps1` + `build_test_audio.py` 本地生成（固定随机种子）。

- 开关：denoise=on · preroll=on · seg_max=8000ms
- 音频合计：397.8s，10 个片段
- **平均 CER：3.14%**

| 片段 | 时长 | 段数 | 判丢 | CER | 解码 p50 | 解码 p95 | RTF |
|---|---|---|---|---|---|---|---|
| 01_continuous | 60.8s | 19 | 0 | 2.74% | 48ms | 70ms | 0.016 |
| 02_pauses | 46.5s | 15 | 0 | 2.52% | 40ms | 51ms | 0.013 |
| 03_reading | 39.6s | 13 | 0 | 1.47% | 47ms | 59ms | 0.016 |
| 04_sensitive | 35.7s | 12 | 0 | 0.00% | 47ms | 54ms | 0.016 |
| 05_fast | 11.4s | 4 | 0 | 3.03% | 45ms | 45ms | 0.015 |
| 06_slow | 31.4s | 6 | 0 | 3.12% | 60ms | 87ms | 0.012 |
| 07_quiet | 39.6s | 17 | 0 | 10.29% | 37ms | 52ms | 0.017 |
| 08_loud | 39.6s | 13 | 0 | 1.47% | 47ms | 61ms | 0.016 |
| 09_noisy | 46.5s | 13 | 1 | 2.52% | 53ms | 91ms | 0.016 |
| 10_very_noisy | 46.5s | 13 | 0 | 4.20% | 59ms | 72ms | 0.016 |

## 用途

- **改任何精度相关代码前后各跑一次**，看 CER 是否真的下降（这是「精度提升」唯一可复现的判据）。
- `--no-denoise` / `--no-preroll` / `--seg-max` 做 A/B；`--only <片段>` 只跑关心的那几个。
- 绝对 CER 只是这台机器 + 这份 TTS 音频集下的相对刻度：它**不是**真实人声准确率，
  但同一份音频集上的前后对比是有效的。
