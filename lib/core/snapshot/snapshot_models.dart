import 'dart:convert';

/// 快照载荷 schema 版本。
///
/// 每次增删字段都要 +1：对比引擎据此判断「旧快照是否具备该字段」，
/// 缺失时把该节标记为不可比，而不是把所有条目误报成「新增/移除」。
const int kSnapshotPayloadVersion = 1;

/// 应用快照载荷（一次采集的完整结果）
///
/// 全部字段都设计成可 JSON 往返；每条记录都保留足够的**展示与对比**信息，
/// 对比引擎不依赖设备当前状态，只看两份载荷即可。
class SnapshotPayload {
  const SnapshotPayload({
    this.payloadVersion = kSnapshotPayloadVersion,
    this.app = const SnapshotAppInfo(),
    this.signature = const SnapshotSignatureInfo(),
    this.permissions = const [],
    this.components = const [],
    this.nativeLibs = const [],
    this.nativeHits = const [],
    this.elfFiles = const [],
    this.dexFiles = const [],
    this.dexHits = const [],
    this.features = const SnapshotFeatures(),
    this.buildVersions = const SnapshotBuildVersions(),
    this.metaData = const [],
    this.staticLibraries = const [],
    this.actionHits = const [],
    this.componentHits = const [],
  });

  final int payloadVersion;
  final SnapshotAppInfo app;
  final SnapshotSignatureInfo signature;
  final List<SnapshotPermission> permissions;
  final List<SnapshotComponent> components;

  /// 全量原生库（ABI + 文件名 + 大小）
  final List<SnapshotNativeLib> nativeLibs;

  /// 命中的第三方原生库（规则）
  final List<SnapshotRuleHit> nativeHits;

  /// ELF 元数据（每个 .so 一条）
  final List<SnapshotElfInfo> elfFiles;

  /// 全量 DEX 文件
  final List<SnapshotDexFile> dexFiles;

  /// 命中的 DEX 规则
  final List<SnapshotRuleHit> dexHits;

  final SnapshotFeatures features;
  final SnapshotBuildVersions buildVersions;
  final List<SnapshotMetaData> metaData;

  /// 命中的静态库规则
  final List<SnapshotRuleHit> staticLibraries;

  /// 命中的 action 规则
  final List<SnapshotRuleHit> actionHits;

  /// 命中的组件规则（type 1-4）
  final List<SnapshotRuleHit> componentHits;

  /// 供列表页展示的精简统计（不解析大 JSON）
  SnapshotSummary get summary => SnapshotSummary(
        nativeLibs: nativeLibs.length,
        dexFiles: dexFiles.length,
        classCount: dexFiles.fold<int>(
          0,
          (n, d) => n + (d.classCount > 0 ? d.classCount : 0),
        ),
        components: components.length,
        permissions: permissions.length,
        deepLinks: deepLinks.length,
        ruleHits: nativeHits.length +
            dexHits.length +
            staticLibraries.length +
            actionHits.length,
        apkSize: app.apkSize,
        featureLabels: features.labels,
      );

  /// 深链（快捷启动）URI 全量去重（按 URI + 来源组件）
  List<String> get deepLinks {
    final out = <String>{};
    for (final c in components) {
      for (final uri in c.deepLinks) {
        out.add('${c.name}|$uri');
      }
    }
    return out.toList();
  }

  Map<String, dynamic> toJson() => {
        'payload_version': payloadVersion,
        'app': app.toJson(),
        'signature': signature.toJson(),
        'permissions': [for (final p in permissions) p.toJson()],
        'components': [for (final c in components) c.toJson()],
        'native_libs': [for (final l in nativeLibs) l.toJson()],
        'native_hits': [for (final h in nativeHits) h.toJson()],
        'elf_files': [for (final e in elfFiles) e.toJson()],
        'dex_files': [for (final d in dexFiles) d.toJson()],
        'dex_hits': [for (final h in dexHits) h.toJson()],
        'features': features.toJson(),
        'build_versions': buildVersions.toJson(),
        'meta_data': [for (final m in metaData) m.toJson()],
        'static_libraries': [for (final s in staticLibraries) s.toJson()],
        'action_hits': [for (final a in actionHits) a.toJson()],
        'component_hits': [for (final c in componentHits) c.toJson()],
      };

  String encode() => jsonEncode(toJson());

  /// 解析快照载荷；格式非法时返回 null（调用方降级为「快照损坏」）
  static SnapshotPayload? decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      return SnapshotPayload.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  factory SnapshotPayload.fromJson(Map<String, dynamic> json) => SnapshotPayload(
        payloadVersion: (json['payload_version'] as num?)?.toInt() ?? 0,
        app: SnapshotAppInfo.fromJson(_map(json['app'])),
        signature: SnapshotSignatureInfo.fromJson(_map(json['signature'])),
        permissions: [
          for (final e in _list(json['permissions']))
            SnapshotPermission.fromJson(_map(e)),
        ],
        components: [
          for (final e in _list(json['components']))
            SnapshotComponent.fromJson(_map(e)),
        ],
        nativeLibs: [
          for (final e in _list(json['native_libs']))
            SnapshotNativeLib.fromJson(_map(e)),
        ],
        nativeHits: [
          for (final e in _list(json['native_hits']))
            SnapshotRuleHit.fromJson(_map(e)),
        ],
        elfFiles: [
          for (final e in _list(json['elf_files']))
            SnapshotElfInfo.fromJson(_map(e)),
        ],
        dexFiles: [
          for (final e in _list(json['dex_files']))
            SnapshotDexFile.fromJson(_map(e)),
        ],
        dexHits: [
          for (final e in _list(json['dex_hits']))
            SnapshotRuleHit.fromJson(_map(e)),
        ],
        features: SnapshotFeatures.fromJson(_map(json['features'])),
        buildVersions:
            SnapshotBuildVersions.fromJson(_map(json['build_versions'])),
        metaData: [
          for (final e in _list(json['meta_data']))
            SnapshotMetaData.fromJson(_map(e)),
        ],
        staticLibraries: [
          for (final e in _list(json['static_libraries']))
            SnapshotRuleHit.fromJson(_map(e)),
        ],
        actionHits: [
          for (final e in _list(json['action_hits']))
            SnapshotRuleHit.fromJson(_map(e)),
        ],
        componentHits: [
          for (final e in _list(json['component_hits']))
            SnapshotRuleHit.fromJson(_map(e)),
        ],
      );
}

/// 列表页用的精简统计
class SnapshotSummary {
  const SnapshotSummary({
    this.nativeLibs = 0,
    this.dexFiles = 0,
    this.classCount = 0,
    this.components = 0,
    this.permissions = 0,
    this.deepLinks = 0,
    this.ruleHits = 0,
    this.apkSize = 0,
    this.featureLabels = const [],
  });

  final int nativeLibs;
  final int dexFiles;
  final int classCount;
  final int components;
  final int permissions;
  final int deepLinks;
  final int ruleHits;
  final int apkSize;
  final List<String> featureLabels;

  Map<String, dynamic> toJson() => {
        'native_libs': nativeLibs,
        'dex_files': dexFiles,
        'class_count': classCount,
        'components': components,
        'permissions': permissions,
        'deep_links': deepLinks,
        'rule_hits': ruleHits,
        'apk_size': apkSize,
        'feature_labels': featureLabels,
      };

  static SnapshotSummary decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return const SnapshotSummary();
      return SnapshotSummary.fromJson(json);
    } catch (_) {
      return const SnapshotSummary();
    }
  }

  factory SnapshotSummary.fromJson(Map<String, dynamic> json) => SnapshotSummary(
        nativeLibs: (json['native_libs'] as num?)?.toInt() ?? 0,
        dexFiles: (json['dex_files'] as num?)?.toInt() ?? 0,
        classCount: (json['class_count'] as num?)?.toInt() ?? 0,
        components: (json['components'] as num?)?.toInt() ?? 0,
        permissions: (json['permissions'] as num?)?.toInt() ?? 0,
        deepLinks: (json['deep_links'] as num?)?.toInt() ?? 0,
        ruleHits: (json['rule_hits'] as num?)?.toInt() ?? 0,
        apkSize: (json['apk_size'] as num?)?.toInt() ?? 0,
        featureLabels: _strList(json['feature_labels']),
      );
}

/// 应用基础信息
class SnapshotAppInfo {
  const SnapshotAppInfo({
    this.packageName = '',
    this.label = '',
    this.versionName = '',
    this.versionCode = '',
    this.apkSize = 0,
    this.uid = 0,
    this.isSystemApp = false,
    this.isDebuggable = false,
    this.dataDir = '',
    this.installer = '',
    this.mainActivity = '',
    this.firstInstallTime = 0,
    this.lastUpdateTime = 0,
    this.minSdk = '',
    this.targetSdk = '',
    this.compileSdk = '',
    this.sharedUserId = '',
    this.abis = const [],
  });

  final String packageName;
  final String label;
  final String versionName;
  final String versionCode;
  final int apkSize;
  final int uid;
  final bool isSystemApp;
  final bool isDebuggable;
  final String dataDir;
  final String installer;
  final String mainActivity;
  final int firstInstallTime;
  final int lastUpdateTime;
  final String minSdk;
  final String targetSdk;
  final String compileSdk;
  final String sharedUserId;
  final List<String> abis;

  Map<String, dynamic> toJson() => {
        'package_name': packageName,
        'label': label,
        'version_name': versionName,
        'version_code': versionCode,
        'apk_size': apkSize,
        'uid': uid,
        'is_system_app': isSystemApp,
        'is_debuggable': isDebuggable,
        'data_dir': dataDir,
        'installer': installer,
        'main_activity': mainActivity,
        'first_install_time': firstInstallTime,
        'last_update_time': lastUpdateTime,
        'min_sdk': minSdk,
        'target_sdk': targetSdk,
        'compile_sdk': compileSdk,
        'shared_user_id': sharedUserId,
        'abis': abis,
      };

  factory SnapshotAppInfo.fromJson(Map<String, dynamic> json) => SnapshotAppInfo(
        packageName: json['package_name'] as String? ?? '',
        label: json['label'] as String? ?? '',
        versionName: json['version_name'] as String? ?? '',
        versionCode: json['version_code'] as String? ?? '',
        apkSize: (json['apk_size'] as num?)?.toInt() ?? 0,
        uid: (json['uid'] as num?)?.toInt() ?? 0,
        isSystemApp: json['is_system_app'] as bool? ?? false,
        isDebuggable: json['is_debuggable'] as bool? ?? false,
        dataDir: json['data_dir'] as String? ?? '',
        installer: json['installer'] as String? ?? '',
        mainActivity: json['main_activity'] as String? ?? '',
        firstInstallTime: (json['first_install_time'] as num?)?.toInt() ?? 0,
        lastUpdateTime: (json['last_update_time'] as num?)?.toInt() ?? 0,
        minSdk: json['min_sdk'] as String? ?? '',
        targetSdk: json['target_sdk'] as String? ?? '',
        compileSdk: json['compile_sdk'] as String? ?? '',
        sharedUserId: json['shared_user_id'] as String? ?? '',
        abis: _strList(json['abis']),
      );
}

/// 签名信息（方案 + 证书）
class SnapshotSignatureInfo {
  const SnapshotSignatureInfo({
    this.signingShape = '',
    this.schemes = const [],
    this.certificates = const [],
  });

  /// single / multiple / rotation
  final String signingShape;
  final List<String> schemes;
  final List<SnapshotCertificate> certificates;

  Map<String, dynamic> toJson() => {
        'signing_shape': signingShape,
        'schemes': schemes,
        'certificates': [for (final c in certificates) c.toJson()],
      };

  factory SnapshotSignatureInfo.fromJson(Map<String, dynamic> json) =>
      SnapshotSignatureInfo(
        signingShape: json['signing_shape'] as String? ?? '',
        schemes: _strList(json['schemes']),
        certificates: [
          for (final e in _list(json['certificates']))
            SnapshotCertificate.fromJson(_map(e)),
        ],
      );
}

/// 单张签名证书
class SnapshotCertificate {
  const SnapshotCertificate({
    this.subject = '',
    this.algorithm = '',
    this.sha256 = '',
    this.sha1 = '',
    this.kind = '',
  });

  final String subject;
  final String algorithm;
  final String sha256;
  final String sha1;

  /// current / history / signer
  final String kind;

  Map<String, dynamic> toJson() => {
        'subject': subject,
        'algorithm': algorithm,
        'sha256': sha256,
        'sha1': sha1,
        'kind': kind,
      };

  factory SnapshotCertificate.fromJson(Map<String, dynamic> json) =>
      SnapshotCertificate(
        subject: json['subject'] as String? ?? '',
        algorithm: json['algorithm'] as String? ?? '',
        sha256: json['sha256'] as String? ?? '',
        sha1: json['sha1'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
      );
}

/// 一项权限（含声明上限与授权状态）
class SnapshotPermission {
  const SnapshotPermission({
    required this.name,
    this.maxSdkVersion = '',
    this.granted = false,
    this.neverForLocation = false,
  });

  final String name;
  final String maxSdkVersion;
  final bool granted;
  final bool neverForLocation;

  Map<String, dynamic> toJson() => {
        'name': name,
        'max_sdk_version': maxSdkVersion,
        'granted': granted,
        'never_for_location': neverForLocation,
      };

  factory SnapshotPermission.fromJson(Map<String, dynamic> json) =>
      SnapshotPermission(
        name: json['name'] as String? ?? '',
        maxSdkVersion: json['max_sdk_version'] as String? ?? '',
        granted: json['granted'] as bool? ?? false,
        neverForLocation: json['never_for_location'] as bool? ?? false,
      );
}

/// 一个组件（含 intent-filter 的 action 与深链）
class SnapshotComponent {
  const SnapshotComponent({
    required this.kind,
    required this.name,
    this.exported = '',
    this.enabled = '',
    this.processName = '',
    this.actions = const [],
    this.deepLinks = const [],
  });

  final String kind;
  final String name;
  final String exported;
  final String enabled;
  final String processName;
  final List<String> actions;
  final List<String> deepLinks;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'name': name,
        'exported': exported,
        'enabled': enabled,
        'process_name': processName,
        'actions': actions,
        'deep_links': deepLinks,
      };

  factory SnapshotComponent.fromJson(Map<String, dynamic> json) =>
      SnapshotComponent(
        kind: json['kind'] as String? ?? '',
        name: json['name'] as String? ?? '',
        exported: json['exported'] as String? ?? '',
        enabled: json['enabled'] as String? ?? '',
        processName: json['process_name'] as String? ?? '',
        actions: _strList(json['actions']),
        deepLinks: _strList(json['deep_links']),
      );
}

/// 一个原生库文件
class SnapshotNativeLib {
  const SnapshotNativeLib({
    required this.abi,
    required this.name,
    this.size = 0,
  });

  final String abi;
  final String name;
  final int size;

  Map<String, dynamic> toJson() => {'abi': abi, 'name': name, 'size': size};

  factory SnapshotNativeLib.fromJson(Map<String, dynamic> json) =>
      SnapshotNativeLib(
        abi: json['abi'] as String? ?? '',
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
      );
}

/// 一条规则命中（原生库 / DEX / 静态库 / action 通用）
class SnapshotRuleHit {
  const SnapshotRuleHit({
    required this.label,
    required this.ruleName,
    required this.matched,
    this.kind = '',
    this.isRegex = false,
  });

  final String label;
  final String ruleName;
  final String matched;

  /// native / dex / static / action
  final String kind;
  final bool isRegex;

  Map<String, dynamic> toJson() => {
        'label': label,
        'rule_name': ruleName,
        'matched': matched,
        'kind': kind,
        'is_regex': isRegex,
      };

  factory SnapshotRuleHit.fromJson(Map<String, dynamic> json) => SnapshotRuleHit(
        label: json['label'] as String? ?? '',
        ruleName: json['rule_name'] as String? ?? '',
        matched: json['matched'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        isRegex: json['is_regex'] as bool? ?? false,
      );
}

/// 单个 .so 的 ELF 元数据
class SnapshotElfInfo {
  const SnapshotElfInfo({
    required this.abi,
    required this.soName,
    this.minPageSize = -1,
    this.aligned16Kb = false,
    this.zipAlignment = 0,
    this.elfType = -1,
    this.needed = const [],
    this.jniEntryPoints = const [],
    this.stripped = false,
  });

  final String abi;
  final String soName;
  final int minPageSize;
  final bool aligned16Kb;
  final int zipAlignment;
  final int elfType;
  final List<String> needed;
  final List<String> jniEntryPoints;
  final bool stripped;

  Map<String, dynamic> toJson() => {
        'abi': abi,
        'so_name': soName,
        'min_page_size': minPageSize,
        'aligned_16kb': aligned16Kb,
        'zip_alignment': zipAlignment,
        'elf_type': elfType,
        'needed': needed,
        'jni_entry_points': jniEntryPoints,
        'stripped': stripped,
      };

  factory SnapshotElfInfo.fromJson(Map<String, dynamic> json) => SnapshotElfInfo(
        abi: json['abi'] as String? ?? '',
        soName: json['so_name'] as String? ?? '',
        minPageSize: (json['min_page_size'] as num?)?.toInt() ?? -1,
        aligned16Kb: json['aligned_16kb'] as bool? ?? false,
        zipAlignment: (json['zip_alignment'] as num?)?.toInt() ?? 0,
        elfType: (json['elf_type'] as num?)?.toInt() ?? -1,
        needed: _strList(json['needed']),
        jniEntryPoints: _strList(json['jni_entry_points']),
        stripped: json['stripped'] as bool? ?? false,
      );
}

/// 一个 DEX 文件
class SnapshotDexFile {
  const SnapshotDexFile({
    required this.name,
    this.size = 0,
    this.classCount = -1,
    this.crc32 = 0,
  });

  final String name;
  final int size;
  final int classCount;
  final int crc32;

  Map<String, dynamic> toJson() => {
        'name': name,
        'size': size,
        'class_count': classCount,
        'crc32': crc32,
      };

  factory SnapshotDexFile.fromJson(Map<String, dynamic> json) => SnapshotDexFile(
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        classCount: (json['class_count'] as num?)?.toInt() ?? -1,
        crc32: (json['crc32'] as num?)?.toInt() ?? 0,
      );
}

/// APK 特征
class SnapshotFeatures {
  const SnapshotFeatures({
    this.kotlinUsed = false,
    this.jetpackCompose = false,
    this.kmp = false,
    this.xposedModule = false,
    this.playSigning = false,
    this.pwa = false,
    this.liveUpdateNotification = false,
    this.agpVersion = '',
  });

  final bool kotlinUsed;
  final bool jetpackCompose;
  final bool kmp;
  final bool xposedModule;
  final bool playSigning;
  final bool pwa;
  final bool liveUpdateNotification;
  final String agpVersion;

  /// 用于对比与展示的标签（顺序固定）
  List<String> get labels => [
        if (kotlinUsed) 'Kotlin',
        if (jetpackCompose) 'Jetpack Compose',
        if (kmp) 'KMP',
        if (xposedModule) 'Xposed',
        if (playSigning) 'Play 签名',
        if (pwa) 'PWA',
        if (liveUpdateNotification) '即时更新通知',
      ];

  Map<String, dynamic> toJson() => {
        'kotlin_used': kotlinUsed,
        'jetpack_compose': jetpackCompose,
        'kmp': kmp,
        'xposed_module': xposedModule,
        'play_signing': playSigning,
        'pwa': pwa,
        'live_update_notification': liveUpdateNotification,
        'agp_version': agpVersion,
        'labels': labels,
      };

  factory SnapshotFeatures.fromJson(Map<String, dynamic> json) =>
      SnapshotFeatures(
        kotlinUsed: json['kotlin_used'] as bool? ?? false,
        jetpackCompose: json['jetpack_compose'] as bool? ?? false,
        kmp: json['kmp'] as bool? ?? false,
        xposedModule: json['xposed_module'] as bool? ?? false,
        playSigning: json['play_signing'] as bool? ?? false,
        pwa: json['pwa'] as bool? ?? false,
        liveUpdateNotification:
            json['live_update_notification'] as bool? ?? false,
        agpVersion: json['agp_version'] as String? ?? '',
      );
}

/// 构建版本检测结果
class SnapshotBuildVersions {
  const SnapshotBuildVersions({
    this.kotlinVersion = '',
    this.gradleVersion = '',
    this.javaVersion = '',
    this.composeVersion = '',
    this.agpVersion = '',
  });

  final String kotlinVersion;
  final String gradleVersion;
  final String javaVersion;
  final String composeVersion;
  final String agpVersion;

  Map<String, dynamic> toJson() => {
        'kotlin_version': kotlinVersion,
        'gradle_version': gradleVersion,
        'java_version': javaVersion,
        'compose_version': composeVersion,
        'agp_version': agpVersion,
      };

  factory SnapshotBuildVersions.fromJson(Map<String, dynamic> json) =>
      SnapshotBuildVersions(
        kotlinVersion: json['kotlin_version'] as String? ?? '',
        gradleVersion: json['gradle_version'] as String? ?? '',
        javaVersion: json['java_version'] as String? ?? '',
        composeVersion: json['compose_version'] as String? ?? '',
        agpVersion: json['agp_version'] as String? ?? '',
      );
}

/// 一条 meta-data
class SnapshotMetaData {
  const SnapshotMetaData({required this.name, this.value = ''});

  final String name;
  final String value;

  Map<String, dynamic> toJson() => {'name': name, 'value': value};

  factory SnapshotMetaData.fromJson(Map<String, dynamic> json) =>
      SnapshotMetaData(
        name: json['name'] as String? ?? '',
        value: json['value'] as String? ?? '',
      );
}

/// 一条持久化快照记录（DB 行 + 已解析载荷）
class SnapshotRecord {
  const SnapshotRecord({
    this.id,
    required this.packageName,
    this.appLabel = '',
    this.versionName = '',
    this.versionCode = '',
    this.createdAt = 0,
    this.note = '',
    this.payloadVersion = 0,
    this.summary = const SnapshotSummary(),
    required this.payload,
  });

  /// 自增主键（未入库为 null）
  final int? id;
  final String packageName;
  final String appLabel;
  final String versionName;
  final String versionCode;

  /// 采集时间（epoch 毫秒）
  final int createdAt;

  /// 备注（如「更新前」「更新后」）
  final String note;
  final int payloadVersion;
  final SnapshotSummary summary;
  final SnapshotPayload payload;

  SnapshotRecord copyWith({int? id}) => SnapshotRecord(
        id: id ?? this.id,
        packageName: packageName,
        appLabel: appLabel,
        versionName: versionName,
        versionCode: versionCode,
        createdAt: createdAt,
        note: note,
        payloadVersion: payloadVersion,
        summary: summary,
        payload: payload,
      );
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];

List<String> _strList(Object? value) => [
      for (final e in _list(value))
        if (e != null) e.toString(),
    ];
