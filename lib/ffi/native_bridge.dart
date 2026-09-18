import 'dart:convert';
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

typedef MutsuRelayPollRecordingC = Pointer<Utf8> Function();
typedef MutsuRelayPollRecordingDart = Pointer<Utf8> Function();

typedef MutsuRelayDownloadAsrModelC = Int32 Function(Pointer<Utf8> url, Pointer<Utf8> destDir);
typedef MutsuRelayDownloadAsrModelDart = int Function(Pointer<Utf8> url, Pointer<Utf8> destDir);

typedef MutsuRelaySetSubtitleFilePathC = Void Function(Pointer<Utf8> path);
typedef MutsuRelaySetSubtitleFilePathDart = void Function(Pointer<Utf8> path);

typedef MutsuRelayGetSubtitleFilePathC = Pointer<Utf8> Function();
typedef MutsuRelayGetSubtitleFilePathDart = Pointer<Utf8> Function();

// ---- P2/P3: 常驻解码线程 / 分段参数 / 异步发送 / 运行统计 ----

typedef MutsuRelayReloadAsrC = Int32 Function(Pointer<Utf8> modelDir);
typedef MutsuRelayReloadAsrDart = int Function(Pointer<Utf8> modelDir);

typedef MutsuRelaySetSegmentMaxMsC = Void Function(Uint32 ms);
typedef MutsuRelaySetSegmentMaxMsDart = void Function(int ms);

typedef MutsuRelayGetSegmentMaxMsC = Uint32 Function();
typedef MutsuRelayGetSegmentMaxMsDart = int Function();

typedef MutsuRelaySetInterimC = Void Function(Int32 enabled);
typedef MutsuRelaySetInterimDart = void Function(int enabled);

typedef MutsuRelayGetInterimC = Int32 Function();
typedef MutsuRelayGetInterimDart = int Function();

typedef MutsuRelayEnqueueMessageC = Int64 Function(Pointer<Utf8> text);
typedef MutsuRelayEnqueueMessageDart = int Function(Pointer<Utf8> text);

typedef MutsuRelayPollSendResultsC = Pointer<Utf8> Function();
typedef MutsuRelayPollSendResultsDart = Pointer<Utf8> Function();

typedef MutsuRelayGetStatsC = Pointer<Utf8> Function();
typedef MutsuRelayGetStatsDart = Pointer<Utf8> Function();

typedef MutsuRelayAsrStateC = Int32 Function();
typedef MutsuRelayAsrStateDart = int Function();

// ---- Native Bridge ----

class NativeBridge {
  static NativeBridge? _instance;
  late final DynamicLibrary _lib;
  bool _initialized = false;
  String? _loadError;

  NativeBridge._();

  static NativeBridge get instance {
    _instance ??= NativeBridge._();
    return _instance!;
  }

  bool get isInitialized => _initialized;

  /// 加载失败的原因（未加载时为 null）。`load()` 失败会**静默退回 mock**，
  /// 这个字段就是让"静默"变得可诊断的出口。
  String? get loadError => _loadError;

  /// 与 native 侧 `ABI_VERSION` 保持一致。改动任何 `mutsurelay_*` 符号都要同时改两处。
  static const int expectedAbiVersion = 2;

  /// Load the native library. Must be called before any other operation.
  void load({String? libraryPath}) {
    if (_initialized) return;

    final path = libraryPath ?? _defaultLibraryPath();
    if (path == null) {
      _loadError = '未找到原生库文件';
      log('Native library path not found, running in mock mode');
      return;
    }

    try {
      // Pre-load runtime dependencies so dlopen can resolve them
      final libDir = File(path).parent.path;
      for (final dep in Platform.isLinux
          ? ['libsherpa-onnx-c-api.so', 'libsherpa-onnx-cxx-api.so', 'libonnxruntime.so']
          : <String>[]) {
        final depPath = '$libDir/$dep';
        if (File(depPath).existsSync()) {
          DynamicLibrary.open(depPath);
        }
      }
      _lib = DynamicLibrary.open(path);

      // 版本先于绑定检查：符号缺失时 _bindFunctions() 会抛错并被下面的 catch
      // 吞成 mock 模式，只有这里能说清"为什么"。
      final abi = _readAbiVersion();
      if (abi != expectedAbiVersion) {
        throw StateError(
          abi == null
              ? '原生库缺少 mutsurelay_abi_version：这是旧版本产物，'
                    '请在本平台重新构建（native/build.ps1 或 native/build.sh）'
              : '原生库 ABI 版本 $abi 与绑定所需 $expectedAbiVersion 不符，'
                    '请在本平台重新构建原生库',
        );
      }

      _bindFunctions();
      _initialized = true;
      _loadError = null;
      log('Native library loaded: $path (abi $abi)');
    } catch (e) {
      // 不清空 _loadError：调用方据此提示用户，而不是让 ASR 静默失效
      _loadError = '$e';
      log('Failed to load native library: $e, running in mock mode');
    }
  }

  int? _readAbiVersion() {
    try {
      final fn = _lib.lookupFunction<Uint32 Function(), int Function()>(
        'mutsurelay_abi_version',
      );
      return fn();
    } catch (_) {
      return null;
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
        'lib/libmutsurelay_native.so',
        'linux/libmutsurelay_native.so',
        'linux/mutsurelay_native/libmutsurelay_native.so',
        'native/target/release/libmutsurelay_native.so',
        'native/target/debug/libmutsurelay_native.so',
      ]);
      for (final type in ['debug', 'profile', 'release']) {
        candidates.add('build/linux/x64/$type/bundle/lib/libmutsurelay_native.so');
      }
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
  late MutsuRelayGetConfigDirPathDart _getConfigDirPath;
  late MutsuRelayGetLastErrorDart _getLastError;
  late MutsuRelayGetAsrLangDart _getAsrLang;
  late MutsuRelayGetCloseBehaviorDart _getCloseBehavior;
  late MutsuRelaySaveConfigDart _saveConfig;
  late MutsuRelayLoadConfigDart _loadConfig;
  late MutsuRelayPollRecordingDart _pollRecording;
  late MutsuRelayDownloadAsrModelDart _downloadAsrModel;
  late MutsuRelaySetSubtitleFilePathDart _setSubtitleFilePath;
  late MutsuRelayGetSubtitleFilePathDart _getSubtitleFilePath;
  late MutsuRelayReloadAsrDart _reloadAsr;
  late MutsuRelaySetSegmentMaxMsDart _setSegmentMaxMs;
  late MutsuRelayGetSegmentMaxMsDart _getSegmentMaxMs;
  late MutsuRelaySetInterimDart _setInterim;
  late MutsuRelayGetInterimDart _getInterim;
  late MutsuRelayEnqueueMessageDart _enqueueMessage;
  late MutsuRelayPollSendResultsDart _pollSendResults;
  late MutsuRelayGetStatsDart _getStats;
  late MutsuRelayAsrStateDart _asrState;

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
    _pollRecording = _lib
        .lookupFunction<MutsuRelayPollRecordingC, MutsuRelayPollRecordingDart>(
          'mutsurelay_poll_recording',
        );
    _downloadAsrModel = _lib
        .lookupFunction<
          MutsuRelayDownloadAsrModelC,
          MutsuRelayDownloadAsrModelDart
        >('mutsurelay_download_asr_model');
    _setSubtitleFilePath = _lib
        .lookupFunction<
          MutsuRelaySetSubtitleFilePathC,
          MutsuRelaySetSubtitleFilePathDart
        >('mutsurelay_set_subtitle_file_path');
    _getSubtitleFilePath = _lib
        .lookupFunction<
          MutsuRelayGetSubtitleFilePathC,
          MutsuRelayGetSubtitleFilePathDart
        >('mutsurelay_get_subtitle_file_path');
    _reloadAsr = _lib
        .lookupFunction<MutsuRelayReloadAsrC, MutsuRelayReloadAsrDart>(
          'mutsurelay_reload_asr',
        );
    _setSegmentMaxMs = _lib
        .lookupFunction<
          MutsuRelaySetSegmentMaxMsC,
          MutsuRelaySetSegmentMaxMsDart
        >('mutsurelay_set_segment_max_ms');
    _getSegmentMaxMs = _lib
        .lookupFunction<
          MutsuRelayGetSegmentMaxMsC,
          MutsuRelayGetSegmentMaxMsDart
        >('mutsurelay_get_segment_max_ms');
    _setInterim = _lib
        .lookupFunction<MutsuRelaySetInterimC, MutsuRelaySetInterimDart>(
          'mutsurelay_set_interim',
        );
    _getInterim = _lib
        .lookupFunction<MutsuRelayGetInterimC, MutsuRelayGetInterimDart>(
          'mutsurelay_get_interim',
        );
    _enqueueMessage = _lib
        .lookupFunction<
          MutsuRelayEnqueueMessageC,
          MutsuRelayEnqueueMessageDart
        >('mutsurelay_enqueue_message');
    _pollSendResults = _lib
        .lookupFunction<
          MutsuRelayPollSendResultsC,
          MutsuRelayPollSendResultsDart
        >('mutsurelay_poll_send_results');
    _getStats = _lib
        .lookupFunction<MutsuRelayGetStatsC, MutsuRelayGetStatsDart>(
          'mutsurelay_get_stats',
        );
    _asrState = _lib
        .lookupFunction<MutsuRelayAsrStateC, MutsuRelayAsrStateDart>(
          'mutsurelay_asr_state',
        );
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

  Map<String, dynamic>? pollRecording() {
    if (!_initialized) return null;
    final ptr = _pollRecording();
    if (ptr == nullptr) return null;
    final json = ptr.toDartString();
    _freeString(ptr);
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
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

  void setSubtitleFilePath(String path) {
    if (!_initialized) return;
    final ptr = path.toNativeUtf8();
    try {
      _setSubtitleFilePath(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  String? getSubtitleFilePath() {
    if (!_initialized) return null;
    final result = _getSubtitleFilePath();
    if (result == nullptr) return null;
    final text = result.toDartString();
    _freeString(result);
    return text;
  }

  // ---- P2/P3 API ----

  /// 重建 ASR recognizer（换模型 / 换语言）。解码线程常驻，重建在后台完成，
  /// 调用立即返回，不会卡 UI。
  int reloadAsr(String modelDir) {
    if (!_initialized) return -1;
    final ptr = modelDir.toNativeUtf8();
    try {
      return _reloadAsr(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  /// 单段最大时长（毫秒），直接决定连续说话时的最坏出字延迟。
  void setSegmentMaxMs(int ms) {
    if (_initialized) _setSegmentMaxMs(ms);
  }

  int getSegmentMaxMs() => _initialized ? _getSegmentMaxMs() : 8000;

  /// 实时半句预览（interim）开关。半句只进界面，不写字幕、不自动发言。
  void setInterim(bool enabled) {
    if (_initialized) _setInterim(enabled ? 1 : 0);
  }

  bool getInterim() => _initialized ? _getInterim() != 0 : true;

  /// 把一条弹幕排入 native 的异步发送队列，立即返回 job id。
  /// 返回值 <= 0 表示**立即失败**（未登录 / 未连接 / 内容为空），此时不会产生任务，
  /// 错误原因用 [getLastError] 取。调用线程不会被网络阻塞。
  int enqueueMessage(String text) {
    if (!_initialized) return -1;
    final ptr = text.toNativeUtf8();
    try {
      return _enqueueMessage(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  /// 取走全部已完成的异步发送结果，每项形如
  /// `{"id": 1, "ok": true, "ms": 120}` 或 `{"id": 1, "ok": false, "error": "...", "ms": 3000}`。
  List<dynamic> pollSendResults() {
    if (!_initialized) return const [];
    final ptr = _pollSendResults();
    if (ptr == nullptr) return const [];
    final json = ptr.toDartString();
    _freeString(ptr);
    try {
      final decoded = jsonDecode(json);
      return decoded is List ? decoded : const [];
    } catch (_) {
      return const [];
    }
  }

  /// 运行统计（队列深度、丢样/丢段计数、解码延迟 p50/p95 等），用于性能观测。
  Map<String, dynamic>? getStats() {
    if (!_initialized) return null;
    final ptr = _getStats();
    if (ptr == nullptr) return null;
    final json = ptr.toDartString();
    _freeString(ptr);
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// recognizer 加载状态：1 = 就绪，0 = 重建中/未尝试，-1 = 加载失败。
  int asrState() => _initialized ? _asrState() : 0;

  bool isAsrReady() => asrState() == 1;

  bool isAsrFailed() => asrState() == -1;

  static void log(String message) {
    // ignore: avoid_print
    print('[NativeBridge] $message');
  }
}
