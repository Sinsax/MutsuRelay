import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import '../models/sentence_item.dart';
import '../models/user_info.dart';
import '../ffi/native_bridge.dart';
import '../theme/app_theme.dart';

enum SendMode { manual, auto }

enum WindowMode { normal, mini }

enum CloseBehavior { exit, hide }

enum CensorMode { off, asterisk, pinyin }

enum ToastType { error, warning, info }

class AppState extends ChangeNotifier {
  // Recording
  bool _isRecording = false;
  bool get isRecording => _isRecording;
  Timer? _recordingPollTimer;
  // 停止录音后仍继续轮询的剩余次数，用于收 native 侧最后 flush 的一段
  int _stopGraceTicks = 0;

  set isRecording(bool value) {
    if (value == _isRecording) return;
    final bridge = NativeBridge.instance;
    if (value) {
      final modelOk = _modelDir().isNotEmpty;
      if (!modelOk) {
        showToast('未加载 ASR 模型，语音识别不可用', ToastType.warning);
      }
      final result = bridge.startRecording();
      if (result != 0) {
        showToast('启动录音失败', ToastType.error);
        return;
      }
      _isRecording = true;
      _startPolling();
    } else {
      // 不立刻取消轮询：native 侧停止后还会 flush 最后一段，
      // 留一小段宽限期把尾句收完，否则每次停止都丢最后一句。
      bridge.stopRecording();
      _stopGraceTicks = 60; // ≈3s
      _liveText = '';
      _audioLevel = 0.0;
      audioLevelNotifier.value = 0.0;
      _isRecording = false;
    }
    notifyListeners();
  }

  void _startPolling() {
    _recordingPollTimer?.cancel();
    _stopGraceTicks = 0;
    _recordingPollTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final bridge = NativeBridge.instance;
      final poll = bridge.pollRecording();
      final recording = poll != null && poll['recording'] == true;

      // 无论是否还在录音，都先把 native 产出的结果取走（一次取走整批）。
      // 此前是单槽覆盖 + 只取一条，一次 flush 含多段时前面的会被丢掉。
      final results = poll?['results'];
      if (results is List && results.isNotEmpty) {
        var got = false;
        for (final item in results) {
          if (item is! Map) continue;
          final text = (item['text'] as String?) ?? '';
          if (text.isEmpty) continue;
          if (item['final'] == false) {
            // interim（实时半句）：只更新预览，不进句列表、不参与自动发言
            if (_liveText != text) {
              _liveText = text;
              got = true;
            }
            continue;
          }
          addSentence(text);
          _liveText = '';
          got = true;
        }
        if (got) notifyListeners();
      }

      if (recording) {
        // recording 为 true 已蕴含 poll != null，无需再断言
        final p = poll;
        _audioLevel = (p['level'] as num?)?.toDouble() ?? 0.0;
        audioLevelNotifier.value = _audioLevel;
        final inSpeech = p['in_speech'] == true;
        if (inSpeech && _liveText.isEmpty) {
          _liveText = '...';
          notifyListeners();
        } else if (!inSpeech && _liveText.isNotEmpty) {
          _liveText = '';
          notifyListeners();
        }
        return;
      }

      // 已停止：宽限期内继续轮询，等 native 把最后一段 flush 出来
      if (_stopGraceTicks > 0) {
        _stopGraceTicks--;
        return;
      }

      final err = (poll?['error'] as String?) ?? '';
      if (err.isNotEmpty) showToast(err, ToastType.error);
      _isRecording = false;
      _audioLevel = 0.0;
      audioLevelNotifier.value = 0.0;
      _liveText = '';
      _recordingPollTimer?.cancel();
      notifyListeners();
    });
  }

  // Connection
  bool _isConnected = false;
  bool get isConnected => _isConnected;
  set isConnected(bool value) {
    _isConnected = value;
    notifyListeners();
  }

  void connectToRoom(int roomId) {
    _roomId = roomId.toString();
    final result = NativeBridge.instance.connectRoom(roomId);
    if (result == 0) {
      final resolved = NativeBridge.instance.getRoomId();
      if (resolved > 0) _roomId = resolved.toString();
      _isConnected = true;
    } else {
      _isConnected = false;
      showToast(NativeBridge.instance.getLastError() ?? '连接失败', ToastType.error);
    }
    notifyListeners();
  }

  void disconnectRoom() {
    NativeBridge.instance.disconnectRoom();
    _isConnected = false;
    notifyListeners();
  }

  // Bilibili
  bool _cookieStatus = false;
  bool get cookieStatus => _cookieStatus;
  set cookieStatus(bool value) {
    _cookieStatus = value;
    notifyListeners();
  }

  UserInfo? _userInfo;
  UserInfo? get userInfo => _userInfo;
  set userInfo(UserInfo? value) {
    _userInfo = value;
    notifyListeners();
  }

  // Room
  String _roomId = '';
  String get roomId => _roomId;
  set roomId(String value) {
    _roomId = value;
    NativeBridge.instance.setRoomId(int.tryParse(value) ?? 0);
    notifyListeners();
  }

  // Send mode
  SendMode _sendMode = SendMode.manual;
  SendMode get sendMode => _sendMode;
  set sendMode(SendMode value) {
    _sendMode = value;
    notifyListeners();
  }

  // Audio — separate ValueNotifier to avoid full tree rebuilds on every poll
  final ValueNotifier<double> audioLevelNotifier = ValueNotifier(0.0);
  double _audioLevel = 0.0;
  double get audioLevel => _audioLevel;

  String _liveText = '';
  String get liveText => _liveText;
  set liveText(String value) {
    _liveText = value;
    notifyListeners();
  }

  // VAD
  double _noiseGate = 0.01;
  double get noiseGate => _noiseGate;
  set noiseGate(double value) {
    _noiseGate = value;
    _noiseGateDisplay = (value / 0.001).round();
    NativeBridge.instance.setNoiseGate(value);
    notifyListeners();
  }

  int _noiseGateDisplay = 10;
  int get noiseGateDisplay => _noiseGateDisplay;

  String get noiseGateHint {
    final v = _noiseGateDisplay;
    if (v <= 3) return '极灵敏';
    if (v <= 8) return '灵敏';
    if (v <= 15) return '标准';
    if (v <= 30) return '迟钝';
    return '极迟钝';
  }

  void setNoiseGateFromSlider(int val) {
    _noiseGateDisplay = val;
    _noiseGate = 0.001 * val;
    NativeBridge.instance.setNoiseGate(_noiseGate);
    saveSettings();
    notifyListeners();
  }

  // Window
  WindowMode _windowMode = WindowMode.normal;
  WindowMode get windowMode => _windowMode;

  bool _alwaysOnTop = false;
  bool get alwaysOnTop => _alwaysOnTop;

  Future<void> toggleAlwaysOnTop() async {
    _alwaysOnTop = !_alwaysOnTop;
    await windowManager.setAlwaysOnTop(_alwaysOnTop);
    notifyListeners();
  }

  Future<void> setWindowMode(WindowMode value) async {
    _windowMode = value;
    _alwaysOnTop = value == WindowMode.mini;
    if (value == WindowMode.mini) {
      await windowManager.setMinimumSize(const Size(280, 320));
      await windowManager.setMaximumSize(const Size(400, 600));
      await windowManager.setSize(const Size(280, 380));
    } else {
      await windowManager.setMinimumSize(
        const Size(AppInsets.normalW, AppInsets.normalH),
      );
      await windowManager.setMaximumSize(const Size(800, 800));
      await windowManager.setSize(
        const Size(AppInsets.normalW, AppInsets.normalH),
      );
    }
    await windowManager.setAlwaysOnTop(_alwaysOnTop);
    notifyListeners();
  }

  double _miniOpacity = 0.55;
  double get miniOpacity => _miniOpacity;
  set miniOpacity(double value) {
    _miniOpacity = value.clamp(0.15, 1.0);
    notifyListeners();
  }

  bool _invertMiniText = false;
  bool get invertMiniText => _invertMiniText;
  set invertMiniText(bool value) {
    _invertMiniText = value;
    notifyListeners();
  }
  void toggleInvertMiniText() {
    _invertMiniText = !_invertMiniText;
    notifyListeners();
  }

  // Settings visibility
  bool _showSettings = false;
  bool get showSettings => _showSettings;
  set showSettings(bool value) {
    if (_showSettings == value) return;
    _showSettings = value;
    if (value) {
      _asrSettingsDirty = false;
    } else if (_asrSettingsDirty) {
      restartAsr();
    }
    notifyListeners();
  }

  bool _showQrLogin = false;
  bool get showQrLogin => _showQrLogin;
  set showQrLogin(bool value) {
    _showQrLogin = value;
    notifyListeners();
  }

  // Settings values
  bool _trayAvailable = true;
  bool get trayAvailable => _trayAvailable;
  set trayAvailable(bool value) {
    _trayAvailable = value;
    notifyListeners();
  }

  CloseBehavior _closeBehavior = CloseBehavior.hide;
  CloseBehavior get closeBehavior => _closeBehavior;
  set closeBehavior(CloseBehavior value) {
    _closeBehavior = value;
    notifyListeners();
    saveSettings();
  }

  bool _asrSettingsDirty = false;
  bool get asrSettingsDirty => _asrSettingsDirty;

  CensorMode _censorMode = CensorMode.pinyin;
  CensorMode get censorMode => _censorMode;
  set censorMode(CensorMode value) {
    _censorMode = value;
    _asrSettingsDirty = true;
    NativeBridge.instance.setCensorMode(value.index);
    notifyListeners();
    saveSettings();
  }

  String _asrLang = 'zh';
  String get asrLang => _asrLang;
  set asrLang(String value) {
    _asrLang = value;
    _asrSettingsDirty = true;
    notifyListeners();
    saveSettings();
  }

  bool _noiseSuppress = true;
  bool get noiseSuppress => _noiseSuppress;
  set noiseSuppress(bool value) {
    _noiseSuppress = value;
    _asrSettingsDirty = true;
    NativeBridge.instance.setNoiseSuppress(value);
    notifyListeners();
    saveSettings();
  }

  bool _asrRestarting = false;
  bool get asrRestarting => _asrRestarting;
  set asrRestarting(bool value) {
    _asrRestarting = value;
    notifyListeners();
  }

  String _subtitleFilePath = '';
  String get subtitleFilePath => _subtitleFilePath;
  set subtitleFilePath(String value) {
    _subtitleFilePath = value;
    NativeBridge.instance.setSubtitleFilePath(value);
    notifyListeners();
    saveSettings();
  }

  // QR code
  String _qrCodeUrl = '';
  String get qrCodeUrl => _qrCodeUrl;
  set qrCodeUrl(String value) {
    _qrCodeUrl = value;
    notifyListeners();
  }

  String _qrCodeKey = '';
  String get qrCodeKey => _qrCodeKey;
  set qrCodeKey(String value) {
    _qrCodeKey = value;
    notifyListeners();
  }

  String _qrCodeStatus = '';
  String get qrCodeStatus => _qrCodeStatus;
  set qrCodeStatus(String value) {
    _qrCodeStatus = value;
    notifyListeners();
  }

  String _qrCodeMessage = '';
  String get qrCodeMessage => _qrCodeMessage;
  set qrCodeMessage(String value) {
    _qrCodeMessage = value;
    notifyListeners();
  }

  int _qrCodeConfirmCount = 0;
  int get qrCodeConfirmCount => _qrCodeConfirmCount;
  set qrCodeConfirmCount(int value) {
    _qrCodeConfirmCount = value;
    notifyListeners();
  }

  // Sentence list
  final List<SentenceItem> _sentenceList = [];
  List<SentenceItem> get sentenceList => _sentenceList;

  int _sentenceId = 0;
  int _listGeneration = 0;

  int get pendingCount => _sentenceList.where((s) => s.isPending).length;

  void addSentence(String text) {
    // 去重收归 Rust 一层（此前 Rust 3s + Dart 2s 两层，正常复述会被吞）
    final item = SentenceItem(id: ++_sentenceId, text: text);
    _sentenceList.insert(0, item);
    if (_sentenceList.length > 500) {
      _sentenceList.removeLast();
    }

    if (_sendMode == SendMode.auto && _isConnected && _cookieStatus) {
      final gen = _listGeneration;
      Future.delayed(const Duration(milliseconds: 500), () {
        if (_listGeneration != gen) return;
        sendItem(item.id);
      });
    }
    notifyListeners();
  }

  void sendItem(int id) {
    if (!_isConnected) return;
    final idx = _sentenceList.indexWhere((s) => s.id == id);
    if (idx == -1) return;
    _sentenceList[idx].status = SentenceStatus.sending;
    notifyListeners();

    final text = _sentenceList[idx].text;
    final bridge = NativeBridge.instance;
    final filtered = bridge.censorText(text) ?? text;
    _dispatchSend(id, filtered, bridge);
  }

  // ---- 异步发送 ----
  // native 侧有独立的网络线程，并对发言做统一节流（避免触发弹幕频率限制）。
  // Dart 只负责投递 + 回收结果，不再在 UI 线程上等 HTTP 往返。

  /// jobId → 句列表里的条目 id
  final Map<int, int> _sendJobs = {};
  Timer? _sendPollTimer;

  void _dispatchSend(int sentenceId, String text, NativeBridge bridge) {
    final jobId = bridge.enqueueMessage(text);
    if (jobId <= 0) {
      // 立即失败（未登录 / 未连接 / 内容为空）：不会有任务产生
      final err = bridge.getLastError() ?? '';
      if (err.isNotEmpty) showToast(err, ToastType.error);
      final i = _sentenceList.indexWhere((s) => s.id == sentenceId);
      if (i != -1) {
        _sentenceList[i].status = SentenceStatus.failed;
        notifyListeners();
      }
      return;
    }
    _sendJobs[jobId] = sentenceId;
    _ensureSendPolling();
  }

  void _ensureSendPolling() {
    if (_sendPollTimer != null) return;
    _sendPollTimer = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => _drainSendResults(),
    );
  }

  void _drainSendResults() {
    final bridge = NativeBridge.instance;
    final items = bridge.pollSendResults();
    var changed = false;

    for (final item in items) {
      if (item is! Map) continue;
      final jobId = (item['id'] as num?)?.toInt() ?? 0;
      final sentenceId = _sendJobs.remove(jobId);
      if (sentenceId == null) continue;

      final ok = item['ok'] == true;
      final i = _sentenceList.indexWhere((s) => s.id == sentenceId);
      if (i != -1) {
        _sentenceList[i].status = ok
            ? SentenceStatus.success
            : SentenceStatus.failed;
        changed = true;
      }
      if (!ok) {
        final err = (item['error'] as String?) ?? '';
        if (err.isNotEmpty) showToast(err, ToastType.error);
      }
    }

    if (changed) notifyListeners();

    // 队列空了就停掉轮询；下次投递再拉起，避免常驻定时器空转
    if (_sendJobs.isEmpty && _sendPollTimer != null) {
      _sendPollTimer!.cancel();
      _sendPollTimer = null;
    }
  }

  void deleteItem(int id) {
    _sentenceList.removeWhere((s) => s.id == id);
    if (_editingId == id) cancelEdit();
    notifyListeners();
  }

  void clearList() {
    _sentenceList.clear();
    _sentenceId = 0;
    _listGeneration++;
    cancelEdit();
    notifyListeners();
  }

  // Editing
  int? _editingId;
  int? get editingId => _editingId;
  String _editText = '';
  String get editText => _editText;
  bool _editCanceled = false;

  void startEdit(int id, String text) {
    _editingId = id;
    _editText = text;
    _editCanceled = false;
    notifyListeners();
  }

  void setEditText(String value) {
    _editText = value;
    notifyListeners();
  }

  void saveEdit(int id) {
    if (_editCanceled) return;
    final item = _sentenceList.where((s) => s.id == id).firstOrNull;
    if (item != null && _editText.trim().isNotEmpty) {
      item.text = _editText.trim();
    }
    _editingId = null;
    _editText = '';
    notifyListeners();
  }

  void blurEdit(int id) {
    Future.delayed(const Duration(milliseconds: 10), () {
      if (!_editCanceled) saveEdit(id);
    });
  }

  void cancelEdit() {
    _editCanceled = true;
    _editingId = null;
    _editText = '';
    notifyListeners();
  }

  // Manual input
  String _manualInput = '';
  String get manualInput => _manualInput;
  set manualInput(String value) {
    _manualInput = value;
    notifyListeners();
  }

  void sendManualMessage() {
    final msg = _manualInput.trim();
    if (msg.isEmpty || !_isConnected || !_cookieStatus) return;

    final id = ++_sentenceId;
    final item = SentenceItem(
      id: id,
      text: msg,
      status: SentenceStatus.sending,
    );
    _sentenceList.insert(0, item);
    _manualInput = '';
    notifyListeners();

    final bridge = NativeBridge.instance;
    final filtered = bridge.censorText(msg) ?? msg;
    _dispatchSend(id, filtered, bridge);
  }

  // Toast
  String _toastMessage = '';
  String get toastMessage => _toastMessage;
  ToastType _toastType = ToastType.info;
  ToastType get toastType => _toastType;
  Timer? _toastTimer;

  void showToast(String msg, [ToastType type = ToastType.info]) {
    _toastTimer?.cancel();
    _toastMessage = msg;
    _toastType = type;
    notifyListeners();
    _toastTimer = Timer(const Duration(seconds: 3), () {
      _toastMessage = '';
      notifyListeners();
    });
  }

  // Native bridge integration
  void restartAsr() {
    if (_asrRestarting) return;
    final bridge = NativeBridge.instance;
    if (!bridge.isInitialized) {
      final why = bridge.loadError;
      showToast(
        why == null ? '原生库未加载，ASR 不可用' : '原生库未加载：$why',
        ToastType.error,
      );
      return;
    }
    _asrRestarting = true;
    notifyListeners();

    // reload 在 native 的常驻解码线程上完成，这里只是投递 + 轮询结果，
    // 不再假装"立即成功"（旧实现无条件弹"已重启"，模型缺失时是假的）。
    bridge.reloadAsr(_modelDir());
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    Timer.periodic(const Duration(milliseconds: 200), (t) {
      final ready = bridge.isAsrReady();
      final failed = bridge.isAsrFailed();
      final timedOut = DateTime.now().isAfter(deadline);
      if (!ready && !failed && !timedOut) return;

      t.cancel();
      _asrRestarting = false;
      if (ready) {
        showToast('ASR 已重启', ToastType.info);
      } else if (failed) {
        showToast('ASR 加载失败：请检查模型文件是否完整', ToastType.error);
      } else {
        showToast('ASR 重启超时', ToastType.error);
      }
      notifyListeners();
    });
  }

  String _modelDir() {
    if (Directory('asr/model').existsSync() &&
        File('asr/model/model.int8.onnx').existsSync()) {
      return 'asr/model';
    }
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = <String>[];
    candidates.addAll(['asr/model', '../asr/model', '../../asr/model']);
    for (final dir in candidates) {
      final p = '${exeDir.path}/$dir';
      if (Directory(p).existsSync() &&
          File('$p/model.int8.onnx').existsSync()) {
        return p;
      }
    }
    return '';
  }

  void generateQrCode() {
    final bridge = NativeBridge.instance;
    final jsonStr = bridge.generateQrcode();
    var message = '请使用B站App扫码';
    if (jsonStr != null) {
      try {
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        _qrCodeUrl = (data['url'] as String?) ?? '';
        _qrCodeKey = (data['key'] as String?) ?? '';
        message = (data['error'] as String?) ?? message;
      } catch (_) {
        _qrCodeUrl = '';
        _qrCodeKey = '';
      }
    }
    _qrCodeStatus = _qrCodeUrl.isEmpty ? 'error' : 'waiting';
    _qrCodeMessage = _qrCodeUrl.isEmpty ? message : '请使用B站App扫码';
    _qrCodeConfirmCount = 0;
    notifyListeners();
  }

  void pollQrCodeStatus() {
    if (_qrCodeStatus != 'waiting' && _qrCodeStatus != 'confirming') return;

    final bridge = NativeBridge.instance;
    final result = bridge.checkQrcodeStatus(_qrCodeKey);
    if (result != null) {
      try {
        final data = jsonDecode(result) as Map<String, dynamic>;
        final status = data['status'] as String? ?? '';
        if (status == 'success') {
          final cookie = data['cookie'] as String?;
          if (cookie != null && cookie.isNotEmpty) {
            bridge.setCookie(cookie);
          }
          _onQrSuccess(bridge);
          return;
        }
        _qrCodeStatus = status.isEmpty ? 'waiting' : status;
        _qrCodeMessage =
            (data['message'] as String?) ??
            (_qrCodeStatus == 'confirming' ? '已扫码，请在手机上确认登录' : '请使用B站App扫码');
        if (_qrCodeStatus == 'confirming') {
          _qrCodeConfirmCount++;
        } else if (_qrCodeStatus == 'waiting') {
          _qrCodeConfirmCount = 0;
        }
        notifyListeners();
      } catch (_) {}
    }

    // Timeout is handled by QrLoginModal's 120s timer
  }

  void _onQrSuccess(NativeBridge bridge) {
    _qrCodeStatus = 'success';
    _qrCodeMessage = '登录成功';
    _cookieStatus = true;

    final info = bridge.getAccountInfo();
    if (info != null) {
      try {
        final data = jsonDecode(info) as Map<String, dynamic>;
        _userInfo = UserInfo(
          mid: (data['mid'] as num?)?.toInt() ?? 0,
          uname: (data['uname'] as String?) ?? 'B站用户',
          isLogin: true,
        );
      } catch (_) {
        _userInfo = UserInfo(mid: 0, uname: 'B站用户', isLogin: true);
      }
    }
    showToast('B站登录成功');
  }

  void resetQrCode() {
    _qrCodeUrl = '';
    _qrCodeKey = '';
    _qrCodeStatus = 'expired';
    _qrCodeMessage = '二维码已过期，请刷新';
    _qrCodeConfirmCount = 0;
    notifyListeners();
  }

  void saveSettings() {
    final bridge = NativeBridge.instance;
    bridge.setRoomId(int.tryParse(_roomId) ?? 0);
    bridge.setAsrLang(_asrLang);
    bridge.setCloseBehavior(_closeBehavior.name);
    bridge.setSubtitleFilePath(_subtitleFilePath);
    bridge.saveConfig();
  }

  void loadSettings() {
    final bridge = NativeBridge.instance;
    if (bridge.loadConfig() == 0) {
      final mode = bridge.getCensorMode();
      _censorMode = CensorMode.values.firstWhere(
        (e) => e.index == mode,
        orElse: () => CensorMode.off,
      );
      _noiseSuppress = bridge.getNoiseSuppress();
      final gate = bridge.getNoiseGate();
      _noiseGate = gate.clamp(0.001, 0.05);
      _noiseGateDisplay = (_noiseGate / 0.001).round().clamp(1, 50);

      final rid = bridge.getRoomId();
      if (rid > 0) _roomId = rid.toString();

      final lang = bridge.getAsrLang();
      if (lang != null && lang.isNotEmpty) _asrLang = lang;

      final cb = bridge.getCloseBehavior();
      if (cb != null && cb.isNotEmpty) {
        _closeBehavior = cb == 'exit' ? CloseBehavior.exit : CloseBehavior.hide;
      }

      final configDir = bridge.getConfigDirPath();
      if (configDir != null) {
        _subtitleFilePath = '$configDir/capture.txt';
        bridge.setSubtitleFilePath(_subtitleFilePath);
      }

      _cookieStatus = bridge.getCookieStatus();
      _isConnected = bridge.isConnected();
      final info = bridge.getAccountInfo();
      if (info != null && info.isNotEmpty) {
        try {
          final data = jsonDecode(info) as Map<String, dynamic>;
          if ((data['is_login'] as bool?) ??
              (data['isLogin'] as bool?) ??
              false) {
            _userInfo = UserInfo(
              mid: (data['mid'] as num?)?.toInt() ?? 0,
              uname: (data['uname'] as String?) ?? 'B站用户',
              isLogin: true,
            );
          }
        } catch (_) {}
      }
    }
  }
}
