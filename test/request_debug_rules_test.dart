/// 「请求调试」改写规则分区 + 环境分区（plan todo 34）测试。
///
/// 覆盖验收标准：
/// - 列出：规则来自门面 Seam 2（`capture.rules.get`），行展示 URL / 方法 /
///   类型 / 开关 / 命中数；
/// - 新建 / 编辑 / 开关 / 删除：断言**精确**的 facade 调用参数；
/// - `capture.rules.set` 载荷映射：`enabled` 默认 `false` + kind 映射
///   （`replace_response` → `replace` / `local_response` → `local`）；
/// - 环境 CRUD：新建 / 编辑键值 / 当前环境切换 / 删除；
/// - 失败 QA：`capture.rules.set` 失败 → `showError`，不崩；
/// - UI 明确标注：规则为全局能力、默认关、WS 不支持改写。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/page/request_debug/environment_section.dart';
import 'package:gstore/page/request_debug/rules_section.dart';

// ==================== 假实现 ====================

/// 假发送器：**不触碰网络**（本测试不发送请求）。
class _FakeSender implements DebugSender {
  @override
  final DebugCookieJar cookieJar = DebugCookieJar();

  @override
  Future<DebugResponse> send({
    required String method,
    required String url,
    List<DebugHeader> headers = const <DebugHeader>[],
    List<DebugQueryParam> query = const <DebugQueryParam>[],
    String body = '',
    List<int>? bodyBytes,
    bool followRedirects = true,
    Duration? timeout,
    bool useCookies = true,
  }) async =>
      const DebugResponse(statusCode: 200);

  @override
  void close() {}
}

/// 假改写规则端口：记录调用、可受控抛错；`setRule` 做 upsert 以模拟引擎。
class _FakeRulesPort implements CaptureRulesPort {
  List<DebugRewriteRule> rules = <DebugRewriteRule>[];
  final List<DebugRewriteRule> setCalls = <DebugRewriteRule>[];
  final List<String> removeCalls = <String>[];
  bool throwOnGet = false;
  bool throwOnSet = false;
  String throwMessage = 'port boom';

  @override
  Future<List<DebugRewriteRule>> getRules() async {
    if (throwOnGet) throw StateError(throwMessage);
    return List<DebugRewriteRule>.of(rules);
  }

  @override
  Future<DebugRewriteRule> setRule(DebugRewriteRule rule) async {
    if (throwOnSet) throw StateError(throwMessage);
    setCalls.add(rule);
    final id = rule.id.isEmpty ? 'rule-minted-${setCalls.length}' : rule.id;
    final stored = rule.copyWith(id: id);
    final index = rules.indexWhere((r) => r.id == id);
    if (index >= 0) {
      rules[index] = stored;
    } else {
      rules.add(stored);
    }
    return stored;
  }

  @override
  Future<bool> removeRule(String id) async {
    removeCalls.add(id);
    final before = rules.length;
    rules.removeWhere((r) => r.id == id);
    return rules.length != before;
  }
}

/// 测试门面：真实内存 store（不落盘）+ 假 sender / 规则端口；记录 save 调用。
class _RecordingFacade extends DefaultRequestDebugFacade {
  _RecordingFacade({
    required super.store,
    required super.sender,
    required super.captureRules,
  });

  int saveCalls = 0;

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async {
    saveCalls++;
    return true;
  }
}

RequestDebugStore _memoryStore() =>
    RequestDebugStore(directoryProvider: () async => Directory.systemTemp);

_RecordingFacade _facade({
  RequestDebugStore? store,
  CaptureRulesPort? captureRules,
}) =>
    _RecordingFacade(
      store: store ?? _memoryStore(),
      sender: _FakeSender(),
      captureRules: captureRules ?? _FakeRulesPort(),
    );

/// 与生产相同的全局通道，使底部弹层 / Snackbar 可真实呈现。
Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(body: child),
    );

DebugRewriteRule _rule(
  String id, {
  bool enabled = false,
  String? method = 'GET',
  String url = 'https://api.example/p',
  DebugRewriteKind kind = DebugRewriteKind.replaceResponse,
  int hitCount = 0,
}) =>
    DebugRewriteRule(
      id: id,
      enabled: enabled,
      method: method,
      url: url,
      kind: kind,
      hitCount: hitCount,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('capture.rules.set 载荷映射', () {
    test('默认关 + replace kind：精确 toJson（含状态 / 头 / Body）', () {
      final request = debugRuleToSetRequest(const DebugRewriteRule(
        id: 'r1',
        // 不显式给 enabled：模型默认 false。
        method: 'POST',
        url: 'https://api.example/x',
        kind: DebugRewriteKind.replaceResponse,
        statusCode: 201,
        respHeaders: <DebugHeader>[
          DebugHeader(name: 'X-A', value: '1'),
          DebugHeader(name: 'X-Off', value: 'z', enabled: false),
        ],
        respBody: 'rewritten',
      ));

      expect(request.toJson(), <String, dynamic>{
        'id': 'r1',
        'enabled': false,
        'method': 'POST',
        'url': 'https://api.example/x',
        'kind': 'replace',
        'statusCode': 201,
        'headers': 'X-A: 1',
        'body': 'rewritten',
      });
    });

    test('local kind：无 id → 省略 id；kind 映射为 local', () {
      final request = debugRuleToSetRequest(const DebugRewriteRule(
        id: '',
        enabled: true,
        url: 'https://api.example/y',
        kind: DebugRewriteKind.localResponse,
        respBody: 'local',
      ));

      expect(request.toJson(), <String, dynamic>{
        'enabled': true,
        'url': 'https://api.example/y',
        'kind': 'local',
        'body': 'local',
      });
    });
  });

  group('改写规则列表', () {
    testWidgets('列表来自 capture.rules.get：展示 URL / 方法 / 类型 / 开关 / 命中数',
        (tester) async {
      final port = _FakeRulesPort()
        ..rules = <DebugRewriteRule>[
          _rule('r1',
              enabled: true, method: 'POST', url: 'https://api.example/p', hitCount: 3),
        ];
      final facade = _facade(captureRules: port);

      await tester.pumpWidget(_host(RequestDebugRulesSection(facade: facade)));
      await tester.pumpAndSettle();

      expect(find.text('https://api.example/p'), findsOneWidget);
      expect(find.textContaining('POST'), findsOneWidget);
      expect(find.textContaining('替换响应'), findsOneWidget);
      expect(find.textContaining('命中 3'), findsOneWidget);
      expect(find.textContaining('已启用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('顶部明确标注：全局能力 / 默认关 / WS 不支持改写', (tester) async {
      final facade = _facade();

      await tester.pumpWidget(_host(RequestDebugRulesSection(facade: facade)));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('request-debug-rules-global-note')),
        findsOneWidget,
      );
      expect(
        find.textContaining('全局引擎能力'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('request-debug-rules-ws-note')),
        findsOneWidget,
      );
      expect(find.textContaining('不支持 WS 改写'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加载失败 → 错误状态 + 重试可恢复', (tester) async {
      final port = _FakeRulesPort()..throwOnGet = true;
      final facade = _facade(captureRules: port);

      await tester.pumpWidget(_host(RequestDebugRulesSection(facade: facade)));
      await tester.pumpAndSettle();

      expect(find.text('规则加载失败'), findsOneWidget);

      port
        ..throwOnGet = false
        ..rules = <DebugRewriteRule>[_rule('r1')];
      await tester.tap(find.byKey(const Key('request-debug-rules-retry')));
      await tester.pumpAndSettle();

      expect(find.text('https://api.example/p'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('新建 / 编辑 / 开关 / 删除', () {
    testWidgets('新建：默认关 + 调参正确 + 列表刷新', (tester) async {
      final port = _FakeRulesPort();
      final facade = _facade(captureRules: port);

      await tester.pumpWidget(_host(RequestDebugRulesSection(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-debug-rules-add')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('request-debug-rule-url')),
        'https://api.example/new',
      );
      await tester.enterText(
        find.byKey(const Key('request-debug-rule-method')),
        'POST',
      );
      await tester.enterText(
        find.byKey(const Key('request-debug-rule-status')),
        '201',
      );
      await tester.enterText(
        find.byKey(const Key('request-debug-rule-headers')),
        'X-A: 1',
      );
      await tester.enterText(
        find.byKey(const Key('request-debug-rule-body')),
        'rewritten',
      );
      await tester.tap(find.byKey(const Key('request-debug-rule-save')));
      await tester.pumpAndSettle();

      // 精确的 facade 调用参数。
      expect(port.setCalls, hasLength(1));
      final passed = port.setCalls.single;
      expect(passed.enabled, isFalse, reason: '默认关：未经开关不得启用');
      expect(passed.kind, DebugRewriteKind.replaceResponse);
      expect(passed.url, 'https://api.example/new');
      expect(passed.method, 'POST');
      expect(passed.statusCode, 201);
      expect(passed.respHeaders!.single.name, 'X-A');
      expect(passed.respHeaders!.single.value, '1');
      expect(passed.respBody, 'rewritten');

      // 精确的 `capture.rules.set` 载荷。
      expect(debugRuleToSetRequest(passed).toJson(), <String, dynamic>{
        'enabled': false,
        'method': 'POST',
        'url': 'https://api.example/new',
        'kind': 'replace',
        'statusCode': 201,
        'headers': 'X-A: 1',
        'body': 'rewritten',
      });

      // 保存后列表刷新出现新规则。
      expect(find.text('https://api.example/new'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('编辑：预填并可保存（保留 id）', (tester) async {
      final port = _FakeRulesPort()
        ..rules = <DebugRewriteRule>[
          const DebugRewriteRule(
            id: 'r1',
            url: 'https://api.example/old',
            kind: DebugRewriteKind.replaceResponse,
            method: 'GET',
            remark: '旧备注',
          ),
        ];
      final facade = _facade(captureRules: port);

      await tester.pumpWidget(_host(RequestDebugRulesSection(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-debug-rule-r1')));
      await tester.pumpAndSettle();

      final urlField = tester.widget<TextField>(
        find.byKey(const Key('request-debug-rule-url')),
      );
      expect(urlField.controller!.text, 'https://api.example/old');
      final remarkField = tester.widget<TextField>(
        find.byKey(const Key('request-debug-rule-remark')),
      );
      expect(remarkField.controller!.text, '旧备注');

      await tester.enterText(
        find.byKey(const Key('request-debug-rule-url')),
        'https://api.example/updated',
      );
      await tester.tap(find.byKey(const Key('request-debug-rule-save')));
      await tester.pumpAndSettle();

      expect(port.setCalls, hasLength(1));
      expect(port.setCalls.single.id, 'r1');
      expect(port.setCalls.single.url, 'https://api.example/updated');
      expect(find.text('https://api.example/updated'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('开关：默认关 → 切换后调用 setRule(enabled:true)', (tester) async {
      final port = _FakeRulesPort()
        ..rules = <DebugRewriteRule>[_rule('r1', enabled: false)];
      final facade = _facade(captureRules: port);

      await tester.pumpWidget(_host(RequestDebugRulesSection(facade: facade)));
      await tester.pumpAndSettle();
      expect(find.textContaining('未启用'), findsOneWidget);

      await tester.tap(find.byKey(const Key('request-debug-rule-toggle-r1')));
      await tester.pumpAndSettle();

      expect(port.setCalls, hasLength(1));
      expect(port.setCalls.single.id, 'r1');
      expect(port.setCalls.single.enabled, isTrue);
      expect(find.textContaining('已启用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('删除：需二次确认，确认后调用 removeRule', (tester) async {
      final port = _FakeRulesPort()..rules = <DebugRewriteRule>[_rule('r1')];
      final facade = _facade(captureRules: port);

      await tester.pumpWidget(_host(RequestDebugRulesSection(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-debug-rule-menu-r1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-debug-rule-delete-r1')));
      await tester.pumpAndSettle();

      expect(find.text('删除改写规则'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(port.removeCalls, isEmpty, reason: '取消确认绝不能删除');

      await tester.tap(find.byKey(const Key('request-debug-rule-menu-r1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-debug-rule-delete-r1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(port.removeCalls, <String>['r1']);
      expect(find.text('暂无改写规则'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('capture.rules.set 失败 → showError 且不崩', (tester) async {
      final port = _FakeRulesPort()..throwOnSet = true;
      final facade = _facade(captureRules: port);

      await tester.pumpWidget(_host(RequestDebugRulesSection(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-debug-rules-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('request-debug-rule-url')),
        'https://api.example/boom',
      );
      await tester.tap(find.byKey(const Key('request-debug-rule-save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('规则保存失败'), findsOneWidget);
      expect(find.textContaining('port boom'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('环境 CRUD', () {
    testWidgets('新建环境 + 键值对编辑 → store 更新并落盘', (tester) async {
      final facade = _facade();

      await tester.pumpWidget(
        _host(RequestDebugEnvironmentSection(facade: facade)),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂无环境'), findsOneWidget);

      await tester.tap(find.byKey(const Key('request-debug-environment-add')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('request-debug-env-name')),
        'dev',
      );
      await tester.enterText(
        find.byKey(const Key('request-debug-env-key-0')),
        'host',
      );
      await tester.enterText(
        find.byKey(const Key('request-debug-env-value-0')),
        'https://api.example',
      );
      await tester.tap(find.byKey(const Key('request-debug-env-save')));
      await tester.pumpAndSettle();

      expect(facade.store.environments, hasLength(1));
      final env = facade.store.environments.single;
      expect(env.name, 'dev');
      expect(env.vars['host'], 'https://api.example');
      expect(facade.saveCalls, greaterThanOrEqualTo(1));
      expect(find.text('dev'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('当前环境切换：设为当前 / 再点取消', (tester) async {
      final facade = _facade();
      final env = facade.store.addEnvironment(
        name: 'dev',
        vars: <String, String>{'host': 'https://api.example'},
      );

      await tester.pumpWidget(
        _host(RequestDebugEnvironmentSection(facade: facade)),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(Key('request-debug-environment-active-${env.id}')),
      );
      await tester.pumpAndSettle();
      expect(facade.store.activeEnvironmentId, env.id);
      expect(find.text('当前：dev'), findsOneWidget);
      expect(find.textContaining('当前环境'), findsWidgets);

      await tester.tap(
        find.byKey(Key('request-debug-environment-active-${env.id}')),
      );
      await tester.pumpAndSettle();
      expect(facade.store.activeEnvironmentId, isNull);
      expect(find.text('当前：未设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('编辑环境：预填 + 修改键值', (tester) async {
      final facade = _facade();
      final env = facade.store.addEnvironment(
        name: 'dev',
        vars: <String, String>{'host': 'https://old.example'},
      );

      await tester.pumpWidget(
        _host(RequestDebugEnvironmentSection(facade: facade)),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(Key('request-debug-environment-${env.id}')),
      );
      await tester.pumpAndSettle();

      final valueField = tester.widget<TextField>(
        find.byKey(const Key('request-debug-env-value-0')),
      );
      expect(valueField.controller!.text, 'https://old.example');

      await tester.enterText(
        find.byKey(const Key('request-debug-env-value-0')),
        'https://new.example',
      );
      await tester.tap(find.byKey(const Key('request-debug-env-save')));
      await tester.pumpAndSettle();

      expect(facade.store.environments.single.vars['host'],
          'https://new.example');
      expect(tester.takeException(), isNull);
    });

    testWidgets('删除环境：需确认，确认后移除（当前环境一并清空）', (tester) async {
      final facade = _facade();
      final env = facade.store.addEnvironment(name: 'dev');
      facade.store.setActiveEnvironment(env.id);

      await tester.pumpWidget(
        _host(RequestDebugEnvironmentSection(facade: facade)),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(Key('request-debug-environment-menu-${env.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('request-debug-environment-delete-${env.id}')),
      );
      await tester.pumpAndSettle();

      expect(find.text('删除环境'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(facade.store.environments, hasLength(1), reason: '取消不得删除');

      await tester.tap(
        find.byKey(Key('request-debug-environment-menu-${env.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('request-debug-environment-delete-${env.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(facade.store.environments, isEmpty);
      expect(facade.store.activeEnvironmentId, isNull);
      expect(find.text('暂无环境'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
