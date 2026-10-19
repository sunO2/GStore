import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/page/home/tab/feature_hub/view.dart';

/// scene-to-gstore-parity todo 6：`FeatureHubPage` 5 组功能网格。
///
/// 覆盖：
/// ① 5 个组标题（场景模式 / 设备性能 / 充电耗电 / 进阶功能 / 辅助）全部渲染；
/// ② 关键条目存在（含 `appList` / `discovery` / `agent`）；
/// ③ 条目点按 push 到既有 `AppRoute`（占位页验证导航）；
/// ④ 全部条目路由均为真实注册路由（无死链）；
/// ⑤ AI 助手项随 `agent_tools` 模块上下线显隐。
///
/// 说明：`isModuleEnabled` 对**未注册**模块返回 `true`（=启用），故基线态
/// AI 项可见；隐藏需「先注册+上线，再 `setModuleEnabled(false)`」。
class TestAgentToolsModule extends AppModule {
  @override
  String get moduleName => 'agent_tools';

  @override
  int get priority => 10;

  @override
  Future<void> onRegister(ModuleContext context) async {}

  @override
  Future<void> onUnregister(ModuleContext context) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = ModuleManager.instance;

  setUp(() async {
    await manager.clear();
    manager.injectContext(null);
  });

  /// 5 组 + 关键条目路由（作为 go_router 占位页，避免 pump 真实页面）。
  GoRouter buildRouter() => GoRouter(
        navigatorKey: appNavigatorKey,
        initialLocation: AppRoute.home,
        routes: <RouteBase>[
          GoRoute(
            path: AppRoute.home,
            builder: (context, state) => const FeatureHubPage(),
          ),
          GoRoute(
            path: AppRoute.appList,
            builder: (context, state) =>
                const Scaffold(body: Text('应用列表占位页')),
          ),
          GoRoute(
            path: AppRoute.discovery,
            builder: (context, state) =>
                const Scaffold(body: Text('发现占位页')),
          ),
          GoRoute(
            path: AppRoute.agent,
            builder: (context, state) =>
                const Scaffold(body: Text('AI 占位页')),
          ),
          GoRoute(
            path: AppRoute.perfProfiles,
            builder: (context, state) =>
                const Scaffold(body: Text('性能配置占位页')),
          ),
        ],
      );

  Future<void> pumpHub(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder item(String id) => find.byKey(Key('feature_item_$id'));
  Finder groupFinder(String id) => find.byKey(Key('feature_group_$id'));

  group('FeatureHubPage 5 组网格', () {
    testWidgets('① 渲染 5 个组标题', (tester) async {
      await pumpHub(tester);

      expect(groupFinder('scene'), findsOneWidget);
      expect(groupFinder('performance'), findsOneWidget);
      expect(groupFinder('battery'), findsOneWidget);
      expect(groupFinder('advanced'), findsOneWidget);
      expect(groupFinder('auxiliary'), findsOneWidget);

      expect(find.text('场景模式'), findsOneWidget);
      expect(find.text('设备性能'), findsOneWidget);
      expect(find.text('充电耗电'), findsOneWidget);
      expect(find.text('进阶功能'), findsOneWidget);
      expect(find.text('辅助'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('② 关键条目存在（含 appList / discovery / agent）', (tester) async {
      await pumpHub(tester);

      expect(item('app_list'), findsOneWidget);
      expect(item('discovery'), findsOneWidget);
      expect(item('agent'), findsOneWidget);
      expect(item('scene_profile'), findsOneWidget);
      // §2.1 重排：性能配置 → 设备性能；耗电统计 → 充电耗电
      expect(item('perf_profile'), findsOneWidget);
      expect(item('battery_stats'), findsOneWidget);
      expect(item('backup'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('③ 点按条目 push 到既有 AppRoute', (tester) async {
      await pumpHub(tester);

      // 应用列表 → AppRoute.appList
      await tester.ensureVisible(item('app_list'));
      await tester.pumpAndSettle();
      await tester.tap(item('app_list'));
      await tester.pumpAndSettle();
      expect(find.text('应用列表占位页'), findsOneWidget);

      // 返回
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();

      // 发现 → AppRoute.discovery
      await tester.ensureVisible(item('discovery'));
      await tester.pumpAndSettle();
      await tester.tap(item('discovery'));
      await tester.pumpAndSettle();
      expect(find.text('发现占位页'), findsOneWidget);

      navigator.pop();
      await tester.pumpAndSettle();

      // AI 助手（默认模块未禁用=启用）→ AppRoute.agent
      await tester.ensureVisible(item('agent'));
      await tester.pumpAndSettle();
      await tester.tap(item('agent'));
      await tester.pumpAndSettle();
      expect(find.text('AI 占位页'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('④ 全部条目路由均为已注册路由（无死链）', () {
      final registered = appRouter.configuration.routes
          .whereType<GoRoute>()
          .map((r) => r.path)
          .toSet();

      for (final g in kHubGroups) {
        for (final e in g.entries) {
          expect(registered.contains(e.route), isTrue,
              reason: '条目 ${e.id} 指向未注册路由 ${e.route}');
        }
      }
    });

    testWidgets('⑤ AI 助手项随 agent_tools 模块上下线显隐', (tester) async {
      // 基线：未禁用 → AI 可见
      await pumpHub(tester);
      expect(item('agent'), findsOneWidget);

      // 注册并上线 agent_tools
      manager.registerKnownModules(() => <AppModule>[TestAgentToolsModule()]);
      await manager.activate(TestAgentToolsModule());
      expect(manager.isModuleEnabled('agent_tools'), isTrue);
      await tester.pump();
      expect(item('agent'), findsOneWidget);

      // 下线 → AI 项隐藏，其余条目不受影响
      await manager.setModuleEnabled('agent_tools', false);
      await tester.pump();
      await tester.pump();
      expect(manager.isModuleEnabled('agent_tools'), isFalse);
      expect(item('agent'), findsNothing);
      expect(item('settings'), findsOneWidget,
          reason: '其余辅助条目不受 agent_tools 影响');

      // 上线恢复
      await manager.setModuleEnabled('agent_tools', true);
      await tester.pump();
      await tester.pump();
      expect(manager.isModuleEnabled('agent_tools'), isTrue);
      expect(item('agent'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
