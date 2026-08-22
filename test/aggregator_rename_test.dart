import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// AppAggregatorManager.renameApp 测试
///
/// 验证"聚合库 appId 改名"（渠道记录迁移后调用，保持聚合库一致）：
/// - 常规改名保留 id/addTime/sortOrder/isEnabled（不重置元数据）
/// - 用户标签随 appId 迁移（不丢失）
/// - 目标 appId 已存在（异常残留）时合并：删源行、保留目标行、标签并入
/// - 幂等：源不存在 / old==new 时 no-op
void main() {
  late AppAddedDatabase db;
  late AppAggregatorManager manager;

  setUpAll(() {
    // Linux 系统仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    // 注意：不使用共享的 inMemoryDatabasePath（':memory:'）——sqflite_common_ffi
    // 将其映射为 .dart_tool 下公共文件，多个测试文件并行 isolate 删除/重建会
    // 互相踩踏（database is locked / disk I/O error）；本文件独享一个文件路径，
    // delete+create 只影响本文件，保证用例隔离。
    final dbFile = p.join(
        await databaseFactory.getDatabasesPath(), 'aggregator_rename_test.db');
    await databaseFactory.deleteDatabase(dbFile);

    db = await AppAddedDatabase.create(dbPath: dbFile);
    await db.addedAppDao.clearAll();
    await db.appTagDao.clearAll();
    manager = AppAggregatorManager.instance;
    manager.debugDatabase = db;
  });

  tearDown(() async {
    await db.close();
  });

  group('renameApp', () {
    test('常规改名：保留 id/addTime/sortOrder/isEnabled，标签迁移到新 appId', () async {
      await db.addedAppDao.insertApp(AddedAppInfo(
        channelId: ChannelType.github.code,
        appId: 'gkd-kit/gkd',
        addTime: 1000,
        sortOrder: 5,
        isEnabled: false,
      ));
      await db.appTagDao.insertTag(AddedAppTag(
        channelId: ChannelType.github.code,
        appId: 'gkd-kit/gkd',
        tag: '工具',
      ));
      await db.appTagDao.insertTag(AddedAppTag(
        channelId: ChannelType.github.code,
        appId: 'gkd-kit/gkd',
        tag: '安全',
      ));

      await manager.renameApp(
        channelCode: 'github',
        oldAppId: 'gkd-kit/gkd',
        newAppId: 'li.songe.gkd',
      );

      // 旧记录消失，新记录保留原元数据
      expect(await db.addedAppDao.getApp('github', 'gkd-kit/gkd'), isNull);
      final renamed = await db.addedAppDao.getApp('github', 'li.songe.gkd');
      expect(renamed, isNotNull);
      expect(renamed!.addTime, 1000);
      expect(renamed.sortOrder, 5);
      expect(renamed.isEnabled, false);

      // 标签迁移
      final tags = (await db.appTagDao.getTags('github', 'li.songe.gkd'))
          .map((e) => e.tag)
          .toList();
      expect(tags, containsAll(['工具', '安全']));
      expect(
        await db.appTagDao.getTags('github', 'gkd-kit/gkd'),
        isEmpty,
      );
    });

    test('目标 appId 已存在（异常残留）：删源行、保留目标行、标签并入目标', () async {
      // 模拟历史 bug 残留：源行（旧 appId）与目标行（新 appId）同时存在
      await db.addedAppDao.insertApp(AddedAppInfo(
        channelId: ChannelType.github.code,
        appId: 'gkd-kit/gkd',
        addTime: 100,
        sortOrder: 1,
      ));
      await db.addedAppDao.insertApp(AddedAppInfo(
        channelId: ChannelType.github.code,
        appId: 'li.songe.gkd',
        addTime: 200, // 目标行（残留，addTime 已重置）
        sortOrder: 0,
      ));
      await db.appTagDao.insertTag(AddedAppTag(
        channelId: ChannelType.github.code,
        appId: 'gkd-kit/gkd',
        tag: '工具',
      ));

      await manager.renameApp(
        channelCode: 'github',
        oldAppId: 'gkd-kit/gkd',
        newAppId: 'li.songe.gkd',
      );

      // 源行被删，目标行保留（不抛唯一索引异常）
      expect(await db.addedAppDao.getApp('github', 'gkd-kit/gkd'), isNull);
      final target = await db.addedAppDao.getApp('github', 'li.songe.gkd');
      expect(target, isNotNull);
      // 标签并入目标行
      final tags = (await db.appTagDao.getTags('github', 'li.songe.gkd'))
          .map((e) => e.tag)
          .toList();
      expect(tags, ['工具']);
    });

    test('幂等：源记录不存在时 no-op，不产生任何变更', () async {
      await manager.renameApp(
        channelCode: 'github',
        oldAppId: '不存在/app',
        newAppId: 'li.songe.gkd',
      );
      expect(await db.addedAppDao.getApp('github', 'li.songe.gkd'), isNull);
      expect(await db.addedAppDao.getTotalCount(), 0);
    });

    test('幂等：oldAppId == newAppId 时 no-op', () async {
      await db.addedAppDao.insertApp(AddedAppInfo(
        channelId: ChannelType.github.code,
        appId: 'li.songe.gkd',
      ));
      await manager.renameApp(
        channelCode: 'github',
        oldAppId: 'li.songe.gkd',
        newAppId: 'li.songe.gkd',
      );
      final row = await db.addedAppDao.getApp('github', 'li.songe.gkd');
      expect(row, isNotNull);
    });
  });
}
