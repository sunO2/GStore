import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/snapshot/app_snapshot_store.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';
import 'package:gstore/page/app_snapshot/compare.dart';
import 'package:gstore/page/app_snapshot/detail.dart';
import 'package:gstore/page/app_snapshot/view.dart';

SnapshotPayload _payload({
  String versionName = '1.0.0',
  int apkSize = 1000,
  List<SnapshotNativeLib> nativeLibs = const [],
  List<SnapshotPermission> permissions = const [],
  List<SnapshotComponent> components = const [],
  List<SnapshotRuleHit> nativeHits = const [],
}) =>
    SnapshotPayload(
      app: SnapshotAppInfo(
        packageName: 'com.demo.app',
        label: 'Demo',
        versionName: versionName,
        versionCode: '1',
        apkSize: apkSize,
        minSdk: '24',
        targetSdk: '34',
        abis: const ['arm64-v8a'],
      ),
      signature: const SnapshotSignatureInfo(
        signingShape: 'single',
        schemes: ['V2', 'V3'],
        certificates: [
          SnapshotCertificate(
            subject: 'CN=Demo',
            algorithm: 'SHA256withRSA',
            sha256: 'aa11bb22cc33dd44',
            kind: 'current',
          ),
        ],
      ),
      permissions: permissions,
      components: components,
      nativeLibs: nativeLibs,
      nativeHits: nativeHits,
      features: const SnapshotFeatures(kotlinUsed: true, jetpackCompose: true),
      buildVersions: const SnapshotBuildVersions(agpVersion: '8.7.2'),
    );

SnapshotRecord _record(
  SnapshotPayload payload, {
  int id = 1,
  int createdAt = 1000,
  String note = '',
}) =>
    SnapshotRecord(
      id: id,
      packageName: payload.app.packageName,
      appLabel: payload.app.label,
      versionName: payload.app.versionName,
      versionCode: payload.app.versionCode,
      createdAt: createdAt,
      note: note,
      payloadVersion: payload.payloadVersion,
      summary: payload.summary,
      payload: payload,
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    // 避免走 path_provider（widget test 里没有插件实现，会一直挂住）
    tempDir = await Directory.systemTemp.createTemp('snapshot_page_test');
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

  testWidgets('快照列表入口可用：导航头有新建按钮，无快照时给出引导', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AppSnapshotPage(
          packageName: 'com.demo.app',
          appLabel: 'Demo',
          sourceDir: '/no/such/base.apk',
          versionName: '1.0.0',
          versionCode: '1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('应用快照'), findsOneWidget);
    expect(find.byTooltip('新建快照'), findsOneWidget);
    expect(find.textContaining('还没有快照'), findsOneWidget);
  });

  testWidgets('对比页按节展示差异，含计数与 from→to', (tester) async {
    final oldP = _payload(
      versionName: '1.0.0',
      apkSize: 1000,
      nativeLibs: const [
        SnapshotNativeLib(abi: 'arm64-v8a', name: 'libgone.so', size: 10),
        SnapshotNativeLib(abi: 'arm64-v8a', name: 'libgrow.so', size: 100),
      ],
      permissions: const [
        SnapshotPermission(name: 'android.permission.CAMERA'),
      ],
    );
    final newP = _payload(
      versionName: '2.0.0',
      apkSize: 2000,
      nativeLibs: const [
        SnapshotNativeLib(abi: 'arm64-v8a', name: 'libgrow.so', size: 400),
        SnapshotNativeLib(abi: 'arm64-v8a', name: 'libnew.so', size: 20),
      ],
      permissions: const [
        SnapshotPermission(name: 'android.permission.CAMERA'),
        SnapshotPermission(name: 'android.permission.RECORD_AUDIO'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AppSnapshotComparePage(
          oldRecord: _record(oldP),
          newRecord: _record(newP, id: 2, createdAt: 2000),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('快照对比'), findsOneWidget);
    expect(find.text('v1.0.0 → v2.0.0'), findsOneWidget);
    // 应用信息节的版本变化
    expect(find.text('版本名: 1.0.0 → 2.0.0'), findsOneWidget);
    // 原生库：新增/移除/变化各一
    expect(find.text('原生库文件'), findsOneWidget);
    expect(find.textContaining('libnew.so'), findsOneWidget);
    expect(find.textContaining('libgone.so'), findsOneWidget);
    expect(find.textContaining('大小: 100 B → 400 B'), findsOneWidget);
    // 权限新增
    expect(find.text('权限'), findsOneWidget);
    expect(find.textContaining('RECORD_AUDIO'), findsOneWidget);
  });

  testWidgets('无差异时给出提示', (tester) async {
    final p = _payload();
    await tester.pumpWidget(
      MaterialApp(
        home: AppSnapshotComparePage(
          oldRecord: _record(p),
          newRecord: _record(p, id: 2, createdAt: 2000),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('两份快照没有差异'), findsOneWidget);
  });

  testWidgets('详情页展示分节内容与签名/原生库/特征', (tester) async {
    // 详情是长列表且按需构建：放大视口让所有分节都参与构建
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = _payload(
      nativeLibs: const [
        SnapshotNativeLib(abi: 'arm64-v8a', name: 'libc++_shared.so', size: 2048),
      ],
      nativeHits: const [
        SnapshotRuleHit(label: 'OkHttp', ruleName: 'okhttp', matched: 'libokhttp.so'),
      ],
      permissions: const [
        SnapshotPermission(
          name: 'android.permission.READ_PHONE_STATE',
          maxSdkVersion: '29',
        ),
      ],
      components: const [
        SnapshotComponent(
          kind: 'activity',
          name: 'com.demo.MainActivity',
          exported: 'true',
          deepLinks: ['demo://open/home'],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: AppSnapshotDetailPage(record: _record(p, note: '更新前'))),
    );
    await tester.pumpAndSettle();

    expect(find.text('快照详情'), findsOneWidget);
    expect(find.text('应用信息'), findsOneWidget);
    expect(find.text('1 张证书'), findsOneWidget);
    expect(find.text('当前证书 · SHA256withRSA'), findsOneWidget);
    expect(find.text('android.permission.READ_PHONE_STATE'), findsOneWidget);
    expect(find.text('maxSdk 29'), findsOneWidget);
    expect(find.text('com.demo.MainActivity'), findsOneWidget);
    expect(find.text('Kotlin'), findsWidgets);
    expect(find.text('OkHttp'), findsOneWidget);
    expect(find.textContaining('更新前'), findsOneWidget);
  });

  testWidgets('详情页在有上一份快照时提供对比入口', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = _payload();
    await tester.pumpWidget(
      MaterialApp(
        home: AppSnapshotDetailPage(
          record: _record(p, id: 2, createdAt: 2000),
          previous: _record(p),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('与上一快照对比'), findsOneWidget);
    await tester.tap(find.byTooltip('与上一快照对比'));
    await tester.pumpAndSettle();
    expect(find.text('快照对比'), findsOneWidget);
  });
}
