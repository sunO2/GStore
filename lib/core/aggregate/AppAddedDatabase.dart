import 'dart:async';

import 'package:floor/floor.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

part 'AppAddedDatabase.g.dart';

/// 已添加应用数据库
@Database(version: 1, entities: [AddedAppInfo])
abstract class AppAddedDatabase extends FloorDatabase {
  AddedAppDao get addedAppDao;

  /// 创建数据库实例
  static Future<AppAddedDatabase> create() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = path.join(dir.path, 'added_apps.db');

    return await $FloorAppAddedDatabase
        .databaseBuilder(dbPath)
        .build();
  }
}

/// 已添加应用实体
@Entity(tableName: 'added_apps')
class AddedAppInfo {
  @PrimaryKey(autoGenerate: true)
  final int? id;

  /// 渠道类型
  final String channelId;

  /// 应用 ID
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

  /// 是否启用
  final bool isEnabled;

  AddedAppInfo({
    this.id,
    required this.channelId,
    required this.appId,
    required this.appName,
    this.iconUrl,
    this.description,
    this.category,
    int? addTime,
    this.sortOrder = 0,
    this.isEnabled = true,
  }) : addTime = addTime ?? DateTime.now().millisecondsSinceEpoch;
}

/// 已添加应用 DAO
@dao
abstract class AddedAppDao {
  /// 获取所有已添加应用（按添加时间倒序）
  @Query('SELECT * FROM added_apps ORDER BY addTime DESC')
  Future<List<AddedAppInfo>> getAllAddedApps();

  /// 获取指定渠道的已添加应用
  @Query('SELECT * FROM added_apps WHERE channelId = :channelId ORDER BY addTime DESC')
  Future<List<AddedAppInfo>> getAppsByChannel(String channelId);

  /// 检查应用是否已添加
  @Query('SELECT * FROM added_apps WHERE channelId = :channelId AND appId = :appId LIMIT 1')
  Future<AddedAppInfo?> getApp(String channelId, String appId);

  /// 添加应用
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<int> insertApp(AddedAppInfo app);

  /// 批量添加应用
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<List<int>> insertApps(List<AddedAppInfo> apps);

  /// 移除应用
  @Query('DELETE FROM added_apps WHERE channelId = :channelId AND appId = :appId')
  Future<void> removeApp(String channelId, String appId);

  /// 清空指定渠道的所有应用
  @Query('DELETE FROM added_apps WHERE channelId = :channelId')
  Future<void> clearChannel(String channelId);

  /// 清空所有应用
  @Query('DELETE FROM added_apps')
  Future<void> clearAll();

  /// 更新应用信息
  @Update(onConflict: OnConflictStrategy.replace)
  Future<void> updateApp(AddedAppInfo app);

  /// 更新排序权重
  @Query('UPDATE added_apps SET sortOrder = :sortOrder WHERE id = :id')
  Future<void> updateSortOrder(int id, int sortOrder);

  /// 获取应用总数
  @Query('SELECT COUNT(*) FROM added_apps')
  Future<int?> getTotalCount();

  /// 获取指定渠道的应用数量
  @Query('SELECT COUNT(*) FROM added_apps WHERE channelId = :channelId')
  Future<int?> getCountByChannel(String channelId);
}
