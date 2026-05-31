import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'app.dart';
import 'ffi/native_bridge.dart';
import 'providers/app_state.dart';
import 'theme/app_theme.dart';

// ---- ICO encoder for tray icon ----
// Windows LoadImage(IMAGE_ICON) requires .ico format, not .png.

void _w32(BytesBuilder bb, int v) {
  bb.addByte(v & 0xFF); bb.addByte((v >> 8) & 0xFF);
  bb.addByte((v >> 16) & 0xFF); bb.addByte((v >> 24) & 0xFF);
}
void _w16(BytesBuilder bb, int v) {
  bb.addByte(v & 0xFF); bb.addByte((v >> 8) & 0xFF);
}

Uint8List _buildIcoFromBgra(Uint8List bgra, int w, int h) {
  final andStride = ((w + 31) >> 5) << 2;
  final andMask = Uint8List(h * andStride);
  andMask.fillRange(0, andMask.length, 0);

  final bih = BytesBuilder();
  _w32(bih, 40); _w32(bih, w); _w32(bih, h * 2);
  _w16(bih, 1); _w16(bih, 32);
  _w32(bih, 0); _w32(bih, 0); _w32(bih, 0); _w32(bih, 0); _w32(bih, 0); _w32(bih, 0);

  final dib = BytesBuilder();
  dib.add(bih.toBytes());
  dib.add(bgra);
  dib.add(andMask);
  final dibBytes = dib.toBytes();

  const pad = 2;
  const imageOffset = 24;

  final ico = BytesBuilder();
  _w16(ico, 0); _w16(ico, 1); _w16(ico, 1);
  ico.addByte(w > 255 ? 0 : w);
  ico.addByte(h > 255 ? 0 : h);
  ico.addByte(0); ico.addByte(0);
  _w16(ico, 1); _w16(ico, 32);
  _w32(ico, dibBytes.length);
  _w32(ico, imageOffset);
  for (int i = 0; i < pad; i++) { ico.addByte(0); }
  ico.add(dibBytes);
  return ico.toBytes();
}

Future<String> _generateTrayIconPath() async {
  // Linux: appindicator expects PNG, not ICO
  if (Platform.isLinux) {
    final data = await rootBundle.load('assets/logo.png');
    final pngFile = File('${Directory.systemTemp.path}/mutsurelay_tray.png');
    await pngFile.writeAsBytes(data.buffer.asUint8List());
    return pngFile.path;
  }

  // Windows: LoadImage(IMAGE_ICON) requires .ico
  Uint8List icoBytes;
  try {
    final data = await rootBundle.load('assets/logo.png');
    final pngBytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final codec = await ui.instantiateImageCodec(pngBytes, targetWidth: 32, targetHeight: 32);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    const w = 32, h = 32;
    final bgra = BytesBuilder();
    for (int y = h - 1; y >= 0; y--) {
      for (int x = 0; x < w; x++) {
        final off = (y * w + x) * 4;
        bgra.addByte(rgba.getUint8(off + 2));
        bgra.addByte(rgba.getUint8(off + 1));
        bgra.addByte(rgba.getUint8(off));
        bgra.addByte(rgba.getUint8(off + 3));
      }
    }
    icoBytes = _buildIcoFromBgra(bgra.toBytes(), w, h);
  } catch (_) {
    // Fallback: generate a simple icon
    const w = 16, h = 16;
    final bgra = BytesBuilder();
    for (int y = h - 1; y >= 0; y--) {
      for (int x = 0; x < w; x++) {
        final dx = x - 7, dy = y - 7;
        final circle = dx * dx + dy * dy <= 49;
        if (circle) { bgra.addByte(0xBE); bgra.addByte(0xC0); bgra.addByte(0x5B); bgra.addByte(0xFF); }
        else { bgra.addByte(0); bgra.addByte(0); bgra.addByte(0); bgra.addByte(0); }
      }
    }
    icoBytes = _buildIcoFromBgra(bgra.toBytes(), w, h);
  }
  final icoFile = File('${Directory.systemTemp.path}/mutsurelay_tray.ico');
  await icoFile.writeAsBytes(icoBytes);
  return icoFile.path;
}

// ---- Tray handler ----

class _TrayHandler with TrayListener {
  final AppState appState;
  bool _windowVisible = true;

  _TrayHandler(this.appState);

  @override
  void onTrayIconMouseDown() async {
    if (_windowVisible) {
      _windowVisible = false;
      await windowManager.setOpacity(0.0);
    } else {
      _windowVisible = true;
      await windowManager.setOpacity(1.0);
      await windowManager.show();
      await windowManager.focus();
    }
  }

  @override
  void onTrayIconRightMouseDown() async {
    // Linux: appindicator auto-shows menu, popUpContextMenu not implemented
    if (!Platform.isLinux) {
      await trayManager.popUpContextMenu();
    }
  }
}

Future<void> _initTray(AppState appState, String iconPath) async {
  final handler = _TrayHandler(appState);
  trayManager.addListener(handler);

  await trayManager.setIcon(iconPath);
  // Linux: setToolTip not implemented in tray_manager plugin
  if (!Platform.isLinux) {
    await trayManager.setToolTip('MutsuRelay');
  }
  // Small delay to let the tray icon register before setting context menu
  await Future.delayed(const Duration(milliseconds: 50));

  final menu = Menu(
    items: [
      MenuItem(
        key: 'show',
        label: '显示',
        onClick: (_) async {
          await windowManager.setOpacity(1.0);
          await windowManager.show();
          await windowManager.focus();
        },
      ),
      MenuItem.separator(),
      MenuItem(
        key: 'quit',
        label: '退出',
        onClick: (_) async {
          NativeBridge.instance.shutdown();
          await trayManager.destroy();
          await windowManager.destroy();
        },
      ),
    ],
  );
  await trayManager.setContextMenu(menu);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  if (!Platform.isLinux) {
    await acrylic.Window.initialize();
    await acrylic.Window.setEffect(
      effect: acrylic.WindowEffect.transparent,
    );
  }

  const windowOptions = WindowOptions(
    size: Size(AppInsets.normalW, AppInsets.normalH),
    minimumSize: Size(AppInsets.normalW, AppInsets.normalH),
    maximumSize: Size(800, 800),
    center: true,
    title: 'MutsuRelay',
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
    skipTaskbar: false,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  // Explicitly set size AFTER window is ready but BEFORE first frame
  await windowManager.setMinimumSize(
    const Size(AppInsets.normalW, AppInsets.normalH),
  );
  await windowManager.setSize(
    const Size(AppInsets.normalW, AppInsets.normalH),
  );

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
  ));

  NativeBridge.instance.load();

  // Search model in project root (dev) and exe-relative (release)
  String findModelDir() {
    if (Directory('asr/model').existsSync()) return 'asr/model';
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = <String>[];
    if (Platform.isWindows) {
      candidates.add('asr/model');
    } else if (Platform.isLinux) {
      candidates.add('lib/asr/model');
    } else if (Platform.isMacOS) {
      candidates.add('../Resources/asr/model');
    }
    candidates.addAll(['asr/model', '../asr/model']);
    for (final dir in candidates) {
      final p = '${exeDir.path}/$dir';
      if (Directory(p).existsSync() && File('$p/model.int8.onnx').existsSync()) {
        return p;
      }
    }
    return '';
  }
  NativeBridge.instance.init(findModelDir());

  final appState = AppState();
  appState.loadSettings();

  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const MutsuRelayApp(),
    ),
  );

  // Defer tray plugin calls to after first frame so plugin channels are registered
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final iconPath = await _generateTrayIconPath();
      await _initTray(appState, iconPath);
    } catch (e) {
      debugPrint('Tray init error: $e');
      appState.trayAvailable = false;
    }
  });
}
