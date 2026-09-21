import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/page/settings/settings_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/db_update_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late PathProviderPlatform originalProvider;
  late FakeAppInfoDao dao;

  /// GitHub releases 响应队列：每次请求弹出队首（不足时回退"无更新"）。
  late List<String> releases;

  setUp(() async {
    await ModuleManager.instance.clear();
    DbManager.resetInstanceForTest();
    docsDir = await Directory.systemTemp.createTemp('tile_update');
    await Directory('${docsDir.path}/gstore').create(recursive: true);
    originalProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(docsDir.path);

    releases = <String>[];
    dao = FakeAppInfoDao(version: '1.0.0');
    final dm = DbManager();
    dm.dbRepositroies['gstore'] = DBRepository(
      'gstore',
      'sunO2',
      'GStore-Repositorys',
      FakeAppInfoDatabase(dao),
    );
    ModuleManager.instance.bind<GithubRestClient>(fakeGithubClient(
      () => releases.isEmpty
          ? releaseJson(version: dao.version ?? '1.0.0', withAsset: false)
          : releases.removeAt(0),
    ));
    ModuleManager.instance.bind<DbManager>(dm);
    ModuleManager.instance.bind<BadgeService>(BadgeService());
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalProvider;
    await ModuleManager.instance.clear();
    DbManager.resetInstanceForTest();
    if (await docsDir.exists()) await docsDir.delete(recursive: true);
  });

  Future<void> pumpTile(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const Scaffold(body: DataUpdateTile()),
    ));
    await tester.pumpAndSettle();
  }

  test('classifyDbUpdateResult：noUpdate 与 error 必须区分（不再都算失败）', () {
    expect(classifyDbUpdateResult(DbUpdateResult.success),
        DbUpdateOutcome.success);
    expect(classifyDbUpdateResult(DbUpdateResult.noUpdate),
        DbUpdateOutcome.noUpdate);
    expect(classifyDbUpdateResult(DbUpdateResult.error),
        DbUpdateOutcome.failure);
    expect(classifyDbUpdateResult(999), DbUpdateOutcome.failure);
  });

  testWidgets('dbRebuiltStream 事件触发版本刷新（不离开页面）', (tester) async {
    await pumpTile(tester);
    expect(find.text('当前版本: 1.0.0'), findsOneWidget);

    // 模拟后端数据库已重建到新版本
    dao.version = '2.0.0';
    DbManager.instance.notifyDbRebuilt();
    await tester.pumpAndSettle();

    expect(find.text('当前版本: 2.0.0'), findsOneWidget,
        reason: 'dbRebuiltStream 到达后 tile 必须刷新版本');
  });

  testWidgets('无更新（-2）→ 提示已是最新，绝不显示"更新失败"', (tester) async {
    releases.add(releaseJson(version: '9.9.9')); // 检查更新：有更新 → 出现按钮
    releases.add(releaseJson(version: '1.0.0', withAsset: false)); // 更新时：无更新

    await pumpTile(tester);
    await tester.tap(find.byIcon(Icons.sync));
    await tester.pumpAndSettle();
    expect(find.text('更新'), findsOneWidget);

    await tester.tap(find.text('更新'));
    await tester.pumpAndSettle();

    expect(find.text('本地数据库已是最新版本'), findsOneWidget,
        reason: 'noUpdate 应走"已是最新"信息提示');
    expect(find.textContaining('数据库更新失败'), findsNothing,
        reason: 'noUpdate 不得误报为失败');
  });

  testWidgets('两次重叠 _performUpdate：只执行一次且 loading 收敛', (tester) async {
    releases.add(releaseJson(version: '9.9.9')); // 检查更新：有更新
    releases.add(releaseJson(version: '9.9.9')); // 执行更新：有更新（进入下载）
    final service = FakeDownloadService(autoComplete: false);
    ModuleManager.instance.bind<IDownloadService>(service);
    addTearDown(service.dispose);

    await pumpTile(tester);
    await tester.tap(find.byIcon(Icons.sync));
    await tester.pumpAndSettle();

    final button =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '更新'));

    // 在真实异步区同步连续触发两次（模拟双连击 / 双触发）：
    // 整个更新链（含 path_provider / dart:io）都在真实事件循环推进。
    await tester.runAsync(() async {
      button.onPressed!();
      button.onPressed!();
      for (var i = 0; i < 100 && service.downloadCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    expect(service.downloadCalls, 1, reason: '单飞守卫必须阻止第二次更新');
    expect(find.text('更新'), findsNothing, reason: '更新进行中应显示 loading');

    // 推送终态，让流程结束（缺失文件 → 失败路径，不做 DB 替换）
    await tester.runAsync(() async {
      service.emitTerminal();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(service.downloadCalls, 1);
    expect(find.byIcon(Icons.sync), findsOneWidget,
        reason: 'loading 必须收敛为可检查状态，不能卡死');
  });
}
