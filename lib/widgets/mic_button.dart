import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

class MicButton extends StatefulWidget {
  const MicButton({super.key});

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton> {
  final ValueNotifier<double> _displayNotifier = ValueNotifier<double>(0.0);
  double _smoothedLevel = 0.0;
  bool _hovered = false;
  AppState? _appState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _appState = context.read<AppState>();
      _appState!.audioLevelNotifier.addListener(_onAudioLevelChanged);
    });
  }

  void _onAudioLevelChanged() {
    if (!mounted) return;
    final state = _appState!;
    if (!state.isRecording) {
      if (_displayNotifier.value != 0.0) {
        _smoothedLevel = 0.0;
        _displayNotifier.value = 0.0;
      }
      return;
    }
    final target = state.audioLevelNotifier.value;
    final diff = target - _smoothedLevel;
    if (diff.abs() < 0.0005) {
      _smoothedLevel = target;
    } else {
      _smoothedLevel += diff * 0.25;
    }
    if ((_smoothedLevel - _displayNotifier.value).abs() > 0.002) {
      _displayNotifier.value = _smoothedLevel;
    }
  }

  @override
  void dispose() {
    _appState?.audioLevelNotifier.removeListener(_onAudioLevelChanged);
    _displayNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, ({bool isRecording, double noiseGate})>(
      selector: (_, state) => (
        isRecording: state.isRecording,
        noiseGate: state.noiseGate,
      ),
      builder: (context, data, _) {
        final state = context.read<AppState>();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: GestureDetector(
                  onTap: () {
                    state.isRecording = !state.isRecording;
                  },
                  child: Transform.scale(
                    scale: _hovered ? 1.08 : 1.0,
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: data.isRecording
                            ? AppColors.micActive
                            : AppColors.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          if (data.isRecording)
                            const BoxShadow(
                              color: Color(0x405BC0BE),
                              blurRadius: 12,
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
                        data.isRecording
                            ? Icons.stop_rounded
                            : Icons.mic_rounded,
                        color: data.isRecording
                            ? Colors.white
                            : AppColors.textDark,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(data.isRecording ? '停止' : '识别',
                style: AppTextStyles.micLabel),
            const SizedBox(height: 4),
            RepaintBoundary(
              child: SizedBox(
                width: 100,
                height: 4,
                child: ListenableBuilder(
                  listenable: _displayNotifier,
                  builder: (context, _) {
                    return CustomPaint(
                      painter: LevelBarPainter(
                        level: _displayNotifier.value,
                        noiseGate: data.noiseGate,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class LevelBarPainter extends CustomPainter {
  final double level;
  final double noiseGate;

  LevelBarPainter({required this.level, required this.noiseGate});

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0x1F5BC0BE);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        const Radius.circular(2),
      ),
      bgPaint,
    );

    final levelWidth = level.clamp(0.0, 1.0) * size.width;
    if (levelWidth > 0) {
      final levelPaint = Paint()..color = AppColors.primary;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, levelWidth, size.height),
          const Radius.circular(2),
        ),
        levelPaint,
      );
    }

    final gateX = (noiseGate * 10.0).clamp(0.0, 1.0) * size.width;
    final gatePaint = Paint()..color = AppColors.danger;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(gateX - 1.0, -1, 2, size.height + 2),
        const Radius.circular(1),
      ),
      gatePaint,
    );
  }

  @override
  bool shouldRepaint(LevelBarPainter oldDelegate) {
    return oldDelegate.level != level || oldDelegate.noiseGate != noiseGate;
  }
}
