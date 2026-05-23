import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import '../providers/app_state.dart';
import '../ffi/native_bridge.dart';
import '../theme/app_theme.dart';

class TopBar extends StatelessWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final isMini = state.windowMode == WindowMode.mini;

        return Container(
          height: AppInsets.headerH,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: isMini ? const Color(0xFF5BC0BE) : const Color(0x1F5BC0BE),
            border: Border(
              bottom: BorderSide(
                color: isMini ? const Color(0x305BC0BE) : AppColors.divider,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              // Drag handle area
              Expanded(
                child: GestureDetector(
                  onPanStart: (_) => windowManager.startDragging(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: Container(
                      color: Colors.transparent,
                      padding: const EdgeInsets.only(left: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: state.windowMode == WindowMode.normal
                                ? _normalModeContent(state)
                                : _miniModeContent(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Action buttons
              _iconBtn(
                Icons.settings_rounded,
                '设置',
                () => state.showSettings = true,
                isMini,
              ),
              const SizedBox(width: 2),
              _iconBtn(
                isMini
                    ? Icons.open_in_full_rounded
                    : Icons.close_fullscreen_rounded,
                isMini ? '展开' : '迷你',
                () => _toggleMode(state),
                isMini,
              ),
              const SizedBox(width: 2),
              _winButtons(state, isMini),
            ],
          ),
        );
      },
    );
  }

  Future<void> _toggleMode(AppState state) async {
    await state.setWindowMode(
      state.windowMode == WindowMode.normal
          ? WindowMode.mini
          : WindowMode.normal,
    );
  }

  Widget _normalModeContent(AppState state) {
    return Row(
      children: [
        _brand(),
        const SizedBox(width: 12),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _statusBadge(
                active: state.cookieStatus,
                label: state.cookieStatus
                    ? (state.userInfo?.uname ?? '已登录')
                    : '未登录',
                icon: state.cookieStatus ? Icons.person : Icons.person_outline,
              ),
              const SizedBox(width: 10),
              _statusBadge(
                active: state.isConnected,
                label: state.isConnected ? '已连接' : '未连接',
                icon: state.isConnected ? Icons.wifi : Icons.wifi_off_rounded,
              ),
              const SizedBox(width: 10),
              _statusBadge(
                active: state.isRecording,
                label: state.isRecording ? '识别中' : '未识别',
                icon: state.isRecording ? Icons.mic : Icons.mic_none_rounded,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _miniModeContent() {
    return _brand(compact: true);
  }

  Widget _brand({bool compact = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/logo_tr.png',
          width: 20,
          height: 20,
          filterQuality: FilterQuality.high,
        ),
        const SizedBox(width: 6),
        Text(
          'MutsuRelay',
          style: compact ? AppTextStyles.miniTitle : AppTextStyles.logo,
        ),
        if (!compact) const SizedBox(width: 12),
      ],
    );
  }

  Widget _statusBadge({
    required bool active,
    required String label,
    IconData? icon,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 100),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active ? AppColors.primary : const Color(0x335BC0BE),
          borderRadius: BorderRadius.circular(AppRadius.tag),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 10,
                color: active ? Colors.white : AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                label,
                style: active ? AppTextStyles.statusActive : AppTextStyles.status,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(
    IconData icon,
    String tooltip,
    VoidCallback onPressed,
    bool isMini,
  ) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Material(
          color: isMini ? const Color(0x80FFFFFF) : const Color(0x335BC0BE),
          borderRadius: BorderRadius.circular(AppRadius.small),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.small),
            onTap: onPressed,
            hoverColor: AppColors.primary,
            child: Center(
              child: Icon(
                icon,
                size: 15,
                color: isMini ? AppColors.textDark : AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _winButtons(AppState state, bool isMini) {
    final baseColor = isMini ? AppColors.textDark : AppColors.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _winBtn(
          Icons.horizontal_rule_rounded,
          '最小化',
          () => windowManager.minimize(),
          baseColor,
          isMini,
          null,
        ),
        const SizedBox(width: 2),
        _winBtn(
          Icons.close_rounded,
          '关闭',
          _closeWindow(state),
          baseColor,
          isMini,
          AppColors.danger,
        ),
      ],
    );
  }

  VoidCallback _closeWindow(AppState state) {
    return () {
      if (state.closeBehavior == CloseBehavior.exit) {
        NativeBridge.instance.shutdown();
        trayManager.destroy();
        windowManager.destroy();
      } else {
        windowManager.hide();
      }
    };
  }

  Widget _winBtn(
    IconData icon,
    String tooltip,
    VoidCallback onPressed,
    Color normalColor,
    bool isMini,
    Color? hoverColor,
  ) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.small),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.small),
            onTap: onPressed,
            hoverColor: hoverColor != null
                ? hoverColor.withValues(alpha: 0.2)
                : const Color(0x335BC0BE),
            child: Center(child: Icon(icon, size: 15, color: normalColor)),
          ),
        ),
      ),
    );
  }
}
