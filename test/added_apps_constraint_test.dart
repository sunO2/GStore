import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// added_apps 唯一约束 UNIQUE(channelId, appId) (v3 → v4) 测试
///
/// A2 目标：聚合库 added_apps 增加 (channelId, appId) 唯一索引，
/// 兜底防止重复添加（AppAggregatorManager.addApp 先查后插 + 索引双保险）。
///
/// v3 表结构（与旧版 AppAddedDatabase.g.dart onCreate 生成的列定义一致，
/// 无唯一索引，重复 (channelId, appId) 可无限插入 —— 缺陷）。
const v3CreateTableSql = '''
CREATE TABLE IF NOT EXISTS `added_apps` (
  `id` INTEGER PRIMARY KEY AUTOINCREMENT,
  `channelId` TEXT NOT NULL,
  `appId` TEXT NOT NULL,
  `addTime` INTEGER NOT NULL,
  `sortOrder` INTEGER NOT NULL,
  `isEnabled` INTEGER NOT NULL
)
''';

/// 向 added_apps 插入一行（ConflictAlgorithm.abort：唯一冲突时抛异常而非静默替换）
Future<void> insertRow(
  sqflite.Database db, {
  required String channelId,
  required String appId,
  int addTime = 1000,
}) {
  return db.insert(
    'added_apps',
    {
      'channelId': channelId,
      'appId': appId,
      'addTime': addTime,
      'sortOrder': 0,
      'isEnabled': 1,
    },
    conflictAlgorithm: ConflictAlgorithm.abort,
  );
}

void main() {
  setUpAll(() {
    // Linux 仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('migration3to4（v3 → v4 迁移路径）', () {
    test('先插重复行再迁移：去重保留 MAX(id)，唯一索引生效后重复插入抛异常', () async {
      // 注意：不使用共享的 inMemoryDatabasePath（':memory:'）——sqflite_common_ffi
      // 将其映射为 .dart_tool 下公共文件，多个测试文件并行 isolate 删除/重建会
      // 互相踩踏（database is locked）；本文件独享一个文件路径，delete+open
      // 只影响本文件，保证用例隔离。
      final v3File = p.join(await databaseFactory.getDatabasesPath(),
          'added_apps_constraint_test.db');
      await databaseFactory.deleteDatabase(v3File);

      // 手工建 v3 表（无唯一索引）
      final db = await databaseFactory.openDatabase(
        v3File,
        options: sqflite.OpenDatabaseOptions(version: 3),
      );
      await db.execute(v3CreateTableSql);

      // 3 行：github/com.a ×2（重复对）+ vivo/com.b ×1
      await insertRow(db, channelId: 'github', appId: 'com.a', addTime: 100);
      await insertRow(db, channelId: 'github', appId: 'com.a', addTime: 200);
      await insertRow(db, channelId: 'vivo', appId: 'com.b', addTime: 300);

      // 执行 v3 → v4 迁移
      await migration3to4(db);

      // 1. 去重：3 行 → 2 行，同 (channelId, appId) 保留 id 最大（最新）的一条
      final rows = await db.query('added_apps');
      expect(rows, hasLength(2), reason: '重复 (github, com.a) 应去重为 1 条');
      final ids = {for (final r in rows) r['id'] as int};
      expect(ids, {2, 3},
          reason: '保留 MAX(id)：github/com.a 保留 id=2，vivo/com.b 保留 id=3');

      // 2. 唯一索引存在（PRAGMA index_list，名称与 Floor 生成的 onCreate 一致）
      final indexList = await db.rawQuery("PRAGMA index_list('added_apps')");
      final uniqueIdx = indexList
          .where((i) => i['name'] == 'index_added_apps_channelId_appId')
          .toList();
      expect(uniqueIdx, hasLength(1),
          reason: '迁移后必须存在 index_added_apps_channelId_appId 唯一索引');
      expect(uniqueIdx.single['unique'], 1, reason: '索引必须为 UNIQUE');

      // 3. 迁移后重复插入同 (channelId, appId) 触发唯一约束（abort → 抛异常）
      await expectLater(
        insertRow(db, channelId: 'github', appId: 'com.a', addTime: 400),
        throwsA(isA<sqflite.DatabaseException>()),
        reason: '唯一索引生效后，重复 (channelId, appId) 插入必须抛 UNIQUE 约束异常',
      );

      await db.close();
    });
  });

  group('全新库（AppAddedDatabase.create v4 onCreate）', () {
    test('重复插入同 (channelId, appId) 触发唯一约束', () async {
      // 注意：不使用共享的 inMemoryDatabasePath（':memory:'）——sqflite_common_ffi
      // 将其映射为 .dart_tool 下公共文件，多个测试文件并行 isolate 删除/重建会
      // 互相踩踏（database is locked）；本文件独享一个文件路径，先删除残留文件
      // 保证 onCreate 按当前 .g.dart（含唯一索引）全新执行，避免旧 schema 残留。
      final dbFile = p.join(await databaseFactory.getDatabasesPath(),
          'added_apps_constraint_test.db');
      await databaseFactory.deleteDatabase(dbFile);

      final db = await AppAddedDatabase.create(dbPath: dbFile);
      addTearDown(db.close);

      // 底层 sqflite 库直接插入（abort，绕过 DAO 的 OnConflictStrategy.replace）
      final sqliteDb = db.database;
      await sqliteDb.insert(
        'added_apps',
        {
          'channelId': 'github',
          'appId': 'com.termux',
          'addTime': 1000,
          'sortOrder': 0,
          'isEnabled': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );

      await expectLater(
        sqliteDb.insert(
          'added_apps',
          {
            'channelId': 'github',
            'appId': 'com.termux',
            'addTime': 2000,
            'sortOrder': 0,
            'isEnabled': 1,
          },
          conflictAlgorithm: ConflictAlgorithm.abort,
        ),
        throwsA(isA<sqflite.DatabaseException>()),
        reason: 'onCreate 唯一索引生效后，同 (channelId, appId) 重复插入必须抛异常',
      );

      await db.close();
    });
  });
}
