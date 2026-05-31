# MutsuRelay Flutter — AGENTS.md

## Commands

```powershell
flutter analyze                          # gate before commit
flutter run -d windows                   # CMake auto-builds Rust if DLL missing
flutter build windows --release          # one-command: download model + cargo build + bundle
dart run tool/build_and_run.dart         # build Rust + flutter run (cross-platform, skip cmake)
native\build.ps1; flutter run -d windows # even faster: copy DLL only, no cmake
flutter clean                            # fix stale C++ build cache after Dart-only changes
```

## Architecture

| Layer | Key files | Notes |
|---|---|---|
| Entry | `lib/main.dart` | Sets window size, ICO encoder, tray init post-frame |
| State | `lib/providers/app_state.dart` | Single `ChangeNotifier` via provider |
| FFI | `lib/ffi/native_bridge.dart` | 30+ C functions, auto-degrades to mock when DLL absent |
| UI | `lib/widgets/settings_modal.dart` | 250px width `Stack` overlay (not a dialog) |
| Rust cdylib | `native/src/lib.rs` | Recording pipeline, C API, config persistence |
| Bilibili | `native/src/bilive.rs` | QR login, cookie, room, subtitle write |
| VAD/ASR | `native/src/lib.rs` + `vad.rs` | cpal + sherpa-onnx SenseVoice |

- Rust lib: `native/Cargo.toml`, features `default = ["asr", "async"]`. `crate-type = ["cdylib", "staticlib"]`.
- `mutsurelay_native.dll` runtime deps: `sherpa-onnx-c-api.dll`, `sherpa-onnx-cxx-api.dll`, `onnxruntime.dll`, `onnxruntime_providers_shared.dll`.
- Native lib autodetected via `_defaultLibraryPath()`; silently drops to mock if not found.

## Rust gotchas

### Language — two statics, must sync
`lib.rs:ASR_LANG` (used by ASR recognizer) and `bilive.rs:LANGUAGE` (config persistence) are separate. `mutsurelay_set_asr_lang` must write to **both** (`lib.rs:627-628`). `mutsurelay_get_asr_lang` reads from `ASR_LANG`. On config load (`_init_internal`, `mutsurelay_load_config`), sync `bilive::get_language()` → `asr_lang()`.

### Language/censor changes need ASR restart
Recognizer is created once per `run_recording_pipeline()`. Changing language or model only takes effect after `restartAsr()` (calls `initAsr`).

### Censor
- `blocklist.txt` must be bundled at `<exe>/asr/blocklist.txt`. `build.ps1` + `windows/CMakeLists.txt` handle this.
- Mode 1 → `[***]`, Mode 2 → pinyin initials via `pinyin` crate ("傻逼" → "sb").
- Character-by-character matching (not `str::replace`), words sorted by length descending.

### VAD
- `max_consecutive_speech` (not cumulative `speech_frames`) guards final recognition.
- VAD_MIN_SPEECH_FRAMES = 3 consecutive active frames required for final push.
- Noise floor: `0.999` during speech, `0.95` during silence.
- Denoising gain matches Tauri: 3 regimes based on signal/noise ratio.

### Config persistence
- `saveSettings()` in Dart batches all setters then calls `bridge.saveConfig()`.
- `saveConfig()` (`lib.rs:684`) reads from Rust static globals, writes `config.toml`.
- `loadConfig()` (`lib.rs:701`) reads `config.toml`, restores statics.
- Note: `asrLang` setter does NOT call `NativeBridge.setAsrLang` directly — relies on `saveSettings()` doing it. Different from `censorMode`/`noiseSuppress` which call native immediately + save.
- `loadSettings()` must call `bridge.setSubtitleFilePath()` or Rust `SUBTITLE_FILE_PATH` stays empty and `capture.txt` is never written.

### Other
- `RECOGNITION_TEXT` uses `std::mem::take` — consumed once per Dart poll.
- Recording pipeline wraps in `catch_unwind`. `Option`/`Result` errors via `?` are NOT caught and silently set `IS_RECORDING` false.
- `clear_last_error()` must be called BEFORE `refresh_user_info()` in `set_cookie()`, or errors are lost.
- `println!` from Rust threads captured by `flutter run` console (`log::info!` less reliable on Windows).

## Flutter gotchas

- Settings modal: `Stack` overlay via `_showSettings` bool. `showSettings = false` auto-calls `restartAsr()`.
- Mini mode: direct `isMini ? MiniScreen : MainScreen` (not `AnimatedSwitcher`) to avoid Windows accessibility bridge crash.
- Tray: `setIcon()` first (NIM_ADD), then `setToolTip()`/`setContextMenu()` (NIM_MODIFY). All post-frame callback.
- `LoadImage(IMAGE_ICON)` requires `.ico` — ICO encoder in `main.dart` from `assets/logo_tr.png`.
- Accessibility bridge `[ERROR:...accessibility_bridge.cc(114)]` on Windows is a Flutter issue, harmless.
- `flutter clean` when C++ build errors appear after Dart-only changes (stale cache).
- `height: double.infinity` inside `Expanded` sets `maxWidth: infinity`, breaking parent.

## Bilibili
- `connectRoom()` may resolve a different internal room ID — always call `getRoomId()` afterward and update Dart's `_roomId`.
