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
      _recordingPollTimer?.cancel();
      bridge.stopRecording();
      _liveText = '';
      _audioLevel = 0.0;
      _isRecording = false;
    }
    notifyListeners();
  }

  void _startPolling() {
    _recordingPollTimer?.cancel();
    _recordingPollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final bridge = NativeBridge.instance;
      if (bridge.isRecording() == 0) {
        _isRecording = false;
        _audioLevel = 0.0;
        _liveText = '';
        _recordingPollTimer?.cancel();
        notifyListeners();
        return;
      }
      _audioLevel = bridge.getAudioLevel();
      final result = bridge.getRecognitionResult();
      if (result != null && result.isNotEmpty) {
        try {
          final data = jsonDecode(result) as Map<String, dynamic>;
          final type = data['type'] as String? ?? '';
          final text = data['text'] as String? ?? '';
          if (text.isNotEmpty) {
            if (type == 'final') {
              addSentence(text);
              _liveText = '';
            } else {
              _liveText = text;
            }
          }
        } catch (_) {}
      }
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

  // Audio
  double _audioLevel = 0.0;
  double get audioLevel => _audioLevel;
  set audioLevel(double value) {
    _audioLevel = value;
    notifyListeners();
  }

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

  Future<void> setWindowMode(WindowMode value) async {
    _windowMode = value;
    if (value == WindowMode.mini) {
      await windowManager.setMinimumSize(const Size(280, 320));
      await windowManager.setMaximumSize(const Size(400, 600));
      await windowManager.setSize(const Size(280, 380));
      await windowManager.setAlwaysOnTop(true);
    } else {
      await windowManager.setMinimumSize(
        const Size(AppInsets.normalW, AppInsets.normalH),
      );
      await windowManager.setMaximumSize(const Size(800, 800));
      await windowManager.setSize(
        const Size(AppInsets.normalW, AppInsets.normalH),
      );
      await windowManager.setAlwaysOnTop(false);
    }
    notifyListeners();
  }

  double _miniOpacity = 0.55;
  double get miniOpacity => _miniOpacity;
  set miniOpacity(double value) {
    _miniOpacity = value.clamp(0.15, 1.0);
    notifyListeners();
  }

  // Settings visibility
  bool _showSettings = false;
  bool get showSettings => _showSettings;
  set showSettings(bool value) {
    _showSettings = value;
    notifyListeners();
  }

  bool _showQrLogin = false;
  bool get showQrLogin => _showQrLogin;
  set showQrLogin(bool value) {
    _showQrLogin = value;
    notifyListeners();
  }

  // Settings values
  CloseBehavior _closeBehavior = CloseBehavior.hide;
  CloseBehavior get closeBehavior => _closeBehavior;
  set closeBehavior(CloseBehavior value) {
    _closeBehavior = value;
    notifyListeners();
    saveSettings();
  }

  CensorMode _censorMode = CensorMode.off;
  CensorMode get censorMode => _censorMode;
  set censorMode(CensorMode value) {
    _censorMode = value;
    NativeBridge.instance.setCensorMode(value.index);
    notifyListeners();
    saveSettings();
  }

  String _asrLang = 'auto';
  String get asrLang => _asrLang;
  set asrLang(String value) {
    _asrLang = value;
    notifyListeners();
    saveSettings();
  }

  bool _noiseSuppress = true;
  bool get noiseSuppress => _noiseSuppress;
  set noiseSuppress(bool value) {
    _noiseSuppress = value;
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
  int _lastFinalTime = 0;
  String _lastFinalText = '';

  int get pendingCount => _sentenceList.where((s) => s.isPending).length;

  void addSentence(String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (text == _lastFinalText && now - _lastFinalTime < 2000) {
      return;
    }
    _lastFinalText = text;
    _lastFinalTime = now;
    final item = SentenceItem(id: ++_sentenceId, text: text);
    _sentenceList.insert(0, item);

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
    Future(() {
      final result = bridge.sendMessage(filtered);
      if (result != 0) {
        final err = bridge.getLastError() ?? '';
        if (err.isNotEmpty) showToast(err, ToastType.error);
      }
      Future.delayed(Duration(milliseconds: result == 0 ? 300 : 100), () {
        final i = _sentenceList.indexWhere((s) => s.id == id);
        if (i != -1) {
          _sentenceList[i].status = result == 0
              ? SentenceStatus.success
              : SentenceStatus.failed;
          notifyListeners();
        }
      });
    });
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
    Future(() {
      final result = bridge.sendMessage(filtered);
      if (result != 0) {
        final err = bridge.getLastError() ?? '';
        if (err.isNotEmpty) showToast(err, ToastType.error);
      }
      final i = _sentenceList.indexWhere((s) => s.id == id);
      if (i != -1) {
        _sentenceList[i].status = result == 0
            ? SentenceStatus.success
            : SentenceStatus.failed;
        notifyListeners();
      }
    });
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
    _asrRestarting = true;
    notifyListeners();
    showToast('正在重启 ASR...', ToastType.info);
    final bridge = NativeBridge.instance;
    Future(() {
      bridge.initAsr(_modelDir());
      _asrRestarting = false;
      showToast('ASR 已重启', ToastType.info);
      notifyListeners();
    });
  }

  String _modelDir() {
    if (Directory('asr/model').existsSync() &&
        File('asr/model/model.int8.onnx').existsSync()) {
      return 'asr/model';
    }
    final exeDir = File(Platform.resolvedExecutable).parent;
    for (final dir in ['asr/model', '../asr/model', '../../asr/model']) {
      final p = '${exeDir.path}\\$dir';
      if (Directory(p).existsSync() &&
          File('$p\\model.int8.onnx').existsSync()) {
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
