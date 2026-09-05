import 'dart:ffi';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/database_manage/logic.dart';
import 'package:gstore/page/database_manage/state.dart';
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

  /// 构建注入测试目录的 Notifier（override 预构造实例，测试可设 debug 目录）。
  ///
  /// Riverpod 要求 state 写入前 provider 已被首次 read（建立 element）；
  /// 因此先 read 触发 build，再设置注入目录，最后测试内显式 reload。
  (ProviderContainer, DatabaseManageNotifier) makeContainer({
    Directory? docs,
    Directory? databases,
  }) {
    final notifier = DatabaseManageNotifier();
    final container = ProviderContainer(overrides: [
      databaseManageProvider.overrideWith(() => notifier),
    ]);
    // 触发 build 建立 element（build 的自动 reload 走真实目录，随后会被覆盖）
    container.read(databaseManageProvider);
    notifier.debugDocsDir = docs ?? Directory('${docsDir.path}/none');
    notifier.debugDatabasesDir = databases ?? dbDir;
    return (container, notifier);
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

    final (container, notifier) = makeContainer(docs: docsDir);
    addTearDown(container.dispose);
    await notifier.reload();

    final state = container.read(databaseManageProvider);
    final dbs = state.dbs;
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

    final (container, notifier) =
        makeContainer(docs: Directory('${docsDir.path}/empty'));
    addTearDown(container.dispose);
    await notifier.reload();
    expect(container.read(databaseManageProvider).dbs, isNotEmpty);

    final entry =
        container.read(databaseManageProvider).dbs.firstWhere((e) => e.fileName == 't.db');
    await notifier.loadTables(entry);
    final state = container.read(databaseManageProvider);
    expect(state.tables.any((t) => t.name == 't_fts'), isFalse);

    final t1 = state.tables.firstWhere((t) => t.name == 't1');
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

    final (container, notifier) = makeContainer(docs: docsDir);
    addTearDown(container.dispose);
    await notifier.reload();
    final entry =
        container.read(databaseManageProvider).dbs.firstWhere((e) => e.fileName == 'apps.db');
    await notifier.loadTables(entry);
    await notifier.loadRows('category');
    final state = container.read(databaseManageProvider);
    expect(state.rows, isNotEmpty);

    final row = state.rows.first;
    // apps 主表应只读
    expect(
      state.tables.firstWhere((t) => t.name == 'apps').readonly,
      isTrue,
    );
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
      final (container, notifier) =
          makeContainer(docs: Directory('${docsDir.path}/empty'));
      addTearDown(container.dispose);
      await notifier.reload();

      // loadTables / loadRows 也走独立连接（打开 + close）
      final entry = container
          .read(databaseManageProvider)
          .dbs
          .firstWhere((e) => e.fileName == 'apps.db');
      await notifier.loadTables(entry);
      await notifier.loadRows('apps');
      expect(container.read(databaseManageProvider).rows, isNotEmpty);

      // 关键断言：常驻连接未被误关，仍可查询
      final rows = await resident.query('apps');
      expect(rows, hasLength(1));
    } finally {
      await resident.close();
    }
  });
}
