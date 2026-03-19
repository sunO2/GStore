// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'BackupData.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BackupMetadata _$BackupMetadataFromJson(Map<String, dynamic> json) =>
    BackupMetadata(
      version: $enumDecode(_$BackupVersionEnumMap, json['version']),
      exportDate: DateTime.parse(json['exportDate'] as String),
      appVersion: json['appVersion'] as String,
      totalApps: (json['totalApps'] as num).toInt(),
      channelCounts: Map<String, int>.from(json['channelCounts'] as Map),
      options: BackupOptions.fromJson(json['options'] as Map<String, dynamic>),
      extraInfo: json['extraInfo'] as String?,
    );

Map<String, dynamic> _$BackupMetadataToJson(BackupMetadata instance) =>
    <String, dynamic>{
      'version': _$BackupVersionEnumMap[instance.version]!,
      'exportDate': instance.exportDate.toIso8601String(),
      'appVersion': instance.appVersion,
      'totalApps': instance.totalApps,
      'channelCounts': instance.channelCounts,
      'options': instance.options,
      'extraInfo': instance.extraInfo,
    };

const _$BackupVersionEnumMap = {
  BackupVersion.v1_0: '1.0',
  BackupVersion.v2_0: '2.0',
};

BackupOptions _$BackupOptionsFromJson(Map<String, dynamic> json) =>
    BackupOptions(
      includeIconUrls: json['includeIconUrls'] as bool? ?? true,
      includeDescription: json['includeDescription'] as bool? ?? true,
      includeCategory: json['includeCategory'] as bool? ?? true,
      includeExtra: json['includeExtra'] as bool? ?? true,
      compressed: json['compressed'] as bool? ?? false,
      enabledOnly: json['enabledOnly'] as bool? ?? false,
      includeAppConfig: json['includeAppConfig'] as bool? ?? false,
    );

Map<String, dynamic> _$BackupOptionsToJson(BackupOptions instance) =>
    <String, dynamic>{
      'includeIconUrls': instance.includeIconUrls,
      'includeDescription': instance.includeDescription,
      'includeCategory': instance.includeCategory,
      'includeExtra': instance.includeExtra,
      'compressed': instance.compressed,
      'enabledOnly': instance.enabledOnly,
      'includeAppConfig': instance.includeAppConfig,
    };

BackupAppItem _$BackupAppItemFromJson(Map<String, dynamic> json) =>
    BackupAppItem(
      channelId: json['channelId'] as String,
      appId: json['appId'] as String,
      appName: json['appName'] as String,
      iconUrl: json['iconUrl'] as String?,
      description: json['description'] as String?,
      category: json['category'] as String?,
      addTime: (json['addTime'] as num).toInt(),
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      isEnabled: json['isEnabled'] as bool? ?? true,
      extra: json['extra'] as String?,
    );

Map<String, dynamic> _$BackupAppItemToJson(BackupAppItem instance) =>
    <String, dynamic>{
      'channelId': instance.channelId,
      'appId': instance.appId,
      'appName': instance.appName,
      'iconUrl': instance.iconUrl,
      'description': instance.description,
      'category': instance.category,
      'addTime': instance.addTime,
      'sortOrder': instance.sortOrder,
      'isEnabled': instance.isEnabled,
      'extra': instance.extra,
    };

ChannelAppBackupItem _$ChannelAppBackupItemFromJson(
        Map<String, dynamic> json) =>
    ChannelAppBackupItem(
      appId: json['appId'] as String,
      name: json['name'] as String,
      user: json['user'] as String,
      repositories: json['repositories'] as String,
      icon: json['icon'] as String,
      description: json['description'] as String,
      category: json['category'] as String?,
      addTime: (json['addTime'] as num).toInt(),
      channelCode: json['channelCode'] as String,
      extra: json['extra'] as String?,
    );

Map<String, dynamic> _$ChannelAppBackupItemToJson(
        ChannelAppBackupItem instance) =>
    <String, dynamic>{
      'appId': instance.appId,
      'name': instance.name,
      'user': instance.user,
      'repositories': instance.repositories,
      'icon': instance.icon,
      'description': instance.description,
      'category': instance.category,
      'addTime': instance.addTime,
      'channelCode': instance.channelCode,
      'extra': instance.extra,
    };

BackupData _$BackupDataFromJson(Map<String, dynamic> json) => BackupData(
      metadata:
          BackupMetadata.fromJson(json['metadata'] as Map<String, dynamic>),
      apps: (json['apps'] as List<dynamic>)
          .map((e) => BackupAppItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      channelApps: (json['channelApps'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(
                k,
                (e as List<dynamic>)
                    .map((e) => ChannelAppBackupItem.fromJson(
                        e as Map<String, dynamic>))
                    .toList()),
          ) ??
          const {},
      appConfig: json['appConfig'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$BackupDataToJson(BackupData instance) =>
    <String, dynamic>{
      'metadata': instance.metadata,
      'apps': instance.apps,
      'channelApps': instance.channelApps,
      'appConfig': instance.appConfig,
    };
