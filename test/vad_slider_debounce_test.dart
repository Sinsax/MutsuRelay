import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mutsurelay/providers/app_state.dart';
import 'package:mutsurelay/widgets/vad_slider.dart';

/// 只关心"什么时候落盘"：把 saveSettings 换成计数器，就能在不碰 native 的前提下
/// 把"拖动不写盘 / 松手后延迟一次 / 来回拖只写一次"钉成回归。
class _SpyAppState extends AppState {
  int saves = 0;

  @override
  void saveSettings() {
    saves++;
  }
}

Future<_SpyAppState> _pumpSlider(WidgetTester tester) async {
  final state = _SpyAppState();
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(
        home: Material(
          child: SizedBox(width: 260, height: 180, child: VadSlider()),
        ),
      ),
    ),
  );
  await tester.pump();
  return state;
}

void main() {
  testWidgets('拖动过程不落盘，松手后延迟一小段才落盘一次', (WidgetTester tester) async {
    final state = await _pumpSlider(tester);

    // 模拟一次拖动里的连续若干步
    for (final v in [12, 18, 24, 30]) {
      state.setNoiseGateFromSlider(v);
    }
    await tester.pump(const Duration(milliseconds: 900));
    expect(state.saves, 0, reason: '拖动过程中不该写配置');
    expect(state.noiseGateDisplay, 30, reason: '运行时门限应当已经跟着走');

    // 松手：延迟窗口内不落盘，窗口过了才落一次
    state.commitNoiseGateSoon();
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.saves, 0, reason: '延迟还没到，不该落盘');
    await tester.pump(const Duration(milliseconds: 600));
    expect(state.saves, 1, reason: '松手后应当只落盘一次');
  });

  testWidgets('手势按下会作废上一轮待提交：来回拖只落盘一次', (WidgetTester tester) async {
    final state = await _pumpSlider(tester);

    state.setNoiseGateFromSlider(20);
    state.commitNoiseGateSoon();
    await tester.pump(const Duration(milliseconds: 200));

    // 延迟窗口内又按下去拖：上一轮提交必须被作废
    state.beginNoiseGateDrag();
    state.setNoiseGateFromSlider(9);
    await tester.pump(const Duration(milliseconds: 900));
    expect(state.saves, 0, reason: '被作废的那一轮不该落盘');

    // 真正结束操作
    state.commitNoiseGateSoon();
    await tester.pump(const Duration(milliseconds: 900));
    expect(state.saves, 1, reason: '只保留最后一次');
  });
}
