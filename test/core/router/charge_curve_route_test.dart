import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';

/// scene-to-gstore-parity todo 22：充电曲线路由（`chargeCurve`）。
///
/// 仅在 **路由配置层** 断言（path + builder 存在，经真实 `appRouter` 解析），
/// **不** mount / pump 真实页面——页面依赖 `shared_preferences` 平台通道。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<GoRoute> topLevelGoRoutes() =>
      appRouter.configuration.routes.whereType<GoRoute>().toList();

  test('chargeCurve 经真实 appRouter 解析到 builder', () {
    final byPath = {for (final r in topLevelGoRoutes()) r.path: r};

    expect(byPath[AppRoute.chargeCurve]?.builder, isNotNull,
        reason: '${AppRoute.chargeCurve} 应注册且可构建页面');
  });

  test('chargeCurve path 恰好注册一次，未知路径不解析', () {
    final paths = topLevelGoRoutes().map((r) => r.path).toList();

    expect(paths.where((p) => p == AppRoute.chargeCurve).length, 1,
        reason: '${AppRoute.chargeCurve} 应恰好注册一次');
    final byPath = {for (final r in topLevelGoRoutes()) r.path: r};
    expect(byPath['/GStore/__does_not_exist__'], isNull,
        reason: '未声明路径不应被 appRouter 解析');
  });
}
