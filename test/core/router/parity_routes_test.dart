import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';

/// scene-to-gstore-parity todo 9：新增 `appList` / `discovery` 两条路由。
///
/// 仅在 **路由配置层** 断言（path + builder 存在，经真实 `appRouter` 解析），
/// **不** mount / pump 真实页面——`ApplistPage` / `DiscoveryPage` 依赖
/// Riverpod provider / FFI / 平台插件，直接 pump 会因环境缺失而失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 取出 [GoRouter] 顶层 [GoRoute] 列表（与 perf_routes_test 同款）。
  List<GoRoute> topLevelGoRoutes() =>
      appRouter.configuration.routes.whereType<GoRoute>().toList();

  test('appList / discovery 经真实 appRouter 解析到 builder', () {
    final byPath = {for (final r in topLevelGoRoutes()) r.path: r};

    expect(byPath[AppRoute.appList]?.builder, isNotNull,
        reason: '${AppRoute.appList} 应注册且可构建页面');
    expect(byPath[AppRoute.discovery]?.builder, isNotNull,
        reason: '${AppRoute.discovery} 应注册且可构建页面');
  });

  test('未注册路径解析为 null（未知路由失败）', () {
    final byPath = {for (final r in topLevelGoRoutes()) r.path: r};

    expect(byPath['/GStore/__does_not_exist__'], isNull,
        reason: '未声明路径不应被 appRouter 解析');
    expect(byPath[AppRoute.appList], isNot(same(byPath[AppRoute.discovery])),
        reason: '两条路由不应指向同一 GoRoute 实例');
  });

  test('路由 path 无重复注册', () {
    final paths = topLevelGoRoutes().map((r) => r.path).toList();

    expect(paths.toSet().length, paths.length, reason: '存在重复注册的 path');
    expect(paths.where((p) => p == AppRoute.appList).length, 1,
        reason: '${AppRoute.appList} 应恰好注册一次');
    expect(paths.where((p) => p == AppRoute.discovery).length, 1,
        reason: '${AppRoute.discovery} 应恰好注册一次');
  });
}
