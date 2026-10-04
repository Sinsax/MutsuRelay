import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mutsurelay/app.dart';
import 'package:mutsurelay/providers/app_state.dart';

/// "双击消息可复制"的右下角提示：普通模式出现、迷你模式不出现、且不吃点击。
void main() {
  testWidgets('右下角提示仅在普通模式出现', (WidgetTester tester) async {
    // 切模式会调 window_manager 的插件方法，测试环境里没有插件实现 —— 直接回 null。
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => null,
    );

    final state = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MutsuRelayApp(),
      ),
    );
    await tester.pump();

    expect(find.text('双击消息可复制'), findsOneWidget, reason: '普通模式应当有提示');
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.text('双击消息可复制'),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isTrue,
      reason: '提示不能吃掉点击',
    );

    // 切到迷你模式：提示必须消失（迷你窗走 MiniScreen）
    await state.setWindowMode(WindowMode.mini);
    await tester.pump();
    expect(find.text('双击消息可复制'), findsNothing, reason: '迷你模式不该有这行提示');

    // 还原，避免遗留的窗口尺寸请求影响后续断言
    await state.setWindowMode(WindowMode.normal);
    await tester.pump();
  });
}
