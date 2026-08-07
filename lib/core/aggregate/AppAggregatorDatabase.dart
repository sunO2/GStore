import 'dart:async';

import 'package:floor/floor.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/logger/LogManager.dart';

part 'AppAggregatorDatabase.g.dart';

/// 应用聚合数据库
/// 使用 channelType + appId 作为复合主键来统一管理所有渠道的应用
@Database(version: 1, entities: [AddedAppInfo])
abstract class AppAggregatorDatabase extends FloorDatabase {
  AddedAppDao get addedAppDao;

  /// 创建数据库实例
  static Future<AppAggregatorDatabase> create() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = path.join(dir.path, 'aggregated_apps.db');

    return await $FloorAppAggregatorDatabase
        .databaseBuilder(dbPath)
        .build();
  }
}

/// 已添加应用实体
/// 使用 channelType + appId 作为复合主键
@Entity(tableName: 'added_apps', primaryKeys: ['channelId', 'appId'])
class AddedAppInfo {
  /// 渠道类型代码
  final String channelId;

  /// 应用 ID（在对应渠道中的 ID）
  final String appId;

  /// 应用名称
  final String appName;

  /// 图标 URL
  final String? iconUrl;

  /// 描述
  final String? description;

  /// 分类
  final String? category;

  /// 添加时间（毫秒时间戳）
  final int addTime;

  /// 排序权重
  final int sortOrder;

  AddedAppInfo({
    required this.channelId,
    required this.appId,
    required this.appName,
    this.iconUrl,
    this.description,
    this.category,
    int? addTime,
    this.sortOrder = 0,
  }) : addTime = addTime ?? DateTime.now().millisecondsSinceEpoch;

  /// 从 Map 创建
  factory AddedAppInfo.fromJson(Map<String, dynamic> json) {
    return AddedAppInfo(
      channelId: json['channelId'] as String,
      appId: json['appId'] as String,
      appName: json['appName'] as String,
      iconUrl: json['iconUrl'] as String?,
      description: json['description'] as String?,
      category: json['category'] as String?,
      addTime: json['addTime'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      sortOrder: json['sortOrder'] as int? ?? 0,
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toJson() {
    return {
      'channelId': channelId,
      'appId': appId,
      'appName': appName,
      'iconUrl': iconUrl,
      'description': description,
      'category': category,
      'addTime': addTime,
      'sortOrder': sortOrder,
    };
  }
}

/// 已添加应用 DAO
@dao
abstract class AddedAppDao {
  /// 添加应用（使用 REPLACE 策略处理复合主键冲突）
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> insertApp(AddedAppInfo app);

  /// 批量添加应用
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> insertApps(List<AddedAppInfo> apps);

  /// 删除应用（通过 channelId + appId）
  @Query('DELETE FROM added_apps WHERE channelId = :channelId AND appId = :appId')
  Future<void> removeApp(String channelId, String appId);

  /// 获取所有已添加应用（按添加时间倒序）
  @Query('SELECT * FROM added_apps ORDER BY addTime DESC')
  Future<List<AddedAppInfo>> getAllAddedApps();

  /// 获取指定渠道的已添加应用
  @Query('SELECT * FROM added_apps WHERE channelId = :channelId ORDER BY addTime DESC')
  Future<List<AddedAppInfo>> getAppsByChannel(String channelId);

  /// 检查应用是否存在（通过 channelId + appId）
  @Query('SELECT * FROM added_apps WHERE channelId = :channelId AND appId = :appId LIMIT 1')
  Future<AddedAppInfo?> getApp(String channelId, String appId);

  /// 清空指定渠道的所有应用
  @Query('DELETE FROM added_apps WHERE channelId = :channelId')
  Future<void> clearChannel(String channelId);

  /// 清空所有应用
  @Query('DELETE FROM added_apps')
  Future<void> clearAll();

  /// 获取应用总数
  @Query('SELECT COUNT(*) FROM added_apps')
  Future<int?> getTotalCount();

  /// 获取指定渠道的应用数量
  @Query('SELECT COUNT(*) FROM added_apps WHERE channelId = :channelId')
  Future<int?> getCountByChannel(String channelId);
}

/// 应用聚合数据库管理器
class AppAggregatorDatabaseManager {
  static AppAggregatorDatabase? _instance;

  static Future<AppAggregatorDatabase> get instance async {
    if (_instance != null) return _instance!;
    _instance = await create();
    return _instance!;
  }

  static Future<AppAggregatorDatabase> create() async {
    final database = await AppAggregatorDatabase.create();
    appLog.info('AppAggregatorDatabase: 数据库初始化成功');
    return database;
  }

  /// 关闭数据库
  static Future<void> close() async {
    if (_instance != null) {
      await _instance!.close();
      _instance = null;
    }
  }
}
