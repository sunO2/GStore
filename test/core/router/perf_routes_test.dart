import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';

/// Todo 8 路由注册验证：真实 [appRouter] 配置里注册了 4 条性能拆分路由。
///
/// 仅在 **路由配置层** 断言（path + builder 存在），**不** mount / pump 真实
/// 页面——这些页面依赖 FFI / 平台插件（Shizuku、原生 perf 模块），端到端
/// 页面挂载留待 F3 手工验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const expectedPaths = <String>[
    '/GStore/perfHardware',
    '/GStore/perfControl',
    '/GStore/perfReports',
    '/GStore/perfThirdParty',
  ];

  /// 取出 [GoRouter] 顶层 [GoRoute] 列表。
  List<GoRoute> topLevelGoRoutes() =>
      appRouter.configuration.routes.whereType<GoRoute>().toList();

  test('appRouter 注册 4 条性能拆分路由（各含 path + builder）', () {
    final byPath = {for (final r in topLevelGoRoutes()) r.path: r};

    for (final path in expectedPaths) {
      expect(byPath.containsKey(path), isTrue, reason: '缺少路由 $path');
      expect(byPath[path]!.builder, isNotNull, reason: '$path 缺少 builder');
    }

    // 非零计数：确认真实命中 4 条（防「零匹配假绿」）。
    final hit = expectedPaths.where(byPath.containsKey).length;
    expect(hit, 4);
  });

  test('AppRoute 常量与实际注册路径一致', () {
    final paths = topLevelGoRoutes().map((r) => r.path).toSet();

    expect(paths, contains(AppRoute.perfHardware));
    expect(paths, contains(AppRoute.perfControl));
    expect(paths, contains(AppRoute.perfReports));
    expect(paths, contains(AppRoute.perfThirdParty));
  });

  test('既有 perfMonitor / perfProfiles 路由保持不变', () {
    final byPath = {for (final r in topLevelGoRoutes()) r.path: r};

    expect(byPath[AppRoute.perfMonitor]?.builder, isNotNull);
    expect(byPath[AppRoute.perfProfiles]?.builder, isNotNull);
  });
}
