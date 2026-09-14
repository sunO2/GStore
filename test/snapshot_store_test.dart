import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/snapshot/app_snapshot_store.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

SnapshotRecord _record({
  required String versionName,
  int createdAt = 1000,
  String packageName = 'com.demo.app',
  String note = '',
  int nativeLibs = 1,
}) =>
    SnapshotRecord(
      packageName: packageName,
      appLabel: 'Demo',
      versionName: versionName,
      versionCode: '1',
      createdAt: createdAt,
      note: note,
      payloadVersion: kSnapshotPayloadVersion,
      summary: SnapshotSummary(nativeLibs: nativeLibs, ruleHits: 3),
      payload: SnapshotPayload(
        app: SnapshotAppInfo(
          packageName: packageName,
          label: 'Demo',
          versionName: versionName,
        ),
        nativeLibs: [
          for (var i = 0; i < nativeLibs; i++)
            SnapshotNativeLib(abi: 'arm64-v8a', name: 'lib$i.so', size: i + 1),
        ],
      ),
    );

void main() {
  late Directory tempDir;

  setUpAll(() {
    // Linux 上通常只有 libsqlite3.so.0（无 .so 开发软链），显式指定动态库
    sqlite_open.open.overrideFor(
      sqlite_open.OperatingSystem.linux,
      () => DynamicLibrary.open('libsqlite3.so.0'),
    );
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('snapshot_store_test');
    AppSnapshotStore.debugDbPath = '${tempDir.path}/snapshots.db';
    await AppSnapshotStore.instance.closeForTest();
  });

  tearDown(() async {
    await AppSnapshotStore.instance.closeForTest();
    AppSnapshotStore.debugDbPath = null;
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('插入后能按应用读回，且载荷完整往返', () async {
    final store = AppSnapshotStore.instance;
    final id = await store.insert(_record(versionName: '1.0.0', nativeLibs: 2));
    expect(id, isNotNull);

    final rows = await store.listByApp('com.demo.app');
    expect(rows, hasLength(1));
    expect(rows.single.versionName, '1.0.0');
    expect(rows.single.summary.nativeLibs, 2);
    // 载荷大字段往返
    expect(rows.single.payload.nativeLibs, hasLength(2));
    expect(rows.single.payload.nativeLibs.first.name, 'lib0.so');
    expect(rows.single.payload.app.label, 'Demo');
  });

  test('按应用隔离，且按时间倒序返回', () async {
    final store = AppSnapshotStore.instance;
    await store.insert(_record(versionName: '1.0.0', createdAt: 1000));
    await store.insert(_record(versionName: '2.0.0', createdAt: 3000));
    await store.insert(_record(versionName: '3.0.0', createdAt: 2000));
    await store.insert(
      _record(versionName: '9.9', createdAt: 4000, packageName: 'com.other.app'),
    );

    final rows = await store.listByApp('com.demo.app');
    expect(rows.map((r) => r.versionName).toList(), ['2.0.0', '3.0.0', '1.0.0']);
    expect(await store.countByApp('com.demo.app'), 3);
    expect(await store.countByApp('com.other.app'), 1);
  });

  test('删除单条与按应用清空', () async {
    final store = AppSnapshotStore.instance;
    final id = await store.insert(_record(versionName: '1.0.0'));
    await store.insert(_record(versionName: '2.0.0', createdAt: 2000));

    expect(await store.delete(id!), isTrue);
    expect(await store.countByApp('com.demo.app'), 1);

    expect(await store.deleteByApp('com.demo.app'), 1);
    expect(await store.countByApp('com.demo.app'), 0);
  });

  test('备注与载荷版本随记录保存', () async {
    final store = AppSnapshotStore.instance;
    await store.insert(_record(versionName: '1.0.0', note: '更新前'));
    final row = (await store.listByApp('com.demo.app')).single;
    expect(row.note, '更新前');
    expect(row.payloadVersion, kSnapshotPayloadVersion);
    expect(row.summary.ruleHits, 3);
  });

  test('载荷以 gzip 落库，且历史明文行仍可读（向后兼容）', () async {
    final store = AppSnapshotStore.instance;
    await store.insert(_record(versionName: '1.0.0', nativeLibs: 3));

    final db = await databaseFactory.openDatabase(AppSnapshotStore.debugDbPath!);
    addTearDown(db.close);
    final raw =
        (await db.query('app_snapshot', columns: ['payload'])).single['payload']
            as String;
    // ① 新写入的载荷已压缩（不是明文 JSON）
    expect(raw.startsWith('gz:'), isTrue,
        reason: '载荷应 gzip+base64 落库，体积约为明文 1/4');
    expect(raw.contains('"native_libs"'), isFalse);

    // ② 压缩载荷能完整读回
    final rows = await store.listByApp('com.demo.app');
    expect(rows.single.payload.nativeLibs, hasLength(3));

    // ③ 历史明文行（升级前写入）仍可解析，不会变成"快照损坏"
    await db.insert('app_snapshot', {
      'packageName': 'com.legacy.app',
      'appLabel': 'Legacy',
      'versionName': '0.9',
      'versionCode': '1',
      'createdAt': 1,
      'payloadVersion': 1,
      'summary': '{}',
      'payload': SnapshotPayload(
        app: const SnapshotAppInfo(
            packageName: 'com.legacy.app', label: 'Legacy'),
        nativeLibs: const [
          SnapshotNativeLib(abi: 'arm64-v8a', name: 'libold.so', size: 1),
        ],
      ).encode(),
      'note': '',
    });
    final legacy = await store.listByApp('com.legacy.app');
    expect(legacy.single.payload.nativeLibs.single.name, 'libold.so');
  });
}
