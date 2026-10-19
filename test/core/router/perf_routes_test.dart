import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';

/// 性能页整合为单页顶部 AppTabBar 后：4 条拆分子路由已删除，
/// 仅保留 perfMonitor / perfProfiles。
///
/// 仅在 **路由配置层** 断言（path + builder 存在），**不** mount / pump 真实
/// 页面——这些页面依赖 FFI / 平台插件（Shizuku、原生 perf 模块）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 取出 [GoRouter] 顶层 [GoRoute] 列表。
  List<GoRoute> topLevelGoRoutes() =>
      appRouter.configuration.routes.whereType<GoRoute>().toList();

  test('appRouter 不再注册 4 条性能拆分子路由', () {
    final paths = topLevelGoRoutes().map((r) => r.path).toSet();

    for (final removed in const <String>[
      '/GStore/perfHardware',
      '/GStore/perfControl',
      '/GStore/perfReports',
      '/GStore/perfThirdParty',
    ]) {
      expect(paths.contains(removed), isFalse, reason: '$removed 应已删除');
    }
  });

  test('既有 perfMonitor / perfProfiles 路由保持不变', () {
    final byPath = {for (final r in topLevelGoRoutes()) r.path: r};

    expect(byPath[AppRoute.perfMonitor]?.builder, isNotNull);
    expect(byPath[AppRoute.perfProfiles]?.builder, isNotNull);
  });
}
