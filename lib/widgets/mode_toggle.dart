import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

class ModeToggle extends StatelessWidget {
  const ModeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('发送方式', style: AppTextStyles.sectionTitle),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color: const Color(0x80FFFFFF),
                borderRadius: BorderRadius.circular(AppRadius.tag),
              ),
              padding: const EdgeInsets.all(3),
              child: Row(
                children: [
                  Expanded(
                    child: _toggleBtn(
                      '手动',
                      state.sendMode == SendMode.manual,
                      () => state.sendMode = SendMode.manual,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: _toggleBtn(
                      '自动',
                      state.sendMode == SendMode.auto,
                      () => state.sendMode = SendMode.auto,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _toggleBtn(String label, bool active, VoidCallback onTap) {
    return Material(
      color: active ? AppColors.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: active ? AppColors.textDark : AppColors.textMuted,
                fontWeight: active ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
