#!/usr/bin/env bash
set -euo pipefail

PROFILE="${1:-release}"

echo "=== Building MutsuRelay Native Library ($PROFILE) ==="

if ! command -v rustc &>/dev/null; then
    echo "Error: Rust is not installed. Install from https://rustup.rs"
    exit 1
fi

echo "Rust version: $(rustc --version)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ "$PROFILE" = "release" ]; then
    cargo build --release
    TARGET_DIR="target/release"
else
    cargo build
    TARGET_DIR="target/debug"
fi

PLATFORM="$(uname -s)"
if [ "$PLATFORM" = "Linux" ]; then
    LIB_FILE="$TARGET_DIR/libmutsurelay_native.so"
    DEST_DIR="../linux/mutsurelay_native"
elif [ "$PLATFORM" = "Darwin" ]; then
    LIB_FILE="$TARGET_DIR/libmutsurelay_native.dylib"
    DEST_DIR="../macos/mutsurelay_native"
else
    echo "Unsupported platform: $PLATFORM"
    exit 1
fi

mkdir -p "$DEST_DIR"

if [ -f "$LIB_FILE" ]; then
    cp "$LIB_FILE" "$DEST_DIR/"
    echo "Copied library to $DEST_DIR"
fi

# Bundle runtime deps (sherpa-onnx etc.) if present in target dir
for dep in libsherpa-onnx-c-api.so libsherpa-onnx-cxx-api.so libonnxruntime.so libonnxruntime_providers_shared.so; do
    dep_path="$TARGET_DIR/$dep"
    if [ -f "$dep_path" ]; then
        cp "$dep_path" "$DEST_DIR/"
    fi
done

echo "=== Build complete ==="
