import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mutsurelay/providers/app_state.dart';
import 'package:mutsurelay/widgets/message_list.dart';

void main() {
  testWidgets('双击消息文本复制完整原文到剪贴板', (WidgetTester tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );

    final state = AppState();
    // 故意用一段会被列表截断的长文本（列表 maxLines: 2）：
    // 双击必须复制**完整原文**，而不是显示出来的那一截。
    const text = '这是一条很长的消息，列表里只会显示两行，但双击复制到的必须是完整原文';
    state.addSentence(text);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: Material(
            child: SizedBox(width: 420, height: 320, child: MessageList()),
          ),
        ),
      ),
    );
    await tester.pump();

    final target = find.text(text);
    expect(target, findsOneWidget, reason: '消息应当渲染出来');

    await tester.tap(target);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(target);
    await tester.pumpAndSettle();

    expect(copied, [text], reason: '双击应把完整原文写进剪贴板');

    // 双击后再单击一次不得再复制（只有双击才触发）
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(copied.length, 1);

    // 让所有挂起的计时器自然走完，否则测试结束时会报
    // "A Timer is still pending"：
    //   - 双击识别器（DoubleTapGestureRecognizer）的 300 ms 等待
    //   - "已复制到剪贴板"提示的 3 s 自动消失计时器（AppState.showToast）
    await tester.pump(const Duration(seconds: 4));
  });
}
