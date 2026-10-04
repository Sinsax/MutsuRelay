#!/usr/bin/env python3
"""校验 C API 的 ABI 版本号两端一致（纯源码检查，不需要编译产物）。

为什么需要它：这是双系统仓库，很容易出现"新绑定 + 另一平台旧产物"。缺符号会让
`_bindFunctions()` 抛错并被 `load()` 吞掉 → 界面照常打开、ASR 其实是 mock 模式。
所以 `native/src/lib.rs` 的 `ABI_VERSION` 与 `lib/ffi/native_bridge.dart` 的
`expectedAbiVersion` 必须同步 +1，两边不一致就是发布阻断项。

用法：
    python native/tools/check_abi.py
退出码 0 = 一致；1 = 不一致或找不到（可直接挂进 CI / 提交前检查）。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RUST = REPO / "native" / "src" / "lib.rs"
DART = REPO / "lib" / "ffi" / "native_bridge.dart"


def parse(path: Path, pattern: str, what: str) -> int:
    text = path.read_text(encoding="utf-8")
    m = re.search(pattern, text)
    if not m:
        print(f"找不到 {what}（{path}）：正则 {pattern}", file=sys.stderr)
        sys.exit(1)
    return int(m.group(1))


def main() -> None:
    rust = parse(RUST, r"ABI_VERSION:\s*u32\s*=\s*(\d+)", "ABI_VERSION")
    dart = parse(DART, r"expectedAbiVersion\s*=\s*(\d+)", "expectedAbiVersion")
    print(f"native/src/lib.rs  ABI_VERSION        = {rust}")
    print(f"lib/ffi/native_bridge.dart  expectedAbiVersion = {dart}")
    if rust != dart:
        print(
            "\n不一致：增删/改变任何 mutsurelay_* 导出符号时，两处必须同时 +1。",
            file=sys.stderr,
        )
        sys.exit(1)
    print("一致 ✓")


if __name__ == "__main__":
    main()
