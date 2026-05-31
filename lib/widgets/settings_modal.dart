import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../ffi/native_bridge.dart';
import '../theme/app_theme.dart';

class SettingsModal extends StatelessWidget {
  const SettingsModal({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        if (!state.showSettings) return const SizedBox.shrink();
        return Stack(
          children: [
            GestureDetector(
              onTap: () => state.showSettings = false,
              child: Container(color: AppColors.overlayBg),
            ),
            Center(
              child: Container(
                width: 250,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5F2),
                  borderRadius: BorderRadius.circular(AppRadius.normal),
                  border: Border.all(color: const Color(0x665BC0BE)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('账号', style: AppTextStyles.settingsSection),
                      const SizedBox(height: 4),
                      if (state.cookieStatus)
                        _loggedInSection(state)
                      else
                        _settingsRow(
                          'B站账号',
                          _actionBtn('登录', () => state.showQrLogin = true),
                        ),
                      const SizedBox(height: 8),
                      _divider(),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Text('语音识别', style: AppTextStyles.settingsSection),
                          if (state.asrRestarting)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Text(
                                '(重启中...)',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                          const Spacer(),
                          Text(
                            '有语音问题请重启asr引擎',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      _languageRow(state),
                      const SizedBox(height: 4),
                      _noiseRow(context, state),
                      const SizedBox(height: 4),
                      _censorModeRow(state),
                      const SizedBox(height: 8),
                      _divider(),
                      const SizedBox(height: 8),
                      const Text('文件', style: AppTextStyles.settingsSection),
                      const SizedBox(height: 4),
                      _dataDirRow(context),
                      const SizedBox(height: 8),
                      _divider(),
                      const SizedBox(height: 8),
                      const Text('窗口', style: AppTextStyles.settingsSection),
                      const SizedBox(height: 4),
                      _closeBehaviorRow(state),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _loggedInSection(AppState state) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: Icon(Icons.check, size: 12, color: AppColors.textDark),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  state.userInfo?.uname ?? '已登录',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark,
                  ),
                ),
                if (state.userInfo != null)
                  Text(
                    'UID: ${state.userInfo!.mid}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
          _logoutBtn(() {
            NativeBridge.instance.logout();
            state.cookieStatus = false;
            state.userInfo = null;
          }),
        ],
      ),
    );
  }

  Widget _logoutBtn(VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: onTap,
        hoverColor: AppColors.danger.withValues(alpha: 0.1),
        child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.danger),
            borderRadius: BorderRadius.circular(5),
          ),
          child: const Text(
            '退出登录',
            style: TextStyle(fontSize: 11, color: AppColors.danger),
          ),
        ),
      ),
    );
  }

  Widget _closeBehaviorRow(AppState state) {
    return _settingsRow(
      '关闭窗口时',
      _toggleGroup<CloseBehavior>(
        [('退出', CloseBehavior.exit), ('托盘', CloseBehavior.hide)],
        state.closeBehavior,
        (v) => state.closeBehavior = v,
      ),
    );
  }

  Widget _censorModeRow(AppState state) {
    return _settingsRow(
      '敏感词过滤',
      _toggleGroup<int>(
        [('关闭', 0), ('[***]', 1), ('首字母', 2)],
        state.censorMode.index,
        (v) => state.censorMode = CensorMode.values[v],
      ),
    );
  }

  Widget _languageRow(AppState state) {
    return _settingsRow(
      '识别语言',
      _toggleGroup<String>(
        [('自动', 'auto'), ('中文', 'zh'), ('英文', 'en'), ('日语', 'ja')],
        state.asrLang,
        (v) => state.asrLang = v,
      ),
    );
  }

  Widget _noiseRow(BuildContext context, AppState state) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              const Text('降噪', style: AppTextStyles.settingsRow),
              const Spacer(),
              _toggleGroup<bool>(
                [('开', true), ('关', false)],
                state.noiseSuppress,
                (v) => state.noiseSuppress = v,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('|', style: TextStyle(color: AppColors.textMuted)),
        ),
        Expanded(
          child: Row(
            children: [
              const Text('asr引擎', style: AppTextStyles.settingsRow),
              const Spacer(),
              _actionBtn(
                '重启',
                () => state.restartAsr(),
                disabled: state.asrRestarting,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _settingsRow(String label, Widget trailing) {
    return Row(
      children: [
        Text(label, style: AppTextStyles.settingsRow),
        const Spacer(),
        trailing,
      ],
    );
  }

  Widget _toggleGroup<T>(
    List<(String, T)> options,
    T current,
    ValueSetter<T> onTap,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x1F5BC0BE),
        borderRadius: BorderRadius.circular(5),
      ),
      padding: const EdgeInsets.all(1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: options.map((opt) {
          final active = opt.$2 == current;
          return Material(
            color: active ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => onTap(opt.$2),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                child: Text(
                  opt.$1,
                  style: TextStyle(
                    fontSize: 11,
                    color: active ? AppColors.textDark : AppColors.textMuted,
                    fontWeight: active ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _divider() {
    return Container(height: 1, color: AppColors.divider);
  }

  Widget _actionBtn(String label, VoidCallback onTap, {bool disabled = false}) {
    return Material(
      color: disabled
          ? AppColors.primary.withValues(alpha: 0.5)
          : AppColors.primary,
      borderRadius: BorderRadius.circular(AppRadius.small),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.small),
        onTap: disabled ? null : onTap,
        hoverColor: AppColors.textDark.withValues(alpha: 0.1),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textDark,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _dataDirRow(BuildContext context) {
    return _settingsRow('配置文件-字幕文件', _actionBtn('打开文件夹', () {
      final path = NativeBridge.instance.getConfigDirPath();
      if (path != null) {
        if (Platform.isLinux) {
          Process.run('xdg-open', [path]);
        } else if (Platform.isMacOS) {
          Process.run('open', [path]);
        } else {
          Process.run('explorer', [path]);
        }
      }
    }));
  }
}
