import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/page/home/tab/mine/view.dart';
import 'package:gstore/page/request_debug/request_debug_page.dart';

/// 「请求调试」工作台（plan todo 30）测试。
///
/// 覆盖：
/// - 我的页「工具」卡渲染「请求调试」入口，点击经 go_router 跳转
///   [AppRoute.requestDebug]；
/// - 工作台渲染 `集合 / 历史 / 环境 / 改写规则` 4 分区；
/// - 空 store 时每个分区渲染各自空态；
/// - 分区切换确实改变内容（非仅高亮）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('我的页「工具」卡「请求调试」入口', () {
    final manager = ModuleManager.instance;

    setUp(() async {
      await manager.clear();
      manager.bind<ThemeController>(ThemeController());
      manager.bind<UserManager>(UserManager.instance);
      FlutterSecureStoragePlatform.instance =
          TestFlutterSecureStoragePlatform(const {});
    });

    Finder requestDebugTile() =>
        find.ancestor(of: find.text('请求调试'), matching: find.byType(ListTile));

    testWidgets('工具卡渲染「请求调试」入口', (tester) async {
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

      expect(requestDebugTile(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点击「请求调试」跳转到 AppRoute.requestDebug', (tester) async {
      final router = GoRouter(
        navigatorKey: appNavigatorKey,
        initialLocation: AppRoute.home,
        routes: [
          GoRoute(
            path: AppRoute.home,
            builder: (context, state) => const MinePage(),
          ),
          GoRoute(
            path: AppRoute.requestDebug,
            builder: (context, state) =>
                const Scaffold(body: Text('请求调试占位页')),
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

      await tester.ensureVisible(requestDebugTile());
      await tester.pumpAndSettle();

      await tester.tap(requestDebugTile());
      await tester.pumpAndSettle();

      expect(find.text('请求调试占位页'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('AppRoute.requestDebug 路径常量正确', () {
      expect(AppRoute.requestDebug, '/GStore/requestDebug');
    });
  });

  group('请求调试工作台', () {
    RequestDebugPage buildPage() => RequestDebugPage(
          facade: _NoIoFacade(RequestDebugStore()),
        );

    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(home: buildPage()));
      await tester.pumpAndSettle();
    }

    testWidgets('渲染 4 分区（集合 / 历史 / 环境 / 改写规则）', (tester) async {
      await pumpPage(tester);

      expect(find.text('集合'), findsOneWidget);
      expect(find.text('历史'), findsOneWidget);
      expect(find.text('环境'), findsOneWidget);
      expect(find.text('改写规则'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('集合分区：导航头承载 [添加集合]/[更多]，分区不再有「集合树」标题',
        (tester) async {
      await pumpPage(tester);

      // Wave 8：集合动作上移到导航头 AppBar。
      expect(
        find.byKey(const Key('request-debug-collection-add')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('request-debug-collection-transfer')),
        findsOneWidget,
      );
      // 旧的分区标题行已移除。
      expect(find.text('集合树'), findsNothing);

      // 「更多」菜单含排序 / 导入 cURL / 导入文件 / 导出项。
      await tester.tap(
        find.byKey(const Key('request-debug-collection-transfer')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('request-debug-collection-sort-toggle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('request-debug-curl-import')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('request-debug-collection-import-file')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('request-debug-collection-export-har')),
        findsOneWidget,
      );
      // 关闭菜单。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 非集合分区不显示这两个 action。
      await tester.tap(find.byKey(const Key('request-debug-segment-history')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('request-debug-collection-add')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('request-debug-collection-transfer')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('集合分区：更多 → 排序 → 完成 → 更多（Wave 9 排序态导航头）',
        (tester) async {
      await pumpPage(tester);

      // 非排序态：显示「更多」，无「完成」。
      expect(
        find.byKey(const Key('request-debug-collection-transfer')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('request-debug-collection-sort-done')),
        findsNothing,
      );
      // 搜索框正常渲染（AppTextField 主题自适应）。
      expect(
        find.byKey(const Key('request-debug-collection-search')),
        findsOneWidget,
      );

      // 「更多」→「排序」。
      await tester.tap(
        find.byKey(const Key('request-debug-collection-transfer')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('request-debug-collection-sort-toggle')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('request-debug-collection-sort-toggle')),
      );
      await tester.pumpAndSettle();

      // 排序态：「更多」被「完成」替换。
      expect(
        find.byKey(const Key('request-debug-collection-sort-done')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('request-debug-collection-transfer')),
        findsNothing,
        reason: '排序态下「更多」菜单必须被替换为「完成」',
      );

      // 「完成」→ 退出排序，恢复「更多」。
      await tester.tap(
        find.byKey(const Key('request-debug-collection-sort-done')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('request-debug-collection-transfer')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('request-debug-collection-sort-done')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('搜索框填充色随主题自适应且不同于文字色（暗色可见性回归）',
        (tester) async {
      Future<({Color? fill, Color? text})> probe(Brightness brightness) async {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: buildPage(),
        ));
        await tester.pumpAndSettle();
        final searchFinder =
            find.byKey(const Key('request-debug-collection-search'));
        final field = tester.widget<TextField>(find.descendant(
          of: searchFinder,
          matching: find.byType(TextField),
        ));
        final textColor = field.style?.color ??
            Theme.of(tester.element(searchFinder)).textTheme.bodyMedium?.color;
        return (fill: field.decoration?.fillColor, text: textColor);
      }

      final light = await probe(Brightness.light);
      expect(light.fill, isNotNull);
      expect(light.text, isNotNull);
      expect(light.fill, isNot(light.text), reason: '亮色下文字与填充不得同色');

      final dark = await probe(Brightness.dark);
      expect(dark.fill, isNotNull);
      expect(dark.text, isNotNull);
      expect(dark.fill, isNot(dark.text),
          reason: '暗色下文字与填充不得同色（白底白字回归）');
      expect(dark.fill, isNot(light.fill),
          reason: 'AppTextField 填充应随主题变化，而非硬编码 #FFFFFF');
      expect(tester.takeException(), isNull);
    });

    testWidgets('切换 4 分区，各分区渲染各自空态', (tester) async {
      await pumpPage(tester);

      // 默认「集合」分区。
      expect(find.text('暂无集合'), findsOneWidget);

      await tester.tap(find.byKey(const Key('request-debug-segment-history')));
      await tester.pumpAndSettle();
      expect(find.text('暂无历史'), findsOneWidget);
      expect(find.text('暂无集合'), findsNothing);

      await tester.tap(find.byKey(const Key('request-debug-segment-environments')));
      await tester.pumpAndSettle();
      expect(find.text('暂无环境'), findsOneWidget);
      expect(find.text('暂无历史'), findsNothing);

      await tester.tap(find.byKey(const Key('request-debug-segment-rules')));
      await tester.pumpAndSettle();
      expect(find.text('暂无改写规则'), findsOneWidget);
      expect(find.text('暂无环境'), findsNothing);

      await tester.tap(find.byKey(const Key('request-debug-segment-collections')));
      await tester.pumpAndSettle();
      expect(find.text('暂无集合'), findsOneWidget);
      expect(find.text('暂无改写规则'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 空改写规则端口：`capture.rules.get` 返回空表（隐藏「规则加载失败」错误态，
/// 使工作台在无规则时渲染「暂无改写规则」空态）。
class _EmptyRulesPort implements CaptureRulesPort {
  const _EmptyRulesPort();

  @override
  Future<List<DebugRewriteRule>> getRules() async =>
      const <DebugRewriteRule>[];

  @override
  Future<DebugRewriteRule> setRule(DebugRewriteRule rule) async => rule;

  @override
  Future<bool> removeRule(String id) async => false;
}

/// 测试用门面：真实空 [RequestDebugStore]，但 `load()` 为空操作。
///
/// widget 测试运行在 fake-async 时区，真实文件 IO 不会完成，会让
/// `pumpAndSettle` 因 loading 动画持续调度帧而超时；故此处绕过磁盘读取。
/// store 的其余 CRUD 语义保持可用（供 todos 31-34 深化时扩展）。
/// 规则端口注入空表（生产默认端口为「未接线」，会显式失败）。
class _NoIoFacade extends DefaultRequestDebugFacade {
  _NoIoFacade(RequestDebugStore store)
      : super(
          store: store,
          sender: DebugSender(),
          captureRules: const _EmptyRulesPort(),
        );

  @override
  Future<void> load() async {}
}
