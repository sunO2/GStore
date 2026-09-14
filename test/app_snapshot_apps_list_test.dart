import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/snapshot/app_snapshot_store.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';
import 'package:gstore/page/app_snapshot/apps_list.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

void _ffiInit() {
  open.overrideFor(
      OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
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
    dbPath = p.join(
        await factory.getDatabasesPath(), 'snapshot_apps_list_test.db');
    await factory.deleteDatabase(dbPath);
    AppSnapshotStore.debugDbPath = dbPath;
  });

  tearDown(() async {
    AppSnapshotAppsPage.debugAppsOverride = null;
    await AppSnapshotStore.instance.closeForTest();
    await factory.deleteDatabase(dbPath);
  });

  /// 造一条最小快照记录
  SnapshotRecord record(String pkg, String label, String version, int at) {
    return SnapshotRecord(
      packageName: pkg,
      appLabel: label,
      versionName: version,
      versionCode: '1',
      createdAt: at,
      payloadVersion: kSnapshotPayloadVersion,
      summary: const SnapshotSummary(nativeLibs: 1),
      payload: SnapshotPayload(
        app: SnapshotAppInfo(
          packageName: pkg,
          label: label,
          versionName: version,
          versionCode: '1',
        ),
      ),
    );
  }

  group('AppSnapshotStore.listApps（按应用聚合）', () {
    test('按包名聚合份数，取最近时间与该份版本号，按最近时间倒序', () async {
      final store = AppSnapshotStore.instance;
      await store.insert(record('com.a', '应用A', '1.0.0', 1000));
      await store.insert(record('com.a', '应用A', '1.0.1', 3000));
      await store.insert(record('com.b', '应用B', '2.0.0', 2000));

      final apps = await store.listApps();
      expect(apps.length, 2);
      // 最近时间倒序：com.a(3000) 在前
      expect(apps[0].packageName, 'com.a');
      expect(apps[0].count, 2);
      expect(apps[0].latestAt, 3000);
      expect(apps[0].latestVersionName, '1.0.1', reason: '应取最近那份的版本号');
      expect(apps[0].appLabel, '应用A');
      expect(apps[1].packageName, 'com.b');
      expect(apps[1].count, 1);
    });

    test('label 为空时用包名兜底展示', () async {
      await AppSnapshotStore.instance.insert(record('com.nolabel', '', '', 100));
      final apps = await AppSnapshotStore.instance.listApps();
      expect(apps.single.displayName, 'com.nolabel');
    });
  });

  group('AppSnapshotAppsPage（快照总览）', () {
    testWidgets('列出已生成快照的应用：名称 / 包名 / 份数 / 最近时间', (tester) async {
      // 直接注入聚合结果：widget 测试不碰 sqflite isolate
      AppSnapshotAppsPage.debugAppsOverride = const [
        SnapshotAppEntry(
            packageName: 'com.a',
            appLabel: '应用A',
            count: 2,
            latestAt: 3000,
            latestVersionName: '1.0.1'),
        SnapshotAppEntry(
            packageName: 'com.b',
            appLabel: '应用B',
            count: 1,
            latestAt: 2000,
            latestVersionName: '2.0.0'),
      ];

      await tester.pumpWidget(const MaterialApp(home: AppSnapshotAppsPage()));
      await tester.pumpAndSettle();

      expect(find.text('应用快照'), findsOneWidget); // AppBar
      expect(find.text('应用A'), findsOneWidget);
      expect(find.text('com.a'), findsOneWidget);
      expect(find.textContaining('2 份快照'), findsOneWidget);
      expect(find.textContaining('v1.0.1'), findsOneWidget);
      expect(find.text('应用B'), findsOneWidget);
      expect(find.textContaining('1 份快照'), findsOneWidget);
      // 列表行可点（点击条目 → 进对应应用的快照页由 Navigator 负责，这里锁住可点性）
      expect(find.byType(ListTile), findsNWidgets(2));
      // 测试环境取不到已安装图标 → 行内回落占位图标（真实图标在真机走 AppIconService）
      expect(find.byIcon(Icons.history_outlined), findsWidgets);
    });

    testWidgets('空态：给出从「应用分析」生成快照的引导', (tester) async {
      AppSnapshotAppsPage.debugAppsOverride = const [];
      await tester.pumpWidget(const MaterialApp(home: AppSnapshotAppsPage()));
      await tester.pumpAndSettle();

      expect(find.text('还没有生成过快照'), findsOneWidget);
      expect(find.textContaining('应用分析'), findsOneWidget);
      expect(find.text('去应用列表'), findsOneWidget);
    });
  });
}
