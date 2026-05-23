import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/app_state.dart';
import '../ffi/native_bridge.dart';
import '../theme/app_theme.dart';
import '../widgets/mic_button.dart';
import '../widgets/mode_toggle.dart';
import '../widgets/vad_slider.dart';
import '../widgets/message_list.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final showRight = constraints.maxWidth >= 400;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _leftPanel(state),
                const SizedBox(width: AppInsets.gap),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, inner) {
                      final msgW = inner.maxWidth > 320 ? (inner.maxWidth < 480 ? inner.maxWidth : 480.0) : inner.maxWidth;
                      return Center(
                        child: SizedBox(width: msgW, child: const MessageList()),
                      );
                    },
                  ),
                ),
                if (showRight) ...[
                  const SizedBox(width: AppInsets.gap),
                  _rightPanel(state),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _leftPanel(AppState state) {
    return SizedBox(
      width: AppInsets.leftPanelW,
      child: SingleChildScrollView(
        child: ListBody(
          children: [
            const Center(child: MicButton()),
            const SizedBox(height: 6),
            _card(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ModeToggle(),
                  const SizedBox(height: 8),
                  const VadSlider(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0x80FFFFFF),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: const [AppShadows.card],
      ),
      child: child,
    );
  }

  Widget _rightPanel(AppState state) {
    return SizedBox(
      width: AppInsets.rightPanelW,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!state.cookieStatus)
            _dashedBtn('登录B站', Icons.qr_code, () => state.showQrLogin = true),
          if (state.cookieStatus) ...[
            _card(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _solidBtn(
                    label: state.isConnected ? '断开连接' : '连接直播间',
                    isActive: state.isConnected,
                    disabled: false,
                    icon: state.isConnected
                        ? Icons.link_off_rounded
                        : Icons.link_rounded,
                    onTap: () {
                      if (state.isConnected) {
                        state.disconnectRoom();
                      } else {
                        final id = NativeBridge.instance.getMyRoomId();
                        if (id <= 0) {
                          state.showToast('请先登录有直播间的账号', ToastType.warning);
                          return;
                        }
                        state.connectToRoom(id);
                      }
                    },
                  ),
                  if (state.isConnected) ...[
                    const SizedBox(height: 8),
                    _roomLink(state.roomId),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _roomLink(String roomId) {
    return Material(
      color: const Color(0x185BC0BE),
      borderRadius: BorderRadius.circular(AppRadius.small),
      child: InkWell(
        onTap: () => _openRoom(roomId),
        hoverColor: AppColors.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.small),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.open_in_new_rounded,
                size: 12,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text('B站 $roomId', style: AppTextStyles.roomLink),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openRoom(String roomId) async {
    if (roomId.isEmpty) return;
    final uri = Uri.parse('https://live.bilibili.com/$roomId');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _dashedBtn(String label, IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        hoverColor: AppColors.primary.withValues(alpha: 0.1),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0x805BC0BE), width: 2),
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _solidBtn({
    required String label,
    required bool isActive,
    required bool disabled,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return Material(
      color: isActive ? AppColors.micActive : AppColors.primary,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: disabled ? null : onTap,
        hoverColor: isActive
            ? Colors.white.withValues(alpha: 0.15)
            : const Color(0xFF7AD4D0),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: isActive ? Colors.white : AppColors.textDark,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: isActive ? Colors.white : AppColors.textDark,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
