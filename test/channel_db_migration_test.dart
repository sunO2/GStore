import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// channel_added_app 复合主键迁移 (v3 → v4) 测试
///
/// v3 表结构：`PRIMARY KEY (appId)`，同 appId 跨渠道互相覆盖（缺陷）。
/// v4 目标：`PRIMARY KEY (channelCode, appId)`，同 appId 跨渠道可共存。
///
/// v3 建表 SQL 与旧版 channel_database.g.dart:99 生成的
/// `CREATE TABLE IF NOT EXISTS channel_added_app` 列定义保持一致。
const v3CreateTableSql = '''
CREATE TABLE IF NOT EXISTS `channel_added_app` (
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
  PRIMARY KEY (`appId`)
)
''';

/// 在 ffi isolate 内执行：覆盖 sqlite3 动态库加载
/// （Linux 仅有 libsqlite3.so.0，无 .so 符号链接；必须经 ffiInit 传入 isolate）
void _ffiInit() {
  open.overrideFor(OperatingSystem.linux,
      () => DynamicLibrary.open('libsqlite3.so.0'));
}

/// 向 channel_added_app 插入一行（v3 表结构，字段与旧 .g.dart:99 一致）
Future<void> insertV3Row(
  Database db, {
  required String appId,
  required String channelCode,
  required String name,
}) {
  return db.insert(
    'channel_added_app',
    {
      'appId': appId,
      'name': name,
      'user': '',
      'repositories': '',
      'apprepo': null,
      'icon': '',
      'description': '',
      'category': null,
      'addTime': 1000,
      'channelCode': channelCode,
      'extra': null,
    },
    conflictAlgorithm: ConflictAlgorithm.abort,
  );
}

/// 行数查询
Future<int> rowCount(Database db) async {
  final result = await db.rawQuery('SELECT COUNT(*) AS c FROM channel_added_app');
  return result.first['c'] as int;
}

void main() {
  late Database db;
  late DatabaseFactory _ffiFactory;

  setUpAll(() {
    _ffiFactory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  });

  setUp(() async {
    // 注意：不使用共享的 inMemoryDatabasePath（':memory:'）——sqflite_common_ffi
    // 将其映射为 .dart_tool 下公共文件，多个测试文件并行 isolate 删除/重建会
    // 互相踩踏（database is locked）；本文件独享一个文件路径，delete+open
    // 只影响本文件，保证用例隔离。
    final dbFile = p.join(
        await _ffiFactory.getDatabasesPath(), 'channel_db_migration_test.db');
    await _ffiFactory.deleteDatabase(dbFile);

    db = await _ffiFactory.openDatabase(
      dbFile,
      options: sqflite.OpenDatabaseOptions(version: 3),
    );
    await db.execute(v3CreateTableSql);
  });

  tearDown(() async {
    await db.close();
    // 清理本文件独占的 db 文件，避免在 .dart_tool 下残留
    await _ffiFactory.deleteDatabase(
        p.join(await _ffiFactory.getDatabasesPath(), 'channel_db_migration_test.db'));
  });

  group('迁移前缺陷复现（v3 表 PRIMARY KEY(appId)）', () {
    test('同 appId 跨渠道共存被 PK 拒绝（RED 证据）', () async {
      // 两条不同 appId 可共存
      await insertV3Row(db, appId: 'com.a', channelCode: 'github', name: 'A');
      await insertV3Row(db, appId: 'com.b', channelCode: 'vivo', name: 'B');
      expect(await rowCount(db), 2);

      // 期望行为：同 appId 不同渠道共存 —— 在 v3 表上必然失败（PK 冲突）
      await expectLater(
        insertV3Row(db, appId: 'com.a', channelCode: 'vivo', name: 'A'),
        throwsA(isA<DatabaseException>()),
        reason: 'v3 主键仅 appId，同 appId 跨渠道插入触发 UNIQUE 冲突（迁移前缺陷）',
      );
    });
  });

  group('migration3to4（v3 → v4 复合主键）', () {
    test('迁移后行保留、复合主键生效、同 appId 跨渠道共存、重复插入 replace 覆盖', () async {
      // 迁移前：两条不同 appId 的记录（com.a/github、com.b/vivo）
      await insertV3Row(db, appId: 'com.a', channelCode: 'github', name: 'A from GitHub');
      await insertV3Row(db, appId: 'com.b', channelCode: 'vivo', name: 'B from Vivo');

      // 执行 v3 → v4 迁移
      await migration3to4(db);

      // 1. 行数保留（2 条不丢）
      expect(await rowCount(db), 2, reason: '迁移不得丢数据');

      // 2. 复合主键生效：PRAGMA table_info 中 channelCode 与 appId 均为主键列，
      //    channelCode 是第 1 键（pk=1）、appId 第 2 键（pk=2）
      final cols = await db.rawQuery('PRAGMA table_info(channel_added_app)');
      final pkCols = <String, int>{
        for (final c in cols)
          if (((c['pk'] as int?) ?? 0) > 0) c['name'] as String: c['pk'] as int,
      };
      expect(pkCols.keys.toSet(), {'channelCode', 'appId'},
          reason: '迁移后主键必须为 (channelCode, appId) 复合主键');
      expect(pkCols['channelCode'], 1);
      expect(pkCols['appId'], 2);

      // 建表 SQL 文本直接确认复合主键定义
      final tableSql = (await db.rawQuery(
              "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'channel_added_app'"))
          .first['sql'] as String;
      expect(tableSql, contains('PRIMARY KEY (`channelCode`, `appId`)'));

      // 3. A1 核心行为：迁移后同 appId 跨渠道可共存（com.a 在 github 与 vivo 同时存在）
      await insertV3Row(db, appId: 'com.a', channelCode: 'vivo', name: 'A from Vivo');
      expect(await rowCount(db), 3,
          reason: '同 appId 跨渠道应共存，不再被单列 appId 主键拒绝');
      final vivoA = await db.rawQuery(
          "SELECT * FROM channel_added_app WHERE appId = 'com.a' AND channelCode = 'vivo'");
      expect(vivoA, hasLength(1));

      // 4. 重复插入同 (channelCode, appId) 走 replace 覆盖（与 DAO OnConflictStrategy.replace 一致）
      await db.rawInsert(
          "INSERT OR REPLACE INTO channel_added_app (appId, name, user, repositories, apprepo, icon, description, category, addTime, channelCode, extra) "
          "VALUES ('com.a', 'A renamed', '', '', NULL, '', '', NULL, 1000, 'github', NULL)");
      expect(await rowCount(db), 3, reason: '同 (channelCode, appId) 重复插入应覆盖而非新增');
      final replaced = await db.rawQuery(
          "SELECT name FROM channel_added_app WHERE appId = 'com.a' AND channelCode = 'github'");
      expect(replaced.single['name'], 'A renamed', reason: 'replace 语义应更新整行');
    });
  });
}
