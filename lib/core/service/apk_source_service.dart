import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:path_provider/path_provider.dart';

/// 一张应用签名证书的信息（LibChecker 风格展示）
class SignatureInfo {
  const SignatureInfo({
    this.algorithm = '',
    this.subject = '',
    this.sha256 = '',
    this.sha1 = '',
    this.kind = '',
  });

  /// 签名算法（如 SHA256withRSA）
  final String algorithm;

  /// 证书主体 Subject DN
  final String subject;

  /// SHA-256 指纹（小写十六进制，冒号分隔）
  final String sha256;

  /// SHA-1 指纹（小写十六进制，冒号分隔）
  final String sha1;

  /// 证书角色：`signer`（并列签名者之一）/ `current`（当前证书）/ `history`（轮换前历史证书）。
  /// 旧版 Android 通道不带该字段 → 空串（按「当前证书」展示）。
  final String kind;

  factory SignatureInfo.fromJson(Map<String, dynamic> json) => SignatureInfo(
        algorithm: (json['algorithm'] as String?) ?? '',
        subject: (json['subject'] as String?) ?? '',
        sha256: (json['sha256'] as String?) ?? '',
        sha1: (json['sha1'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? '',
      );

  /// 是否为轮换前的历史证书
  bool get isHistory => kind == 'history';
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
    this.signingShape = 'single',
  });

  /// 签名证书列表（可能为空）
  final List<SignatureInfo> signatures;

  /// 签名形态：`single`（单证书）/ `multiple`（多个并列签名者）/ `rotation`（含轮换历史）
  final String signingShape;

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
      signingShape: (json['signingShape'] as String?) ?? 'single',
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

/// 组件状态（LibChecker 风格：exported/enabled/processName）
class ComponentStateDetail {
  const ComponentStateDetail({
    required this.type,
    required this.name,
    required this.exported,
    required this.enabled,
    this.processName = '',
  });

  /// 组件类型（ACTIVITY/SERVICE/RECEIVER/PROVIDER）
  final String type;

  /// 完整类名（如 com.foo.BarActivity）
  final String name;

  /// 是否导出（可被其他应用唤起）
  final bool exported;

  /// 是否启用（android:enabled）
  final bool enabled;

  /// 所属进程名（默认进程为空串）
  final String processName;

  factory ComponentStateDetail.fromJson(Map<String, dynamic> json) =>
      ComponentStateDetail(
        type: (json['type'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        exported: (json['exported'] as bool?) ?? false,
        enabled: (json['enabled'] as bool?) ?? true,
        processName: (json['processName'] as String?) ?? '',
      );
}

/// 权限授权状态（granted / neverForLocation）
class PermissionStateDetail {
  const PermissionStateDetail({
    required this.name,
    required this.granted,
    this.neverForLocation = false,
  });

  /// 权限名（如 android.permission.ACCESS_FINE_LOCATION）
  final String name;

  /// 是否已授权
  final bool granted;

  /// 是否声明 neverForLocation（定位权限但声明不用于定位）
  final bool neverForLocation;

  factory PermissionStateDetail.fromJson(Map<String, dynamic> json) =>
      PermissionStateDetail(
        name: (json['name'] as String?) ?? '',
        granted: (json['granted'] as bool?) ?? false,
        neverForLocation: (json['neverForLocation'] as bool?) ?? false,
      );
}

/// APK 导入路径的 typed 失败（`CORE_E_APK_*`）。
///
/// 非法 URI / 无法物化的 `content://` 一律抛此异常，绝不静默返回错误路径。
class ApkSourceException implements Exception {
  const ApkSourceException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ApkSourceException($code): $message';
}

/// `content://` 读取接缝：返回 APK 字节；null = 读取方放弃。
typedef ContentUriReader = Future<List<int>?> Function(String uri);

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

  /// 测试用：注入合成组件/权限详情，跳过平台通道调用。
  /// 传 null 恢复真实通道调用。
  ({List<ComponentStateDetail> components, List<PermissionStateDetail> permissions})?
      _debugComponentsDetail;

  /// 测试用：注入合成的应用详情，跳过平台通道调用。
  /// 传 null 恢复真实通道调用。
  InstalledAppDetail? _debugInstalledAppDetail;

  /// 测试用：注入合成的 APK 源路径列表，跳过平台通道调用。
  /// 传 null 恢复真实通道调用。
  List<String>? _debugSourceDirs;

  /// 是否支持（仅 Android 平台）
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 无 content resolver 时的稳定错误码（Dart 侧当前 BLOCKED，见
  /// [materialiseContentUri]）。
  static const String uriBlockedCode = 'CORE_E_APK_URI_BLOCKED';

  /// 既不是绝对路径、也不是 `file://` / `content://` 的导入地址。
  static const String uriUnsupportedCode = 'CORE_E_APK_URI_UNSUPPORTED';

  /// 空路径 / 非法 `file://`。
  static const String pathInvalidCode = 'CORE_E_APK_PATH_INVALID';

  /// 测试接缝：注入 `content://` 读取器（生产默认 null = BLOCKED）。
  ContentUriReader? _debugContentUriReader;

  /// 测试接缝：覆盖物化目标目录（默认 `getTemporaryDirectory()`）。
  String? _debugCacheDir;

  /// 把弹层 / 系统选择器给出的地址归一为**核心导入可用的绝对路径**。
  ///
  /// 注意：`CoreApi.importFile` 的生成参数名是 `pathOrFd`（不是计划早期措辞里的
  /// `path`），路径或已打开的 fd 字符串都能传。
  /// * 绝对路径 → 原样返回；
  /// * `file://` → 解码后的本地路径；
  /// * `content://` → 先物化到 cacheDir 再返回（见 [materialiseContentUri]）；
  /// * 其它 → [uriUnsupportedCode]。
  Future<String> resolveImportPath(String pathOrUri) async {
    final value = pathOrUri.trim();
    if (value.isEmpty) {
      throw const ApkSourceException(pathInvalidCode, 'empty APK path');
    }
    if (value.startsWith('content://')) {
      return materialiseContentUri(value);
    }
    if (value.startsWith('file://')) {
      final parsed = Uri.tryParse(value);
      if (parsed == null || parsed.path.isEmpty || parsed.path == '/') {
        throw ApkSourceException(
          pathInvalidCode,
          'malformed file URI: $value',
        );
      }
      return parsed.path;
    }
    if (value.startsWith('/')) return value;
    throw ApkSourceException(
      uriUnsupportedCode,
      'expected an absolute path, file:// or content:// URI: $value',
    );
  }

  /// 把 `content://` 物化到 cacheDir 并返回本地 APK 路径。
  ///
  /// **BLOCKED（Dart 侧）**：`gstore/platform` 与 `gstore/apk_source` 都没有
  /// 暴露 `ContentResolver.openInputStream`，所以默认没有可用的读取器；此时抛
  /// [uriBlockedCode]，绝不把 `content://` 当普通路径交给导入层（那会静默失败）。
  /// 读取器可经 [debugSetContentUriReader] 注入（测试 / 未来新增通道）。
  Future<String> materialiseContentUri(
    String uri, {
    ContentUriReader? reader,
  }) async {
    final read = reader ?? _debugContentUriReader;
    if (read == null) {
      throw ApkSourceException(
        uriBlockedCode,
        'no content resolver channel in Dart; cannot materialise $uri',
      );
    }
    final bytes = await read(uri);
    if (bytes == null || bytes.isEmpty) {
      throw ApkSourceException(uriBlockedCode, 'no bytes for $uri');
    }
    final cachePath =
        _debugCacheDir ?? (await getTemporaryDirectory()).path;
    final dir = Directory('$cachePath/gstore_apk_import');
    await dir.create(recursive: true);
    final name = 'apk_${uri.hashCode.abs()}_${bytes.length}.apk';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 测试用：注入 `content://` 读取器（null 恢复 BLOCKED 默认）。
  @visibleForTesting
  void debugSetContentUriReader(ContentUriReader? reader) {
    _debugContentUriReader = reader;
  }

  /// 测试用：覆盖物化目标目录（null 恢复 `getTemporaryDirectory()`）。
  @visibleForTesting
  void debugSetCacheDir(String? path) {
    _debugCacheDir = path;
  }

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

  /// 获取已安装应用的组件与权限授权状态（LibChecker 风格）：
  /// 四类组件（ACTIVITY/SERVICE/RECEIVER/PROVIDER）的 exported/enabled/processName，
  /// 以及权限 granted/neverForLocation。失败/不支持时返回空。
  Future<({List<ComponentStateDetail> components, List<PermissionStateDetail> permissions})>
      getComponentsDetail(String packageName) async {
    final debug = _debugComponentsDetail;
    if (debug != null) return debug;
    if (!isSupported || packageName.isEmpty) {
      return (components: const <ComponentStateDetail>[], permissions: const <PermissionStateDetail>[]);
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getComponentsDetail',
        {'packageName': packageName},
      );
      if (result == null) {
        return (components: const <ComponentStateDetail>[], permissions: const <PermissionStateDetail>[]);
      }
      final rawComponents =
          (result['components'] as List<dynamic>?) ?? const [];
      final rawPermissions =
          (result['permissionStates'] as List<dynamic>?) ?? const [];
      final components = <ComponentStateDetail>[
        for (final raw in rawComponents)
          if (raw is Map)
            ComponentStateDetail.fromJson(raw.map(
              (k, v) => MapEntry(k.toString(), v as dynamic),
            )),
      ];
      final permissions = <PermissionStateDetail>[
        for (final raw in rawPermissions)
          if (raw is Map)
            PermissionStateDetail.fromJson(raw.map(
              (k, v) => MapEntry(k.toString(), v as dynamic),
            )),
      ];
      return (components: components, permissions: permissions);
    } catch (e) {
      appLog.error('ApkSourceService: 获取组件详情失败 - $e');
      return (components: const <ComponentStateDetail>[], permissions: const <PermissionStateDetail>[]);
    }
  }

  /// 测试用：注入合成权限列表（null 恢复真实通道调用）。
  @visibleForTesting
  void debugSetPermissions(List<String>? permissions) {
    _debugPermissions = permissions;
  }

  /// 测试用：注入合成组件/权限详情（null 恢复真实通道调用）。
  @visibleForTesting
  void debugSetComponentsDetail(
    ({List<ComponentStateDetail> components, List<PermissionStateDetail> permissions})?
        detail,
  ) {
    _debugComponentsDetail = detail;
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
