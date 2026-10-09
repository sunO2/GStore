// Todo 7 tests：抓包 → 改写规则预填透传（Capture → rewrite-rule prefill）。
//
// 覆盖验收：
// - `app_router` 读取 `state.extra` 并透传：抓包详情「创建改写规则」经
//   `appRouter.go(AppRoute.requestDebug, extra: CaptureRulePrefill)` 落到
//   「改写规则」分区，且规则编辑器以 method/url/status/headers/body 预填；
// - `RequestDebugPage(initialSection/rulePrefill)` 直接构造亦同样生效；
// - 无 `extra` / 无预填 → 回退默认「集合」分区，行为**不变**。
//
// 密闭式：注入 _NoIoFacade（真实内存 store，load 空操作）+ 空规则端口，
// 不触碰 FFI / 网络 / 磁盘。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/page/proxy/proxy_capture_bridge.dart';
import 'package:gstore/page/request_debug/request_debug_page.dart';

/// 空改写规则端口：`capture.rules.get` 返回空表（不触碰 FFI）。
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

/// 测试门面：真实内存空 store，但 `load()` 为空操作（绕过磁盘 IO）。
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

_NoIoFacade _noIoFacade() => _NoIoFacade(
      RequestDebugStore(directoryProvider: () async => Directory.systemTemp),
    );

/// 与生产相同的全局通道，使底部弹层 / Snackbar 可真实呈现。
Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

/// 抓包「创建改写规则」派生出的预填（等价 captureRulePrefill 产物）。
CaptureRulePrefill _prefill() => const CaptureRulePrefill(
      method: 'PUT',
      url: 'https://api.test/v2/item',
      replaceBody: '{"ok":true}',
      statusCode: 201,
      responseHeaders: 'X-Resp: 1',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RequestDebugPage 预填参数', () {
    testWidgets('initialSection=改写规则 + rulePrefill → 编辑器预填字段', (tester) async {
      await tester.pumpWidget(_host(RequestDebugPage(
        facade: _noIoFacade(),
        initialSection: RequestDebugSection.rules,
        rulePrefill: _prefill(),
      )));
      await tester.pumpAndSettle();

      expect(find.text('新建改写规则'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('request-debug-rule-url')))
            .controller!
            .text,
        'https://api.test/v2/item',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('request-debug-rule-method')))
            .controller!
            .text,
        'PUT',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('request-debug-rule-status')))
            .controller!
            .text,
        '201',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('request-debug-rule-headers')))
            .controller!
            .text,
        'X-Resp: 1',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('request-debug-rule-body')))
            .controller!
            .text,
        '{"ok":true}',
      );
      expect(
        tester
            .widget<Switch>(find.byKey(const Key('request-debug-rule-enabled')))
            .value,
        isFalse,
        reason: '预填不得隐式开启规则（默认关）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('无 initialSection / rulePrefill → 默认集合分区（行为不变）', (tester) async {
      await tester.pumpWidget(_host(RequestDebugPage(facade: _noIoFacade())));
      await tester.pumpAndSettle();

      expect(find.text('暂无集合'), findsOneWidget);
      expect(find.text('新建改写规则'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('app_router extra 透传', () {
    test('requestDebugRouteArgs：extra 为预填 → 改写规则分区 + 同实例预填', () {
      final prefill = _prefill();
      final args = requestDebugRouteArgs(prefill);

      expect(args.section, RequestDebugSection.rules);
      expect(args.rulePrefill, same(prefill));
    });

    test('requestDebugRouteArgs：无 extra → 分区/预填均为 null（回退默认）', () {
      final args = requestDebugRouteArgs(null);

      expect(args.section, isNull);
      expect(args.rulePrefill, isNull);
    });

    test('requestDebugRouteArgs：非预填 extra 亦安全回退', () {
      final args = requestDebugRouteArgs(<String, Object?>{'x': 1});

      expect(args.section, isNull);
      expect(args.rulePrefill, isNull);
    });
  });

  group('路由端到端（buildRequestDebugRoute 读 state.extra）', () {
    GoRouter buildRouter() => GoRouter(
          navigatorKey: appNavigatorKey,
          initialLocation: AppRoute.home,
          routes: [
            GoRoute(
              path: AppRoute.home,
              builder: (context, state) =>
                  const Scaffold(body: Text('home')),
            ),
            GoRoute(
              path: AppRoute.requestDebug,
              builder: (context, state) =>
                  buildRequestDebugRoute(state, facade: _noIoFacade()),
            ),
          ],
        );

    testWidgets('抓包创建改写规则 → 落到改写规则分区并预填', (tester) async {
      final router = buildRouter();
      await tester.pumpWidget(MaterialApp.router(
        routerConfig: router,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      ));
      await tester.pumpAndSettle();

      router.go(AppRoute.requestDebug, extra: _prefill());
      await tester.pumpAndSettle();

      expect(find.text('新建改写规则'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('request-debug-rule-url')))
            .controller!
            .text,
        'https://api.test/v2/item',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('request-debug-rule-method')))
            .controller!
            .text,
        'PUT',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('普通入口（无 extra）→ 默认集合分区', (tester) async {
      final router = buildRouter();
      await tester.pumpWidget(MaterialApp.router(
        routerConfig: router,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      ));
      await tester.pumpAndSettle();

      router.go(AppRoute.requestDebug);
      await tester.pumpAndSettle();

      expect(find.text('暂无集合'), findsOneWidget);
      expect(find.text('新建改写规则'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
