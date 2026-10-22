import 'dart:convert';

import 'package:flutter/services.dart';

/// `gstore/platform` 通道名：Android 侧静态能力（清单 / 设备 / 性能读数 / Shizuku 执行）。
const String platformChannelName = 'gstore/platform';

/// `gstore/install_events` 事件通道名：安装终端结果（installed / failed / denied / timeout）。
const String installEventsChannelName = 'gstore/install_events';

/// Android 侧返回的 typed 错误信封（`{"ok":false,"code":...,"message":...}`）
/// 或通道层错误（未实现 / 解码失败）的归一化异常。
class PlatformChannelException implements Exception {
  const PlatformChannelException(this.code, this.message);

  /// 稳定错误码，形如 `CORE_E_PLATFORM_DENIED` / `CORE_E_PLATFORM_UNIMPLEMENTED`。
  final String code;

  /// 人类可读的补充信息（原生侧 message 或通道错误描述）。
  final String message;

  @override
  String toString() => 'PlatformChannelException($code): $message';
}

/// `gstore/install_events` 的一条终端事件。
///
/// `ok` 由枚举出的 [status] 派生（Decision 12：状态是唯一事实来源，布尔只是派生值），
/// 因此即使 wire 上的 `ok` 与 `status` 冲突也以 `status` 为准。
class InstallEvent {
  const InstallEvent({
    required this.sessionId,
    required this.packageName,
    required this.ok,
    required this.status,
    required this.method,
    required this.installedVersion,
    required this.error,
  });

  /// 解析一次 `EventChannel` 载荷。缺失键按空值处理，绝不抛出。
  factory InstallEvent.fromMap(Map<Object?, Object?> map) {
    final status = map['status']?.toString() ?? '';
    return InstallEvent(
      sessionId: map['sessionId']?.toString() ?? '',
      packageName: map['packageName']?.toString(),
      ok: status == 'installed',
      status: status,
      method: map['method']?.toString(),
      installedVersion: map['installedVersion']?.toString(),
      error: map['error']?.toString(),
    );
  }

  final String sessionId;
  final String? packageName;
  final bool ok;
  final String status;
  final String? method;
  final String? installedVersion;
  final String? error;
}

/// `gstore/platform` 的最小类型化客户端。
///
/// 只依赖 `dart:convert` 与 `package:flutter/services.dart`，不引用应用内其它模块，
/// 这样在应用层改造（Todo 5）完成前也能独立测试。所有 JSON 方法把原生返回的
/// `String` 解析为 Map/List；`{"ok":false,...}` 信封统一抛
/// [PlatformChannelException]。
class PlatformChannelClient {
  PlatformChannelClient({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 与 Kotlin `PlatformChannel.CHANNEL` 对齐的通道名。
  static const String channelName = platformChannelName;

  final MethodChannel _channel;

  /// `listInstalled` → 加宽后的已安装应用清单（snake_case 键）。
  Future<List<Map<String, Object?>>> listInstalled() async {
    final decoded = await _invokeJson('listInstalled');
    return _asList(decoded).map(_asObject).toList(growable: false);
  }

  /// `getInstalled` → 单个应用对象；未知包返回 null。
  Future<Map<String, Object?>?> getInstalled(String packageName) async {
    final decoded = await _invokeJson('getInstalled', packageName);
    return decoded == null ? null : _asObject(decoded);
  }

  /// `getSourceDir` → APK 路径；未知包返回 null。
  Future<String?> getSourceDir(String packageName) =>
      _invoke<String>('getSourceDir', packageName);

  /// `getSignatures` → 签名条目数组。
  Future<List<Map<String, Object?>>> getSignatures(String packageName) async {
    final decoded = await _invokeJson('getSignatures', packageName);
    return _asList(decoded).map(_asObject).toList(growable: false);
  }

  /// `getPermissions` → 申请的权限名列表。
  Future<List<String>> getPermissions(String packageName) async {
    final decoded = await _invokeJson('getPermissions', packageName);
    return _asList(decoded)
        .whereType<String>()
        .toList(growable: false);
  }

  /// `getComponents` → `{components:[...], permission_states:[...]}`。
  Future<Map<String, Object?>> getComponents(String packageName) async {
    final decoded = await _invokeJson('getComponents', packageName);
    return _asObject(decoded);
  }

  /// `deviceInfo` → `{manufacturer,model,device,android_version,sdk_int,abis}`。
  Future<Map<String, Object?>> deviceInfo() async =>
      _asObject(await _invokeJson('deviceInfo'));

  /// `readBattery` → `BatteryChannel.readJson` 的对象。
  Future<Map<String, Object?>> readBattery() async =>
      _asObject(await _invokeJson('readBattery'));

  /// `readDeviceState` → `DeviceStateChannel.readJson` 的对象。
  Future<Map<String, Object?>> readDeviceState() async =>
      _asObject(await _invokeJson('readDeviceState'));

  /// `readForeground` → `ForegroundAccessibilityService.readJson` 的对象。
  Future<Map<String, Object?>> readForeground() async =>
      _asObject(await _invokeJson('readForeground'));

  /// `readFrameMetrics` → `FrameMetricsCollector.readJson` 的对象。
  Future<Map<String, Object?>> readFrameMetrics() async =>
      _asObject(await _invokeJson('readFrameMetrics'));

  /// `exec` → Shizuku shell 输出；Shizuku 不可用时为 null。
  Future<String?> exec(String command) => _invoke<String>('exec', command);

  /// `available` → Shizuku 是否可用（Binder 存活且已授权）。
  Future<bool> available() async => (await _invoke<bool>('available')) ?? false;

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException catch (e) {
      throw PlatformChannelException(
        'CORE_E_PLATFORM_UNIMPLEMENTED',
        e.message ?? '$method is not implemented on this platform',
      );
    } on PlatformException catch (e) {
      throw PlatformChannelException(
        e.code,
        e.message ?? e.details?.toString() ?? '$method failed',
      );
    }
  }

  Future<Object?> _invokeJson(String method, [Object? arguments]) async {
    final raw = await _invoke<Object?>(method, arguments);
    if (raw == null) return null;
    final Object? decoded = raw is String ? _decodeJson(raw, method) : raw;
    if (decoded is Map && decoded['ok'] == false) {
      throw PlatformChannelException(
        decoded['code']?.toString() ?? 'CORE_E_PLATFORM_FAILED',
        decoded['message']?.toString() ?? '$method failed',
      );
    }
    return decoded;
  }

  Object? _decodeJson(String raw, String method) {
    try {
      return jsonDecode(raw);
    } on FormatException catch (e) {
      throw PlatformChannelException(
        'CORE_E_PLATFORM_DECODE',
        '$method returned malformed JSON: ${e.message}',
      );
    }
  }

  List<Object?> _asList(Object? value) {
    if (value is List) return value;
    throw const PlatformChannelException(
      'CORE_E_PLATFORM_DECODE',
      'expected a JSON array',
    );
  }

  Map<String, Object?> _asObject(Object? value) {
    if (value is Map) {
      return value.map<String, Object?>(
        (Object? key, Object? item) => MapEntry(key.toString(), item),
      );
    }
    throw const PlatformChannelException(
      'CORE_E_PLATFORM_DECODE',
      'expected a JSON object',
    );
  }
}
