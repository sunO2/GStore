/// F-Droid 仓库管理相关模型
library;

import 'dart:convert';

import 'package:floor/floor.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';

/// 源配置下的一个镜像（**从属于源**，不是独立的源）
///
/// 层级：源（仓库身份）= repoUrl + 指纹 → 镜像列表（可逐个启用/禁用）。
/// 索引声明的镜像会自动发现进来（`fromIndex=true`），用户也可手动添加。
class FdroidMirror {
  const FdroidMirror({required this.url, this.enabled = true, this.fromIndex = false});

  final String url;

  /// 是否参与回退（禁用后仍保留在列表里，便于随时恢复）
  final bool enabled;

  /// 是否来自索引自动声明（用户手动添加的为 false）
  final bool fromIndex;

  /// 兼容两种历史/新格式：`"url"` 或 `{"url":…,"enabled":…,"fromIndex":…}`
  factory FdroidMirror.fromJson(dynamic json) {
    if (json is String) return FdroidMirror(url: json);
    final m = json as Map<String, dynamic>;
    return FdroidMirror(
      url: m['url'] as String,
      enabled: m['enabled'] as bool? ?? true,
      fromIndex: m['fromIndex'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() =>
      {'url': url, 'enabled': enabled, 'fromIndex': fromIndex};

  FdroidMirror copyWith({bool? enabled, bool? fromIndex}) => FdroidMirror(
        url: url,
        enabled: enabled ?? this.enabled,
        fromIndex: fromIndex ?? this.fromIndex,
      );

  @override
  bool operator ==(Object other) => other is FdroidMirror && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// F-Droid 数据源配置
class FdroidSource {
  /// 源ID
  final String id;

  /// 源名称
  final String name;

  /// 源地址（仓库地址）
  final String repoUrl;

  /// 是否启用
  final bool enabled;

  /// 优先级（数字越小优先级越高）
  final int priority;

  /// 镜像列表（从属于本源的镜像站；可逐个启用/禁用）
  final List<FdroidMirror> mirrors;

  /// 是否启用镜像回退。
  /// 为 true 时**优先尝试镜像**（国内网络避免先卡在官方站超时），失败再回退到源地址。
  final bool useMirrors;

  /// 仓库签名指纹（SHA-256 十六进制，大写）。来自深链 `?fingerprint=` 或用户手动确认，
  /// 用于确认第三方源身份（TOFU）；为空表示未固定。
  final String? fingerprint;

  FdroidSource({
    required this.id,
    required this.name,
    required this.repoUrl,
    this.enabled = true,
    this.priority = 0,
    /// 兼容旧格式：传字符串会被转成默认启用的 [FdroidMirror]
    List<dynamic>? mirrors,
    this.fingerprint,
    this.useMirrors = true,
  }) : mirrors = [
          for (final m in mirrors ?? const [])
            m is FdroidMirror ? m : FdroidMirror(url: m as String),
        ];

  /// 从 JSON 创建
  factory FdroidSource.fromJson(Map<String, dynamic> json) {
    return FdroidSource(
      id: json['id'] as String,
      name: json['name'] as String,
      repoUrl: json['repoUrl'] as String,
      enabled: json['enabled'] as bool? ?? true,
      priority: json['priority'] as int? ?? 0,
      mirrors: (json['mirrors'] as List?)
              ?.map(FdroidMirror.fromJson)
              .toList() ??
          const [],
      fingerprint: json['fingerprint'] as String?,
      useMirrors: json['useMirrors'] as bool? ?? true,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'repoUrl': repoUrl,
      'enabled': enabled,
      'priority': priority,
      'mirrors': mirrors.map((m) => m.toJson()).toList(),
      'useMirrors': useMirrors,
      if (fingerprint != null) 'fingerprint': fingerprint,
    };
  }

  /// 默认的官方源
  static FdroidSource get official => FdroidSource(
    id: 'official',
    name: 'F-Droid Official',
    repoUrl: 'https://f-droid.org/repo',
    priority: 0,
    // 镜像从属于官方源：国内镜像默认启用并优先（useMirrors=true）
    mirrors: const [
      FdroidMirror(url: 'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo'), // 清华（国内推荐）
      FdroidMirror(url: 'https://mirrors.niyawe.de/fdroid/repo'),
      FdroidMirror(url: 'https://ftp.fau.de/fdroid/repo'),
    ],
    useMirrors: true,
  );

  /// @Deprecated 旧版把镜像当成独立源；现在镜像从属于 [official] 的 mirrors。
  /// 仅用于读取历史配置，勿再新增。
  @Deprecated('镜像应配置在官方源的 mirrors 下，而不是作为独立源')
  static FdroidSource get tunaMirror => FdroidSource(
    id: 'tuna_mirror',
    name: 'Tsinghua Mirror',
    repoUrl: 'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo',
    priority: -1,
  );

  /// 复制并覆盖部分字段（镜像配置保存等场景）
  FdroidSource copyWith({
    String? name,
    String? repoUrl,
    bool? enabled,
    int? priority,
    List<FdroidMirror>? mirrors,
    String? fingerprint,
    bool? useMirrors,
  }) {
    return FdroidSource(
      id: id,
      name: name ?? this.name,
      repoUrl: repoUrl ?? this.repoUrl,
      enabled: enabled ?? this.enabled,
      priority: priority ?? this.priority,
      mirrors: mirrors ?? this.mirrors,
      fingerprint: fingerprint ?? this.fingerprint,
      useMirrors: useMirrors ?? this.useMirrors,
    );
  }

  @override
  String toString() {
    return 'FdroidSource{id: $id, name: $name, enabled: $enabled}';
  }
}

/// 某个源**最近一次同步**的真实结果（来自模块 download_repo 的返回负载）
///
/// 按源记录：多源下一个"整体上次同步"是没有意义的（会退化成"最后完成那个源"）。
class FdroidSyncInfo {
  const FdroidSyncInfo({
    required this.at,
    required this.incremental,
    this.totalApps,
    this.elapsedMs,
    this.verified = false,
    this.resolvedUrl,
  });

  /// 本地完成时间
  final DateTime at;

  /// 是否走了增量（entry.json + diff）；false = 全量下载
  final bool incremental;

  /// 该源的索引应用数
  final int? totalApps;

  /// 耗时（毫秒）
  final int? elapsedMs;

  /// 是否通过 SHA-256 校验
  final bool verified;

  /// 本次实际生效的地址（镜像回退后真正可用的那个）
  final String? resolvedUrl;

  @override
  String toString() =>
      'FdroidSyncInfo(${at.toIso8601String()}, 增量=$incremental, apps=$totalApps)';
}

/// 单个源的索引数据统计
///
/// 多源下"合计"会掩盖关键信息（哪个源还没同步、哪个源一条数据都没有），
/// 所以统计以**源**为单位给出；需要合计由调用方自行求和。
class FdroidSourceStat {
  const FdroidSourceStat({
    required this.source,
    required this.appCount,
    this.lastSync,
  });

  final FdroidSource source;

  /// 该源自己库里的应用数（未同步过为 0）
  final int appCount;

  /// 该源最近一次同步结果（本次会话内）；null = 本会话还没同步过
  final FdroidSyncInfo? lastSync;

  /// 该源是否参与多源搜索/加载
  bool get enabled => source.enabled;

  @override
  String toString() => 'FdroidSourceStat(${source.name}: $appCount)';
}

/// LocalizedText / LocalizedFile 取值：优先中文，其次英文，再退化为首个非空
///
/// 索引里的本地化字段形态不定（字符串 / {locale: value} 映射），
/// 这里统一处理，避免各处重复实现。
String fdroidLocalizedText(Object? v, {String? locale}) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  if (v is List) {
    for (final e in v) {
      final s = fdroidLocalizedText(e, locale: locale);
      if (s.isNotEmpty) return s;
    }
    return '';
  }
  if (v is Map) {
    // LocalizedFile 对象：{"name":"/icons/x.png","sha256":...,"size":...}
    // ← 真机（Bitwarden 源）暴露：featureGraphic/icon 都是这个形态，
    //   若按「locale→字符串」取值会拿到空（甚至把 sha256/size 当成路径）。
    final n = v['name'];
    if (n != null) return fdroidLocalizedText(n, locale: locale);
    // 本地化包装：{"en-US": <LocalizedText|LocalizedFile>}
    for (final k in [locale ?? 'zh-CN', 'zh', 'en-US', 'en']) {
      final hit = v[k];
      if (hit != null) {
        final s = fdroidLocalizedText(hit, locale: locale);
        if (s.isNotEmpty) return s;
      }
    }
    for (final e in v.values) {
      final s = fdroidLocalizedText(e, locale: locale);
      if (s.isNotEmpty) return s;
    }
  }
  return '';
}

/// 从 metadata JSON 取出的**应用级**扩展信息（不新增数据库列，全部来自 metadata）
class FdroidAppMeta {
  const FdroidAppMeta({
    this.antiFeatures = const [],
    this.screenshots = const [],
    this.featureGraphic = '',
    this.promoGraphic = '',
    this.localizedName = '',
    this.localizedSummary = '',
  });

  /// 抗特性 key（如 Tracking / NonFreeNet / Ads）
  final List<String> antiFeatures;

  /// 截图相对路径（已按当前语言挑选）
  final List<String> screenshots;

  /// 特色图 / 宣传图相对路径
  final String featureGraphic;
  final String promoGraphic;

  /// 本地化后的名称/摘要（索引支持多语言）
  final String localizedName;
  final String localizedSummary;

  /// 递归取值：支持 `String` / `List<String>` / `{locale: List|String}` 三种形态
  ///
  /// 索引里 screenshots 实际是 **locale → 列表** 的嵌套结构，
  /// 所以这里对 Map 先按语言取，再展开列表。
  static List<String> _stringList(Object? v) {
    if (v == null) return const [];
    if (v is String) return v.isEmpty ? const [] : [v];
    if (v is List) return v.expand(_stringList).toList();
    if (v is Map) {
      // LocalizedFile 对象：只取 name（sha256/size 不是路径）
      if (v['name'] != null) {
        final s = fdroidLocalizedText(v['name']);
        return s.isEmpty ? const [] : [s];
      }
      for (final k in const ['zh-CN', 'zh', 'en-US', 'en']) {
        final hit = v[k];
        if (hit != null) {
          final list = _stringList(hit);
          if (list.isNotEmpty) return list;
        }
      }
      return v.values.expand(_stringList).toList();
    }
    return const [];
  }


  /// 从应用级 `metadata` JSON 解析（缺失/非法一律降级为空）
  static FdroidAppMeta parse(String? metadataJson) {
    if (metadataJson == null || metadataJson.isEmpty) return const FdroidAppMeta();
    try {
      final m = jsonDecode(metadataJson);
      if (m is! Map) return const FdroidAppMeta();
      return FdroidAppMeta(
        antiFeatures: m['antiFeatures'] is Map
            ? (m['antiFeatures'] as Map).keys.map((e) => e.toString()).toList()
            : _stringList(m['antiFeatures']),
        screenshots: _stringList(m['screenshots']),
        featureGraphic: fdroidLocalizedText(m['featureGraphic']),
        promoGraphic: fdroidLocalizedText(m['promoGraphic']),
        localizedName: fdroidLocalizedText(m['name']),
        localizedSummary: fdroidLocalizedText(m['summary']),
      );
    } catch (_) {
      return const FdroidAppMeta();
    }
  }
}

/// 单个版本（索引 v2 的 `versions` 里的一条）
///
/// 索引 v2 的 `versions` 是 **map（key=versionCode）**；这里做**宽松解析**：
/// 也接受数组形式、缺字段、LocalizedText/antiFeatures 的多种形态，
/// 避免因仓库端的小差异丢掉整条数据。
class FdroidAppVersion {
  const FdroidAppVersion({
    required this.versionCode,
    required this.versionName,
    this.apkName = '',
    this.size = 0,
    this.sha256 = '',
    this.minSdk = 0,
    this.targetSdk = 0,
    this.nativecode = const [],
    this.antiFeatures = const [],
    this.releaseChannels = const [],
    this.whatsNew = '',
  });

  final int versionCode;
  final String versionName;

  /// APK 文件名（索引 `file.name`）
  final String apkName;

  /// APK 字节数（索引 `file.size`）
  final int size;

  /// APK 的 SHA-256（安装前应与下载到的文件比对）
  final String sha256;

  final int minSdk;
  final int targetSdk;

  /// 该版本包含的 ABI（`manifest.nativecode`）
  final List<String> nativecode;

  /// 该版本被标记的抗特性（`antiFeatures` 的 key）
  final List<String> antiFeatures;

  /// 发布通道（如 `beta`）
  final List<String> releaseChannels;
  final String whatsNew;

  /// 当前设备 API level 是否可装（minSdk 未知或设备未知时不误判）
  bool supportsSdk(int? deviceSdk) {
    if (minSdk <= 0 || deviceSdk == null) return true;
    return minSdk <= deviceSdk;
  }

  /// 综合兼容：ABI + minSdk（用于详情页标记与过滤）
  bool isCompatible({String? deviceAbi, int? deviceSdk}) =>
      supportsAbi(deviceAbi) && supportsSdk(deviceSdk);

  /// 当前设备 ABI 是否可装（nativecode 为空 = 无原生代码，任何 ABI 都可）
  bool supportsAbi(String? deviceAbi) {
    if (nativecode.isEmpty) return true;
    if (deviceAbi == null || deviceAbi.isEmpty) return true;
    return nativecode.contains(deviceAbi);
  }

  static int _asInt(Object? v) =>
      v is int ? v : (v is String ? (int.tryParse(v) ?? 0) : 0);

  static String _asText(Object? v) => fdroidLocalizedText(v);

  static List<String> _keysOf(Object? v) {
    if (v is Map) return v.keys.map((e) => e.toString()).toList();
    if (v is List) return v.map((e) => e.toString()).toList();
    return const [];
  }

  /// 从单个版本对象解析（字段缺失即留默认值，不抛异常）
  static FdroidAppVersion? fromJson(Object? raw, {int? fallbackCode}) {
    if (raw is! Map) return null;
    final file = raw['file'] is Map ? raw['file'] as Map : const {};
    final manifest = raw['manifest'] is Map ? raw['manifest'] as Map : const {};
    final sdk = manifest['usesSdk'] is Map ? manifest['usesSdk'] as Map : const {};
    final code = _asInt(manifest['versionCode'] ?? raw['versionCode'] ?? fallbackCode);
    final abis = manifest['nativecode'] ?? raw['nativecode'];
    return FdroidAppVersion(
      versionCode: code,
      versionName: _asText(manifest['versionName'] ?? raw['versionName']),
      apkName: _asText(file['name'] ?? raw['apkName']),
      size: _asInt(file['size'] ?? raw['size']),
      sha256: _asText(file['sha256'] ?? raw['hash'] ?? raw['sha256']),
      minSdk: _asInt(sdk['minSdkVersion'] ?? raw['minSdk']),
      targetSdk: _asInt(sdk['targetSdkVersion'] ?? raw['targetSdk']),
      nativecode: abis is List ? abis.map((e) => e.toString()).toList() : const [],
      antiFeatures: _keysOf(raw['antiFeatures']),
      releaseChannels: raw['releaseChannels'] is List
          ? (raw['releaseChannels'] as List).map((e) => e.toString()).toList()
          : const [],
      whatsNew: _asText(raw['whatsNew']),
    );
  }

  /// 解析整个 `versions` JSON（顶层可为 map 或数组），按版本号**从新到旧**排序
  static List<FdroidAppVersion> parseAll(String? versionsJson) {
    if (versionsJson == null || versionsJson.isEmpty) return const [];
    try {
      final v = jsonDecode(versionsJson);
      final out = <FdroidAppVersion>[];
      if (v is Map) {
        v.forEach((k, raw) {
          final parsed =
              FdroidAppVersion.fromJson(raw, fallbackCode: int.tryParse(k.toString()));
          if (parsed != null && parsed.versionCode > 0) out.add(parsed);
        });
      } else if (v is List) {
        for (final raw in v) {
          final parsed = FdroidAppVersion.fromJson(raw);
          if (parsed != null && parsed.versionCode > 0) out.add(parsed);
        }
      }
      out.sort((a, b) => b.versionCode.compareTo(a.versionCode));
      return out;
    } catch (_) {
      return const [];
    }
  }
}

/// F-Droid 应用信息（数据库存储格式）
@Entity(tableName: 'FdroidApp')
class FdroidApp {
  /// 包名（主键）
  @PrimaryKey()
  final String packageName;

  /// 应用名称
  final String name;

  /// 摘要
  final String summary;

  /// 描述
  final String? description;

  /// 图标文件名
  final String icon;

  /// 许可证
  final String? license;

  /// 开发者
  final String? authorName;

  /// 源代码 URL
  final String? sourceCode;

  /// 项目 URL
  final String? projectUrl;

  /// 网站 URL
  final String? webSite;

  /// 捐赠链接
  final String? donate;

  /// 分类列表（不存储到数据库）
  @ignore
  final List<String>? categories;

  /// 添加时间（不存储到数据库）
  @ignore
  final DateTime? added;

  /// 最后更新时间（不存储到数据库）
  @ignore
  final DateTime? lastUpdated;

  /// 元数据原始数据（不存储到数据库）
  @ignore
  final Map<String, dynamic>? metadata;

  /// 该应用来自哪个源（多源聚合搜索时写入，用于把查询/安装路由回正确的库）
  @ignore
  final String? sourceId;

  /// 版本列表（解析自索引 `versions`；不落库）
  @ignore
  final List<FdroidAppVersion> versions;

  /// 建议版本号（索引声明的稳定版；用于 beta 语义）
  @ignore
  final int? suggestedVersionCode;

  /// 应用级扩展信息（抗特性/截图/特色图/本地化名称；解析自 metadata）
  @ignore
  final FdroidAppMeta appMeta;

  FdroidApp({
    required this.packageName,
    required this.name,
    required this.summary,
    this.description,
    required this.icon,
    this.license,
    this.authorName,
    this.sourceCode,
    this.projectUrl,
    this.webSite,
    this.donate,
    this.categories,
    this.added,
    this.lastUpdated,
    this.metadata,
    this.sourceId,
    this.versions = const [],
    this.suggestedVersionCode,
    this.appMeta = const FdroidAppMeta(),
  });

  /// 从 index-v2 的 app 数据创建
  factory FdroidApp.fromIndexV2(String packageName, Map<String, dynamic> data) {
    // 提取图标
    final icon = data['icon'] as String?;
    final licenseData = data['license'];

    // 提取许可证
    String? licenseStr;
    if (licenseData is String) {
      licenseStr = licenseData;
    } else if (licenseData is List && licenseData.isNotEmpty) {
      licenseStr = licenseData[0].toString();
    }

    return FdroidApp(
      packageName: packageName,
      name: data['name'] as String? ?? packageName,
      summary: data['summary'] as String? ?? '',
      description: data['description'] as String?,
      icon: icon ?? '$packageName.png',
      license: licenseStr,
      authorName: data['authorName'] as String?,
      sourceCode: data['sourceCode'] as String?,
      projectUrl: data['projectUrl'] as String?,
      webSite: data['webSite'] as String?,
      donate: data['donate'] as String?,
      categories: (data['categories'] as List?)?.cast<String>(),
      added: data['added'] != null
          ? DateTime.tryParse(data['added'])
          : null,
      lastUpdated: data['lastUpdated'] != null
          ? DateTime.tryParse(data['lastUpdated'])
          : null,
      metadata: data,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'packageName': packageName,
      'name': name,
      'summary': summary,
      'description': description,
      'icon': icon,
      'license': license,
      'authorName': authorName,
      'sourceCode': sourceCode,
      'projectUrl': projectUrl,
      'webSite': webSite,
      'donate': donate,
      'categories': categories,
      'added': added?.toIso8601String(),
      'lastUpdated': lastUpdated?.toIso8601String(),
      'metadata': metadata,
    };
  }

  @override
  String toString() {
    return 'FdroidApp{packageName: $packageName, name: $name}';
  }
}

/// F-Droid 包信息（一个应用可能有多个包）
@Entity(tableName: 'FdroidPackage')
class FdroidPackage {
  /// 包 ID（自增主键）
  @PrimaryKey(autoGenerate: true)
  final int? id;

  /// 包名
  final String packageName;

  /// APK 文件名
  final String apkName;

  /// 版本名称
  final String versionName;

  /// 版本号
  final int versionCode;

  /// 文件大小（字节）
  final int size;

  /// SHA256 哈希
  final String? hash;

  /// 哈希类型
  final String? hashType;

  /// 签名者 SHA256
  final String? signer;

  /// 添加时间（不存储到数据库）
  @ignore
  final DateTime? added;

  /// 平台架构
  final String? nativecode;

  FdroidPackage({
    this.id,
    required this.packageName,
    required this.apkName,
    required this.versionName,
    required this.versionCode,
    required this.size,
    this.hash,
    this.hashType,
    this.signer,
    this.added,
    this.nativecode,
  });

  /// 从 index-v2 的 package 数据创建
  factory FdroidPackage.fromIndexV2(
    String packageName,
    String apkName,
    Map<String, dynamic> data,
  ) {
    final hash = data['hash'] as String?;
    final hashType = data['hashType'] as String?;
    final signer = data['signer'] as String?;

    return FdroidPackage(
      packageName: packageName,
      apkName: apkName,
      versionName: data['versionName'] as String? ?? '',
      versionCode: data['versionCode'] as int? ?? 0,
      size: data['size'] as int? ?? 0,
      hash: hash,
      hashType: hashType,
      signer: signer,
      added: data['added'] != null
          ? DateTime.tryParse(data['added'])
          : null,
      nativecode: data['nativecode'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'packageName': packageName,
      'apkName': apkName,
      'versionName': versionName,
      'versionCode': versionCode,
      'size': size,
      'hash': hash,
      'hashType': hashType,
      'signer': signer,
      'added': added?.toIso8601String(),
      'nativecode': nativecode,
    };
  }

  /// 下载链接（相对路径）
  String get downloadUrl => '/$apkName';

  /// 转换为 DownloadInfo（用于下载）
  DownloadInfo toDownloadInfo(String baseUrl) {
    return DownloadInfo(
      url: '$baseUrl$apkName',
      name: apkName,
      size: size,
      version: versionName,
      platform: nativecode,
    );
  }
}

/// 版本管理信息
@Entity(tableName: 'FdroidVersionInfo')
class FdroidVersionInfo {
  /// 当前索引版本号
  final int indexVersion;

  /// 仓库地址（主键）
  @PrimaryKey()
  final String repoUrl;

  /// 最后检查时间（不存储到数据库）
  @ignore
  final DateTime lastCheckTime;

  /// 可用的增量文件列表（不存储到数据库）
  @ignore
  final List<int> availableVersions;

  /// HTTP Last-Modified 响应头（用于条件请求）
  final String? lastModified;

  /// HTTP ETag 响应头（用于条件请求）
  final String? entityTag;

  FdroidVersionInfo({
    required this.indexVersion,
    required this.repoUrl,
    DateTime? lastCheckTime,
    List<int>? availableVersions,
    this.lastModified,
    this.entityTag,
  })  : lastCheckTime = lastCheckTime ?? DateTime.now(),
        availableVersions = availableVersions ?? <int>[];

  /// 检查是否有新的增量更新
  bool get hasUpdate {
    if (availableVersions.isEmpty) return false;
    return availableVersions.last > indexVersion;
  }

  /// 获取下一个要下载的版本号
  int? getNextVersion() {
    if (!hasUpdate) return null;

    // 找到当前版本的下一个版本
    for (final version in availableVersions) {
      if (version > indexVersion) {
        return version;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'indexVersion': indexVersion,
      'lastCheckTime': lastCheckTime.toIso8601String(),
      'repoUrl': repoUrl,
      'availableVersions': availableVersions,
      'lastModified': lastModified,
      'entityTag': entityTag,
    };
  }

  factory FdroidVersionInfo.fromJson(Map<String, dynamic> json) {
    return FdroidVersionInfo(
      indexVersion: json['indexVersion'] as int,
      lastCheckTime: DateTime.parse(json['lastCheckTime'] as String),
      repoUrl: json['repoUrl'] as String,
      availableVersions:
          (json['availableVersions'] as List?)?.cast<int>() ?? [],
      lastModified: json['lastModified'] as String?,
      entityTag: json['entityTag'] as String?,
    );
  }
}
