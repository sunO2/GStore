import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/page/home/tab/discovery/logic.dart';
import 'package:gstore/page/home/tab/discovery/state.dart';
import 'package:gstore/page/home/tab/discovery/view.dart';

/// scene-to-gstore-parity todo 12：`DiscoveryPage` 改为可 push 页面。
///
/// 覆盖：
/// ① 真实 `appRouter` 注册 `AppRoute.discovery` 且 builder 可构建页面（路由可达）；
/// ② push 进入 `DiscoveryPage`：页面构建，且页面自身恰好一个 `Scaffold`；
/// ③ AppBar 自动返回 affordance（`BackButton`）存在；
/// ④ pop 返回上一页；
/// ⑤ 未知/缺失路由不解析到 `DiscoveryPage`（errorBuilder 兜底），页面不构建。
///
/// 说明：用 `_SeededDiscoveryNotifier` 预置数据，避免真实渠道加载（`ChannelManager`
/// 空实例），使页面纯展示、可确定性构建。

/// 预置数据的发现页 Notifier（与 other_pages_border_theme_test 同款）：
/// `build` 直接返回含应用状态，不触发真实渠道加载/订阅。
class _SeededDiscoveryNotifier extends DiscoveryNotifier {
  @override
  DiscoveryState build() {
    return DiscoveryState(
      channelApps: const {
        'github': [
          AppSummary(
            appId: 'com.example.test',
            name: '测试应用',
            user: 'user',
            repositories: 'repo',
            icon: '',
            des: '',
          ),
        ],
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String rootRoute = '/root';

  /// 测试用 GoRouter：root 桩 + 真实 `DiscoveryPage` 挂在 `AppRoute.discovery`。
  GoRouter buildRouter() => GoRouter(
        navigatorKey: appNavigatorKey,
        initialLocation: rootRoute,
        errorBuilder: (context, state) => Scaffold(
          body: Center(child: Text('route-error ${state.uri}')),
        ),
        routes: <RouteBase>[
          GoRoute(
            path: rootRoute,
            builder: (context, state) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => context.push(AppRoute.discovery),
                  child: const Text('打开发现页'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoute.discovery,
            builder: (context, state) => const DiscoveryPage(),
          ),
        ],
      );

  Future<GoRouter> pumpRoot(WidgetTester tester) async {
    final router = buildRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          discoveryProvider.overrideWith(_SeededDiscoveryNotifier.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  Future<GoRouter> openDiscovery(WidgetTester tester) async {
    final router = await pumpRoot(tester);
    await tester.tap(find.text('打开发现页'));
    await tester.pumpAndSettle();
    return router;
  }

  group('DiscoveryPage 作为可 push 页面', () {
    test('① 真实 appRouter 注册 AppRoute.discovery 且可构建页面', () {
      final byPath = {
        for (final r in appRouter.configuration.routes.whereType<GoRoute>())
          r.path: r,
      };
      expect(byPath[AppRoute.discovery], isNotNull,
          reason: '${AppRoute.discovery} 应注册到真实 appRouter');
      expect(byPath[AppRoute.discovery]?.builder, isNotNull,
          reason: '${AppRoute.discovery} 应能构建页面');
    });

    testWidgets('②③ push 进入 discovery：页面构建 + 恰好一个 Scaffold + 返回 affordance',
        (tester) async {
      await openDiscovery(tester);

      expect(find.byType(DiscoveryPage), findsOneWidget);
      // 页面内容构建（预置应用可见）
      expect(find.text('测试应用'), findsOneWidget);
      // 页面自身恰好一个 Scaffold（未新增第二个）
      expect(
        find.descendant(
          of: find.byType(DiscoveryPage),
          matching: find.byType(Scaffold),
        ),
        findsOneWidget,
      );
      expect(find.byType(Scaffold), findsOneWidget,
          reason: '被 push 的发现页仅一个可见 Scaffold');
      // AppBar 标题 + 自动返回按钮（可 pop）
      expect(find.text('发现'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('④ 返回（pop）回到上一页', (tester) async {
      await openDiscovery(tester);
      expect(find.byType(DiscoveryPage), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.byType(DiscoveryPage), findsNothing);
      expect(find.text('打开发现页'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('⑤ 未知/缺失路由不解析到 DiscoveryPage', (tester) async {
      final router = await pumpRoot(tester);

      router.go('/GStore/__does_not_exist__');
      await tester.pumpAndSettle();

      expect(find.byType(DiscoveryPage), findsNothing,
          reason: '未声明路径不应构建 discovery 页面');
      expect(find.textContaining('route-error'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
