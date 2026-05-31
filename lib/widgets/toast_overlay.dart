import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

class ToastOverlay extends StatefulWidget {
  const ToastOverlay({super.key});

  @override
  State<ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<ToastOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnim;
  bool _hiding = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        setState(() => _hiding = false);
      }
    });
  }

  String _prevMessage = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.watch<AppState>();
    final msg = state.toastMessage;
    if (msg.isNotEmpty && msg != _prevMessage) {
      _prevMessage = msg;
      _hiding = false;
      _controller.forward(from: 0.0);
    } else if (msg.isEmpty && _prevMessage.isNotEmpty && !_hiding) {
      _hiding = true;
      _controller.reverse();
      _prevMessage = '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final show = state.toastMessage.isNotEmpty || _hiding;
        if (!show) return const SizedBox.shrink();

        Color bgColor;
        switch (state.toastType) {
          case ToastType.error:
            bgColor = AppColors.danger;
          case ToastType.warning:
            bgColor = AppColors.warning;
          case ToastType.info:
            bgColor = AppColors.info;
        }

        return Positioned(
          bottom: 16,
          left: 0,
          right: 0,
          child: AnimatedBuilder(
            animation: _fadeAnim,
            builder: (context, child) {
              return Opacity(
                opacity: _fadeAnim.value,
                child: child,
              );
            },
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  boxShadow: [
                    BoxShadow(
                      color: bgColor.withValues(alpha: 0.4),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(state.toastMessage, style: AppTextStyles.toast),
              ),
            ),
          ),
        );
      },
    );
  }
}
