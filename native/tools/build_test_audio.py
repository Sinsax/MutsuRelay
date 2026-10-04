#!/usr/bin/env python3
"""把 make_test_audio.ps1 合成的逐句 WAV 拼装成测试音频集，并派生增益 / 噪声变体。

为什么需要这一层：TTS 只能给出"逐句 WAV"，而测试分段器需要可控的**句间静音**、
可控的**音量**与可控的**噪声底**。这三样都在这里做，且固定随机种子 —— 也就是说
同一台机器上重跑，音频逐样本一致，CER 数字才可复现。

产物（全部写入 testdata/asr/wav/，已 gitignore）：

| 文件 | 来源文本 | 特征 | 想压的问题 |
|---|---|---|---|
| 01_continuous | 01 | 句间 0.15 s | 逼出 max_segment 强制切段 |
| 02_pauses | 02 | 句间 1.5 s | 逼出静音判停 |
| 03_reading | 03 | 句间 0.45 s | 稳定 CER 基线 |
| 04_sensitive | 04 | 含屏蔽词 | 敏感词链路 |
| 05_fast | 05 | rate +6 | 快速说话 |
| 06_slow | 06 | rate -4 | 慢速 + 停顿多 |
| 07_quiet | 03 | −12 dB | 小声说话被门限切掉 |
| 08_loud | 03 | +6 dB | 大声是否削顶 |
| 09_noisy | 02 | SNR 18 dB 风扇+键盘 | 噪声底抬高后的判停 |
| 10_very_noisy | 02 | SNR 10 dB 同上 | 强噪声下的可用性 |

变体的参考文本 = 源片段的 ref/*.txt（见 CLIP_SOURCE）。

用法：
    python native/tools/build_test_audio.py
    python native/tools/build_test_audio.py --seed 7        # 默认 20260918
"""

from __future__ import annotations

import argparse
import wave
from pathlib import Path

import numpy as np

SR = 16000
REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / "testdata" / "asr"
PARTS = ROOT / "parts"
WAV = ROOT / "wav"

# 片段 -> (句间静音秒数)。0.15 s 让句子首尾相接（连续说话），1.5 s 用于长停顿。
CLIP_SILENCE = {
    "01_continuous": 0.15,
    "02_pauses": 1.5,
    "03_reading": 0.45,
    "04_sensitive": 0.45,
    "05_fast": 0.45,
    "06_slow": 0.9,
}

# 变体 -> (源片段, 线性增益)
CLIP_GAIN = {
    "07_quiet": ("03_reading", 0.25),      # ≈ -12 dB
    "08_loud": ("03_reading", 2.0),        # ≈ +6 dB
}

# 变体 -> (源片段, 信噪比 dB)
CLIP_NOISE = {
    "09_noisy": ("02_pauses", 18.0),
    "10_very_noisy": ("02_pauses", 10.0),
}


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        if w.getframerate() != SR or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise SystemExit(
                f"{path} 不是 16 kHz / 单声道 / 16 bit（先跑 make_test_audio.ps1）"
            )
        data = w.readframes(w.getnframes())
    return np.frombuffer(data, dtype="<i2").astype(np.float32)


def write_wav(path: Path, samples: np.ndarray) -> None:
    clipped = int(np.sum(np.abs(samples) > 32767))
    if clipped:
        print(f"    ! {path.name}: {clipped} 个样本削顶")
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(np.clip(samples, -32768, 32767).astype("<i2").tobytes())


def assemble(clip: str) -> np.ndarray:
    parts = sorted((PARTS / clip).glob("*.wav"))
    if not parts:
        raise SystemExit(f"缺少 {PARTS / clip}/*.wav —— 先跑 native/tools/make_test_audio.ps1")
    gap = np.zeros(int(SR * CLIP_SILENCE[clip]), dtype=np.float32)
    chunks: list[np.ndarray] = []
    for i, p in enumerate(parts):
        if i:
            chunks.append(gap)
        chunks.append(read_wav(p))
    chunks.append(np.zeros(int(SR * 0.3), dtype=np.float32))  # 尾部留白，收尾段能判停
    return np.concatenate(chunks)


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(x), dtype=np.float64)))


def make_noise(n: int, rng: np.random.Generator) -> np.ndarray:
    """风扇底噪（低通白噪）+ 键盘敲击（衰减脉冲）。"""
    white = rng.normal(0.0, 1.0, n)
    # 一阶低通：把白噪压成"呼呼"的风扇声
    fan = np.empty_like(white)
    acc = 0.0
    for i in range(0, n, 1):
        acc += 0.02 * (white[i] - acc)
        fan[i] = acc
    # 缓慢起伏的音量包络，避免噪声过于平稳
    t = np.arange(n) / SR
    fan *= 1.0 + 0.3 * np.sin(2 * np.pi * 0.13 * t) + 0.2 * np.sin(2 * np.pi * 0.37 * t)

    clicks = np.zeros(n, dtype=np.float64)
    pos = int(SR * 5)
    while pos < n - SR // 10:
        length = int(SR * rng.uniform(0.004, 0.012))
        env = np.exp(-np.linspace(0.0, 9.0, length))
        clicks[pos : pos + length] += rng.normal(0.0, 1.0, length) * env
        pos += int(SR * rng.uniform(0.6, 1.6))

    noise = fan / (np.std(fan) + 1e-12) + 1.2 * clicks / (np.std(clicks) + 1e-12)
    return noise


def mix_at_snr(speech: np.ndarray, noise: np.ndarray, snr_db: float) -> np.ndarray:
    s_rms = rms(speech)
    n_rms = rms(noise)
    target = s_rms / (10 ** (snr_db / 20.0))
    return speech + noise * (target / (n_rms + 1e-12))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=20260918)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)

    wavs: dict[str, np.ndarray] = {}
    for clip in CLIP_SILENCE:
        wavs[clip] = assemble(clip)

    for clip, (src, gain) in CLIP_GAIN.items():
        wavs[clip] = wavs[src] * gain

    for clip, (src, snr) in CLIP_NOISE.items():
        speech = wavs[src]
        wavs[clip] = mix_at_snr(speech, make_noise(len(speech), rng), snr)

    total = 0.0
    print(f"{'片段':<16}{'时长':>8}{'RMS':>10}  说明")
    for clip in sorted(wavs):
        x = wavs[clip]
        write_wav(WAV / f"{clip}.wav", x)
        secs = len(x) / SR
        total += secs
        src = CLIP_GAIN.get(clip, CLIP_NOISE.get(clip, (clip,)))[0]
        note = "原始" if src == clip else f"由 {src} 派生"
        print(f"{clip:<16}{secs:7.1f}s{rms(x):10.0f}  {note}")
    print(f"\n合计 {total / 60:.1f} 分钟 → {WAV}")


if __name__ == "__main__":
    main()
