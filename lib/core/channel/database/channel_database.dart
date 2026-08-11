import 'dart:async';

import 'package:floor/floor.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/logger/LogManager.dart';

part 'channel_database.g.dart';

/// 渠道应用数据库
/// 每个渠道维护自己添加的应用列表
@Database(version: 4, entities: [ChannelAddedApp])
abstract class ChannelDatabase extends FloorDatabase {
  ChannelAddedAppDao get dao;

  /// 创建数据库实例
  static Future<ChannelDatabase> create() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = path.join(dir.path, 'channel_apps.db');

    return await $FloorChannelDatabase
        .databaseBuilder(dbPath)
        .addMigrations([
          // v1 -> v2：添加 extra 列
          Migration(1, 2, (database) async {
            await database.execute(
              'ALTER TABLE channel_added_app ADD COLUMN extra TEXT',
            );
            appLog.info('ChannelDatabase: 已添加 extra 列');
          }),
          // v2 -> v3：添加 apprepo 列（GitHub 渠道仓库完整名）
          Migration(2, 3, (database) async {
            await database.execute(
              'ALTER TABLE channel_added_app ADD COLUMN apprepo TEXT',
            );
            appLog.info('ChannelDatabase: 已添加 apprepo 列');
          }),
          // v3 -> v4：重建表为复合主键 (channelCode, appId)，
          // 同 appId 跨渠道不再互相覆盖（A1）
          Migration(3, 4, migration3to4),
        ])
        .addCallback(Callback(
          onCreate: (database, version) async {
            appLog.info('ChannelDatabase: 创建数据库，版本 $version');
          },
          onOpen: (database) async {
            appLog.info('ChannelDatabase: 打开数据库');
          },
        ))
        .build();
  }
}

/// v3 → v4 迁移：channel_added_app 主键从单列 appId 重建为复合主键 (channelCode, appId)
///
/// 目的：同 appId 跨渠道应用可共存（GitHub 渠道 appId 为 owner/repo，
/// 与 LocalDb/vivo 渠道包名可能相同，旧主键导致互相覆盖丢数据）。
///
/// 策略：重建表迁移（与 AppAddedDatabase v2→v3 先例一致）——
/// 建新表（列与现表完全一致，主键为复合）→ 拷贝数据 → 删旧表 → 重命名。
/// 注意：SQL 无 IF NOT EXISTS 守卫，Floor 按数据库版本号只执行一次，
/// 重复执行报 table exists 属预期行为，重跑幂等由版本号机制保证。
Future<void> migration3to4(sqflite.Database database) async {
  await database.execute('''
    CREATE TABLE `channel_added_app_new` (
      `appId` TEXT NOT NULL,
      `name` TEXT NOT NULL,
      `user` TEXT NOT NULL,
      `repositories` TEXT NOT NULL,
      `apprepo` TEXT,
      `icon` TEXT NOT NULL,
      `description` TEXT NOT NULL,
      `category` TEXT,
      `addTime` INTEGER NOT NULL,
      `channelCode` TEXT NOT NULL,
      `extra` TEXT,
      PRIMARY KEY (`channelCode`, `appId`)
    )
  ''');
  await database.execute('''
    INSERT INTO channel_added_app_new (appId, name, user, repositories, apprepo, icon, description, category, addTime, channelCode, extra)
    SELECT appId, name, user, repositories, apprepo, icon, description, category, addTime, channelCode, extra FROM channel_added_app
  ''');
  await database.execute('DROP TABLE channel_added_app');
  await database
      .execute('ALTER TABLE channel_added_app_new RENAME TO channel_added_app');
  appLog.info(
      'ChannelDatabase: v3→v4 迁移完成，channel_added_app 复合主键 (channelCode, appId)');
}

/// 渠道数据库单例
class ChannelDatabaseManager {
  static ChannelDatabase? _instance;

  /// 正在创建中的 future（并发保护：多个调用方同时请求时只建一次库）
  static Future<ChannelDatabase>? _creating;

  static Future<ChannelDatabase> get instance {
    final existing = _instance;
    if (existing != null) return Future.value(existing);
    // 已有正在创建的 future → 复用（避免并发重复建库）
    final inFlight = _creating;
    if (inFlight != null) return inFlight;
    final creating = create();
    _creating = creating;
    return creating.whenComplete(() {
      _creating = null;
    });
  }

  static Future<ChannelDatabase> create() async {
    final database = await ChannelDatabase.create();
    _instance = database;
    appLog.info('ChannelDatabase: 数据库初始化成功');
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
