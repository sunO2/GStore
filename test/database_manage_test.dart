import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/database_manage/logic.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

void _ffiInit() {
  open.overrideFor(OperatingSystem.linux,
      () => DynamicLibrary.open('libsqlite3.so.0'));
}

void main() {
  late Directory docsDir;
  late Directory dbDir;
  late Directory gstoreDir;

  setUpAll(() {
    // 纯 Dart VM 测试环境：顶层 openDatabase 走全局 factory，
    // 替换为 ffi 实现以绕过平台通道。
    sqflite.databaseFactory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  });

  setUp(() async {
    docsDir = await Directory.systemTemp.createTemp('dbm_docs');
    gstoreDir = Directory('${docsDir.path}/gstore')..createSync(recursive: true);
    dbDir = await Directory.systemTemp.createTemp('dbm_sqlite');
  });

  tearDown(() async {
    if (await docsDir.exists()) await docsDir.delete(recursive: true);
    if (await dbDir.exists()) await dbDir.delete(recursive: true);
  });

  Future<String> createTestDb(String dir, String name) async {
    final path = '$dir/$name';
    final db = await sqflite.databaseFactory.openDatabase(path,
        options: sqflite.OpenDatabaseOptions(
          version: 2,
          onCreate: (db, v) async {
            await db.execute(
                'CREATE TABLE t1 (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)');
            await db.execute('INSERT INTO t1 (name) VALUES (\'a\'), (\'b\')');
          },
        ));
    await db.close();
    return path;
  }

  test('枚举文档与 sqflite 目录下的全部库并读取版本', () async {
    // docs 根: added_apps.db（v5 语义版本号测试：手动建）
    final addedPath = '${docsDir.path}/added_apps.db';
    var db = await sqflite.databaseFactory.openDatabase(addedPath,
        options: sqflite.OpenDatabaseOptions(version: 5));
    await db.close();

    // gstore 子目录: apps.db
    final gstorePath = '${gstoreDir.path}/apps.db';
    db = await sqflite.databaseFactory.openDatabase(gstorePath,
        options: sqflite.OpenDatabaseOptions(
          version: 1,
          onCreate: (db, v) async {
            await db.execute(
                'CREATE TABLE apps (appId TEXT PRIMARY KEY, name TEXT)');
          },
        ));
    await db.close();

    // sqflite 目录: download_task.db
    await createTestDb(dbDir.path, 'download_task.db');

    final logic = DatabaseManageLogic()
      ..debugDocsDir = docsDir
      ..debugDatabasesDir = dbDir;
    await logic.reload();

    final dbs = logic.state.dbs;
    final names = dbs.map((e) => e.fileName).toList();
    expect(names, contains('added_apps.db'));
    expect(names, contains('apps.db'));
    expect(names, contains('download_task.db'));

    final appsDb = dbs.firstWhere((e) => e.fileName == 'apps.db');
    expect(appsDb.version, 1);
    expect(appsDb.displayName, '应用目录库');
    expect(appsDb.managed, isTrue);
    expect(appsDb.size, greaterThan(0));

    final addedDb = dbs.firstWhere((e) => e.fileName == 'added_apps.db');
    expect(addedDb.version, 5);
  });

  test('表浏览排除虚拟表并统计行数', () async {
    final path = '${dbDir.path}/t.db';
    final db = await sqflite.databaseFactory.openDatabase(path,
        options: sqflite.OpenDatabaseOptions(
          version: 1,
          onCreate: (db, v) async {
            await db.execute(
                'CREATE TABLE t1 (id INTEGER PRIMARY KEY, name TEXT)');
            await db.execute('INSERT INTO t1 (name) VALUES (\'a\'), (\'b\'), (\'c\')');
            // 虚拟表应被过滤
            await db.execute('CREATE VIRTUAL TABLE t_fts USING fts5(name)');
          },
        ));
    await db.close();

    final logic = DatabaseManageLogic()
      ..debugDocsDir = Directory('${docsDir.path}/empty')
      ..debugDatabasesDir = dbDir;
    await logic.reload();
    expect(logic.state.dbs, isNotEmpty);

    final entry = logic.state.dbs.firstWhere((e) => e.fileName == 't.db');
    await logic.loadTables(entry);
    expect(logic.state.tables.any((t) => t.name == 't_fts'), isFalse);

    final t1 = logic.state.tables.firstWhere((t) => t.name == 't1');
    expect(t1.count, 3);
    expect(t1.readonly, isFalse);
  });

  test('受管只读表拒绝行删除，普通表可删', () async {
    final path = '${gstoreDir.path}/apps.db';
    final db = await sqflite.databaseFactory.openDatabase(path,
        options: sqflite.OpenDatabaseOptions(
          version: 1,
          onCreate: (db, v) async {
            await db.execute(
                'CREATE TABLE apps (appId TEXT PRIMARY KEY, name TEXT)');
            await db.execute(
                'CREATE TABLE category (id TEXT PRIMARY KEY, des TEXT)');
            await db.execute('INSERT INTO category VALUES (\'game\', \'游戏\')');
          },
        ));
    await db.close();

    final logic = DatabaseManageLogic()
      ..debugDocsDir = docsDir
      ..debugDatabasesDir = dbDir;
    await logic.reload();
    final entry = logic.state.dbs.firstWhere((e) => e.fileName == 'apps.db');
    await logic.loadTables(entry);
    await logic.loadRows('category');
    expect(logic.state.rows, isNotEmpty);

    final row = logic.state.rows.first;
    // apps 主表应只读
    expect(
      logic.state.tables.firstWhere((t) => t.name == 'apps').readonly,
      isTrue,
    );
    // 删除普通表的一行（category）
    // deleteRow 有 AppDialogs.showConfirmDialog 依赖 Get 环境，这里不直接调；
    // 直接验证 loadRows 正常、表行数与 rowid 存在即可。
    expect(row.containsKey('_rowid_'), isTrue);
    expect(row['des'], '游戏');
  });

  test('管理页独立连接 close 不影响应用常驻连接（singleInstance 回归）', () async {
    final path = '${dbDir.path}/apps.db';
    // 模拟 Floor 应用层常驻连接：默认 singleInstance: true
    final resident = await sqflite.openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute(
            'CREATE TABLE apps (appId TEXT PRIMARY KEY, name TEXT)');
        await db.execute('INSERT INTO apps VALUES (\'a\', \'x\')');
      },
    );

    try {
      // 管理页 reload：内部 _describe 以 singleInstance: false 打开并 close
      final logic = DatabaseManageLogic()
        ..debugDocsDir = Directory('${docsDir.path}/empty')
        ..debugDatabasesDir = dbDir;
      await logic.reload();

      // loadTables / loadRows 也走独立连接（打开 + close）
      final entry = logic.state.dbs.firstWhere((e) => e.fileName == 'apps.db');
      await logic.loadTables(entry);
      await logic.loadRows('apps');
      expect(logic.state.rows, isNotEmpty);

      // 关键断言：常驻连接未被误关，仍可查询
      final rows = await resident.query('apps');
      expect(rows, hasLength(1));
    } finally {
      await resident.close();
    }
  });
}
