import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

class MiniToolbar extends StatelessWidget {
  const MiniToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
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
              const SizedBox(width: 8),
              _miniModeToggle(state),
              _miniSettingsBtn(context),
              _miniInvertBtn(state),
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

  Widget _miniSettingsBtn(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => context.read<AppState>().showSettings = true,
          child: Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            child: const Icon(
              Icons.settings_rounded,
              size: 13,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _miniInvertBtn(AppState state) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: GestureDetector(
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

  Widget _opacitySlider(AppState state) {
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: AppColors.primary,
        inactiveTrackColor: const Color(0x4D5BC0BE),
        thumbColor: AppColors.primary,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
        trackShape: const RoundedRectSliderTrackShape(),
        overlayColor: Colors.transparent,
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
