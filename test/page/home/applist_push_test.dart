import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/page/home/tab/applist/view.dart';

/// scene-to-gstore-parity todo 11：`ApplistPage` 改为可 push 页面。
///
/// 覆盖：
/// ① push 进入 `ApplistPage`（自带 Scaffold，未新增第二个）；
/// ② AppBar 自动返回 affordance（`BackButton`）存在；
/// ③ 空态「浏览发现页」→ `context.push(AppRoute.discovery)`；
/// ④ pop 回列表页，状态保留（仍为空态）；deep-link/pop 不崩溃；
/// ⑤ 已失效的「我的频道」入口已移除，header 文案对齐新交互（2 个入口）。
///
/// 说明：测试不注册 `aggregate` 模块 → `ApplistNotifier._init` 降级为空态，
/// 不触发网络；`UserManager`/`BadgeService` 未注册时页面尽力而为跳过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String rootRoute = '/root';
  final manager = ModuleManager.instance;

  setUp(() async {
    await manager.clear();
    manager.injectContext(null);
  });

  GoRouter buildRouter() => GoRouter(
        navigatorKey: appNavigatorKey,
        initialLocation: rootRoute,
        routes: <RouteBase>[
          GoRoute(
            path: rootRoute,
            builder: (context, state) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => context.push(AppRoute.appList),
                  child: const Text('打开应用列表'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoute.appList,
            builder: (context, state) => const ApplistPage(),
          ),
          GoRoute(
            path: AppRoute.discovery,
            builder: (context, state) =>
                const Scaffold(body: Text('发现占位页')),
          ),
        ],
      );

  Future<void> pumpRoot(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openApplist(WidgetTester tester) async {
    await pumpRoot(tester);
    await tester.tap(find.text('打开应用列表'));
    await tester.pumpAndSettle();
  }

  testWidgets('① push 进入 ApplistPage：恰好一个 Scaffold + 返回 affordance',
      (tester) async {
    await openApplist(tester);

    expect(find.byType(ApplistPage), findsOneWidget);
    // 空态文案（聚合模块未注册 → 降级空态）
    expect(find.text('还没有添加任何应用'), findsOneWidget);
    // 未新增第二个 Scaffold：被推入的列表页仅一个可见 Scaffold
    expect(find.byType(Scaffold), findsOneWidget);
    // AppBar 自动返回按钮（可 pop）
    expect(find.byType(BackButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('③④⑤ 浏览发现页 → discovery；pop 回列表且状态保留',
      (tester) async {
    await openApplist(tester);

    // ⑤ 文案对齐新交互：2 个入口；「我的频道」入口已移除
    expect(find.text('2种方式快速添加应用：'), findsOneWidget);
    expect(find.text('我的频道'), findsNothing);

    // ③ 点按「浏览发现页」→ push discovery
    await tester.tap(find.text('浏览发现页'));
    await tester.pumpAndSettle();
    expect(find.text('发现占位页'), findsOneWidget);

    // ④ pop 回列表页：状态保留（仍为空态列表），无异常
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byType(ApplistPage), findsOneWidget);
    expect(find.text('还没有添加任何应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
