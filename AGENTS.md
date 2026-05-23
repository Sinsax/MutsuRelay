# MutsuRelay Flutter — AGENTS.md

## Commands

```powershell
flutter analyze                          # gate before commit
flutter run -d windows                   # run desktop app
cargo build                              # build Rust lib (native/)
flutter clean                            # fix C++ build errors after Dart-only changes

# Full build flow
cd native; .\download-model.ps1          # one-time (~200MB SenseVoice)
cd native; .\build.ps1                   # release (default); -Profile debug for debug
cd ..; flutter run -d windows
```

## Architecture

```
lib/main.dart                 # Entry: init window, gen ICO, init tray (post-frame), runApp
lib/app.dart                  # MutsuRelayApp + MutsuRelayHome (mode switch, overlays)
lib/providers/app_state.dart  # Central ChangeNotifier — recording, connection, settings, toast
lib/ffi/native_bridge.dart    # Dart FFI bindings → mutsurelay_native.dll (30+ C fns)
lib/screens/main_screen.dart  # Normal mode layout (left panel + message list + right panel)
lib/screens/mini_screen.dart  # Mini mode overlay (transparent bg via miniOpacity)
lib/widgets/                  # All UI components (top_bar, settings_modal, mic_button, etc.)
lib/theme/app_theme.dart      # Colors, text styles, layout constants (AppInsets)
native/src/lib.rs             # Rust cdylib: recording pipeline, cpal+VAD+ASR, C API
native/src/bilive.rs          # Bilibili QR login, cookie, room connect, send message
native/src/vad.rs             # VAD: RMS, resample, NoiseEstimator, is_speech_active
native/src/censor.rs           # Keyword censor (asterisk/pinyin)
```

- State: `provider` + `ChangeNotifier`, via `Consumer<AppState>` or `context.watch<AppState>()`.
- Window: `TitleBarStyle.hidden` via `window_manager`. Tray via `tray_manager`.
- Native lib degrades to mock mode when DLL absent (auto-detected in `NativeBridge.load()`).

## Key Layout

| Constant | Value | Notes |
|---|---|---|
| `AppInsets.normalW` | 608 | Normal mode window width |
| `AppInsets.normalH` | 320 | Normal mode window height |
| `AppInsets.miniW` / `miniH` | 280 / 360 | Mini mode (actual size set in `setWindowMode`: 280×380) |
| `AppInsets.leftPanelW` | 120 | Left panel (mic + VAD) |
| `AppInsets.rightPanelW` | 140 | Right panel (send mode, room ID, clear) |
| `AppInsets.miniToolbarH` | 30 | Mini toolbar height |
| Settings modal width | 250 | Must stay <280 to fit mini mode with border |

## Known Gotchas

### Tray
- Windows `LoadImage(IMAGE_ICON)` requires `.ico`, not `.png`. ICO encoder in `main.dart` decodes `assets/logo_tr.png` → BGRA → BITMAPINFOHEADER + AND mask.
- Tray init order: `setIcon()` first (`NIM_ADD`), then `setToolTip()`/`setContextMenu()` (`NIM_MODIFY`). All tray calls deferred to `addPostFrameCallback` (after `runApp`).
- Right-click menu: must call `trayManager.popUpContextMenu()` explicitly (tray_manager 0.5.2).

### Rust Native
- `println!` from Rust background threads is captured by `flutter run` console; `log::info!` may be less reliable on Windows.
- `clear_last_error()` must be called BEFORE `refresh_user_info()` in `set_cookie()` (`bilive.rs:302`), not after, or errors are lost.
- `RECOGNITION_TEXT` uses `std::mem::take` each poll — each Rust-side recognition string is consumed exactly once per Dart poll cycle.
- Recording pipeline wrapped in `catch_unwind` (`mutsurelay_start_recording`) — Rust panics are caught but `Option`/`Result` errors via `?` are not, and silently set `IS_RECORDING` false.
- `env_logger` initialized once in `mutsurelay_init()` with `INITIALIZED` guard.
- Cargo features: `default = ["asr", "async"]`. `asr` enables `sherpa-onnx` (heavy, `features = ["shared"]`), `async` enables `tokio`.
- Runtime DLL deps for `mutsurelay_native.dll`: `sherpa-onnx-c-api.dll`, `sherpa-onnx-cxx-api.dll`, `onnxruntime.dll`, `onnxruntime_providers_shared.dll`. `build.ps1` copies them automatically.
- ASR model: `download-model.ps1` → `asr/model/`. Loaded from working dir (dev) or exe-relative paths (release).

### Flutter / Dart
- `fontFamily` must be single name — `'Segoe UI'` only, no CSS-style stacks.
- `SingleChildScrollView` + `Column` => RenderFlex overflow. Use `ListBody` inside scroll views.
- `height: double.infinity` inside `Expanded` sets `maxWidth: infinity`, breaking parent.
- Settings modal width = 250 (narrow enough for 280px mini mode). Modal is a `Stack` overlay via `showSettings` bool — not a dialog.
- Level bar (`mic_button.dart`) is always rendered (100×4px SizedBox) to prevent layout jump — noise gate indicator visible even when idle.
- Noise gate indicator position: `((noiseGateDisplay - 1) / 49.0 * 94)` maps slider range 1–50 linearly to 0–94px bar width.
- Mini mode opacity: `miniOpacity` controls `windowManager.setOpacity()` for desktop see-through. Settings modal disables it temporarily (`setOpacity(1.0)`) when opened in mini mode, restores on close. MiniScreen bg is solid; window opacity handles the transparency effect. TopBar uses `Color(0x805BC0BE)`.
- Mini mode uses direct `isMini ? MiniScreen : MainScreen` (not `AnimatedSwitcher`) to avoid Windows accessibility bridge crash.
- First-frame layout depends on window size being set before `runApp`. `main.dart` calls `setMinimumSize` + `setSize` in `waitUntilReadyToShow`.
- Accessibility bridge `[ERROR:...accessibility_bridge.cc(114)]` on Windows is a Flutter engine issue, harmless.
- `flutter clean` required when C++ build errors appear after Dart-only changes (stale build cache).

### Bilibili
- `connectRoom()` may resolve a different internal room ID — always call `getRoomId()` afterward and update Dart's `_roomId`.
