# MutsuRelay Flutter — AGENTS.md

## Commands

```sh
fvm flutter analyze                    # gate before commit
fvm flutter test                       # widget test (single)
fvm flutter run -d linux               # builds Rust + bundles deps via CMake
fvm flutter run -d windows             # same on Windows
fvm dart run tool/build_and_run.dart    # fastest dev loop: Rust build + flutter run, skips cmake
fvm dart run tool/package.dart          # builds release + AppImage + tar.gz (Linux) or Inno Setup + ZIP (Windows)
native/build.sh                        # cargo build + copy .so to linux/mutsurelay_native
native/build.ps1                       # same for .dll → windows/mutsurelay_native
cargo test                             # 58 Rust unit tests (censor/audio/segmenter/text/asr)
cargo check --all-targets              # fast Rust compile check (includes examples/ + tests)
cargo run --example replay -- --help   # offline replay + CER, for accuracy A/B on a WAV
python native/tools/smoke_native.py    # runtime smoke test of the C API (works without Flutter)
fvm flutter clean                      # fix stale C++ build cache after Dart-only changes
```

- FVM auto-detected on Linux (`fvm` on PATH → `fvm flutter`); Windows always uses plain `flutter`.
- `cargo test` links a large sherpa-onnx/onnxruntime stack — run it in the background, it can exceed the foreground timeout.
- CI (`.github/workflows/build.yml.disabled`): rename to `build.yml` to enable. Jobs: analyze → build-windows + build-linux (sequential deps, not parallel).
- Version single source of truth: `version:` in `pubspec.yaml`.

## C API versioning (important)

`mutsurelay_abi_version()` returns `lib.rs:ABI_VERSION` (currently **2**).
`native_bridge.dart:expectedAbiVersion` must match. **Whenever you add, remove, or change any
`mutsurelay_*` export, bump both.**

Why: this is a dual-boot repo, so it's easy to run new bindings against the other platform's old
artifact. Without the check, a missing symbol makes `_bindFunctions()` throw, `load()` swallows it,
and the app silently falls back to **mock mode** — it looks like it works but ASR is dead. With the
check, `NativeBridge.loadError` carries the reason and `main.dart` toasts it on the first frame.

## Architecture

| Layer | Key files | Notes |
|---|---|---|
| Entry | `lib/main.dart` | Window sizing, ICO encoder, tray init post-frame, model dir detection |
| State | `lib/providers/app_state.dart` | Single `ChangeNotifier` via provider, all getters/setters |
| FFI | `lib/ffi/native_bridge.dart` | 40+ C functions via dart:ffi, auto-degrades to mock when lib absent |
| UI | `lib/widgets/settings_modal.dart` | 250px `Stack` overlay (not a dialog), config dir open via `xdg-open`/`open`/`explorer` |
| C API + assembly | `native/src/lib.rs` | ~40 `extern "C"` fns + globals + capture/frontend threads |
| Capture | `native/src/audio.rs` | Lock-free SPSC `AudioRing`, anti-aliased streaming `StreamResampler`, `rms`/`peak` |
| Segmentation | `native/src/segmenter.rs` | Pure-logic VAD/segmentation state machine (replaced `vad.rs`) |
| Recognition | `native/src/asr.rs` | Persistent decode thread, resident recognizer, bounded queue, latency stats |
| Text | `native/src/text.rs` | Clean / seam dedup / global dedup / sentence split / result queue |
| Bilibili | `native/src/bilive.rs` | QR login, cookie, room connection, subtitle write, async send queue |
| Tools | `native/examples/replay.rs`, `native/tools/smoke_native.py` | Offline CER replay; runtime C API smoke test |

Thread model: `cpal callback → AudioRing → frontend thread → bounded segment queue → resident
decode thread → result queue → Dart 50 ms poll`. Plus a separate `net` thread for sends.

- Rust lib: `native/Cargo.toml`, features `default = ["asr", "async"]`, `crate-type = ["cdylib", "staticlib", "rlib"]` (rlib is for `examples/replay.rs`).
- Native lib auto-detected via `_defaultLibraryPath()` (10+ candidate paths); falls back to mock if not found **or if the ABI version mismatches**.
- ASR model: 240MB `model.int8.onnx` + `tokens.txt` in `asr/model/`, downloaded via `cmake/download_model.cmake` (tar.bz2 from sherpa-onnx GitHub releases).

## Platform gotchas

### Dual-boot (FVM + platform switch)
- `tool/build_and_run.dart` and `tool/package.dart` auto-detect stale `.dart_tool/package_config.json` (checks for `C:/` on Linux or `/home/` on Windows) and run `clean + pub get`. This fixes "can't find flutter SDK" after switching OS.
- `.fvmrc` always says `"flutter": "stable"` — FVM follows it.

### Linux: native lib pre-loading
- `libmutsurelay_native.so` has **no RPATH** (confirmed by `readelf`).
- `native_bridge.dart:load()` pre-loads `libsherpa-onnx-c-api.so`, `libsherpa-onnx-cxx-api.so`, `libonnxruntime.so` via `DynamicLibrary.open` **before** opening the main lib. This is **essential in dev mode** (`flutter run`) where `LD_LIBRARY_PATH` is not set.
- In AppImage, `AppRun` sets `LD_LIBRARY_PATH="$HERE/lib"` — pre-loading is redundant but harmless.
- Bundle layout (AppImage): `lib/libmutsurelay_native.so`, `lib/libonnxruntime.so`, `lib/libsherpa-onnx-c-api.so`, `lib/libsherpa-onnx-cxx-api.so`, `asr/model/model.int8.onnx`, `asr/model/tokens.txt`.

### Linux: cpal audio device selection
- `native/src/lib.rs:154-167` prefers mic-named devices, then `"pulse"/"default"/"sysdefault:"` (PipeWire PulseAudio compat), then first available. On PipeWire systems, the virtual `"pipewire"` device often doesn't deliver audio frames to cpal's ALSA backend — the fix selects `"pulse"` or `"sysdefault:"` devices first.

### Linux: tray_manager limitations
- `setToolTip` and `popUpContextMenu` are **not implemented** in `tray_manager` Linux C++ plugin (only `setIcon`, `setTitle`, `setContextMenu`, `destroy`). Both calls are gated behind `if (!Platform.isLinux)`.
- `libayatana-appindicator` auto-shows the context menu on any click — it has no "activate" signal for distinguishing left/right clicks. Left-click always shows the menu. Users restore the window by clicking "显示" in the menu.
- Icon must be PNG (not ICO) — `_generateTrayIconPath()` returns `.png` on Linux, `.ico` on Windows.
- Tray init runs in `addPostFrameCallback`. On failure, `trayAvailable` is set `false` but close-behavior logic no longer checks it (user preference).

### Linux: flutter_acrylic
- `flutter_acrylic` (transparent window effect) is skipped on Linux (`main.dart:170`). Only works on Windows/macOS.

### Windows: native lib & DLL search
- `build.ps1` copies `mutsurelay_native.dll` + runtime deps (`sherpa-onnx-c-api.dll`, `onnxruntime.dll`, etc.) to `windows/mutsurelay_native/`. No pre-loading needed — Windows searches the exe directory automatically.
- Release build (`flutter build windows --release`): `windows/CMakeLists.txt` + `cmake/native_bundle.cmake` handle Rust build, model download, and DLL bundling via `install()`.
- Debug build copies also go to `build/windows/x64/runner/Debug/` so `flutter run -d windows` finds everything.

### Windows: tray & close
- Tray icon requires `.ico` format (`LoadImage(IMAGE_ICON)`). Built at runtime from `assets/logo.png` via in-memory ICO encoder in `main.dart`.
- Close in hide mode: Windows uses `windowManager.hide()` (works normally). Linux uses `setOpacity(0.0)` because `hide()` destroys the tray indicator.

## Rust gotchas

### Language — two statics, must sync
`ASR_LANG` (`lib.rs`, used by `mutsurelay_get_asr_lang`) and `bilive.rs:LANGUAGE` (config persistence) are separate globals. `mutsurelay_set_asr_lang` must write to both. On config load, sync `bilive::get_language()` into `asr_lang()`.

### Language/censor changes need an ASR reload — and it is now async
The recognizer is created once and lives on the **persistent decode thread**. Changing language or
model only takes effect after a `Ctl::Reload` (`restartAsr()` → `bridge.reloadAsr()`).
The reload happens in the background, so `reloadAsr()` returns immediately; poll
`mutsurelay_asr_state()` (1 = ready, 0 = loading, -1 = failed) to know when it's actually done.
`restartAsr()` in Dart does exactly this before toasting success — do not assume it succeeded.

### Censor
- `blocklist.txt` must be bundled at `<exe>/asr/blocklist.txt`. `build.ps1` + `CMakeLists.txt` handle this.
- Mode 1 → `[***]`, Mode 2 → pinyin initials ("傻逼" → "sb").
- Matching is char-by-char over a `Blocklist { words, by_first }` index (not a full scan, not `str::replace`); words deduped via `HashSet` and sorted by **char count** descending.
- Replacement is **per span**: ≤2 chars → full pinyin, longer → initials. Deliberately no whole-sentence special case.

### Segmenter (`segmenter.rs`, replaced `vad.rs`)
- Pure logic, no IO/threads — all segmentation behaviour is unit-testable.
- **Single energy domain**: decisions, noise floor, and segment energy all use *raw* energy, the same scale as the user's gate. Never compare a post-gain RMS against a raw gate.
- **pre-roll is snapshotted at onset**, *before* the onset frame is written into the pre-roll buffer (otherwise the onset frame gets counted twice).
- `max_consecutive_speech` (not cumulative frames) guards final recognition; `VAD_MIN_SPEECH_FRAMES` = 3.
- Suppression gain is clamped to **0.6~1.0** and smoothed over time (the old 0.3 regimes crushed fricatives).
- `seam_overlap_ms` describes the **start** of a segment (overlap with the previous segment's tail, computed in `begin_segment` from `last_close_end`). It is *not* a function of how the segment ended.
- `interim_snapshot()` returns `Segment { interim: true, id: u64::MAX }` → decode emits it as `final: false` only (preview). If you ever treat it as a final segment, half-sentences get written to the subtitle file and auto-sent.

### Config persistence
- `saveSettings()` in Dart batches all setters then calls `bridge.saveConfig()`.
- `saveConfig()` reads Rust statics, writes `config.toml`. `loadConfig()` reads `config.toml`, restores statics.
- `loadConfig()` also triggers an ASR reload (it may change language/model dir).
- `asrLang` setter does NOT call `bridge.setAsrLang` directly — relies on `saveSettings()` to batch it. Different from `censorMode`/`noiseSuppress` which call native immediately + save.
- `loadSettings()` must call `bridge.setSubtitleFilePath()` or Rust `SUBTITLE_FILE_PATH` stays empty and `capture.txt` is never written.

### Sending
- `mutsurelay_enqueue_message()` returns a job id immediately; results come back via `mutsurelay_poll_send_results()`. The `net` thread throttles to one send per 300 ms.
- Return ≤ 0 means **immediate failure** (not logged in / not connected / empty) and no job is created — read `mutsurelay_get_last_error()`.
- `mutsurelay_send_message()` (synchronous, blocks on the HTTP round trip) still exists in Rust but is **deliberately not bound in Dart** — don't bind it; it re-introduces the UI-thread blocking that P2 removed.

### Other
- Results go through `asr::result_queue()` (append, bounded 64, drops oldest). There is no single-slot `mem::take` anymore.
- `poll_recording()` drains the whole queue per call; Dart consumes the batch. Don't reintroduce single-slot readers.
- Recording pipeline wraps in `catch_unwind`. `Option`/`Result` errors via `?` are NOT caught and silently set `IS_RECORDING` false.
- `clear_last_error()` must be called BEFORE `refresh_user_info()` in `set_cookie()`, or errors are lost.

## Dart gotchas

- Settings modal: `Stack` overlay via `_showSettings` bool. `showSettings = false` auto-calls `restartAsr()`.
- Recording poll (50 ms) drains the whole result batch. Items with `final: false` are **interim preview** → update `_liveText` only; never `addSentence()` them (that would also trigger auto-send).
- Stopping does **not** cancel the poll immediately — there's a ~3 s grace period to collect the last flushed segment, otherwise every stop drops the final sentence.
- Sends go through `_dispatchSend()` → `enqueueMessage()` and are collected by `_drainSendResults()` (150 ms timer that stops itself when idle). Don't call anything blocking from the UI thread.
- Mini mode: `isMini ? MiniScreen : MainScreen` (not `AnimatedSwitcher`) to avoid Windows accessibility bridge crash.
- `flutter clean` when C++ build errors appear after Dart-only changes (stale CMake cache).
- `height: double.infinity` inside `Expanded` sets `maxWidth: infinity`, breaking parent layout.

## Bilibili
- `connectRoom()` may resolve a different internal room ID — always call `getRoomId()` afterward and update Dart's `_roomId`.
