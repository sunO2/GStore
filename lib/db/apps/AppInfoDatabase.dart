// required package imports
import 'dart:async';
import 'dart:io';
import 'package:floor/floor.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/db/apps/AppInfoDao.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:gstore/db/apps/AppInfo.dart';

part 'AppInfoDatabase.g.dart';

@TypeConverters([CategoryConverter])
@Database(version: 1, entities: [AppInfo, AppInfoConfig, AppCategory])
abstract class AppInfoDatabase extends FloorDatabase {
  AppInfoDao get dao;
}

class Builder extends _$AppInfoDatabaseBuilder {
  Builder(super.name);

  @override
  Future<AppInfoDatabase> build() async {
    // 使用应用私有目录（Android 11+ 外部共享目录受作用域存储限制）
    final dir = await getApplicationDocumentsDirectory();
    var path = File("${dir.path}/$name");

    final database = _$AppInfoDatabase();
    database.database = await database.open(
      path.path,
      _migrations,
      _callback,
    );

    // 初始化 FTS5 全文搜索索引（失败不影响数据库使用，仅降级为 LIKE 搜索）
    try {
      await _setupFts5(database.database);
    } catch (e) {
      debugPrint('AppInfoDatabase: FTS5 初始化失败（降级为 LIKE 搜索）- $e');
    }
    return database;
  }

  /// 初始化 FTS5 全文搜索
  /// 创建虚拟表 + 触发器同步 apps 表，并回填已有数据
  Future<void> _setupFts5(sqflite.DatabaseExecutor db) async {
    // 创建 FTS5 虚拟表
    // unicode61 兼容所有 SQLite 版本；查询用前缀匹配（"词"*）
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS apps_fts USING fts5(
        appId UNINDEXED,
        name,
        des,
        content=''
      )
    ''');

    // 创建触发器：apps 表插入/更新/删除时同步
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS apps_fts_insert AFTER INSERT ON apps BEGIN
        INSERT INTO apps_fts(rowid, appId, name, des)
        VALUES (new.rowid, new.appId, new.name, new.des);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS apps_fts_delete AFTER DELETE ON apps BEGIN
        DELETE FROM apps_fts WHERE rowid = old.rowid;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS apps_fts_update AFTER UPDATE ON apps BEGIN
        DELETE FROM apps_fts WHERE rowid = old.rowid;
        INSERT INTO apps_fts(rowid, appId, name, des)
        VALUES (new.rowid, new.appId, new.name, new.des);
      END
    ''');

    // 回填已有数据（幂等：检查 apps_fts 是否为空）
    final count = await db.rawQuery('SELECT count(*) AS c FROM apps_fts');
    final c = count.isNotEmpty ? (count.first['c'] as int? ?? 0) : 0;
    if (c == 0) {
      await db.execute('''
        INSERT INTO apps_fts(rowid, appId, name, des)
        SELECT rowid, appId, name, des FROM apps
      ''');
    }
  }
}

class CategoryConverter extends TypeConverter<List<String>?, String?> {
  @override
  List<String> decode(String? databaseValue) {
    return databaseValue?.split(",") ?? [];
  }

  @override
  String encode(List<String>? value) {
    return value?.join(",") ?? "";
  }
}
