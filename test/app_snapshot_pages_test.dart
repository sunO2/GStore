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
  SnapshotArscInfo arsc = const SnapshotArscInfo(),
  List<SnapshotAsset> assets = const [],
  List<SnapshotDexFile> dexFiles = const [],
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
      arsc: arsc,
      assets: assets,
      dexFiles: dexFiles,
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
    // 注意：快照页**不接收版本号**——版本一律由采集器从真实来源读取
    // （APK 文件 / APK 内 manifest），避免上游页面把过期版本带进快照。
    await tester.pumpWidget(
      const MaterialApp(
        home: AppSnapshotPage(
          packageName: 'com.demo.app',
          appLabel: 'Demo',
          sourceDir: '/no/such/base.apk',
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

    // 折叠态：先看到"哪些节变了"（角标），不必展开全部条目
    expect(find.text('应用信息'), findsOneWidget);
    expect(find.text('原生库文件'), findsOneWidget);
    expect(find.text('权限'), findsOneWidget);
    // 三节都应有变化角标（+a −r ~c 形态）
    expect(find.textContaining('~'), findsWidgets);

    // 展开「应用信息」→ 版本变化的条目级差异
    await _tapSection(tester, '应用信息');
    expect(find.text('版本名'), findsOneWidget);
    expect(find.text('− 1.0.0'), findsOneWidget);
    expect(find.text('+ 2.0.0'), findsOneWidget);

    // 展开「原生库文件」→ 新增/移除/变化各一
    await _tapSection(tester, '原生库文件');
    expect(find.textContaining('libnew.so'), findsOneWidget);
    expect(find.textContaining('libgone.so'), findsOneWidget);
    // 不再是 `大小: 100 B → 400 B` 的箭头单行，而是字段 + 旧值 − / 新值 +（附体积差）
    expect(find.text('100 B → 400 B'), findsNothing);
    expect(find.text('+ 400 B  (+300 B)'), findsOneWidget);
    expect(find.text('− 100 B'), findsOneWidget);
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
    // 概览（应用信息）默认展开
    expect(find.text('应用信息'), findsOneWidget);
    expect(find.text('包名'), findsOneWidget);
    // 其余分区默认折叠：标题与计数可见，内容需展开
    expect(find.text('1 张证书'), findsOneWidget);

    await _tapSection(tester, '签名');
    expect(find.text('当前证书 · SHA256withRSA'), findsOneWidget);

    await _tapSection(tester, '权限');
    expect(find.text('android.permission.READ_PHONE_STATE'), findsOneWidget);
    expect(find.text('maxSdk 29'), findsOneWidget);

    await _tapSection(tester, '组件');
    expect(find.text('com.demo.MainActivity'), findsOneWidget);

    await _tapSection(tester, '特征与构建版本');
    expect(find.text('Kotlin'), findsWidgets);

    await _tapSection(tester, '命中的第三方库');
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

  testWidgets('对比页：搜索可定位条目，并跨分区命中', (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final oldP = _payload(
      nativeLibs: const [
        SnapshotNativeLib(
            abi: 'arm64-v8a', name: 'libtarget.so', size: 1, crc32: 1),
        SnapshotNativeLib(
            abi: 'arm64-v8a', name: 'libother.so', size: 1, crc32: 2),
      ],
      arsc: const SnapshotArscInfo(
        present: true,
        crc32: 1,
        parsed: true,
        resources: [
          SnapshotArscResource(
              id: 0x7f010001, typeName: 'string', key: 'app_name', value: 'A'),
        ],
      ),
    );
    final newP = _payload(
      nativeLibs: const [
        SnapshotNativeLib(
            abi: 'arm64-v8a', name: 'libtarget.so', size: 9, crc32: 3),
        SnapshotNativeLib(
            abi: 'arm64-v8a', name: 'libother.so', size: 1, crc32: 2),
      ],
      arsc: const SnapshotArscInfo(
        present: true,
        crc32: 2,
        parsed: true,
        resources: [
          SnapshotArscResource(
              id: 0x7f010001, typeName: 'string', key: 'app_name', value: 'B'),
        ],
      ),
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

    // 搜索 app_name → 命中资源分区（搜索态自动展开）
    await tester.enterText(find.byType(TextField), 'app_name');
    await tester.pumpAndSettle();
    expect(find.text('resources.arsc 资源'), findsOneWidget);
    expect(find.textContaining('app_name'), findsWidgets);
    // 未命中的原生库条目不应出现
    expect(find.textContaining('libother.so'), findsNothing);
  });
  testWidgets('.so 体积变化的展示：字段名 / 旧值 − 新值 +（含体积差），不再用箭头单行', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final oldP = _payload(nativeLibs: const [
      SnapshotNativeLib(
          abi: 'arm64-v8a', name: 'libfoo.so', size: 1048576, crc32: 111),
    ]);
    final newP = _payload(nativeLibs: const [
      SnapshotNativeLib(
          abi: 'arm64-v8a', name: 'libfoo.so', size: 3145728, crc32: 222),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: AppSnapshotComparePage(
          oldRecord: _record(oldP),
          newRecord: _record(newP, id: 2, createdAt: 2000),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tapSection(tester, '原生库文件');

    // 字段名单独一行
    expect(find.text('大小'), findsOneWidget);
    // 旧值、新值各一行；新值行带体积差（+2.0 MB）
    expect(find.text('− 1.0 MB'), findsOneWidget);
    expect(find.text('+ 3.0 MB  (+2.0 MB)'), findsOneWidget);
    // 旧的 `字段: 旧 → 新` 单行形态不应再出现（页头的版本/时间箭头是合理的）
    expect(find.textContaining('大小:'), findsNothing);
    expect(find.textContaining(' → '), findsNWidgets(2));
    // 内容指纹不同 → 角标与结论
    expect(find.text('内容不同'), findsOneWidget);
    expect(find.text('内容已变（同名但不是同一个文件）'), findsOneWidget);
  });

  testWidgets('对比方向：默认早→晚，可一键互换（旧/新显式标注）', (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final oldP = _payload(versionName: '1.0.0');
    // 后一份 +1000 字节，用于判断方向
    final newP = _payload(versionName: '2.0.0', apkSize: 2000);

    await tester.pumpWidget(
      MaterialApp(
        home: AppSnapshotComparePage(
          oldRecord: _record(oldP, createdAt: 1000),
          newRecord: _record(newP, id: 2, createdAt: 2000),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 默认方向：早（1.0.0）→ 晚（2.0.0），且显式标注旧/新
    expect(find.text('v1.0.0 → v2.0.0'), findsOneWidget);
    expect(find.textContaining('旧 '), findsOneWidget);
    expect(find.textContaining('→ 新 '), findsOneWidget);

    // 一键互换后方向反转（1.0.0 变成"新"侧）
    await tester.tap(find.byTooltip('互换对比方向（旧↔新）'));
    await tester.pumpAndSettle();
    expect(find.text('v2.0.0 → v1.0.0'), findsOneWidget);
    expect(find.textContaining('（已互换方向）'), findsOneWidget);

    // 差异也随之反向：APK 大小从 2000 → 1000（差值为负）
    await _tapSection(tester, '应用信息');
    expect(find.text('− 2.0 KB'), findsOneWidget);
    expect(find.text('+ 1000 B  (−1.0 KB)'), findsOneWidget);
  });

}

/// 展开某个分区：先把标题滚进视口再点（分区内容高低变化会影响可见性）
Future<void> _tapSection(WidgetTester tester, String title) async {
  final finder = find.text(title);
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}
