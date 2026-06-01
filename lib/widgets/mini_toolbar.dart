import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

class MiniToolbar extends StatelessWidget {
  const MiniToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, ({bool isRecording, SendMode sendMode, bool invertMiniText, double miniOpacity, bool alwaysOnTop})>(
      selector: (_, state) => (
        isRecording: state.isRecording,
        sendMode: state.sendMode,
        invertMiniText: state.invertMiniText,
        miniOpacity: state.miniOpacity,
        alwaysOnTop: state.alwaysOnTop,
      ),
      builder: (context, data, _) {
        final state = context.read<AppState>();
        return Container(
          height: AppInsets.miniToolbarH,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            color: Color(0xCC5BC0BE),
            border: Border(
              bottom: BorderSide(color: Color(0x335BC0BE), width: 1),
            ),
          ),
          child: Row(
            children: [
              _miniMicBtn(state),
              const SizedBox(width: 4),
              _miniModeToggle(state),
              const SizedBox(width: 4),
              _miniInvertBtn(state),
              const SizedBox(width: 4),
              _miniPinBtn(state),
              const SizedBox(width: 4),
              Expanded(child: _opacitySlider(state)),
            ],
          ),
        );
      },
    );
  }

  Widget _miniMicBtn(AppState state) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => state.isRecording = !state.isRecording,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: state.isRecording ? AppColors.micActive : AppColors.primary,
            shape: BoxShape.circle,
            boxShadow: state.isRecording
                ? [
                    BoxShadow(
                      color: AppColors.micActive.withValues(alpha: 0.4),
                      blurRadius: 6,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            Icons.mic_rounded,
            size: 14,
            color: state.isRecording ? Colors.white : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _miniInvertBtn(AppState state) {
    return GestureDetector(
        onTap: () => state.toggleInvertMiniText(),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: state.invertMiniText ? Colors.white.withValues(alpha: 0.3) : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            state.invertMiniText ? 'A' : 'A',
            style: TextStyle(
              fontSize: 11,
              color: state.invertMiniText ? AppColors.textDark : Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
  }

  Widget _miniModeToggle(AppState state) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x66FFFFFF),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      padding: const EdgeInsets.all(1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _miniToggleBtn(
            '手动',
            state.sendMode == SendMode.manual,
            () => state.sendMode = SendMode.manual,
          ),
          const SizedBox(width: 1),
          _miniToggleBtn(
            '自动',
            state.sendMode == SendMode.auto,
            () => state.sendMode = SendMode.auto,
          ),
        ],
      ),
    );
  }

  Widget _miniToggleBtn(String label, bool active, VoidCallback onTap) {
    return Material(
      color: active ? AppColors.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: active ? Colors.white : Colors.white.withValues(alpha: 0.8),
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _miniPinBtn(AppState state) {
    return Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => state.toggleAlwaysOnTop(),
          child: Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            child: Icon(
              state.alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
              size: 14,
              color: Colors.white,
            ),
          ),
        ),
      );
  }

  Widget _opacitySlider(AppState state) {
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: Colors.white,
        inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
        thumbColor: Colors.white,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
        trackShape: const RoundedRectSliderTrackShape(),
        overlayColor: Colors.transparent,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
      ),
      child: Slider(
        min: 0.15,
        max: 1.0,
        value: state.miniOpacity,
        onChanged: (v) {
          state.miniOpacity = v;
        },
      ),
    );
  }
}
