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
@Database(version: 1, entities: [ChannelAddedApp])
abstract class ChannelDatabase extends FloorDatabase {
  ChannelAddedAppDao get dao;

  /// 创建数据库实例
  static Future<ChannelDatabase> create() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = path.join(dir.path, 'channel_apps.db');

    return await $FloorChannelDatabase
        .databaseBuilder(dbPath)
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
