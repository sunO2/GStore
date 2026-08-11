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
///
/// v5：新增 added_app_tags 用户标签表（(channelId, appId) 关联），
/// 跨渠道统一为应用打自定义标签（渠道自带分类 + 用户标签合并展示）。
@Database(version: 5, entities: [AddedAppInfo, AddedAppTag])
abstract class AppAddedDatabase extends FloorDatabase {
  AddedAppDao get addedAppDao;

  /// 用户标签 DAO
  AppTagDao get appTagDao;

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
        .addMigrations([
          _migration1to2,
          _migration2to3,
          _migration3to4,
          _migration4to5,
        ])
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

  /// v4 → v5：新增用户标签表（(channelId, appId, tag) 复合主键）
  static final _migration4to5 = Migration(4, 5, (database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS added_app_tags (
        channelId TEXT NOT NULL,
        appId TEXT NOT NULL,
        tag TEXT NOT NULL,
        addTime INTEGER NOT NULL,
        PRIMARY KEY (channelId, appId, tag)
      )
    ''');
  });
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

/// 用户自定义标签实体
/// 按 (channelId, appId) 关联已添加应用（与 added_apps 引用表同构），
/// 跨渠道统一为应用打标签；标签与渠道自带分类合并后供首页分类展示。
/// 复合主键 (channelId, appId, tag) 经 @Entity(primaryKeys:) 声明
/// （Floor 复合主键约定：primaryKeys 字段列表，而非多个 @PrimaryKey 注解）。
@Entity(tableName: 'added_app_tags', primaryKeys: ['channelId', 'appId', 'tag'])
class AddedAppTag {
  /// 渠道类型
  final String channelId;

  /// 应用 ID（在对应渠道中的 ID，与 added_apps.appId 一致）
  final String appId;

  /// 用户自定义标签（可复用 AppCategory.id 或自由输入）
  final String tag;

  /// 添加时间（毫秒时间戳）
  final int addTime;

  AddedAppTag({
    required this.channelId,
    required this.appId,
    required this.tag,
    int? addTime,
  }) : addTime = addTime ?? DateTime.now().millisecondsSinceEpoch;
}

/// 用户标签 DAO
@dao
abstract class AppTagDao {
  /// 获取指定应用的全部标签
  @Query('SELECT * FROM added_app_tags WHERE channelId = :channelId AND appId = :appId ORDER BY addTime')
  Future<List<AddedAppTag>> getTags(String channelId, String appId);

  /// 获取指定渠道的全部标签
  @Query('SELECT * FROM added_app_tags WHERE channelId = :channelId')
  Future<List<AddedAppTag>> getTagsByChannel(String channelId);

  /// 获取全部标签
  @Query('SELECT * FROM added_app_tags')
  Future<List<AddedAppTag>> getAllTags();

  /// 添加单个标签（复合主键冲突时 replace）
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> insertTag(AddedAppTag tag);

  /// 批量添加标签
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> insertTags(List<AddedAppTag> tags);

  /// 移除单个标签
  @Query('DELETE FROM added_app_tags WHERE channelId = :channelId AND appId = :appId AND tag = :tag')
  Future<void> removeTag(String channelId, String appId, String tag);

  /// 移除应用的全部标签（应用从首页移除时联动清理）
  @Query('DELETE FROM added_app_tags WHERE channelId = :channelId AND appId = :appId')
  Future<void> removeTagsOfApp(String channelId, String appId);

  /// 清空指定渠道的所有标签
  @Query('DELETE FROM added_app_tags WHERE channelId = :channelId')
  Future<void> clearChannel(String channelId);

  /// 清空所有标签
  @Query('DELETE FROM added_app_tags')
  Future<void> clearAll();
}
