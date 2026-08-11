import 'dart:async';

import 'package:floor/floor.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

part 'AppAddedDatabase.g.dart';

/// 已添加应用数据库
///
/// v3：聚合库瘦身为"引用表"，仅存渠道 + 应用 ID + 聚合元数据，
/// 应用信息（名称/图标/描述/包名）统一由渠道实时查询（含 metadata 覆盖），
/// 渠道数据变更后无需同步聚合库。
///
/// v4：added_apps 增加 UNIQUE(channelId, appId) 唯一索引，
/// 兜底防重复添加（addApp 先查后插 + 索引约束双保险）。
@Database(version: 4, entities: [AddedAppInfo])
abstract class AppAddedDatabase extends FloorDatabase {
  AddedAppDao get addedAppDao;

  /// 创建数据库实例
  /// [dbPath] 可注入数据库文件路径（测试用内存库等）
  static Future<AppAddedDatabase> create({String? dbPath}) async {
    String dbPathValue = dbPath ?? '';
    if (dbPathValue.isEmpty) {
      final dir = await getApplicationDocumentsDirectory();
      dbPathValue = path.join(dir.path, 'added_apps.db');
    }

    return await $FloorAppAddedDatabase
        .databaseBuilder(dbPathValue)
        .addMigrations([_migration1to2, _migration2to3, _migration3to4])
        .build();
  }

  /// v1 → v2：新增 packageName 字段（历史迁移，保留兼容）
  static final _migration1to2 = Migration(1, 2, (database) async {
    await database.execute('ALTER TABLE added_apps ADD COLUMN packageName TEXT');
  });

  /// v2 → v3：重建表，丢弃应用信息冗余字段（appName/iconUrl/description/category/packageName），
  /// 仅保留引用字段：id / channelId / appId / addTime / sortOrder / isEnabled
  static final _migration2to3 = Migration(2, 3, (database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS added_apps_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        channelId TEXT NOT NULL,
        appId TEXT NOT NULL,
        addTime INTEGER NOT NULL,
        sortOrder INTEGER NOT NULL,
        isEnabled INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      INSERT INTO added_apps_new (id, channelId, appId, addTime, sortOrder, isEnabled)
      SELECT id, channelId, appId, addTime, sortOrder, isEnabled FROM added_apps
    ''');
    await database.execute('DROP TABLE added_apps');
    await database.execute('ALTER TABLE added_apps_new RENAME TO added_apps');
  });

  /// v3 → v4：先去重历史重复记录，再建 UNIQUE(channelId, appId) 唯一索引
  /// （索引名与 Floor 生成的 onCreate 一致，保证新装库与迁移库结构等价）
  static final _migration3to4 = Migration(3, 4, migration3to4);
}

/// v3 → v4 迁移：added_apps 唯一约束 UNIQUE(channelId, appId)
///
/// 1. 去重：同 (channelId, appId) 保留 id 最大（最新）的一条；
/// 2. 建唯一索引（名称与 Floor 生成的 `index_added_apps_channelId_appId` 一致）。
Future<void> migration3to4(sqflite.Database database) async {
  await database.execute('''
    DELETE FROM added_apps
    WHERE id NOT IN (SELECT MAX(id) FROM added_apps GROUP BY channelId, appId)
  ''');
  await database.execute('''
    CREATE UNIQUE INDEX IF NOT EXISTS `index_added_apps_channelId_appId`
    ON added_apps (channelId, appId)
  ''');
}

/// 已添加应用实体（引用表）
/// 仅保存渠道 + 应用 ID + 聚合元数据；应用信息由渠道实时查询
@Entity(
  tableName: 'added_apps',
  indices: [Index(value: ['channelId', 'appId'], unique: true)],
)
class AddedAppInfo {
  @PrimaryKey(autoGenerate: true)
  final int? id;

  /// 渠道类型
  final String channelId;

  /// 应用 ID（在对应渠道中的 ID，metadata 收录时为真实包名）
  final String appId;

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
