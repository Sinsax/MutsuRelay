import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'app_lifecycle.dart';
import 'providers/app_state.dart';
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
    if (!mounted) return;
    // 注意：`context.read` 必须发生在任何 await 之前。
    final state = context.read<AppState>();
    if (state.closeBehavior == CloseBehavior.hide) {
      await windowManager.setOpacity(0.0);
      return;
    }
    await quitApp();
  }

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, WindowMode>(
      selector: (_, state) => state.windowMode,
      builder: (context, windowMode, _) {
        final isMini = windowMode == WindowMode.mini;
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
              // 右下角使用提示：**只在普通模式**出现（迷你窗有自己的 MiniScreen），
              // 颜色刻意很淡，且 IgnorePointer 保证它不吃任何点击。
              // 文案与 message_list.dart 里双击复制的 Tooltip 保持一致。
              if (!isMini)
                Positioned(
                  right: 8,
                  bottom: 4,
                  child: IgnorePointer(
                    child: Text(
                      '双击消息可复制',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 0.2,
                        color: AppColors.textDim.withValues(alpha: 0.75),
                      ),
                    ),
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
