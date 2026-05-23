import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

class QrLoginModal extends StatefulWidget {
  const QrLoginModal({super.key});

  @override
  State<QrLoginModal> createState() => _QrLoginModalState();
}

class _QrLoginModalState extends State<QrLoginModal> {
  Timer? _pollTimer;
  Timer? _timeoutTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.watch<AppState>();
    if (state.showQrLogin && _pollTimer == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final s = context.read<AppState>();
        if (s.qrCodeUrl.isEmpty) {
          _refreshQrcode();
        } else {
          _startPolling();
        }
      });
    } else if (!state.showQrLogin) {
      _pollTimer?.cancel();
      _pollTimer = null;
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _timeoutTimer?.cancel();
    super.dispose();
  }

  void _refreshQrcode() {
    final state = context.read<AppState>();
    state.generateQrCode();
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _timeoutTimer?.cancel();

    _timeoutTimer = Timer(const Duration(seconds: 120), () {
      if (!mounted) return;
      final state = context.read<AppState>();
      state.resetQrCode();
      _pollTimer?.cancel();
    });

    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final state = context.read<AppState>();
      if (state.qrCodeStatus == 'success') {
        _pollTimer?.cancel();
        _timeoutTimer?.cancel();
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) state.showQrLogin = false;
        });
        return;
      }
      if (state.qrCodeStatus == 'expired') {
        _pollTimer?.cancel();
        return;
      }
      state.pollQrCodeStatus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        if (!state.showQrLogin) return const SizedBox.shrink();
        return Stack(
          children: [
            GestureDetector(
              onTap: () => state.showQrLogin = false,
              child: Container(color: AppColors.overlayBg),
            ),
            Center(
              child: Container(
                width: 220,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5F2),
                  borderRadius: BorderRadius.circular(AppRadius.normal),
                  border: Border.all(color: const Color(0x665BC0BE)),
                  boxShadow: const [AppShadows.modal],
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _qrCodeBox(state),
                    const SizedBox(height: 12),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: state.qrCodeStatus == 'success'
                            ? AppColors.success.withValues(alpha: 0.1)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(AppRadius.small),
                      ),
                      child: Text(
                        state.qrCodeMessage,
                        style: TextStyle(
                          fontSize: 12,
                          color: state.qrCodeStatus == 'success'
                              ? AppColors.success
                              : (state.qrCodeConfirmCount >= 3
                                    ? AppColors.warning
                                    : AppColors.textMuted),
                          fontWeight: state.qrCodeConfirmCount >= 3
                              ? FontWeight.w500
                              : FontWeight.normal,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (state.qrCodeStatus != 'success')
                      _actionBtn('刷新二维码', _refreshQrcode),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _qrCodeBox(AppState state) {
    if (state.qrCodeStatus == 'success') {
      return Container(
        width: 180,
        height: 180,
        decoration: BoxDecoration(
          color: const Color(0x335BC0BE),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle_rounded,
              size: 48,
              color: AppColors.success,
            ),
            SizedBox(height: 8),
            Text(
              '登录成功',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    return Container(
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x4D5BC0BE)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (state.qrCodeUrl.isNotEmpty)
            QrImageView(
              data: state.qrCodeUrl,
              version: QrVersions.auto,
              size: 160,
              backgroundColor: Colors.white,
              padding: const EdgeInsets.all(6),
            )
          else
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.textDim,
              ),
            ),
          if (state.qrCodeConfirmCount >= 3)
            Positioned(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.phone_android,
                      size: 14,
                      color: AppColors.textDark,
                    ),
                    SizedBox(width: 6),
                    Text(
                      '已扫码',
                      style: TextStyle(fontSize: 12, color: AppColors.textDark),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actionBtn(String label, VoidCallback onTap) {
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(AppRadius.small),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.small),
        onTap: onTap,
        hoverColor: AppColors.primaryLight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textDark,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
