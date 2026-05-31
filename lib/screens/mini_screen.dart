import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/message_list.dart';
import '../widgets/mini_toolbar.dart';

class MiniScreen extends StatelessWidget {
  const MiniScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        return GestureDetector(
          onSecondaryTap: () => state.showSettings = true,
          child: Container(
            decoration: BoxDecoration(
              color: state.invertMiniText
                  ? const Color(0xFFDAF5F0).withValues(alpha: state.miniOpacity)
                  : const Color(0xFF1A2E2A).withValues(alpha: state.miniOpacity),
              borderRadius: BorderRadius.circular(AppRadius.small),
            ),
            clipBehavior: Clip.antiAlias,
            child: const Column(
              children: [
                MiniToolbar(),
                Expanded(child: MessageList()),
              ],
            ),
          ),
        );
      },
    );
  }
}
