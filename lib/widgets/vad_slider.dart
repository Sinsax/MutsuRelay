import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

class VadSlider extends StatelessWidget {
  const VadSlider({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('灵敏度 ${state.noiseGateDisplay}', style: AppTextStyles.sectionTitle),
            const SizedBox(height: 2),
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: AppColors.primary,
                inactiveTrackColor: const Color(0x335BC0BE),
                thumbColor: AppColors.primary,
                overlayColor: AppColors.primary.withValues(alpha: 0.1),
                thumbShape: _VadThumbShape(),
                trackShape: const RoundedRectSliderTrackShape(),
                rangeThumbShape: const RoundRangeSliderThumbShape(),
              ),
              child: Slider(
                min: 1,
                max: 50,
                value: state.noiseGateDisplay.toDouble(),
                onChanged: (v) {
                  state.setNoiseGateFromSlider(v.round());

                },
              ),
            ),
            Text(state.noiseGateHint, style: AppTextStyles.micLabel),
          ],
        );
      },
    );
  }
}

class _VadThumbShape extends SliderComponentShape {
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(16, 16);
  }

  @override
  void paint(PaintingContext context, Offset center,
      {required Animation<double> activationAnimation,
      required Animation<double> enableAnimation,
      required bool isDiscrete,
      required TextPainter labelPainter,
      required RenderBox parentBox,
      required SliderThemeData sliderTheme,
      required TextDirection textDirection,
      required double value,
      required double textScaleFactor,
      required Size sizeWithOverflow}) {
    final canvas = context.canvas;
    final shadowOffset = center + const Offset(0, 1);

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    canvas.drawCircle(shadowOffset, 8, shadowPaint);

    final outerPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 8, outerPaint);

    final innerPaint = Paint()
      ..color = sliderTheme.thumbColor!
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 6, innerPaint);
  }
}
