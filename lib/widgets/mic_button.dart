import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

class MicButton extends StatefulWidget {
  const MicButton({super.key});

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;
  bool _hovered = false;
  bool _lastRecording = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  void _syncPulse(bool isRecording) {
    if (isRecording == _lastRecording) return;
    _lastRecording = isRecording;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (isRecording) {
        if (!_pulseController.isAnimating) _pulseController.repeat();
      } else {
        _pulseController.stop();
        _pulseController.reset();
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        _syncPulse(state.isRecording);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child:               GestureDetector(
                onTap: () {
                  state.isRecording = !state.isRecording;
                },
                child: AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (context, child) {
                    final scale = _hovered ? 1.08 : 1.0;
                    final pulseExtra = state.isRecording
                        ? 0.03 * _pulseAnim.value
                        : 0.0;
                    return Transform.scale(
                      scale: scale + pulseExtra,
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: state.isRecording
                              ? AppColors.micActive
                              : AppColors.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            if (state.isRecording)
                              BoxShadow(
                                color: AppColors.micActive.withValues(
                                    alpha: 0.5 * (1 - _pulseAnim.value)),
                                blurRadius: 10 + 8 * _pulseAnim.value,
                                spreadRadius: 0,
                              )
                            else if (_hovered)
                              const BoxShadow(
                                color: Color(0x805BC0BE),
                                blurRadius: 12,
                                spreadRadius: 0,
                              )
                            else
                              const BoxShadow(
                                color: Colors.transparent,
                                blurRadius: 0,
                                spreadRadius: 0,
                              ),
                          ],
                        ),
                        child: Icon(
                          state.isRecording
                              ? Icons.stop_rounded
                              : Icons.mic_rounded,
                          color: state.isRecording
                              ? Colors.white
                              : AppColors.textDark,
                          size: 24,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(state.isRecording ? '停止' : '识别', style: AppTextStyles.micLabel),
            const SizedBox(height: 4),
            SizedBox(
              width: 100,
              height: 4,
              child: _levelBar(state),
            ),
          ],
        );
      },
    );
  }

  Widget _levelBar(AppState state) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Stack(
        children: [
          Container(
            width: double.infinity,
            height: 4,
            color: const Color(0x1F5BC0BE),
          ),
          AnimatedFractionallySizedBox(
            duration: const Duration(milliseconds: 80),
            widthFactor: state.audioLevel.clamp(0.0, 1.0),
            child: Container(
              height: 4,
              color: AppColors.primary,
            ),
          ),
          Positioned(
            left: (state.noiseGate * 6.0).clamp(0.0, 1.0) * 94.0,
            top: -1,
            child: Container(
              width: 2,
              height: 6,
              decoration: BoxDecoration(
                color: AppColors.danger,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
