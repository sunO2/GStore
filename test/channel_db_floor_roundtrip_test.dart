import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// 渠道库**经由 Floor 生成代码**的读写往返
///
/// 为什么必须有这个测试：实体（channel_added_app.dart）与 @Database(version:)
/// 改了但 `channel_database.g.dart` 没重新生成时——
///   · 生成的 mapper 不含新列 → 读出来永远是 null（源标识"添加了却查不到"）
///   · 生成的 open() 里写死旧版本号 → 迁移根本不执行，列也不存在
/// 单测若只直接 new 实体、不经过生成代码，这条路径完全测不到（真机踩过）。
///
/// 在 ffi isolate 内覆盖 sqlite3 动态库加载（Linux 只有 libsqlite3.so.0）
void _ffiInit() {
  open.overrideFor(OperatingSystem.linux,
      () => DynamicLibrary.open('libsqlite3.so.0'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late sqflite.DatabaseFactory factory;
  late String dbPath;

  setUpAll(() {
    factory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  });

  setUp(() async {
    sqflite.databaseFactory = factory;
    dbPath = p.join(await factory.getDatabasesPath(),
        'channel_floor_roundtrip_test.db');
    await factory.deleteDatabase(dbPath);
  });

  tearDown(() async {
    await factory.deleteDatabase(dbPath);
  });

  Future<ChannelDatabase> openDb() =>
      $FloorChannelDatabase.databaseBuilder(dbPath).build();

  test('生成代码版本号与 @Database 一致（不一致则迁移不执行）', () async {
    final db = await openDb();
    addTearDown(db.close);
    expect(await db.database.getVersion(), 5,
        reason: 'channel_database.g.dart 必须与 @Database(version: 5) 同步');
  });

  test('sourceId 真的落库并能读回（生成 mapper 必须包含该列）', () async {
    final db = await openDb();
    addTearDown(db.close);

    await db.dao.insertApp(ChannelAddedApp.withChannel(
      appId: 'com.x8bit.bitwarden',
      name: 'Bitwarden',
      user: 'Bitwarden',
      repositories: 'com.x8bit.bitwarden',
      icon: 'com.x8bit.bitwarden/en-US/icon_a=.png',
      description: '密码管理器',
      addTime: 1700000000000,
      channel: ChannelType.fdroid,
      sourceId: 'fp:BITWARDEN',
    ));

    final read =
        await db.dao.getApp('com.x8bit.bitwarden', ChannelType.fdroid.code);
    expect(read, isNotNull);
    expect(read!.sourceId, 'fp:BITWARDEN',
        reason: '生成代码必须映射并写入 sourceId 列');
    expect(read.sourceIdentity, 'fp:BITWARDEN',
        reason: '读侧据此把详情/资源路由回正确的源');
    // 图标仍只存仓库内相对键（不是完整 URL）
    expect(read.icon, 'com.x8bit.bitwarden/en-US/icon_a=.png');
  });

  test('未带源标识的行读回为 null（读侧再回落 extra，不猜源）', () async {
    final db = await openDb();
    addTearDown(db.close);

    await db.dao.insertApp(ChannelAddedApp.withChannel(
      appId: 'com.no.source',
      name: 'NoSource',
      user: '',
      repositories: '',
      icon: 'x.png',
      description: '',
      addTime: 1700000000000,
      channel: ChannelType.fdroid,
    ));

    final read = await db.dao.getApp('com.no.source', ChannelType.fdroid.code);
    expect(read!.sourceId, isNull);
    expect(read.sourceIdentity, isNull);
  });
}
