import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:mutsurelay_flutter/providers/app_state.dart';
import 'package:mutsurelay_flutter/screens/main_screen.dart';

void main() {
  testWidgets('Main screen renders mic button', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const _TestWrapper(),
      ),
    );
    await tester.pump();
    expect(find.text('识别'), findsOneWidget);
  });
}

class _TestWrapper extends StatelessWidget {
  const _TestWrapper();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Material(
        child: SizedBox(width: 600, height: 320, child: MainScreen()),
      ),
    );
  }
}
