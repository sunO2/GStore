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
@Database(version: 3, entities: [ChannelAddedApp])
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
