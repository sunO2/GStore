import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/page/home/logic.dart';
import 'package:gstore/page/home/state.dart';
import 'package:gstore/page/home/tab/dashboard/view.dart';
import 'package:gstore/page/home/tab/feature_hub/view.dart';
import 'package:gstore/page/home/tab/mine/view.dart';
import 'package:gstore/page/home/view.dart';

/// plan todo 5：`HomePage` 改为 Scene 经典三 tab 外壳（功能 / 首页 / 设置）。
///
/// 覆盖：
/// ① 底部 `NavigationBar` 恰好 3 个 destination，文案为 功能/首页/设置，
///    且不再出现 AI 助手 / 发现 / 我的；
/// ② 初始选中 tab 0（功能），默认渲染 `FeatureHubPage`；
/// ③ 切换有效：首页 → `DashboardPage`（index 1），设置 → `MinePage`（index 2），
///    再回到功能 → `FeatureHubPage`（index 0），`NavigationBar.selectedIndex` 同步；
/// ④ 三 tab 语义与 `HomeTab3` 模型一致（labels/下标），根级页面标签常量一致。
///
/// **密闭性**：首页三 tab 中「首页」为 `DashboardPage`（消费生产 `PerfModule`）。
/// 本测试经 `ModuleBootstrap.debugConfigure` 注入零延迟的「模块不可用」接缝，
/// 使生产 `PerfModule.instance.tunables()` 立即降级为占位（无 FFI / 无网络 /
/// 无挂起定时器），从而可在纯 widget 测试中安全切换三 tab。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = ModuleManager.instance;
  final bootstrap = ModuleBootstrap.instance;

  late ProviderContainer container;

  setUp(() async {
    // 生产 `PerfModule` 走 `ModuleBootstrap`：注入 ensure 抛错 + 零延迟退避，
    // 使 `tunables()` 快速失败（DashboardPage 捕获后降级），不留挂起定时器。
    bootstrap.debugReset();
    bootstrap.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        onProgress,
      }) async =>
          throw StateError('perf module unavailable in home_tabs_test'),
      delayOverride: (Duration duration) async {},
    );

    await manager.clear();
    manager.injectContext(null);

    container = ProviderContainer();
    addTearDown(container.dispose);

    // 页面依赖服务（MinePage 等经 ModuleManager 注册表取用）。
    manager.bind<GithubRestClient>(GithubRestClient(DioClient().get()));
    manager.bind<UserManager>(UserManager.instance);
    manager.bind<ThemeController>(ThemeController());
    manager.bind<BadgeService>(BadgeService());
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(const {});
  });

  tearDown(() {
    bootstrap.debugReset();
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 底部导航内指定文案的 destination。
  Finder navDest(String label) => find.descendant(
      of: find.byType(NavigationBar), matching: find.text(label));

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(navDest(label));
    await tester.pumpAndSettle();
  }

  NavigationBar navBar(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar));

  group('HomePage 三 tab 外壳（功能 / 首页 / 设置）', () {
    testWidgets('① 恰好 3 个 destination：功能/首页/设置，无 AI/发现/我的',
        (tester) async {
      await pumpHome(tester);

      final bar = navBar(tester);
      expect(bar.destinations.length, 3, reason: '必须是 Scene 经典三 tab');

      expect(navDest('功能'), findsOneWidget);
      expect(navDest('首页'), findsOneWidget);
      expect(navDest('设置'), findsOneWidget);

      expect(navDest('AI 助手'), findsNothing, reason: 'AI 已改为路由/网格项');
      expect(navDest('发现'), findsNothing);
      expect(navDest('我的'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('② 初始选中 tab 0（功能）并渲染 FeatureHubPage', (tester) async {
      await pumpHome(tester);

      expect(navBar(tester).selectedIndex, 0);
      expect(container.read(homeProvider).index, 0);
      expect(find.byType(FeatureHubPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('③ 切换：首页 → 设置 → 功能，页面与 selectedIndex 同步',
        (tester) async {
      await pumpHome(tester);

      // 首页 → DashboardPage（index 1）
      await tapTab(tester, '首页');
      expect(navBar(tester).selectedIndex, 1);
      expect(container.read(homeProvider).index, 1);
      expect(find.byType(DashboardPage), findsOneWidget);

      // 设置 → MinePage（index 2）
      await tapTab(tester, '设置');
      expect(navBar(tester).selectedIndex, 2);
      expect(container.read(homeProvider).index, 2);
      expect(find.byType(MinePage), findsOneWidget);

      // 回到功能 → FeatureHubPage（index 0）
      await tapTab(tester, '功能');
      expect(navBar(tester).selectedIndex, 0);
      expect(container.read(homeProvider).index, 0);
      expect(find.byType(FeatureHubPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('④ 标签与 HomeTab3 模型 / 页面常量一致', () {
      expect(HomeTab3.values.map((t) => t.label).toList(), ['功能', '首页', '设置']);
      expect(HomeTab3.features.tabIndex, 0);
      expect(HomeTab3.home.tabIndex, 1);
      expect(HomeTab3.settings.tabIndex, 2);
      expect(FeatureHubPage.tabLabel, '功能');
      expect(MinePage.tabLabel, '设置');
    });
  });
}
