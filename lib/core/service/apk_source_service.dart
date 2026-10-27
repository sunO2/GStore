import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/CoreApiFacade.dart';
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

/// `gstore/apk_source.materializeUri` 接缝：返回本地绝对路径。
typedef MaterializeUriResolver = Future<String> Function(String pathOrUri);

/// `CoreApi.importFile` 接缝：返回导入结果句柄（FRB `BigInt`）。
typedef CoreApkImporter = Future<BigInt> Function(String pathOrFd);

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

  /// 物化 / 导入地址的稳定错误码（与 Kotlin `gstore/apk_source` 一致）。
  static const String uriMalformedCode = 'CORE_E_APK_URI_MALFORMED';
  static const String uriUnsupportedCode = 'CORE_E_APK_URI_UNSUPPORTED';
  static const String uriUnreadableCode = 'CORE_E_APK_URI_UNREADABLE';
  static const String uriCopyFailedCode = 'CORE_E_APK_URI_COPY_FAILED';

  /// 测试接缝：替换 `gstore/apk_source.materializeUri`（null = 真实通道）。
  MaterializeUriResolver? _debugMaterializeUriResolver;

  /// 测试接缝：替换 `CoreApi.importFile`（null = 真实 FRB 句柄）。
  CoreApkImporter? _debugCoreImporter;

  /// 把弹层 / 系统选择器给出的地址归一为**核心导入可用的绝对路径**。
  ///
  /// 归一统一交给 `gstore/apk_source.materializeUri`（既有通道，不新增
  /// `gstore/platform` 方法）：Kotlin 侧把 `content://` 流式拷贝到
  /// `cacheDir/imports/<sha256(uri)>.<ext>`，并把绝对路径原样返回，
  /// 因此 Dart 侧始终只走一次通道。
  ///
  /// `CoreApi.importFile` 的生成参数名是 `pathOrFd`（不是计划早期措辞里的
  /// `path`），见 [importApk]。
  Future<String> resolveImportPath(String pathOrUri) async {
    final value = pathOrUri.trim();
    if (value.isEmpty) {
      throw const ApkSourceException(uriMalformedCode, 'empty APK path');
    }
    if (value.startsWith('file://')) {
      throw ApkSourceException(
        uriUnsupportedCode,
        'file:// APK paths are not importable: $value',
      );
    }
    if (!value.startsWith('/') && !value.startsWith('content://')) {
      throw ApkSourceException(
        uriUnsupportedCode,
        'expected an absolute path or content:// URI: $value',
      );
    }
    final resolver = _debugMaterializeUriResolver ?? _materializeViaChannel;
    return resolver(value);
  }

  /// 解析 [pathOrUri] 后交给 `CoreApi.importFile(pathOrFd:)`。
  ///
  /// 测试可经 [debugSetCoreImporter] 注入假件；生产复用 [CoreApiFacade]
  /// 的进程级句柄（与 `CoreBootstrap` 同一实例）。
  Future<BigInt> importApk(String pathOrUri) async {
    final resolved = await resolveImportPath(pathOrUri);
    final importer = _debugCoreImporter ?? _defaultCoreImporter;
    return importer(resolved);
  }

  Future<String> _materializeViaChannel(String pathOrUri) async {
    final String? raw;
    try {
      raw = await _channel.invokeMethod<String>('materializeUri', pathOrUri);
    } on MissingPluginException catch (error) {
      throw ApkSourceException(
        uriUnreadableCode,
        error.message ?? 'gstore/apk_source.materializeUri unavailable',
      );
    } on PlatformException catch (error) {
      throw ApkSourceException(
        error.code.isEmpty ? uriUnreadableCode : error.code,
        error.message ?? 'materializeUri failed',
      );
    }
    if (raw == null || raw.isEmpty) {
      throw ApkSourceException(
        uriUnreadableCode,
        'materializeUri returned no path for $pathOrUri',
      );
    }
    // 成功返回本地绝对路径；失败返回与 PlatformChannel 同款的 JSON 信封。
    if (!raw.startsWith('{')) return raw;
    return _decodeEnvelope(raw, pathOrUri);
  }

  String _decodeEnvelope(String raw, String pathOrUri) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw ApkSourceException(
        uriMalformedCode,
        'materializeUri returned malformed JSON: $raw',
      );
    }
    if (decoded is! Map) {
      throw ApkSourceException(
        uriMalformedCode,
        'materializeUri returned a non-object envelope: $raw',
      );
    }
    if (decoded['ok'] == false) {
      throw ApkSourceException(
        decoded['code']?.toString() ?? uriUnreadableCode,
        decoded['message']?.toString() ??
            'materializeUri failed for $pathOrUri',
      );
    }
    final path = decoded['path'];
    if (path is String && path.isNotEmpty) return path;
    throw ApkSourceException(
      uriMalformedCode,
      'materializeUri envelope has no path: $raw',
    );
  }

  Future<BigInt> _defaultCoreImporter(String pathOrFd) async {
    final support = await getApplicationSupportDirectory();
    final root = '${support.path}/gstore_core';
    final api = await CoreApiFacade.init(
      dataDir: '$root/data',
      filesDir: '$root/files',
      cacheDir: '$root/cache',
    );
    return api.importFile(pathOrFd: pathOrFd);
  }

  /// 测试用：替换 `materializeUri` 通道调用（null 恢复真实通道）。
  @visibleForTesting
  void debugSetMaterializeUriResolver(MaterializeUriResolver? resolver) {
    _debugMaterializeUriResolver = resolver;
  }

  /// 测试用：替换 `CoreApi.importFile`（null 恢复真实 FRB 句柄）。
  @visibleForTesting
  void debugSetCoreImporter(CoreApkImporter? importer) {
    _debugCoreImporter = importer;
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
