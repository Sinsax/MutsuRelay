#!/usr/bin/env python3
"""在测试音频集上跑 replay，产出 CER / 解码耗时基线，并写成 docs/asr-baseline.md。

这是 P0 欠的最后一块：`native/examples/replay.rs` 早就就绪，但一直没有测试音频集，
所以文档里所有"精度变好了"都只是主观判断。本脚本把它变成可复现的数字。

前置：
    powershell -NoProfile -ExecutionPolicy Bypass -File native/tools/make_test_audio.ps1
    python native/tools/build_test_audio.py

用法：
    python native/tools/cer_baseline.py                    # 默认跑全部片段
    python native/tools/cer_baseline.py --only 01_continuous 02_pauses
    python native/tools/cer_baseline.py --no-denoise       # A/B：关掉降噪增益
    python native/tools/cer_baseline.py --md docs/asr-baseline.md
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WAV = REPO / "testdata" / "asr" / "wav"
REF = REPO / "testdata" / "asr" / "ref"

# 变体 -> 参考文本（变体复用源片段的文本）
CLIP_REF = {
    "07_quiet": "03_reading",
    "08_loud": "03_reading",
    "09_noisy": "02_pauses",
    "10_very_noisy": "02_pauses",
}

ORDER = [
    "01_continuous",
    "02_pauses",
    "03_reading",
    "04_sensitive",
    "05_fast",
    "06_slow",
    "07_quiet",
    "08_loud",
    "09_noisy",
    "10_very_noisy",
]


def run_one(clip: str, extra: list[str]) -> dict:
    ref = CLIP_REF.get(clip, clip)
    cmd = [
        "cargo",
        "run",
        "--quiet",
        "--manifest-path",
        str(REPO / "native" / "Cargo.toml"),
        "--example",
        "replay",
        "--",
        f"--model={REPO / 'asr' / 'model'}",
        f"--wav={WAV / f'{clip}.wav'}",
        f"--ref={REF / f'{ref}.txt'}",
        "--quiet",
        "--json",
        *extra,
    ]
    out = subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", cwd=REPO
    )
    if out.returncode != 0:
        print((out.stdout or "")[-2000:], file=sys.stderr)
        print((out.stderr or "")[-2000:], file=sys.stderr)
        raise SystemExit(f"{clip}: replay 失败（exit {out.returncode}）")
    return json.loads(out.stdout)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", default=None)
    ap.add_argument("--md", default=str(REPO / "docs" / "asr-baseline.md"))
    ap.add_argument("--no-denoise", action="store_true")
    ap.add_argument("--no-preroll", action="store_true")
    ap.add_argument("--seg-max", type=int, default=None)
    args = ap.parse_args()

    if not WAV.exists() or not any(WAV.glob("*.wav")):
        raise SystemExit("还没有音频集：先跑 native/tools/make_test_audio.ps1 与 build_test_audio.py")

    clips = args.only or [c for c in ORDER if (WAV / f"{c}.wav").exists()]

    extra: list[str] = []
    if args.no_denoise:
        extra.append("--no-denoise")
    if args.no_preroll:
        extra.append("--no-preroll")
    if args.seg_max:
        extra.append(f"--seg-max={args.seg_max}")

    rows = []
    for clip in clips:
        r = run_one(clip, extra)
        cer = r["cer"] if r["cer"] is not None else float("nan")
        rows.append((clip, r, cer))
        print(
            f"{clip:<16} CER {cer * 100:6.2f}%  段 {r['segments']:>3}  "
            f"判丢 {r['rejected']:>2}  解码 p50 {r['decode_p50_ms']:>4}ms  "
            f"p95 {r['decode_p95_ms']:>4}ms  RTF {r['rtf']:.3f}"
        )

    cer_values = [c for _, _, c in rows if c == c]
    mean_cer = sum(cer_values) / len(cer_values) if cer_values else float("nan")
    total_ms = sum(r["audio_ms"] for _, r, _ in rows)
    print(f"\n平均 CER {mean_cer * 100:.2f}%（{len(cer_values)} 个片段），音频合计 {total_ms / 1000:.1f}s")

    switches = []
    switches.append(f"denoise={'off' if args.no_denoise else 'on'}")
    switches.append(f"preroll={'off' if args.no_preroll else 'on'}")
    switches.append(f"seg_max={args.seg_max or 8000}ms")

    lines = [
        "# ASR 离线基线（replay）",
        "",
        "> 由 `python native/tools/cer_baseline.py` 生成，请勿手改；",
        "> 音频集由 `native/tools/make_test_audio.ps1` + `build_test_audio.py` 本地生成（固定随机种子）。",
        "",
        f"- 开关：{' · '.join(switches)}",
        f"- 音频合计：{total_ms / 1000:.1f}s，{len(rows)} 个片段",
        f"- **平均 CER：{mean_cer * 100:.2f}%**",
        "",
        "| 片段 | 时长 | 段数 | 判丢 | CER | 解码 p50 | 解码 p95 | RTF |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for clip, r, cer in rows:
        lines.append(
            f"| {clip} | {r['audio_ms'] / 1000:.1f}s | {r['segments']} | {r['rejected']} | "
            f"{cer * 100:.2f}% | {r['decode_p50_ms']}ms | {r['decode_p95_ms']}ms | {r['rtf']:.3f} |"
        )
    lines += [
        "",
        "## 用途",
        "",
        "- **改任何精度相关代码前后各跑一次**，看 CER 是否真的下降（这是「精度提升」唯一可复现的判据）。",
        "- `--no-denoise` / `--no-preroll` / `--seg-max` 做 A/B；`--only <片段>` 只跑关心的那几个。",
        "- 绝对 CER 只是这台机器 + 这份 TTS 音频集下的相对刻度：它**不是**真实人声准确率，",
        "  但同一份音频集上的前后对比是有效的。",
    ]
    Path(args.md).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"已写入 {args.md}")


if __name__ == "__main__":
    main()
