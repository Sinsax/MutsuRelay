# MutsuRelay Flutter — AGENTS.md

## Commands

```sh
fvm flutter analyze                    # gate before commit
fvm flutter run -d linux               # builds Rust + bundles deps via CMake
fvm flutter run -d windows             # same on Windows
fvm dart run tool/build_and_run.dart    # fastest dev loop: Rust build + flutter run, skips cmake
fvm dart run tool/package.dart          # builds release + AppImage + tar.gz (Linux) or Inno Setup + ZIP (Windows)
native/build.sh                        # cargo build + copy .so to linux/mutsurelay_native
native/build.ps1                       # same for .dll → windows/mutsurelay_native
fvm flutter clean                      # fix stale C++ build cache after Dart-only changes
```

- FVM auto-detected on Linux (`fvm` on PATH → `fvm flutter`); Windows always uses plain `flutter`.
- CI (`.github/workflows/build.yml`): analyze → build-windows + build-linux (sequential deps, not parallel).

## Architecture

| Layer | Key files | Notes |
|---|---|---|
| Entry | `lib/main.dart` | Window sizing, ICO encoder, tray init post-frame, model dir detection |
| State | `lib/providers/app_state.dart` | Single `ChangeNotifier` via provider, all getters/setters |
| FFI | `lib/ffi/native_bridge.dart` | 30+ C functions via dart:ffi, auto-degrades to mock when lib absent |
| UI | `lib/widgets/settings_modal.dart` | 250px `Stack` overlay (not a dialog), config dir open via `xdg-open`/`open`/`explorer` |
| Rust cdylib | `native/src/lib.rs` | Recording pipeline, C API (719 lines), config persistence, ASR init |
| Bilibili | `native/src/bilive.rs` | QR login, cookie, room connection, subtitle write |
| VAD/ASR | `native/src/lib.rs` + `vad.rs` | cpal mic capture + sherpa-onnx SenseVoice |

- Rust lib: `native/Cargo.toml`, features `default = ["asr", "async"]`, `crate-type = ["cdylib", "staticlib"]`.
- Native lib auto-detected via `_defaultLibraryPath()` (10+ candidate paths); silently falls back to mock if not found.
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
`ASR_LANG` (used by ASR recognizer) and `bilive.rs:LANGUAGE` (config persistence) are separate globals. `mutsurelay_set_asr_lang` must write to both. `mutsurelay_get_asr_lang` reads from `ASR_LANG`. On config load, sync `bilive::get_language()` into `asr_lang()`.

### Language/censor changes need ASR restart
Recognizer is created once per `run_recording_pipeline()`. Changing language or model only takes effect after `restartAsr()` (calls `initAsr` from Dart).

### Censor
- `blocklist.txt` must be bundled at `<exe>/asr/blocklist.txt`. `build.ps1` + `CMakeLists.txt` handle this.
- Mode 1 → `[***]`, Mode 2 → pinyin initials ("傻逼" → "sb").
- Character-by-character matching (not `str::replace`), words sorted by length descending.

### VAD
- `max_consecutive_speech` (not cumulative `speech_frames`) guards final recognition.
- `VAD_MIN_SPEECH_FRAMES` = 3 consecutive active frames required for final push.
- Noise floor: `0.999` during speech, `0.95` during silence.
- Denoising gain: 3 regimes based on signal/noise ratio.

### Config persistence
- `saveSettings()` in Dart batches all setters then calls `bridge.saveConfig()`.
- `saveConfig()` reads Rust statics, writes `config.toml`. `loadConfig()` reads `config.toml`, restores statics.
- `asrLang` setter does NOT call `bridge.setAsrLang` directly — relies on `saveSettings()` to batch it. Different from `censorMode`/`noiseSuppress` which call native immediately + save.
- `loadSettings()` must call `bridge.setSubtitleFilePath()` or Rust `SUBTITLE_FILE_PATH` stays empty and `capture.txt` is never written.

### Other
- `RECOGNITION_TEXT` uses `std::mem::take` — consumed once per Dart poll.
- Recording pipeline wraps in `catch_unwind`. `Option`/`Result` errors via `?` are NOT caught and silently set `IS_RECORDING` false.
- `clear_last_error()` must be called BEFORE `refresh_user_info()` in `set_cookie()`, or errors are lost.

## Dart gotchas

- Settings modal: `Stack` overlay via `_showSettings` bool. `showSettings = false` auto-calls `restartAsr()`.
- Mini mode: `isMini ? MiniScreen : MainScreen` (not `AnimatedSwitcher`) to avoid Windows accessibility bridge crash.
- `flutter clean` when C++ build errors appear after Dart-only changes (stale CMake cache).
- `height: double.infinity` inside `Expanded` sets `maxWidth: infinity`, breaking parent layout.

## Bilibili
- `connectRoom()` may resolve a different internal room ID — always call `getRoomId()` afterward and update Dart's `_roomId`.
