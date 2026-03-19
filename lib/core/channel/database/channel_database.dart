import 'dart:async';

import 'package:floor/floor.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';

part 'channel_database.g.dart';

/// 渠道应用数据库
/// 每个渠道维护自己添加的应用列表
@Database(version: 2, entities: [ChannelAddedApp])
abstract class ChannelDatabase extends FloorDatabase {
  ChannelAddedAppDao get dao;

  /// 创建数据库实例
  static Future<ChannelDatabase> create() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = path.join(dir.path, 'channel_apps.db');

    return await $FloorChannelDatabase
        .databaseBuilder(dbPath)
        .addCallback(Callback(
          onCreate: (database, version) async {
            debugPrint('ChannelDatabase: 创建数据库，版本 $version');
          },
          onUpgrade: (database, startVersion, endVersion) async {
            debugPrint('ChannelDatabase: 升级数据库 $startVersion -> $endVersion');
            // 从版本 1 升级到版本 2：添加 extra 列
            if (startVersion == 1 && endVersion == 2) {
              await database.execute(
                'ALTER TABLE channel_added_app ADD COLUMN extra TEXT',
              );
              debugPrint('ChannelDatabase: 已添加 extra 列');
            }
          },
          onOpen: (database) async {
            debugPrint('ChannelDatabase: 打开数据库');
          },
        ))
        .build();
  }
}

/// 渠道数据库单例
class ChannelDatabaseManager {
  static ChannelDatabase? _instance;

  static Future<ChannelDatabase> get instance async {
    if (_instance != null) return _instance!;
    _instance = await create();
    return _instance!;
  }

  static Future<ChannelDatabase> create() async {
    final database = await ChannelDatabase.create();
    debugPrint('ChannelDatabase: 数据库初始化成功');
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
