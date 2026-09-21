import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/page/home/tab/mine/view.dart';

/// 我的页「工具」卡「代理」入口测试
///
/// 验证：
/// - 工具组内渲染「代理 / VPN · 局域网代理与流量」入口；
/// - 点击该入口经 go_router 跳转到 [AppRoute.proxy]（值为 `/GStore/proxy`）。
///
/// 生产路由（app_router.dart）把 `AppRoute.proxy` 指向 `ProxyHomePage`；
/// 本测试用占位页替换真实页面，避免在 widget 测试中触发原生代理模块。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = ModuleManager.instance;

  setUp(() async {
    await manager.clear();
    manager.bind<ThemeController>(ThemeController());
    manager.bind<UserManager>(UserManager.instance);
    // 无 WebDAV 配置：备份区走精简分支，不影响工具卡
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(const {});
  });

  Finder proxyTile() =>
      find.ancestor(of: find.text('代理'), matching: find.byType(ListTile));

  testWidgets('工具卡渲染「代理」入口', (tester) async {
    final router = GoRouter(
      navigatorKey: appNavigatorKey,
      initialLocation: AppRoute.home,
      routes: [
        GoRoute(
          path: AppRoute.home,
          builder: (context, state) => const MinePage(),
        ),
      ],
    );

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp.router(
        routerConfig: router,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      ),
    ));
    await tester.pumpAndSettle();

    expect(proxyTile(), findsOneWidget);
    expect(find.text('VPN / 局域网代理与流量'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击「代理」入口跳转到 AppRoute.proxy', (tester) async {
    final router = GoRouter(
      navigatorKey: appNavigatorKey,
      initialLocation: AppRoute.home,
      routes: [
        GoRoute(
          path: AppRoute.home,
          builder: (context, state) => const MinePage(),
        ),
        GoRoute(
          path: AppRoute.proxy,
          builder: (context, state) =>
              const Scaffold(body: Text('代理占位页')),
        ),
      ],
    );

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp.router(
        routerConfig: router,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      ),
    ));
    await tester.pumpAndSettle();

    // 入口可能在折叠/滚动区域外：先滚动到可见再点击
    await tester.ensureVisible(proxyTile());
    await tester.pumpAndSettle();

    await tester.tap(proxyTile());
    await tester.pumpAndSettle();

    expect(find.text('代理占位页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('AppRoute.proxy 路径常量正确', () {
    expect(AppRoute.proxy, '/GStore/proxy');
  });
}
