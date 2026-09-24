/// 抓包 MITM CA 安装 / 状态的 Dart 侧封装（todo 18）。
///
/// Kotlin 在既有 `gstore/proxy_vpn` 通道上**新增**了四个方法
/// [installUserCa] / [installSystemCa] / [detectRoot] / [systemCaInstalled]，
/// 委托给 `CaInstaller`（todo 17）。本文件把这些方法包成**可注入**接口
/// [ProxyCaService]，生产实现为 [MethodChannelProxyCaService]，测试可注入假实现。
///
/// ## 诚实契约
/// - `installUserCa` 成功仅代表「系统安装器已拉起 / 引导已下发」
///   （`userActionRequired=true`、`installed=false`），**不声称已安装**。
/// - `installSystemCa` 仅 root 可用；非 root 由原生返回 `ok=false, code=NOT_ROOT`。
/// - 通道异常一律转**结构化**结果 / 异常，绝不崩溃；证书字节**不写日志**。
///
/// 真机安装路径 **UNVERIFIED**（本仓库无 adb 设备），仅经静态分支审查。
library;

import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 顶层安装动作（与 Kotlin `CaInstaller.CaInstallAction` 逐项对齐）。
enum CaInstallAction {
  /// 系统证书存储已存在该 CA → 无需安装。
  alreadyInstalled,

  /// 已 root → 写系统证书存储。
  installSystem,

  /// 非 root 且 API ≤ 30 → 拉起 KeyChain 用户证书安装器。
  installUserKeychain,

  /// 非 root 且 API ≥ 31 → 导出 + 引导到「安全设置」手动安装。
  installUserGuide,
}

/// 系统证书写入方式（与 Kotlin `CaInstaller.SystemCaMethod` 对齐）。
enum SystemCaMethod {
  /// Android ≤ 13（API ≤ 33）：直接写 `/system/etc/security/cacerts`。
  legacyFs,

  /// Android 14+（API ≥ 34）：`nsenter` 后覆盖 APEX cacerts。
  apexNsenter,
}

/// API 边界：30 = Android 11（KeyChain 安装最后一个稳定可用大版本）。
const int kUserCaKeychainMaxSdk = 30;

/// API 边界：33 = Android 13（其后系统 cacerts 迁入 APEX）。
const int kLegacyCacertsMaxSdk = 33;

/// 选择 CA 安装动作（纯函数，镜像 Kotlin `CaInstaller.chooseCaInstallAction`）。
///
/// 优先级：已安装 > root 系统写入 > 用户证书（按 API 分 KeyChain / 引导）。
/// 不读取任何全局状态，所有输入显式传入，便于全组合穷举单测。
CaInstallAction chooseCaInstallAction(
  int sdkInt,
  bool isRooted,
  bool systemInstalled,
) {
  if (systemInstalled) return CaInstallAction.alreadyInstalled;
  if (isRooted) return CaInstallAction.installSystem;
  return sdkInt <= kUserCaKeychainMaxSdk
      ? CaInstallAction.installUserKeychain
      : CaInstallAction.installUserGuide;
}

/// 选择系统 CA 写入方式（纯函数，镜像 Kotlin `CaInstaller.chooseSystemCaMethod`）。
SystemCaMethod chooseSystemCaMethod(int sdkInt) =>
    sdkInt <= kLegacyCacertsMaxSdk
        ? SystemCaMethod.legacyFs
        : SystemCaMethod.apexNsenter;

/// 一次 CA 安装 / 状态操作的结构化结果。
///
/// 由原生返回的 `Map<String, Any?>` 解析而来；原生通道异常也会被降级为本类型的
/// 失败实例（`ok=false`），调用方按 [code] 分支处理，绝不崩溃。
class CaInstallResult {
  const CaInstallResult({
    required this.ok,
    required this.code,
    this.installed = false,
    this.userActionRequired = false,
    this.action,
    this.message,
    this.savedPath,
    this.settingsOpened,
    this.fileName,
    this.reason,
  });

  /// 失败结果（原生通道异常 / 非法响应降级用）。
  const CaInstallResult.failure(String code, String? message)
      : ok = false,
        code = code,
        installed = false,
        userActionRequired = false,
        action = null,
        message = message,
        savedPath = null,
        settingsOpened = null,
        fileName = null,
        reason = null;

  /// 通道不可用（非 Android / 插件未注册）时的固定错误码。
  static const String channelUnavailableCode = 'CHANNEL_UNAVAILABLE';

  /// 用户在系统 UI 取消 / 拒绝时的错误码（原生经 `result.error` 回传）。
  static const String userCancelledCode = 'USER_CANCELLED';

  /// 操作是否按预期完成（注意：`ok=true` 不代表证书已写入，见 [installed]）。
  final bool ok;

  /// 原生侧语义码（`SYSTEM_CA_INSTALLED` / `NOT_ROOT` / `USER_KEYCHAIN_LAUNCHED` …）。
  final String code;

  /// 证书是否**已确认**写入证书存储。
  final bool installed;

  /// 是否已下发动作、等待用户在系统 UI 确认（用户证书安装器 / 引导路径）。
  final bool userActionRequired;

  /// 实际执行的安装动作（`keychain` / `guide` / `legacy_fs` / `apex_nsenter` …）。
  final String? action;

  /// 面向用户的说明。
  final String? message;

  /// 引导路径导出的证书文件路径（Downloads）。
  final String? savedPath;

  /// 引导路径是否成功打开了「安全设置」。
  final bool? settingsOpened;

  /// 系统 CA 写入的文件名（`<hash>.0`）。
  final String? fileName;

  /// 原生附带的补充原因（如降级到引导的 `reason`）。
  final String? reason;

  /// 用户是否取消 / 拒绝。
  bool get cancelled => code == userCancelledCode;

  /// 从原生 `Map<String, Any?>` 解析；非映射或字段缺失时降级为失败结果，不抛。
  factory CaInstallResult.fromChannel(Object? raw) {
    if (raw is! Map) {
      return const CaInstallResult.failure(
        'BAD_RESPONSE',
        '原生返回了非映射结果',
      );
    }
    final map = raw.cast<Object?, Object?>();
    final ok = map['ok'] == true;
    final code = map['code'] as String?;
    return CaInstallResult(
      ok: ok,
      code: code ?? (ok ? 'OK' : 'UNKNOWN'),
      installed: map['installed'] == true,
      userActionRequired: map['userActionRequired'] == true,
      action: map['action'] as String?,
      message: map['message'] as String?,
      savedPath: map['savedPath'] as String?,
      settingsOpened: map['settingsOpened'] as bool?,
      fileName: map['fileName'] as String?,
      reason: map['reason'] as String?,
    );
  }
}

/// 状态探测（[ProxyCaService.detectRoot] / [ProxyCaService.systemCaInstalled]）
/// 通道异常时的**结构化**异常。调用方应捕获并按 [code] 分支，绝不崩溃。
class ProxyCaException implements Exception {
  const ProxyCaException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ProxyCaException($code): $message';
}

/// CA 安装 / 状态能力的可注入接口（生产见 [MethodChannelProxyCaService]）。
abstract class ProxyCaService {
  /// 安装到**用户**证书存储；返回结构化结果（`userActionRequired` 语义）。
  Future<CaInstallResult> installUserCa(Uint8List bytes);

  /// 安装到**系统**证书存储（仅 root）；非 root 返回 `ok=false, code=NOT_ROOT`。
  Future<CaInstallResult> installSystemCa(String pem);

  /// 是否检测到 root。通道异常时抛 [ProxyCaException]。
  Future<bool> detectRoot();

  /// 系统证书存储是否已存在该 CA（[pem] 缺省用最近一次成功写入的文件名）。
  /// 通道异常时抛 [ProxyCaException]。
  Future<bool> systemCaInstalled({String? pem});
}

/// 生产实现：经既有 `gstore/proxy_vpn` 通道转发（仅新增方法）。
class MethodChannelProxyCaService implements ProxyCaService {
  MethodChannelProxyCaService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 与 Kotlin `MainActivity` / [ProxyVpnTrigger] 共用的通道名。
  static const String channelName = 'gstore/proxy_vpn';

  final MethodChannel _channel;

  @override
  Future<CaInstallResult> installUserCa(Uint8List bytes) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'installUserCa',
        <String, Object?>{'bytes': bytes},
      );
      return CaInstallResult.fromChannel(raw);
    } on PlatformException catch (e) {
      return CaInstallResult.failure(e.code, e.message);
    } on MissingPluginException {
      return const CaInstallResult.failure(
        CaInstallResult.channelUnavailableCode,
        '平台通道不可用（非 Android 或插件未注册）',
      );
    }
  }

  @override
  Future<CaInstallResult> installSystemCa(String pem) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'installSystemCa',
        <String, Object?>{'pem': pem},
      );
      return CaInstallResult.fromChannel(raw);
    } on PlatformException catch (e) {
      return CaInstallResult.failure(e.code, e.message);
    } on MissingPluginException {
      return const CaInstallResult.failure(
        CaInstallResult.channelUnavailableCode,
        '平台通道不可用（非 Android 或插件未注册）',
      );
    }
  }

  @override
  Future<bool> detectRoot() async {
    try {
      return await _channel.invokeMethod<bool>('detectRoot') ?? false;
    } on PlatformException catch (e) {
      throw ProxyCaException(e.code, e.message ?? 'root 检测失败');
    } on MissingPluginException {
      throw const ProxyCaException(
        CaInstallResult.channelUnavailableCode,
        '平台通道不可用（非 Android 或插件未注册）',
      );
    }
  }

  @override
  Future<bool> systemCaInstalled({String? pem}) async {
    try {
      return await _channel.invokeMethod<bool>('systemCaInstalled', <String, Object?>{
        if (pem != null) 'pem': pem,
      }) ??
          false;
    } on PlatformException catch (e) {
      throw ProxyCaException(e.code, e.message ?? '系统证书状态检测失败');
    } on MissingPluginException {
      throw const ProxyCaException(
        CaInstallResult.channelUnavailableCode,
        '平台通道不可用（非 Android 或插件未注册）',
      );
    }
  }
}
