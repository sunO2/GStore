/// 应用信息实体类
/// 统一数据库实体，不继承接口（Floor 限制）
library;

import 'package:floor/floor.dart';

/// 应用信息实体
/// 存储在统一数据库中的纯数据类
@Entity(tableName: 'apps')
class AppInfoEntity {
  /// 应用包名（主键）
  @PrimaryKey(autoGenerate: false)
  final String packageName;

  /// 应用名称
  final String appName;

  /// 应用图标URL
  final String icon;

  /// 应用简短描述
  final String description;

  /// 来源渠道
  /// 标识应用来自哪个渠道
  final String channelId;

  /// 渠道中的应用ID
  /// 原始渠道中的应用标识（如GitHub的owner/repo）
  final String? appId;

  /// 添加时间戳（毫秒）
  final int addTime;

  /// 最后更新时间戳（毫秒）
  final int? updateTime;

  AppInfoEntity({
    required this.packageName,
    required this.appName,
    required this.icon,
    required this.description,
    required this.channelId,
    this.appId,
    int? addTime,
    this.updateTime,
  })  : addTime = addTime ?? DateTime.now().millisecondsSinceEpoch;

  /// 从 IDetailInfo 创建实体
  factory AppInfoEntity.fromDetailInfo(
    dynamic detail,
    String channelId,
  ) {
    // 处理不同类型的输入
    if (detail is Map) {
      final map = detail as Map;
      return AppInfoEntity(
        packageName: map['packageName']?.toString() ?? '',
        appName: map['name']?.toString() ?? map['appName']?.toString() ?? '',
        icon: map['icon']?.toString() ?? '',
        description: map['description']?.toString() ??
            map['des']?.toString() ??
            map['summary']?.toString() ??
            '',
        channelId: channelId,
        appId: map['appId']?.toString(),
      );
    }

    // 如果是实现了 IAppInfo 的对象
    try {
      final packageName = detail.packageName;
      final appName = detail.appName;
      final icon = detail.icon;
      final description = detail.description;

      return AppInfoEntity(
        packageName: packageName,
        appName: appName,
        icon: icon,
        description: description,
        channelId: channelId,
      );
    } catch (e) {
      throw ArgumentError('Cannot convert ${detail.runtimeType} to AppInfoEntity');
    }
  }

  /// 从旧的 AppInfo 创建实体（用于数据迁移）
  factory AppInfoEntity.fromLegacyAppInfo(
    dynamic legacyApp,
    String channelId, {
    String? packageName,
  }) {
    // 处理不同类型的旧数据
    if (legacyApp is Map) {
      final map = legacyApp as Map;
      return AppInfoEntity(
        packageName: packageName ??
            map['packageName']?.toString() ??
            map['appId']?.toString() ??
            '',
        appName: map['name']?.toString() ?? map['appName']?.toString() ?? '',
        icon: map['icon']?.toString() ?? '',
        description: map['des']?.toString() ??
            map['description']?.toString() ??
            map['summary']?.toString() ??
            '',
        channelId: channelId,
        appId: map['appId']?.toString(),
        addTime: DateTime.now().millisecondsSinceEpoch,
      );
    }

    throw ArgumentError('Unsupported type: ${legacyApp.runtimeType}');
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() {
    return {
      'packageName': packageName,
      'appName': appName,
      'icon': icon,
      'description': description,
      'channelId': channelId,
      'appId': appId,
      'addTime': addTime,
      'updateTime': updateTime,
    };
  }

  @override
  String toString() {
    return 'AppInfoEntity{packageName: $packageName, appName: $appName, channelId: $channelId}';
  }
}
