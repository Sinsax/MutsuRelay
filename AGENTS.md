# MutsuRelay Flutter — AGENTS.md

## Commands

```sh
flutter analyze                        # gate before commit
flutter test                           # widget test (single)
flutter run -d windows                 # builds Rust + bundles deps via CMake
flutter run -d linux                   # same on Linux
dart run tool/build_and_run.dart        # fastest dev loop: Rust build + flutter run, skips cmake
dart run tool/package.dart              # builds release + AppImage + tar.gz (Linux) or Inno Setup + ZIP (Windows)
native/build.sh                        # cargo build + copy .so to linux/mutsurelay_native
native/build.ps1                       # same for .dll → windows/mutsurelay_native
cargo test                             # 67 Rust unit tests (censor/audio/segmenter/text/asr)
cargo check --all-targets              # fast Rust compile check (includes examples/ + tests)
cargo run --example replay -- --help   # offline replay + CER, for accuracy A/B on a WAV
python native/tools/smoke_native.py    # runtime smoke test of the C API (works without Flutter)
python native/tools/check_abi.py       # ABI 版本两端一致性（纯源码，提交前跑，不用编译）
python native/tools/cer_baseline.py    # 在测试音频集上跑 replay → docs/asr-baseline.md（CER 基线）
flutter clean                          # fix stale C++ build cache after Dart-only changes
```

测试音频集（CER 基线的前提，音频本体不入库）：

```sh
powershell -NoProfile -ExecutionPolicy Bypass -File native/tools/make_test_audio.ps1  # TTS 逐句合成（需 zh-CN 语音）
python native/tools/build_test_audio.py          # 拼句间静音 + 增益/噪声变体 → testdata/asr/wav/
python native/tools/cer_baseline.py              # 全部片段跑一遍，写 docs/asr-baseline.md
python native/tools/cer_baseline.py --only 07_quiet --no-denoise   # 单片段 A/B
```

- **`make_test_audio.ps1` 必须保存为「UTF-8 with BOM」**：Windows PowerShell 5.1 会把无 BOM 的
  `.ps1` 按 ANSI(GBK) 解码，中文注释里的字节会吃掉字符串的结束引号，报
  `字符串缺少终止符` / `UnexpectedToken` 这类看不出原因的解析错误。用 `write` 工具重写该文件后
  记得补回 BOM（`python -c "import io;p='native/tools/make_test_audio.ps1';io.open(p,'w',encoding='utf-8-sig',newline='\r\n').write(io.open(p,encoding='utf-8').read())"`）。

- Linux uses `fvm flutter …` (`fvm` is on PATH there); Windows has no fvm — use plain `flutter`.
- **Windows: Flutter is at `C:\Users\para\flutter\flutter\bin` and is NOT on PATH** (the PATH entry
  `F:\para\Code\flutter\bin` is a dead path). Call it by absolute path, e.g.
  `& "C:\Users\para\flutter\flutter\bin\flutter.bat" analyze`, or fix PATH.
- **`flutter test` breaks behind the local proxy**: `HTTP_PROXY/HTTPS_PROXY=127.0.0.1:13605` is
  applied to the flutter_tester WebSocket → `Invalid WebSocket upgrade request`. Clear them (or set
  `NO_PROXY=127.0.0.1,localhost`) before running tests.
- Any `flutter analyze|test|run` rewrites `linux|windows/flutter/generated_plugin_registrant.cc` and
  `generated_plugins.cmake`. Content is identical; with `core.autocrlf=true` git still shows them as
  modified (line endings only). `git checkout --` those 4 files after a run.
- `cargo test` links a large sherpa-onnx/onnxruntime stack — run it in the background, it can exceed the foreground timeout.
- CI (`.github/workflows/build.yml`) is **enabled**: pushes to `master`/`test` run analyze
  (flutter analyze + `check_abi.py` + `cargo check`) → build-windows + build-linux (sequential deps,
  not parallel), and `v*` tags publish a Release. To disable it again, rename the file to
  `build.yml.disabled` (that is how it was parked on 2026-06-10). Note ubuntu-24.04 package names:
  `fuse`/`locate` no longer exist — the Linux job deliberately installs neither and runs
  appimagetool with `APPIMAGE_EXTRACT_AND_RUN=1`. The Linux packaging step calls the repo's own
  `dart run tool/package.dart` (manual AppDir + appimagetool) — CI and local packaging must stay the
  same path; the old fastforge invocation failed on every run (2026-06-02, 2026-09-18).
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
- `config.toml` 还有 `segment_max_ms`（单段上限，默认 8000）与 `interim`（实时半句，默认 true）：
  两者在 `mutsurelay_save_config`/`load_config` 里读写 `SEGMENT_MAX_MS` / `INTERIM_ENABLED` 静态量。
  **它们不需要重建 recognizer**，所以 load 路径故意不碰 `trigger_reload*()`。
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

- Settings modal: `Stack` overlay via `_showSettings` bool. Closing it calls `restartAsr()` **only when
  `_asrSettingsDirty`** — i.e. only for changes that really need a new recognizer (language / model /
  censor / noise suppress). 段长上限与 interim 只影响后续分段，刻意**不**置脏，否则关一次设置窗就
  白重载一次 229 MB 模型。
- 设置面板里的「运行统计」由 `AppState.showSettings` 打开时启动的 1 s 定时器刷新，关掉即取消
  （`getStats()` 取 `mutsurelay_get_stats`）。判据：调参时 `asr_reloads` 不该涨。
- Recording poll (50 ms) drains the whole result batch. Items with `final: false` are **interim preview** → update `_liveText` only; never `addSentence()` them (that would also trigger auto-send).
- Stopping does **not** cancel the poll immediately — there's a ~3 s grace period to collect the last flushed segment, otherwise every stop drops the final sentence.
- Sends go through `_dispatchSend()` → `enqueueMessage()` and are collected by `_drainSendResults()` (150 ms timer that stops itself when idle). Don't call anything blocking from the UI thread.
- Mini mode: `isMini ? MiniScreen : MainScreen` (not `AnimatedSwitcher`) to avoid Windows accessibility bridge crash.
- `flutter clean` when C++ build errors appear after Dart-only changes (stale CMake cache).
- `height: double.infinity` inside `Expanded` sets `maxWidth: infinity`, breaking parent layout.

## Bilibili
- `connectRoom()` may resolve a different internal room ID — always call `getRoomId()` afterward and update Dart's `_roomId`.
