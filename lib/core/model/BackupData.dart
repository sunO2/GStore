import 'package:json_annotation/json_annotation.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';

part 'BackupData.g.dart';

/// 备份数据格式版本
enum BackupVersion {
  @JsonValue('1.0')
  v1_0, // 仅聚合数据库

  @JsonValue('2.0')
  v2_0, // 聚合数据库 + 渠道数据库

  @JsonValue('2.1')
  v2_1, // v2.0 + 用户分类标签 + 代理配置
}

/// 备份元数据
@JsonSerializable()
class BackupMetadata {
  /// 格式版本
  final BackupVersion version;

  /// 导出时间
  final DateTime exportDate;

  /// 应用版本
  final String appVersion;

  /// 应用总数
  final int totalApps;

  /// 各渠道应用数量
  final Map<String, int> channelCounts;

  /// 导出选项
  final BackupOptions options;

  /// 额外信息（用于存储备注等）
  final String? extraInfo;

  const BackupMetadata({
    required this.version,
    required this.exportDate,
    required this.appVersion,
    required this.totalApps,
    required this.channelCounts,
    required this.options,
    this.extraInfo,
  });

  factory BackupMetadata.fromJson(Map<String, dynamic> json) =>
      _$BackupMetadataFromJson(json);

  Map<String, dynamic> toJson() => _$BackupMetadataToJson(this);

  BackupMetadata copyWith({
    BackupVersion? version,
    DateTime? exportDate,
    String? appVersion,
    int? totalApps,
    Map<String, int>? channelCounts,
    BackupOptions? options,
    String? extraInfo,
  }) {
    return BackupMetadata(
      version: version ?? this.version,
      exportDate: exportDate ?? this.exportDate,
      appVersion: appVersion ?? this.appVersion,
      totalApps: totalApps ?? this.totalApps,
      channelCounts: channelCounts ?? this.channelCounts,
      options: options ?? this.options,
      extraInfo: extraInfo ?? this.extraInfo,
    );
  }
}

/// 备份选项
@JsonSerializable()
class BackupOptions {
  /// 是否包含图标 URL
  final bool includeIconUrls;

  /// 是否包含描述
  final bool includeDescription;

  /// 是否包含分类
  final bool includeCategory;

  /// 是否包含 extra 字段
  final bool includeExtra;

  /// 是否压缩（gzip）
  final bool compressed;

  /// 仅包含已启用的应用
  final bool enabledOnly;

  /// 是否包含应用配置
  final bool includeAppConfig;

  const BackupOptions({
    this.includeIconUrls = true,
    this.includeDescription = true,
    this.includeCategory = true,
    this.includeExtra = true,
    this.compressed = false,
    this.enabledOnly = false,
    this.includeAppConfig = false,
  });

  factory BackupOptions.fromJson(Map<String, dynamic> json) =>
      _$BackupOptionsFromJson(json);

  Map<String, dynamic> toJson() => _$BackupOptionsToJson(this);

  BackupOptions copyWith({
    bool? includeIconUrls,
    bool? includeDescription,
    bool? includeCategory,
    bool? includeExtra,
    bool? compressed,
    bool? enabledOnly,
    bool? includeAppConfig,
  }) {
    return BackupOptions(
      includeIconUrls: includeIconUrls ?? this.includeIconUrls,
      includeDescription: includeDescription ?? this.includeDescription,
      includeCategory: includeCategory ?? this.includeCategory,
      includeExtra: includeExtra ?? this.includeExtra,
      compressed: compressed ?? this.compressed,
      enabledOnly: enabledOnly ?? this.enabledOnly,
      includeAppConfig: includeAppConfig ?? this.includeAppConfig,
    );
  }
}

/// 应用备份项
@JsonSerializable()
class BackupAppItem {
  /// 渠道 ID
  final String channelId;

  /// 应用 ID
  final String appId;

  /// 应用名称
  final String appName;

  /// 图标 URL
  final String? iconUrl;

  /// 描述
  final String? description;

  /// 分类（逗号分隔或数组）
  @JsonKey(includeFromJson: true, includeToJson: true)
  final String? category;

  /// 添加时间（毫秒时间戳）
  final int addTime;

  /// 排序权重
  final int sortOrder;

  /// 是否启用
  final bool isEnabled;

  /// 扩展字段（JSON 字符串）
  final String? extra;

  const BackupAppItem({
    required this.channelId,
    required this.appId,
    required this.appName,
    this.iconUrl,
    this.description,
    this.category,
    required this.addTime,
    this.sortOrder = 0,
    this.isEnabled = true,
    this.extra,
  });

  factory BackupAppItem.fromJson(Map<String, dynamic> json) =>
      _$BackupAppItemFromJson(json);

  Map<String, dynamic> toJson() => _$BackupAppItemToJson(this);

  /// 从 AddedAppInfo 转换
  /// 聚合库只存引用（v3），应用信息字段用 appId 占位（备份格式保持兼容）
  static BackupAppItem fromAddedAppInfo(AddedAppInfo app, BackupOptions options) {
    return BackupAppItem(
      channelId: app.channelId,
      appId: app.appId,
      appName: app.appId,
      iconUrl: null,
      description: null,
      category: null,
      addTime: app.addTime,
      sortOrder: app.sortOrder,
      isEnabled: app.isEnabled,
      extra: null, // extra 字段从渠道数据库获取
    );
  }

  /// 从渠道数据库的 ChannelAddedApp 转换
  static BackupAppItem fromChannelAddedApp(
    ChannelAddedApp channelApp,
    BackupOptions options,
  ) {
    return BackupAppItem(
      channelId: channelApp.channelCode,
      appId: channelApp.appId,
      appName: channelApp.name,
      iconUrl: options.includeIconUrls ? channelApp.icon : null,
      description: options.includeDescription ? channelApp.description : null,
      category: options.includeCategory ? channelApp.category : null,
      addTime: channelApp.addTime,
      sortOrder: 0,
      isEnabled: true,
      extra: options.includeExtra ? channelApp.extra : null,
    );
  }

  /// 转换为 AddedAppInfo
  /// 聚合库只存引用（v3），应用信息字段（appName/iconUrl/description/category）
  /// 在恢复时忽略，恢复后由渠道实时获取
  AddedAppInfo toAddedAppInfo() {
    return AddedAppInfo(
      channelId: channelId,
      appId: appId,
      addTime: addTime,
      sortOrder: sortOrder,
      isEnabled: isEnabled,
    );
  }

  /// 转换为 ChannelAddedApp
  ChannelAddedApp toChannelAddedApp() {
    return ChannelAddedApp(
      appId: appId,
      name: appName,
      user: '', // 需要从渠道获取
      repositories: '', // 需要从渠道获取
      icon: iconUrl ?? '',
      description: description ?? '',
      category: category,
      addTime: addTime,
      channelCode: channelId,
      extra: extra,
    );
  }
}

/// 渠道应用备份项（用于序列化）
/// 这是 ChannelAddedApp 的可序列化版本
@JsonSerializable()
class ChannelAppBackupItem {
  /// 应用 ID
  final String appId;

  /// 应用名称
  final String name;

  /// 开发者
  final String user;

  /// 仓库/包名
  final String repositories;

  /// 图标 URL
  final String icon;

  /// 描述
  final String description;

  /// 分类（逗号分隔）
  final String? category;

  /// 添加时间（毫秒时间戳）
  final int addTime;

  /// 渠道类型代码
  final String channelCode;

  /// 扩展字段（JSON 字符串格式存储额外信息）
  final String? extra;

  const ChannelAppBackupItem({
    required this.appId,
    required this.name,
    required this.user,
    required this.repositories,
    required this.icon,
    required this.description,
    this.category,
    required this.addTime,
    required this.channelCode,
    this.extra,
  });

  factory ChannelAppBackupItem.fromJson(Map<String, dynamic> json) =>
      _$ChannelAppBackupItemFromJson(json);

  Map<String, dynamic> toJson() => _$ChannelAppBackupItemToJson(this);

  /// 从 ChannelAddedApp 转换
  static ChannelAppBackupItem fromChannelAddedApp(ChannelAddedApp app) {
    return ChannelAppBackupItem(
      appId: app.appId,
      name: app.name,
      user: app.user,
      repositories: app.repositories,
      icon: app.icon,
      description: app.description,
      category: app.category,
      addTime: app.addTime,
      channelCode: app.channelCode,
      extra: app.extra,
    );
  }

  /// 转换为 ChannelAddedApp
  ChannelAddedApp toChannelAddedApp() {
    return ChannelAddedApp(
      appId: appId,
      name: name,
      user: user,
      repositories: repositories,
      icon: icon,
      description: description,
      category: category,
      addTime: addTime,
      channelCode: channelCode,
      extra: extra,
    );
  }
}

/// 标签备份项（用户自定义分类标签，与 AddedAppTag 同构）
@JsonSerializable()
class BackupTagItem {
  /// 渠道 ID
  final String channelId;

  /// 应用 ID
  final String appId;

  /// 用户自定义标签
  final String tag;

  const BackupTagItem({
    required this.channelId,
    required this.appId,
    required this.tag,
  });

  factory BackupTagItem.fromJson(Map<String, dynamic> json) =>
      _$BackupTagItemFromJson(json);

  Map<String, dynamic> toJson() => _$BackupTagItemToJson(this);

  /// 转换为 AddedAppTag（导入恢复用，addTime 取当前时间）
  AddedAppTag toAddedAppTag() {
    return AddedAppTag(channelId: channelId, appId: appId, tag: tag);
  }
}

/// 完整备份数据
@JsonSerializable()
class BackupData {
  /// 元数据
  final BackupMetadata metadata;

  /// 应用列表（聚合数据库）
  final List<BackupAppItem> apps;

  /// 渠道应用数据（按渠道代码分组）
  /// 格式: { "channelCode": [ChannelAppBackupItem, ...] }
  /// 仅在 v2.0 及以上版本包含
  final Map<String, List<ChannelAppBackupItem>> channelApps;

  /// 应用配置数据
  /// 格式: { "configKey": configData }
  /// 仅在 includeAppConfig 为 true 时包含
  @JsonKey(includeFromJson: true, includeToJson: true)
  final Map<String, dynamic>? appConfig;

  /// 扩展数据（v2.1 新增）
  /// 包含：F-Droid 源列表、Agent 配置等
  /// 格式: { "category": data }
  @JsonKey(includeFromJson: true, includeToJson: true)
  final Map<String, dynamic>? extras;

  /// 用户分类标签（v2.1 新增；v2.0 及更早备份不含此字段，缺失 → null）
  @JsonKey(includeFromJson: true, includeToJson: true)
  final List<BackupTagItem>? tags;

  const BackupData({
    required this.metadata,
    required this.apps,
    this.channelApps = const {},
    this.appConfig,
    this.extras,
    this.tags,
  });

  factory BackupData.fromJson(Map<String, dynamic> json) {
    // 处理 v1.0 格式（没有 channelApps）
    if (!json.containsKey('channelApps') || json['channelApps'] == null) {
      return BackupData(
        metadata: BackupMetadata.fromJson(json['metadata']),
        apps: (json['apps'] as List)
                .map((item) => BackupAppItem.fromJson(item))
                .toList(),
        channelApps: {},
        appConfig: json['appConfig'] as Map<String, dynamic>?,
        extras: json['extras'] as Map<String, dynamic>?,
        tags: json['tags'] == null
            ? null
            : (json['tags'] as List)
                .map((item) => BackupTagItem.fromJson(item))
                .toList(),
      );
    }

    // 处理 v2.0/v2.1 格式
    return _$BackupDataFromJson(json);
  }

  Map<String, dynamic> toJson() => _$BackupDataToJson(this);

  /// 获取指定渠道的应用
  List<BackupAppItem> getAppsByChannel(String channelId) {
    return apps.where((app) => app.channelId == channelId).toList();
  }

  /// 获取指定渠道的渠道应用数据
  List<ChannelAppBackupItem> getChannelAppsByChannel(String channelCode) {
    return channelApps[channelCode] ?? [];
  }

  /// 获取应用数量统计
  Map<String, int> getChannelCounts() {
    final counts = <String, int>{};
    for (final app in apps) {
      counts[app.channelId] = (counts[app.channelId] ?? 0) + 1;
    }
    return counts;
  }

  /// 获取渠道应用数量统计
  Map<String, int> getChannelAppCounts() {
    final counts = <String, int>{};
    channelApps.forEach((channelCode, apps) {
      counts[channelCode] = apps.length;
    });
    return counts;
  }

  BackupData copyWith({
    BackupMetadata? metadata,
    List<BackupAppItem>? apps,
    Map<String, List<ChannelAppBackupItem>>? channelApps,
    Map<String, dynamic>? appConfig,
    Map<String, dynamic>? extras,
    List<BackupTagItem>? tags,
  }) {
    return BackupData(
      metadata: metadata ?? this.metadata,
      apps: apps ?? this.apps,
      channelApps: channelApps ?? this.channelApps,
      appConfig: appConfig ?? this.appConfig,
      extras: extras ?? this.extras,
      tags: tags ?? this.tags,
    );
  }
}
