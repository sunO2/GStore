/// F-Droid 仓库管理相关模型
library;

import 'package:floor/floor.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';

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

  /// 镜像地址列表
  final List<String> mirrors;

  FdroidSource({
    required this.id,
    required this.name,
    required this.repoUrl,
    this.enabled = true,
    this.priority = 0,
    List<String>? mirrors,
  }) : mirrors = mirrors ?? [];

  /// 从 JSON 创建
  factory FdroidSource.fromJson(Map<String, dynamic> json) {
    return FdroidSource(
      id: json['id'] as String,
      name: json['name'] as String,
      repoUrl: json['repoUrl'] as String,
      enabled: json['enabled'] as bool? ?? true,
      priority: json['priority'] as int? ?? 0,
      mirrors: (json['mirrors'] as List?)?.cast<String>() ?? [],
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
      'mirrors': mirrors,
    };
  }

  /// 默认的官方源
  static FdroidSource get official => FdroidSource(
    id: 'official',
    name: 'F-Droid Official',
    repoUrl: 'https://f-droid.org/repo',
    priority: 0,
    mirrors: [
      'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo', // 清华镜像（国内推荐）
      'https://ftp.fau.de/fdroid/repo',
      'https://mirrors.niyawe.de/fdroid/repo',
    ],
  );

  /// 清华镜像源（国内推荐）
  static FdroidSource get tunaMirror => FdroidSource(
    id: 'tuna_mirror',
    name: 'Tsinghua Mirror',
    repoUrl: 'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo',
    priority: -1, // 更高优先级
  );

  @override
  String toString() {
    return 'FdroidSource{id: $id, name: $name, enabled: $enabled}';
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
