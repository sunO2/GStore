import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';

/// 一张应用签名证书的信息（LibChecker 风格展示）
class SignatureInfo {
  const SignatureInfo({
    this.algorithm = '',
    this.subject = '',
    this.sha256 = '',
    this.sha1 = '',
  });

  /// 签名算法（如 SHA256withRSA）
  final String algorithm;

  /// 证书主体 Subject DN
  final String subject;

  /// SHA-256 指纹（小写十六进制，冒号分隔）
  final String sha256;

  /// SHA-1 指纹（小写十六进制，冒号分隔）
  final String sha1;

  factory SignatureInfo.fromJson(Map<String, dynamic> json) => SignatureInfo(
        algorithm: (json['algorithm'] as String?) ?? '',
        subject: (json['subject'] as String?) ?? '',
        sha256: (json['sha256'] as String?) ?? '',
        sha1: (json['sha1'] as String?) ?? '',
      );
}

/// 已安装应用详情（签名 / meta-data / 主 Activity / 安装信息 / APK 大小 / SDK 版本 / 系统信息）
class InstalledAppDetail {
  const InstalledAppDetail({
    this.signatures = const [],
    this.metaData = const {},
    this.mainActivity = '',
    this.apkSize = 0,
    this.firstInstallTime = 0,
    this.lastUpdateTime = 0,
    this.minSdk,
    this.targetSdk,
    this.uid = 0,
    this.sharedUserId = '',
    this.installer = '',
    this.installerAppName = '',
    this.installerIconPng = '',
    this.isSystemApp = false,
    this.isDebuggable = false,
    this.dataDir = '',
  });

  /// 签名证书列表（可能为空）
  final List<SignatureInfo> signatures;

  /// 清单 meta-data（String → String）
  final Map<String, String> metaData;

  /// 主 Activity 完整类名（可能为空字符串）
  final String mainActivity;

  /// APK 文件大小（字节）
  final int apkSize;

  /// 首次安装时间（毫秒时间戳）
  final int firstInstallTime;

  /// 最近更新时间（毫秒时间戳）
  final int lastUpdateTime;

  /// 最低支持 SDK（API 24+ 才有，可能为 null）
  final int? minSdk;

  /// 目标 SDK
  final int? targetSdk;

  /// 应用 UID（Linux 用户标识）
  final int uid;

  /// sharedUserId（共享 UID 标识，无则空字符串）
  final String sharedUserId;

  /// 安装来源包名（如 com.android.vending），无则空字符串
  final String installer;

  /// 安装来源应用名（如「Google Play」；来源应用已卸载/不可达时为空）
  final String installerAppName;

  /// 安装来源应用图标（PNG base64，无则空字符串）
  final String installerIconPng;

  /// 是否为系统应用
  final bool isSystemApp;

  /// 是否可调试（android:debuggable）
  final bool isDebuggable;

  /// 应用数据目录（/data/data/<pkg> 或 /data/user/0/<pkg>）
  final String dataDir;

  factory InstalledAppDetail.fromJson(Map<String, dynamic> json) {
    final rawSignatures = (json['signatures'] as List<dynamic>?) ?? const [];
    final rawMetaData = (json['metaData'] as Map<dynamic, dynamic>?) ?? const {};
    return InstalledAppDetail(
      signatures: [
        for (final raw in rawSignatures)
          if (raw is Map)
            SignatureInfo.fromJson(
              // MethodChannel 解码的嵌套 map 类型是 Map<Object?, Object?>，
              // 不能直接用 whereType<Map<String, dynamic>>() 过滤（会全部落空），
              // 此处镜像 metaData 的处理：key 经 toString 归一，value 保持 dynamic。
              raw.map((k, v) => MapEntry(k.toString(), v as dynamic)),
            ),
      ],
      metaData: rawMetaData.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      ),
      mainActivity: (json['mainActivity'] as String?) ?? '',
      apkSize: (json['apkSize'] as int?) ?? 0,
      firstInstallTime: (json['firstInstallTime'] as int?) ?? 0,
      lastUpdateTime: (json['lastUpdateTime'] as int?) ?? 0,
      minSdk: (json['minSdk'] as int?),
      targetSdk: (json['targetSdk'] as int?),
      uid: (json['uid'] as int?) ?? 0,
      sharedUserId: (json['sharedUserId'] as String?) ?? '',
      installer: (json['installer'] as String?) ?? '',
      installerAppName: (json['installerAppName'] as String?) ?? '',
      installerIconPng: (json['installerIconPng'] as String?) ?? '',
      isSystemApp: (json['isSystemApp'] as bool?) ?? false,
      isDebuggable: (json['isDebuggable'] as bool?) ?? false,
      dataDir: (json['dataDir'] as String?) ?? '',
    );
  }
}

/// 已安装应用 APK 路径（sourceDir）获取服务
///
/// installed_apps 插件的 AppInfo 不含 sourceDir/apkPath 字段，
/// 故通过自定义 MethodChannel 调用 PackageManager.getApplicationInfo(...).sourceDir
/// 获取已安装应用的 APK 文件路径（供 SDK 分析使用）。
class ApkSourceService {
  ApkSourceService._();

  static final ApkSourceService instance = ApkSourceService._();

  static const MethodChannel _channel = MethodChannel('gstore/apk_source');

  /// 测试用：注入合成权限列表，跳过平台通道调用。
  /// 传 null 恢复真实通道调用。
  List<String>? _debugPermissions;

  /// 测试用：注入合成的应用详情，跳过平台通道调用。
  /// 传 null 恢复真实通道调用。
  InstalledAppDetail? _debugInstalledAppDetail;

  /// 测试用：注入合成的 APK 源路径列表，跳过平台通道调用。
  /// 传 null 恢复真实通道调用。
  List<String>? _debugSourceDirs;

  /// 是否支持（仅 Android 平台）
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 获取已安装应用的 sourceDir（APK 路径），失败/不支持时返回 null
  Future<String?> getSourceDir(String packageName) async {
    if (!isSupported || packageName.isEmpty) return null;
    try {
      final result = await _channel.invokeMethod<String>('getSourceDir', {
        'packageName': packageName,
      });
      return (result == null || result.isEmpty) ? null : result;
    } catch (e) {
      appLog.error('ApkSourceService: 获取 sourceDir 失败 - $e');
      return null;
    }
  }

  /// 获取已安装应用的全部 APK 源路径（base + split APK）。
  ///
  /// split APK 分发（Android App Bundle / Play）时原生库位于
  /// split_config.*.apk，单独读 base 的 `lib/` 会漏掉全部 .so；
  /// 失败/不支持时返回空列表。
  Future<List<String>> getSourceDirs(String packageName) async {
    final debug = _debugSourceDirs;
    if (debug != null) return debug;
    if (!isSupported || packageName.isEmpty) return const [];
    try {
      final result = await _channel.invokeListMethod<String>('getSourceDirs', {
        'packageName': packageName,
      });
      return result ?? const [];
    } catch (e) {
      appLog.error('ApkSourceService: 获取 sourceDirs 失败 - $e');
      return const [];
    }
  }

  /// 获取系统解压后的原生库目录（nativeLibraryDir，LibChecker 第三层兜底）。
  /// 失败/不支持时返回空字符串。
  Future<String> getNativeLibraryDir(String packageName) async {
    if (!isSupported || packageName.isEmpty) return '';
    try {
      final result = await _channel.invokeMethod<String>(
          'getNativeLibraryDir', {
        'packageName': packageName,
      });
      return result ?? '';
    } catch (e) {
      appLog.error('ApkSourceService: 获取 nativeLibraryDir 失败 - $e');
      return '';
    }
  }

  /// 获取已安装应用声明的权限列表（PackageManager.GET_PERMISSIONS），
  /// 失败/不支持时返回空列表
  Future<List<String>> getPermissions(String packageName) async {
    final debug = _debugPermissions;
    if (debug != null) return debug;
    if (!isSupported || packageName.isEmpty) return const [];
    try {
      final result = await _channel.invokeListMethod<String>('getPermissions', {
        'packageName': packageName,
      });
      return result ?? const [];
    } catch (e) {
      appLog.error('ApkSourceService: 获取权限列表失败 - $e');
      return const [];
    }
  }

  /// 获取已安装应用详情（签名/meta-data/mainActivity/安装时间/APK 大小/minSdk/targetSdk），
  /// 失败/不支持时返回默认空实例
  Future<InstalledAppDetail> getInstalledAppDetail(String packageName) async {
    final debug = _debugInstalledAppDetail;
    if (debug != null) return debug;
    if (!isSupported || packageName.isEmpty) return const InstalledAppDetail();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getInstalledAppDetail',
        {'packageName': packageName},
      );
      return result == null
          ? const InstalledAppDetail()
          : InstalledAppDetail.fromJson(result);
    } catch (e) {
      appLog.error('ApkSourceService: 获取应用详情失败 - $e');
      return const InstalledAppDetail();
    }
  }

  /// 测试用：注入合成权限列表（null 恢复真实通道调用）。
  @visibleForTesting
  void debugSetPermissions(List<String>? permissions) {
    _debugPermissions = permissions;
  }

  /// 测试用：注入合成的应用详情（null 恢复真实通道调用）。
  @visibleForTesting
  void debugSetInstalledAppDetail(InstalledAppDetail? detail) {
    _debugInstalledAppDetail = detail;
  }

  /// 测试用：注入合成的 APK 源路径列表（null 恢复真实通道调用）。
  @visibleForTesting
  void debugSetSourceDirs(List<String>? dirs) {
    _debugSourceDirs = dirs;
  }
}
