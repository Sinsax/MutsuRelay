import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/user_info.dart';
import '../providers/app_state.dart';
import '../ffi/native_bridge.dart';
import '../theme/app_theme.dart';

class SettingsModal extends StatelessWidget {
  const SettingsModal({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, ({bool showSettings, bool cookieStatus, UserInfo? userInfo, bool asrRestarting, String asrLang, bool noiseSuppress, CensorMode censorMode, CloseBehavior closeBehavior, int segmentMaxMs, bool interim, Map<String, dynamic>? stats})>(
      selector: (_, state) => (
        showSettings: state.showSettings,
        cookieStatus: state.cookieStatus,
        userInfo: state.userInfo,
        asrRestarting: state.asrRestarting,
        asrLang: state.asrLang,
        noiseSuppress: state.noiseSuppress,
        censorMode: state.censorMode,
        closeBehavior: state.closeBehavior,
        segmentMaxMs: state.segmentMaxMs,
        interim: state.interim,
        stats: state.asrStats,
      ),
      builder: (context, data, _) {
        final appState = context.read<AppState>();
        if (!data.showSettings) return const SizedBox.shrink();
        return Stack(
          children: [
            GestureDetector(
              onTap: () => appState.showSettings = false,
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
                      if (data.cookieStatus)
                        _loggedInSection(data, appState)
                      else
                        _settingsRow(
                          'B站账号',
                          _actionBtn('登录', () => appState.showQrLogin = true),
                        ),
                      const SizedBox(height: 8),
                      _divider(),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Text('语音识别', style: AppTextStyles.settingsSection),
                          if (data.asrRestarting)
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
                      _languageRow(data, appState),
                      const SizedBox(height: 4),
                      _noiseRow(data, appState),
                      const SizedBox(height: 4),
                      _censorModeRow(data, appState),
                      const SizedBox(height: 4),
                      _segmentRow(data, appState),
                      const SizedBox(height: 4),
                      _interimRow(data, appState),
                      const SizedBox(height: 8),
                      _divider(),
                      const SizedBox(height: 8),
                      const Text('其他', style: AppTextStyles.settingsSection),
                      const SizedBox(height: 4),
                      _dataDirRow(context),
                      const SizedBox(height: 4),
                      _closeBehaviorRow(data, appState),
                      const SizedBox(height: 6),
                      _statsRow(data),
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

  Widget _loggedInSection(({bool showSettings, bool cookieStatus, UserInfo? userInfo, bool asrRestarting, String asrLang, bool noiseSuppress, CensorMode censorMode, CloseBehavior closeBehavior, int segmentMaxMs, bool interim, Map<String, dynamic>? stats}) data, AppState appState) {
    final bridge = NativeBridge.instance;
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
                  data.userInfo?.uname ?? '已登录',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark,
                  ),
                ),
                if (data.userInfo != null)
                  Text(
                    'UID: ${data.userInfo!.mid}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
          _logoutBtn(() {
            bridge.logout();
            appState.cookieStatus = false;
            appState.userInfo = null;
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

  Widget _closeBehaviorRow(({bool showSettings, bool cookieStatus, UserInfo? userInfo, bool asrRestarting, String asrLang, bool noiseSuppress, CensorMode censorMode, CloseBehavior closeBehavior, int segmentMaxMs, bool interim, Map<String, dynamic>? stats}) data, AppState appState) {
    return _settingsRow(
      '关闭窗口时',
      _toggleGroup<CloseBehavior>(
        [('退出', CloseBehavior.exit), ('托盘', CloseBehavior.hide)],
        data.closeBehavior,
        (v) => appState.closeBehavior = v,
      ),
    );
  }

  Widget _censorModeRow(({bool showSettings, bool cookieStatus, UserInfo? userInfo, bool asrRestarting, String asrLang, bool noiseSuppress, CensorMode censorMode, CloseBehavior closeBehavior, int segmentMaxMs, bool interim, Map<String, dynamic>? stats}) data, AppState appState) {
    return _settingsRow(
      '敏感词过滤',
      _toggleGroup<int>(
        [('关闭', 0), ('[***]', 1), ('首字母', 2)],
        data.censorMode.index,
        (v) => appState.censorMode = CensorMode.values[v],
      ),
    );
  }

  /// 单段时长上限。它直接决定连续说话时的**最坏出字延迟**：
  /// 8 s 上限意味着最坏情况要等 8 s 才整段出字（interim 只给半句预览）。
  /// 改这个值只影响后续分段，不需要重启 ASR。
  Widget _segmentRow(({bool showSettings, bool cookieStatus, UserInfo? userInfo, bool asrRestarting, String asrLang, bool noiseSuppress, CensorMode censorMode, CloseBehavior closeBehavior, int segmentMaxMs, bool interim, Map<String, dynamic>? stats}) data, AppState appState) {
    return _settingsRow(
      '单段上限',
      _toggleGroup<int>(
        [('4s', 4000), ('6s', 6000), ('8s', 8000), ('12s', 12000)],
        data.segmentMaxMs,
        (v) => appState.segmentMaxMs = v,
      ),
    );
  }

  /// interim（实时半句预览）开关。半句只进预览行，不写字幕、不自动发言。
  Widget _interimRow(({bool showSettings, bool cookieStatus, UserInfo? userInfo, bool asrRestarting, String asrLang, bool noiseSuppress, CensorMode censorMode, CloseBehavior closeBehavior, int segmentMaxMs, bool interim, Map<String, dynamic>? stats}) data, AppState appState) {
    return _settingsRow(
      '实时预览',
      _toggleGroup<bool>(
        [('开', true), ('关', false)],
        data.interim,
        (v) => appState.interim = v,
      ),
    );
  }

  /// 运行统计。这几个数是排障入口，不是装饰：
  /// - `asr_reloads`：调参时**不该涨**，涨了说明重建闸失效（CPU 与出字延迟会退化）；
  /// - `dropped_segments`：段队列溢出丢最旧，涨了说明解码跟不上；
  /// - `frontend_iter_max_ms`：采集线程单次迭代峰值，旧实现这里是 1.5~4 s。
  Widget _statsRow(({bool showSettings, bool cookieStatus, UserInfo? userInfo, bool asrRestarting, String asrLang, bool noiseSuppress, CensorMode censorMode, CloseBehavior closeBehavior, int segmentMaxMs, bool interim, Map<String, dynamic>? stats}) data) {
    final s = data.stats;
    final String text;
    if (s == null) {
      text = '原生库未加载，暂无统计';
    } else {
      text = '重建 ${s['asr_reloads'] ?? 0}(省 ${s['asr_reload_skipped'] ?? 0}) · '
          '丢段 ${s['dropped_segments'] ?? 0} · 丢样 ${s['dropped_samples'] ?? 0}\n'
          '解码p50 ${s['decode_p50_ms'] ?? 0}ms · 段队列 ${s['seg_queue_depth'] ?? 0}'
          ' · 采集峰值 ${s['frontend_iter_max_ms'] ?? 0}ms';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('运行统计', style: AppTextStyles.settingsRow),
            const Spacer(),
            Text(
              '每秒刷新',
              style: TextStyle(fontSize: 9, color: AppColors.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          text,
          style: TextStyle(
            fontSize: 10,
            height: 1.35,
            color: AppColors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _languageRow(({bool showSettings, bool cookieStatus, UserInfo? userInfo, bool asrRestarting, String asrLang, bool noiseSuppress, CensorMode censorMode, CloseBehavior closeBehavior, int segmentMaxMs, bool interim, Map<String, dynamic>? stats}) data, AppState appState) {
    return _settingsRow(
      '识别语言',
      _toggleGroup<String>(
        [('自动', 'auto'), ('中文', 'zh'), ('英文', 'en'), ('日语', 'ja')],
        data.asrLang,
        (v) => appState.asrLang = v,
      ),
    );
  }

  Widget _noiseRow(({bool showSettings, bool cookieStatus, UserInfo? userInfo, bool asrRestarting, String asrLang, bool noiseSuppress, CensorMode censorMode, CloseBehavior closeBehavior, int segmentMaxMs, bool interim, Map<String, dynamic>? stats}) data, AppState appState) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              const Text('降噪', style: AppTextStyles.settingsRow),
              const Spacer(),
              _toggleGroup<bool>(
                [('开', true), ('关', false)],
                data.noiseSuppress,
                (v) => appState.noiseSuppress = v,
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
                () => appState.restartAsr(),
                disabled: data.asrRestarting,
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
