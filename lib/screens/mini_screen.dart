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
    return Selector<AppState, ({bool invertMiniText, double miniOpacity})>(
      selector: (_, state) => (
        invertMiniText: state.invertMiniText,
        miniOpacity: state.miniOpacity,
      ),
      builder: (context, data, _) {
        final state = context.read<AppState>();
        return GestureDetector(
          onSecondaryTap: () => state.showSettings = true,
          child: Container(
            decoration: BoxDecoration(
              color: data.invertMiniText
                  ? const Color(0xFFDAF5F0).withValues(alpha: data.miniOpacity)
                  : const Color(0xFF1A2E2A).withValues(alpha: data.miniOpacity),
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
