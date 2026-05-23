import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// ---- C API type definitions ----

typedef MutsuRelayInitC = Int32 Function(Pointer<Utf8> modelDir);
typedef MutsuRelayInitDart = int Function(Pointer<Utf8> modelDir);

typedef MutsuRelayInitAsrC = Int32 Function(Pointer<Utf8> modelDir);
typedef MutsuRelayInitAsrDart = int Function(Pointer<Utf8> modelDir);

typedef MutsuRelayShutdownC = Void Function();
typedef MutsuRelayShutdownDart = void Function();

typedef MutsuRelayStartRecordingC = Int32 Function();
typedef MutsuRelayStartRecordingDart = int Function();

typedef MutsuRelayStopRecordingC = Void Function();
typedef MutsuRelayStopRecordingDart = void Function();

typedef MutsuRelayIsRecordingC = Int32 Function();
typedef MutsuRelayIsRecordingDart = int Function();

typedef MutsuRelaySetNoiseGateC = Void Function(Double gate);
typedef MutsuRelaySetNoiseGateDart = void Function(double gate);

typedef MutsuRelayGetNoiseGateC = Double Function();
typedef MutsuRelayGetNoiseGateDart = double Function();

typedef MutsuRelaySetNoiseSuppressC = Void Function(Int32 enabled);
typedef MutsuRelaySetNoiseSuppressDart = void Function(int enabled);

typedef MutsuRelayGetNoiseSuppressC = Int32 Function();
typedef MutsuRelayGetNoiseSuppressDart = int Function();

typedef MutsuRelaySetCensorModeC = Void Function(Int32 mode);
typedef MutsuRelaySetCensorModeDart = void Function(int mode);

typedef MutsuRelayGetCensorModeC = Int32 Function();
typedef MutsuRelayGetCensorModeDart = int Function();

typedef MutsuRelayCensorTextC = Pointer<Utf8> Function(Pointer<Utf8> input);
typedef MutsuRelayCensorTextDart = Pointer<Utf8> Function(Pointer<Utf8> input);

typedef MutsuRelayFreeStringC = Void Function(Pointer<Utf8> s);
typedef MutsuRelayFreeStringDart = void Function(Pointer<Utf8> s);

typedef MutsuRelayGenerateQrcodeC = Pointer<Utf8> Function();
typedef MutsuRelayGenerateQrcodeDart = Pointer<Utf8> Function();

typedef MutsuRelayCheckQrcodeStatusC =
    Pointer<Utf8> Function(Pointer<Utf8> key);
typedef MutsuRelayCheckQrcodeStatusDart =
    Pointer<Utf8> Function(Pointer<Utf8> key);

typedef MutsuRelaySetCookieC = Int32 Function(Pointer<Utf8> cookie);
typedef MutsuRelaySetCookieDart = int Function(Pointer<Utf8> cookie);

typedef MutsuRelayGetAccountInfoC = Pointer<Utf8> Function();
typedef MutsuRelayGetAccountInfoDart = Pointer<Utf8> Function();

typedef MutsuRelayGetCookieStatusC = Int32 Function();
typedef MutsuRelayGetCookieStatusDart = int Function();

typedef MutsuRelayLogoutC = Void Function();
typedef MutsuRelayLogoutDart = void Function();

typedef MutsuRelayConnectRoomC = Int32 Function(Int64 roomId);
typedef MutsuRelayConnectRoomDart = int Function(int roomId);

typedef MutsuRelayDisconnectRoomC = Void Function();
typedef MutsuRelayDisconnectRoomDart = void Function();

typedef MutsuRelayIsConnectedC = Int32 Function();
typedef MutsuRelayIsConnectedDart = int Function();

typedef MutsuRelaySetRoomIdC = Void Function(Int64 roomId);
typedef MutsuRelaySetRoomIdDart = void Function(int roomId);

typedef MutsuRelayGetMyRoomIdC = Int64 Function();
typedef MutsuRelayGetMyRoomIdDart = int Function();

typedef MutsuRelaySetAsrLangC = Void Function(Pointer<Utf8> lang);
typedef MutsuRelaySetAsrLangDart = void Function(Pointer<Utf8> lang);

typedef MutsuRelaySetCloseBehaviorC = Void Function(Pointer<Utf8> behavior);
typedef MutsuRelaySetCloseBehaviorDart = void Function(Pointer<Utf8> behavior);

typedef MutsuRelaySendMessageC = Int32 Function(Pointer<Utf8> text);
typedef MutsuRelaySendMessageDart = int Function(Pointer<Utf8> text);

typedef MutsuRelayGetConfigDirPathC = Pointer<Utf8> Function();
typedef MutsuRelayGetConfigDirPathDart = Pointer<Utf8> Function();

typedef MutsuRelayGetLastErrorC = Pointer<Utf8> Function();
typedef MutsuRelayGetLastErrorDart = Pointer<Utf8> Function();

typedef MutsuRelayGetRoomIdC = Int64 Function();
typedef MutsuRelayGetRoomIdDart = int Function();

typedef MutsuRelayGetAsrLangC = Pointer<Utf8> Function();
typedef MutsuRelayGetAsrLangDart = Pointer<Utf8> Function();

typedef MutsuRelayGetCloseBehaviorC = Pointer<Utf8> Function();
typedef MutsuRelayGetCloseBehaviorDart = Pointer<Utf8> Function();

typedef MutsuRelaySaveConfigC = Int32 Function();
typedef MutsuRelaySaveConfigDart = int Function();

typedef MutsuRelayLoadConfigC = Int32 Function();
typedef MutsuRelayLoadConfigDart = int Function();

typedef MutsuRelayGetAudioLevelC = Double Function();
typedef MutsuRelayGetAudioLevelDart = double Function();

typedef MutsuRelayGetRecognitionResultC = Pointer<Utf8> Function();
typedef MutsuRelayGetRecognitionResultDart = Pointer<Utf8> Function();

typedef MutsuRelayDownloadAsrModelC = Int32 Function(Pointer<Utf8> url, Pointer<Utf8> destDir);
typedef MutsuRelayDownloadAsrModelDart = int Function(Pointer<Utf8> url, Pointer<Utf8> destDir);

// ---- Native Bridge ----

class NativeBridge {
  static NativeBridge? _instance;
  late final DynamicLibrary _lib;
  bool _initialized = false;

  NativeBridge._();

  static NativeBridge get instance {
    _instance ??= NativeBridge._();
    return _instance!;
  }

  bool get isInitialized => _initialized;

  /// Load the native library. Must be called before any other operation.
  void load({String? libraryPath}) {
    if (_initialized) return;

    final path = libraryPath ?? _defaultLibraryPath();
    if (path == null) {
      log('Native library path not found, running in mock mode');
      return;
    }

    try {
      _lib = DynamicLibrary.open(path);
      _bindFunctions();
      _initialized = true;
      log('Native library loaded: $path');
    } catch (e) {
      log('Failed to load native library: $e, running in mock mode');
    }
  }

  String? _defaultLibraryPath() {
    final candidates = <String>[];
    if (Platform.isWindows) {
      candidates.addAll([
        'mutsurelay_native.dll',
        'windows\\mutsurelay_native\\mutsurelay_native.dll',
        'native\\target\\debug\\mutsurelay_native.dll',
        'native\\target\\release\\mutsurelay_native.dll',
        'build\\windows\\runner\\Release\\mutsurelay_native.dll',
        'build\\windows\\x64\\runner\\Debug\\mutsurelay_native.dll',
      ]);
    } else if (Platform.isLinux) {
      candidates.addAll([
        'libmutsurelay_native.so',
        'linux/libmutsurelay_native.so',
      ]);
    } else if (Platform.isMacOS) {
      candidates.addAll([
        'libmutsurelay_native.dylib',
        'macos/libmutsurelay_native.dylib',
      ]);
    }
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  // ---- Bound function references ----

  late MutsuRelayInitDart _init;
  late MutsuRelayInitAsrDart _initAsr;
  late MutsuRelayShutdownDart _shutdown;
  late MutsuRelayStartRecordingDart _startRecording;
  late MutsuRelayStopRecordingDart _stopRecording;
  late MutsuRelayIsRecordingDart _isRecording;
  late MutsuRelaySetNoiseGateDart _setNoiseGate;
  late MutsuRelayGetNoiseGateDart _getNoiseGate;
  late MutsuRelaySetNoiseSuppressDart _setNoiseSuppress;
  late MutsuRelayGetNoiseSuppressDart _getNoiseSuppress;
  late MutsuRelaySetCensorModeDart _setCensorMode;
  late MutsuRelayGetCensorModeDart _getCensorMode;
  late MutsuRelayGetRoomIdDart _getRoomId;
  late MutsuRelayCensorTextDart _censorText;
  late MutsuRelayFreeStringDart _freeString;
  late MutsuRelayGenerateQrcodeDart _generateQrcode;
  late MutsuRelayCheckQrcodeStatusDart _checkQrcodeStatus;
  late MutsuRelaySetCookieDart _setCookie;
  late MutsuRelayGetAccountInfoDart _getAccountInfo;
  late MutsuRelayGetCookieStatusDart _getCookieStatus;
  late MutsuRelayLogoutDart _logout;
  late MutsuRelayConnectRoomDart _connectRoom;
  late MutsuRelayDisconnectRoomDart _disconnectRoom;
  late MutsuRelayIsConnectedDart _isConnected;
  late MutsuRelaySetRoomIdDart _setRoomId;
  late MutsuRelayGetMyRoomIdDart _getMyRoomId;
  late MutsuRelaySetAsrLangDart _setAsrLang;
  late MutsuRelaySetCloseBehaviorDart _setCloseBehavior;
  late MutsuRelaySendMessageDart _sendMessage;
  late MutsuRelayGetConfigDirPathDart _getConfigDirPath;
  late MutsuRelayGetLastErrorDart _getLastError;
  late MutsuRelayGetAsrLangDart _getAsrLang;
  late MutsuRelayGetCloseBehaviorDart _getCloseBehavior;
  late MutsuRelaySaveConfigDart _saveConfig;
  late MutsuRelayLoadConfigDart _loadConfig;
  late MutsuRelayGetAudioLevelDart _getAudioLevel;
  late MutsuRelayGetRecognitionResultDart _getRecognitionResult;
  late MutsuRelayDownloadAsrModelDart _downloadAsrModel;

  void _bindFunctions() {
    _init = _lib.lookupFunction<MutsuRelayInitC, MutsuRelayInitDart>(
      'mutsurelay_init',
    );
    _initAsr = _lib.lookupFunction<MutsuRelayInitAsrC, MutsuRelayInitAsrDart>(
      'mutsurelay_init_asr',
    );
    _shutdown = _lib
        .lookupFunction<MutsuRelayShutdownC, MutsuRelayShutdownDart>(
          'mutsurelay_shutdown',
        );
    _startRecording = _lib
        .lookupFunction<
          MutsuRelayStartRecordingC,
          MutsuRelayStartRecordingDart
        >('mutsurelay_start_recording');
    _stopRecording = _lib
        .lookupFunction<MutsuRelayStopRecordingC, MutsuRelayStopRecordingDart>(
          'mutsurelay_stop_recording',
        );
    _isRecording = _lib
        .lookupFunction<MutsuRelayIsRecordingC, MutsuRelayIsRecordingDart>(
          'mutsurelay_is_recording',
        );
    _setNoiseGate = _lib
        .lookupFunction<MutsuRelaySetNoiseGateC, MutsuRelaySetNoiseGateDart>(
          'mutsurelay_set_noise_gate',
        );
    _getNoiseGate = _lib
        .lookupFunction<MutsuRelayGetNoiseGateC, MutsuRelayGetNoiseGateDart>(
          'mutsurelay_get_noise_gate',
        );
    _setNoiseSuppress = _lib
        .lookupFunction<
          MutsuRelaySetNoiseSuppressC,
          MutsuRelaySetNoiseSuppressDart
        >('mutsurelay_set_noise_suppress');
    _getNoiseSuppress = _lib
        .lookupFunction<
          MutsuRelayGetNoiseSuppressC,
          MutsuRelayGetNoiseSuppressDart
        >('mutsurelay_get_noise_suppress');
    _setCensorMode = _lib
        .lookupFunction<MutsuRelaySetCensorModeC, MutsuRelaySetCensorModeDart>(
          'mutsurelay_set_censor_mode',
        );
    _getCensorMode = _lib
        .lookupFunction<MutsuRelayGetCensorModeC, MutsuRelayGetCensorModeDart>(
          'mutsurelay_get_censor_mode',
        );
    _getRoomId = _lib
        .lookupFunction<MutsuRelayGetRoomIdC, MutsuRelayGetRoomIdDart>(
          'mutsurelay_get_room_id',
        );
    _censorText = _lib
        .lookupFunction<MutsuRelayCensorTextC, MutsuRelayCensorTextDart>(
          'mutsurelay_censor_text',
        );
    _freeString = _lib
        .lookupFunction<MutsuRelayFreeStringC, MutsuRelayFreeStringDart>(
          'mutsurelay_free_string',
        );
    _generateQrcode = _lib
        .lookupFunction<
          MutsuRelayGenerateQrcodeC,
          MutsuRelayGenerateQrcodeDart
        >('mutsurelay_generate_qrcode');
    _checkQrcodeStatus = _lib
        .lookupFunction<
          MutsuRelayCheckQrcodeStatusC,
          MutsuRelayCheckQrcodeStatusDart
        >('mutsurelay_check_qrcode_status');
    _setCookie = _lib
        .lookupFunction<MutsuRelaySetCookieC, MutsuRelaySetCookieDart>(
          'mutsurelay_set_cookie',
        );
    _getAccountInfo = _lib
        .lookupFunction<
          MutsuRelayGetAccountInfoC,
          MutsuRelayGetAccountInfoDart
        >('mutsurelay_get_account_info');
    _getCookieStatus = _lib
        .lookupFunction<
          MutsuRelayGetCookieStatusC,
          MutsuRelayGetCookieStatusDart
        >('mutsurelay_get_cookie_status');
    _logout = _lib.lookupFunction<MutsuRelayLogoutC, MutsuRelayLogoutDart>(
      'mutsurelay_logout',
    );
    _connectRoom = _lib
        .lookupFunction<MutsuRelayConnectRoomC, MutsuRelayConnectRoomDart>(
          'mutsurelay_connect_room',
        );
    _disconnectRoom = _lib
        .lookupFunction<
          MutsuRelayDisconnectRoomC,
          MutsuRelayDisconnectRoomDart
        >('mutsurelay_disconnect_room');
    _isConnected = _lib
        .lookupFunction<MutsuRelayIsConnectedC, MutsuRelayIsConnectedDart>(
          'mutsurelay_is_connected',
        );
    _setRoomId = _lib
        .lookupFunction<MutsuRelaySetRoomIdC, MutsuRelaySetRoomIdDart>(
          'mutsurelay_set_room_id',
        );
    _getMyRoomId = _lib
        .lookupFunction<MutsuRelayGetMyRoomIdC, MutsuRelayGetMyRoomIdDart>(
          'mutsurelay_get_my_room_id',
        );
    _setAsrLang = _lib
        .lookupFunction<MutsuRelaySetAsrLangC, MutsuRelaySetAsrLangDart>(
          'mutsurelay_set_asr_lang',
        );
    _setCloseBehavior = _lib
        .lookupFunction<
          MutsuRelaySetCloseBehaviorC,
          MutsuRelaySetCloseBehaviorDart
        >('mutsurelay_set_close_behavior');
    _sendMessage = _lib
        .lookupFunction<MutsuRelaySendMessageC, MutsuRelaySendMessageDart>(
          'mutsurelay_send_message',
        );
    _getConfigDirPath = _lib
        .lookupFunction<
          MutsuRelayGetConfigDirPathC,
          MutsuRelayGetConfigDirPathDart
        >('mutsurelay_get_config_dir_path');
    _getLastError = _lib
        .lookupFunction<MutsuRelayGetLastErrorC, MutsuRelayGetLastErrorDart>(
          'mutsurelay_get_last_error',
        );
    _getAsrLang = _lib
        .lookupFunction<MutsuRelayGetAsrLangC, MutsuRelayGetAsrLangDart>(
          'mutsurelay_get_asr_lang',
        );
    _getCloseBehavior = _lib
        .lookupFunction<
          MutsuRelayGetCloseBehaviorC,
          MutsuRelayGetCloseBehaviorDart
        >('mutsurelay_get_close_behavior');
    _saveConfig = _lib
        .lookupFunction<MutsuRelaySaveConfigC, MutsuRelaySaveConfigDart>(
          'mutsurelay_save_config',
        );
    _loadConfig = _lib
        .lookupFunction<MutsuRelayLoadConfigC, MutsuRelayLoadConfigDart>(
          'mutsurelay_load_config',
        );
    _getAudioLevel = _lib
        .lookupFunction<MutsuRelayGetAudioLevelC, MutsuRelayGetAudioLevelDart>(
          'mutsurelay_get_audio_level',
        );
    _getRecognitionResult = _lib
        .lookupFunction<
          MutsuRelayGetRecognitionResultC,
          MutsuRelayGetRecognitionResultDart
        >('mutsurelay_get_recognition_result');
    _downloadAsrModel = _lib
        .lookupFunction<
          MutsuRelayDownloadAsrModelC,
          MutsuRelayDownloadAsrModelDart
        >('mutsurelay_download_asr_model');
  }

  // ---- Public API (with null safety when not loaded) ----

  int init(String modelDir) {
    if (!_initialized) return -1;
    final ptr = modelDir.toNativeUtf8();
    try {
      return _init(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  int initAsr(String modelDir) {
    if (!_initialized) return -1;
    final ptr = modelDir.toNativeUtf8();
    try {
      return _initAsr(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  void shutdown() {
    if (!_initialized) return;
    _shutdown();
  }

  int startRecording() => _initialized ? _startRecording() : -1;
  void stopRecording() {
    if (_initialized) _stopRecording();
  }

  int isRecording() => _initialized ? _isRecording() : 0;

  void setNoiseGate(double gate) {
    if (_initialized) _setNoiseGate(gate);
  }

  double getNoiseGate() => _initialized ? _getNoiseGate() : 0.01;

  void setNoiseSuppress(bool enabled) {
    if (_initialized) _setNoiseSuppress(enabled ? 1 : 0);
  }

  bool getNoiseSuppress() => _initialized ? _getNoiseSuppress() != 0 : true;

  void setCensorMode(int mode) {
    if (_initialized) _setCensorMode(mode);
  }

  int getCensorMode() => _initialized ? _getCensorMode() : 0;

  String? censorText(String input) {
    if (!_initialized) return input;
    final ptr = input.toNativeUtf8();
    try {
      final result = _censorText(ptr);
      if (result == nullptr) return input;
      final text = result.toDartString();
      _freeString(result);
      return text;
    } finally {
      calloc.free(ptr);
    }
  }

  String? generateQrcode() {
    if (!_initialized) return null;
    final result = _generateQrcode();
    if (result == nullptr) return null;
    final text = result.toDartString();
    _freeString(result);
    return text;
  }

  String? checkQrcodeStatus(String key) {
    if (!_initialized) return null;
    final ptr = key.toNativeUtf8();
    try {
      final result = _checkQrcodeStatus(ptr);
      if (result == nullptr) return null;
      final text = result.toDartString();
      _freeString(result);
      return text;
    } finally {
      calloc.free(ptr);
    }
  }

  int setCookie(String cookie) {
    if (!_initialized) return -1;
    final ptr = cookie.toNativeUtf8();
    try {
      return _setCookie(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  String? getAccountInfo() {
    if (!_initialized) return null;
    final result = _getAccountInfo();
    if (result == nullptr) return null;
    final text = result.toDartString();
    _freeString(result);
    return text;
  }

  bool getCookieStatus() => _initialized ? _getCookieStatus() != 0 : false;

  void logout() {
    if (_initialized) _logout();
  }

  int connectRoom(int roomId) => _initialized ? _connectRoom(roomId) : -1;

  void disconnectRoom() {
    if (_initialized) _disconnectRoom();
  }

  bool isConnected() => _initialized ? _isConnected() != 0 : false;

  void setRoomId(int roomId) {
    if (_initialized) _setRoomId(roomId);
  }

  int getMyRoomId() => _initialized ? _getMyRoomId() : -1;

  void setAsrLang(String lang) {
    if (!_initialized) return;
    final ptr = lang.toNativeUtf8();
    try {
      _setAsrLang(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  void setCloseBehavior(String behavior) {
    if (!_initialized) return;
    final ptr = behavior.toNativeUtf8();
    try {
      _setCloseBehavior(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  int sendMessage(String text) {
    if (!_initialized) return -1;
    final ptr = text.toNativeUtf8();
    try {
      return _sendMessage(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  String? getConfigDirPath() {
    if (!_initialized) return null;
    final result = _getConfigDirPath();
    if (result == nullptr) return null;
    final text = result.toDartString();
    _freeString(result);
    return text;
  }

  String? getLastError() {
    if (!_initialized) return null;
    final result = _getLastError();
    if (result == nullptr) return null;
    final text = result.toDartString();
    _freeString(result);
    return text;
  }

  String? getAsrLang() {
    if (!_initialized) return null;
    final result = _getAsrLang();
    if (result == nullptr) return null;
    final text = result.toDartString();
    _freeString(result);
    return text;
  }

  String? getCloseBehavior() {
    if (!_initialized) return null;
    final result = _getCloseBehavior();
    if (result == nullptr) return null;
    final text = result.toDartString();
    _freeString(result);
    return text;
  }

  int getRoomId() => _initialized ? _getRoomId() : 0;

  int saveConfig() => _initialized ? _saveConfig() : -1;

  int loadConfig() => _initialized ? _loadConfig() : -1;

  double getAudioLevel() => _initialized ? _getAudioLevel() : 0.0;

  String? getRecognitionResult() {
    if (!_initialized) return null;
    final ptr = _getRecognitionResult();
    if (ptr == nullptr) return null;
    final text = ptr.toDartString();
    _freeString(ptr);
    return text;
  }

  int downloadAsrModel(String url, String destDir) {
    if (!_initialized) return -1;
    final urlPtr = url.toNativeUtf8();
    final dirPtr = destDir.toNativeUtf8();
    try {
      return _downloadAsrModel(urlPtr, dirPtr);
    } finally {
      calloc.free(urlPtr);
      calloc.free(dirPtr);
    }
  }

  static void log(String message) {
    // ignore: avoid_print
    print('[NativeBridge] $message');
  }
}
