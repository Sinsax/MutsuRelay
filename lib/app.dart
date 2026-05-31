import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'providers/app_state.dart';
import 'ffi/native_bridge.dart';
import 'theme/app_theme.dart';
import 'widgets/top_bar.dart';
import 'widgets/settings_modal.dart';
import 'widgets/qr_login_modal.dart';
import 'widgets/toast_overlay.dart';
import 'screens/main_screen.dart';
import 'screens/mini_screen.dart';

class MutsuRelayApp extends StatelessWidget {
  const MutsuRelayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MutsuRelay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: 'Segoe UI',
      ),
      home: const MutsuRelayHome(),
    );
  }
}

class MutsuRelayHome extends StatefulWidget {
  const MutsuRelayHome({super.key});

  @override
  State<MutsuRelayHome> createState() => _MutsuRelayHomeState();
}

class _MutsuRelayHomeState extends State<MutsuRelayHome> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    final state = context.read<AppState>();
    if (state.closeBehavior == CloseBehavior.hide) {
      await windowManager.setOpacity(0.0);
    } else {
      NativeBridge.instance.shutdown();
      await trayManager.destroy();
      await windowManager.destroy();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final isMini = state.windowMode == WindowMode.mini;
        return Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              Container(
                decoration: isMini
                    ? null
                    : const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [AppColors.bg, AppColors.bgEnd],
                        ),
                      ),
                child: Column(
                  children: [
                    const TopBar(),
                    Expanded(
                      child: Padding(
                        padding: isMini
                            ? EdgeInsets.zero
                            : const EdgeInsets.all(AppInsets.padding),
                        child: isMini
                            ? const MiniScreen(key: ValueKey('mini'))
                            : const MainScreen(key: ValueKey('main')),
                      ),
                    ),
                  ],
                ),
              ),
              // Overlays
              const SettingsModal(),
              const QrLoginModal(),
              const ToastOverlay(),
            ],
          ),
        );
      },
    );
  }
}
