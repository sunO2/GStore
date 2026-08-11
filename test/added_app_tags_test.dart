import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// added_app_tags 用户标签表 (v4 → v5) 测试
///
/// 验证：
/// - insertTag/getTags 写入读取往返
/// - 复合主键 (channelId, appId, tag) 冲突时 OnConflictStrategy.replace 幂等
/// - removeTag / removeTagsOfApp 清理
/// - 全新库 onCreate 与 _migration4to5 迁移建表等价（fresh-install == migrated）
void main() {
  setUpAll(() {
    // Linux 仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('AppTagDao（v5 全新库）', () {
    late AppAddedDatabase db;

    setUp(() async {
      // 注意：不使用共享的 inMemoryDatabasePath（':memory:'）——sqflite_common_ffi
      // 将其映射为 .dart_tool 下公共文件，多个测试文件并行 isolate 删除/重建会
      // 互相踩踏（详见 aggregator_parallel_test 的 readonly 竞态）；本文件独享
      // 一个文件路径，delete+create 只影响本文件，保证用例隔离。
      final dbFile = p.join(
          await databaseFactory.getDatabasesPath(), 'added_app_tags_test.db');
      await databaseFactory.deleteDatabase(dbFile);

      db = await AppAddedDatabase.create(dbPath: dbFile);
      addTearDown(db.close);
    });

    test('insertTag + getTags 往返：写入 2 个标签可完整读出（含 addTime）', () async {
      await db.appTagDao.insertTag(
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: '效率工具', addTime: 100),
      );
      await db.appTagDao.insertTag(
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: '我的标签', addTime: 200),
      );

      final tags = await db.appTagDao.getTags('github', 'com.a');
      expect(tags, hasLength(2));
      expect(tags.map((e) => e.tag), ['效率工具', '我的标签'],
          reason: 'ORDER BY addTime：addTime 升序返回');
      expect(tags.first.addTime, 100);
      expect(tags[1].addTime, 200);

      // 不同应用/渠道互不串扰
      final other = await db.appTagDao.getTags('github', 'com.b');
      expect(other, isEmpty);
      final otherChannel = await db.appTagDao.getTags('vivo', 'com.a');
      expect(otherChannel, isEmpty);
    });

    test('复合主键冲突 replace：同 (channelId, appId, tag) 重复插入不产生重复行', () async {
      await db.appTagDao.insertTag(
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: '工具', addTime: 100),
      );
      await db.appTagDao.insertTag(
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: '工具', addTime: 999),
      );

      final tags = await db.appTagDao.getAllTags();
      expect(tags, hasLength(1), reason: '复合主键冲突应 replace 而非新增重复行');
      expect(tags.single.addTime, 999, reason: 'replace 语义：后写覆盖先写');
    });

    test('insertTags 批量写入', () async {
      await db.appTagDao.insertTags([
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: 'a'),
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: 'b'),
        AddedAppTag(channelId: 'github', appId: 'com.b', tag: 'a'),
      ]);

      expect(await db.appTagDao.getAllTags(), hasLength(3));
      expect(await db.appTagDao.getTagsByChannel('github'), hasLength(3));
      expect(await db.appTagDao.getTags('github', 'com.a'), hasLength(2));
    });

    test('removeTag：仅移除指定标签，其余保留', () async {
      await db.appTagDao.insertTags([
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: 'a', addTime: 1),
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: 'b', addTime: 2),
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: 'c', addTime: 3),
      ]);

      await db.appTagDao.removeTag('github', 'com.a', 'b');

      final tags = await db.appTagDao.getTags('github', 'com.a');
      expect(tags.map((e) => e.tag), ['a', 'c']);

      // 其余应用的标签不受影响
      await db.appTagDao.insertTag(
        AddedAppTag(channelId: 'github', appId: 'com.b', tag: 'b'),
      );
      await db.appTagDao.removeTag('github', 'com.a', 'b'); // 已删，幂等
      expect(await db.appTagDao.getTags('github', 'com.b'), hasLength(1));
    });

    test('removeTagsOfApp：清理应用全部标签，其他应用不受影响', () async {
      await db.appTagDao.insertTags([
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: 'a'),
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: 'b'),
        AddedAppTag(channelId: 'github', appId: 'com.b', tag: 'c'),
        AddedAppTag(channelId: 'vivo', appId: 'com.a', tag: 'd'),
      ]);

      await db.appTagDao.removeTagsOfApp('github', 'com.a');

      expect(await db.appTagDao.getTags('github', 'com.a'), isEmpty);
      expect(await db.appTagDao.getTags('github', 'com.b'), hasLength(1));
      expect(await db.appTagDao.getTags('vivo', 'com.a'), hasLength(1));
    });

    test('clearChannel / clearAll 清理', () async {
      await db.appTagDao.insertTags([
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: 'a'),
        AddedAppTag(channelId: 'github', appId: 'com.b', tag: 'b'),
        AddedAppTag(channelId: 'vivo', appId: 'com.c', tag: 'c'),
      ]);

      await db.appTagDao.clearChannel('github');
      expect(await db.appTagDao.getAllTags(), hasLength(1));

      await db.appTagDao.clearAll();
      expect(await db.appTagDao.getAllTags(), isEmpty);
    });
  });

  group('v4 → v5 迁移（_migration4to5）', () {
    test('迁移建表与全新库 onCreate 等价：4 列 + 复合主键，迁移后可正常读写', () async {
      // 1. 手工建 v4 库：仅 added_apps 表 + UNIQUE 索引（模拟上一版本 schema），
      //    数据库版本设为 4，随后用 AppAddedDatabase 的迁移链打开 → 触发 _migration4to5
      final v4File = p.join(await databaseFactory.getDatabasesPath(), 'v4_tags.db');
      await databaseFactory.deleteDatabase(v4File);
      final v4db = await databaseFactory.openDatabase(
        v4File,
        options: sqflite.OpenDatabaseOptions(
          version: 4,
          onCreate: (db, version) async {
            await db.execute(
                'CREATE TABLE `added_apps` (`id` INTEGER PRIMARY KEY AUTOINCREMENT, `channelId` TEXT NOT NULL, `appId` TEXT NOT NULL, `addTime` INTEGER NOT NULL, `sortOrder` INTEGER NOT NULL, `isEnabled` INTEGER NOT NULL)');
          },
        ),
      );
      await v4db.execute(
          'CREATE UNIQUE INDEX `index_added_apps_channelId_appId` ON `added_apps` (`channelId`, `appId`)');
      await v4db.close();

      // 2. 用 Floor 打开（版本 5 + 迁移链 1→5），触发 v4 → v5 迁移建表
      final db = await AppAddedDatabase.create(dbPath: v4File);
      addTearDown(() async {
        await db.close();
        await databaseFactory.deleteDatabase(v4File);
      });

      // 3. PRAGMA table_info：列名/类型/NOT NULL 与生成 onCreate 完全一致
      final columns = await db.database.rawQuery(
        "PRAGMA table_info('added_app_tags')",
      );
      expect(columns.map((c) => c['name']), ['channelId', 'appId', 'tag', 'addTime'],
          reason: '迁移建表列顺序必须与 Floor 生成 onCreate 一致');
      expect(columns.map((c) => c['type']), ['TEXT', 'TEXT', 'TEXT', 'INTEGER']);
      expect(columns.every((c) => c['notnull'] == 1), isTrue,
          reason: '全部列 NOT NULL');

      // 4. PRAGMA table_info 的 pk 列：3 个字段均为复合主键成员（pk 序号 1/2/3）
      final pkColumns =
          columns.where((c) => (c['pk'] as int) > 0).toList();
      expect(pkColumns.map((c) => c['name']), ['channelId', 'appId', 'tag'],
          reason: '复合主键 (channelId, appId, tag)');

      // 5. 迁移后立即读写：insert → get 往返正常（fresh-install 与 migrated 等价）
      await db.appTagDao.insertTag(
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: '迁移后标签'),
      );
      final tags = await db.appTagDao.getTags('github', 'com.a');
      expect(tags, hasLength(1));
      expect(tags.single.tag, '迁移后标签');

      // 6. 重复插入同复合主键触发 replace（迁移建表的复合主键真实生效）
      await db.appTagDao.insertTag(
        AddedAppTag(channelId: 'github', appId: 'com.a', tag: '迁移后标签'),
      );
      expect(await db.appTagDao.getAllTags(), hasLength(1));
    });
  });
}
