import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/page/settings/settings_page.dart';

/// plan todo 13：设置 tab 分组对齐 Scene（SELinux/主题/通知/调试/日志）。
///
/// 覆盖：
/// - 既有 GStore 分组名保留（外观 / 数据与同步 / 数据源管理 / 模块 /
///   安装与权限 / 下载 / 关于），既有入口/key 不删除；
/// - 每个分组标注其对齐的 Scene 设置分组（`Scene · …` 徽标）；
/// - 新增「日志与调试」组复用既有路由（日志 / 网络调试 / 请求调试）；
/// - 目标路由未注册时该行渲染为禁用行（不崩溃）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = ModuleManager.instance;

  setUp(() async {
    await manager.clear();
    manager.injectContext(null);
    if (!manager.hasService<BadgeService>()) {
      manager.bind<BadgeService>(BadgeService.instance);
    }
  });

  /// 占位目标页（仅用于让 GoRouter 注册对应路径）。
  Widget placeholder(String label) => Scaffold(body: Text(label));

  /// 全量路由：Scene 对齐组内三条路由均已注册（行应为可用态）。
  GoRouter fullRouter() => GoRouter(
        initialLocation: AppRoute.settings,
        routes: [
          GoRoute(
              path: AppRoute.settings,
              builder: (_, __) => const SettingsPage()),
          GoRoute(
              path: AppRoute.logViewer,
              builder: (_, __) => placeholder('日志页')),
          GoRoute(
              path: AppRoute.proxy, builder: (_, __) => placeholder('网络调试页')),
          GoRoute(
              path: AppRoute.requestDebug,
              builder: (_, __) => placeholder('请求调试页')),
        ],
      );

  Future<void> pump(WidgetTester tester, GoRouter router) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        ProviderScope(child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  group('设置页分组对齐 Scene', () {
    testWidgets('分组标注对齐的 Scene 分组标题', (tester) async {
      await pump(tester, fullRouter());

      // 首屏：外观 = Scene「主题」
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('Scene · 主题'), findsOneWidget);

      // 安装与权限 = Scene「SELinux 权限」
      await scrollTo(tester, find.text('Scene · SELinux 权限'));
      expect(find.text('安装与权限'), findsOneWidget);

      // 下载 = Scene「通知」
      await scrollTo(tester, find.text('Scene · 通知'));
      expect(find.text('下载'), findsOneWidget);

      // 日志与调试 = Scene「调试 / 日志」
      await scrollTo(tester, find.text('Scene · 调试 / 日志'));
      expect(find.text('日志与调试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('既有分组名与入口全部保留', (tester) async {
      await pump(tester, fullRouter());

      // 严格按文档顺序自上下滚，逐项断言保留（分组名 + 抽样入口交错）。
      const ordered = [
        '外观',
        '数据与同步',
        '数据备份',
        'GitHub 代理',
        '数据库管理',
        '数据源管理',
        'F-Droid 源管理',
        '脚本渠道',
        '模块',
        '模块管理',
        '安装与权限',
        '安装方式',
      ];
      for (final text in ordered) {
        await scrollTo(tester, find.text(text));
        expect(find.text(text), findsOneWidget, reason: '「$text」应保留');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('日志/调试组复用既有路由且可用', (tester) async {
      await pump(tester, fullRouter());
      await scrollTo(tester, find.text('查看日志'));

      for (final title in const ['查看日志', '网络调试', '请求调试']) {
        final tile =
            tester.widget<ListTile>(find.widgetWithText(ListTile, title));
        expect(tile.enabled, isTrue, reason: '「$title」路由已注册 → 可用');
        expect(tile.onTap, isNotNull);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('目标路由缺失 → 渲染禁用行（不崩溃）', (tester) async {
      // 只注册设置页，未注册 logViewer/proxy/requestDebug
      final router = GoRouter(
        initialLocation: AppRoute.settings,
        routes: [
          GoRoute(
              path: AppRoute.settings,
              builder: (_, __) => const SettingsPage()),
        ],
      );
      await pump(tester, router);
      await scrollTo(tester, find.text('查看日志'));

      final tile = tester
          .widget<ListTile>(find.widgetWithText(ListTile, '查看日志'));
      expect(tile.enabled, isFalse, reason: '目标页缺失 → 禁用行');
      expect(tile.onTap, isNull, reason: '禁用行不可点击');
      expect(find.text('功能不可用'), findsWidgets);
      expect(tester.takeException(), isNull, reason: '缺失目标页不得崩溃');
    });
  });
}
