/// 「请求调试」各分区搜索 / 过滤 / 排序（plan todo 15）测试。
///
/// 覆盖验收标准：
/// - 纯函数：集合树 / 历史 / 环境 / 规则的过滤与排序（不修改输入、空查询返回
///   原副本、无匹配返回空、绝不抛异常）；
/// - widget：在各分区输入关键字只剩匹配项；无匹配显示空态；清空恢复全量；
///   无匹配不崩。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_search.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/page/request_debug/collection_section.dart';
import 'package:gstore/page/request_debug/environment_section.dart';
import 'package:gstore/page/request_debug/history_section.dart';
import 'package:gstore/page/request_debug/rules_section.dart';

// ==================== 假实现 ====================

/// 假发送器：**不触碰网络**。
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
    bool skipTlsVerify = false,
    DebugCancellationToken? cancelToken,
  }) async =>
      const DebugResponse(statusCode: 200);

  @override
  void close() {}
}

/// 假改写规则端口：内存表。
class _FakeRulesPort implements CaptureRulesPort {
  List<DebugRewriteRule> rules = <DebugRewriteRule>[];

  @override
  Future<List<DebugRewriteRule>> getRules() async =>
      List<DebugRewriteRule>.of(rules);

  @override
  Future<DebugRewriteRule> setRule(DebugRewriteRule rule) async => rule;

  @override
  Future<bool> removeRule(String id) async => false;
}

/// 测试门面：真实内存 store（不落盘）+ 假 sender / 规则端口。
class _RecordingFacade extends DefaultRequestDebugFacade {
  _RecordingFacade({
    required super.store,
    required super.sender,
    required super.captureRules,
  });

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async => true;
}

RequestDebugStore _memoryStore() =>
    RequestDebugStore(directoryProvider: () async => Directory.systemTemp);

_RecordingFacade _facade({CaptureRulesPort? captureRules}) => _RecordingFacade(
      store: _memoryStore(),
      sender: _FakeSender(),
      captureRules: captureRules ?? _FakeRulesPort(),
    );

/// 与生产相同的全局通道，使底部弹层 / Snackbar 可真实呈现。
Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(body: child),
    );

DebugRequest _request(String id, {String name = '', String url = ''}) =>
    DebugRequest(id: id, name: name, url: url);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==================== 纯函数：集合树 ====================

  group('filterDebugCollections', () {
    List<DebugCollection> tree() => <DebugCollection>[
      DebugCollection(
        id: 'c1',
        name: 'Alpha',
        requests: <DebugRequest>[
          _request('r1', name: 'List users', url: 'https://example.com/users'),
        ],
      ),
      DebugCollection(
        id: 'c2',
        name: 'Beta',
        requests: <DebugRequest>[
          _request('r2', name: 'Health', url: 'https://example.com/health'),
        ],
      ),
    ];

    test('空查询返回全部（副本，不改输入）', () {
      final input = tree();
      final out = filterDebugCollections(input, '  ');
      expect(out.map((e) => e.id), <String>['c1', 'c2']);
      expect(out, isNot(same(input)));
    });

    test('请求命中：只剩该请求与所属集合', () {
      final out = filterDebugCollections(tree(), 'health');
      expect(out.map((e) => e.id), <String>['c2']);
      expect(out.single.requests.single.id, 'r2');
    });

    test('集合名命中：保留集合并保留其全部请求', () {
      final out = filterDebugCollections(tree(), 'alpha');
      expect(out.map((e) => e.id), <String>['c1']);
      expect(out.single.requests.single.id, 'r1');
    });

    test('子文件夹命中：保留祖先链（层级）', () {
      final input = <DebugCollection>[
        DebugCollection(id: 'c0', name: 'Root'),
        DebugCollection(id: 'c1', name: 'Nested', parentId: 'c0'),
      ];
      final out = filterDebugCollections(input, 'nested');
      expect(out.map((e) => e.id), <String>['c0', 'c1']);
    });

    test('无匹配返回空，不抛', () {
      expect(filterDebugCollections(tree(), 'zzz-nope'), isEmpty);
    });
  });

  group('sortDebugCollections', () {
    List<DebugCollection> tree() => <DebugCollection>[
      DebugCollection(id: 'b', name: 'Beta'),
      DebugCollection(id: 'a', name: 'Alpha'),
      DebugCollection(id: 'z', name: 'Zeta', parentId: 'a'),
    ];

    test('original 返回输入副本（原顺序）', () {
      final out = sortDebugCollections(tree(), DebugSortOrder.original);
      expect(out.map((e) => e.id), <String>['b', 'a', 'z']);
    });

    test('nameAsc：同级排序且保持父子层级', () {
      final out = sortDebugCollections(tree(), DebugSortOrder.nameAsc);
      expect(out.map((e) => e.id), <String>['a', 'z', 'b']);
    });

    test('nameDesc：同级降序', () {
      final out = sortDebugCollections(tree(), DebugSortOrder.nameDesc);
      expect(out.map((e) => e.id), <String>['b', 'a', 'z']);
    });
  });

  // ==================== 纯函数：历史 ====================

  group('filterDebugHistory / sortDebugHistory', () {
    DebugHistoryEntry entry(String id, String url, int ts) => DebugHistoryEntry(
          id: id,
          tsMs: ts,
          request: _request(id, url: url),
          responseSummary: const DebugResponseSummary(statusCode: 200),
        );

    final entries = <DebugHistoryEntry>[
      entry('h1', 'https://example.com/b', 2),
      entry('h2', 'https://example.com/a', 1),
    ];

    test('过滤：URL 命中；空查询返回全部；无匹配为空', () {
      expect(
        filterDebugHistory(entries, 'b').map((e) => e.id),
        <String>['h1'],
      );
      expect(filterDebugHistory(entries, ''), hasLength(2));
      expect(filterDebugHistory(entries, 'nope'), isEmpty);
    });

    test('排序：original 保持（最新在前）；nameAsc 按 URL', () {
      expect(
        sortDebugHistory(entries, DebugSortOrder.original).map((e) => e.id),
        <String>['h1', 'h2'],
      );
      expect(
        sortDebugHistory(entries, DebugSortOrder.nameAsc).map((e) => e.id),
        <String>['h2', 'h1'],
      );
    });
  });

  // ==================== 纯函数：环境 ====================

  group('filterDebugEnvironments / sortDebugEnvironments', () {
    final envs = <DebugEnvironment>[
      DebugEnvironment(id: 'e1', name: 'prod', vars: {'host': 'p'}),
      DebugEnvironment(id: 'e2', name: 'dev', vars: {'token': 't'}),
    ];

    test('过滤：名称 / 变量键命中；无匹配为空', () {
      expect(
        filterDebugEnvironments(envs, 'dev').map((e) => e.id),
        <String>['e2'],
      );
      expect(
        filterDebugEnvironments(envs, 'host').map((e) => e.id),
        <String>['e1'],
      );
      expect(filterDebugEnvironments(envs, 'nope'), isEmpty);
    });

    test('排序：nameAsc / nameDesc', () {
      expect(
        sortDebugEnvironments(envs, DebugSortOrder.nameAsc).map((e) => e.id),
        <String>['e2', 'e1'],
      );
      expect(
        sortDebugEnvironments(envs, DebugSortOrder.nameDesc).map((e) => e.id),
        <String>['e1', 'e2'],
      );
    });
  });

  // ==================== 纯函数：改写规则 ====================

  group('filterDebugRules / sortDebugRules', () {
    final rules = <DebugRewriteRule>[
      const DebugRewriteRule(
        id: 'r1',
        method: 'GET',
        url: 'https://example.com/b',
        kind: DebugRewriteKind.replaceResponse,
        remark: 'beta rule',
      ),
      const DebugRewriteRule(
        id: 'r2',
        method: 'POST',
        url: 'https://example.com/a',
        kind: DebugRewriteKind.localResponse,
        remark: 'alpha rule',
      ),
    ];

    test('过滤：URL / 方法 / 备注命中；无匹配为空', () {
      expect(filterDebugRules(rules, 'post').map((e) => e.id), <String>['r2']);
      expect(
        filterDebugRules(rules, 'beta').map((e) => e.id),
        <String>['r1'],
      );
      expect(filterDebugRules(rules, 'nope'), isEmpty);
    });

    test('排序：nameAsc 按 URL', () {
      expect(
        sortDebugRules(rules, DebugSortOrder.nameAsc).map((e) => e.id),
        <String>['r2', 'r1'],
      );
    });
  });

  // ==================== widget：集合分区 ====================

  group('集合分区搜索', () {
    _RecordingFacade seeded() {
      final facade = _facade();
      final c1 = facade.store.addCollection(name: 'Alpha');
      facade.store.addRequest(
        c1.id,
        _request('r1', name: 'List users', url: 'https://example.com/users'),
      );
      final c2 = facade.store.addCollection(name: 'Beta');
      facade.store.addRequest(
        c2.id,
        _request('r2', name: 'Health', url: 'https://example.com/health'),
      );
      return facade;
    }

    testWidgets('输入关键字只剩匹配；清空恢复；无匹配空态且不崩', (tester) async {
      await tester.pumpWidget(
        _host(RequestDebugCollectionSection(facade: seeded())),
      );
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/users'), findsOneWidget);
      expect(find.text('https://example.com/health'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('request-debug-collection-search')),
        'health',
      );
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/health'), findsOneWidget);
      expect(find.text('https://example.com/users'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('request-debug-collection-search')),
        'no-such-thing',
      );
      await tester.pumpAndSettle();
      expect(find.text('未找到匹配的集合'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.enterText(
        find.byKey(const Key('request-debug-collection-search')),
        '',
      );
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/users'), findsOneWidget);
      expect(find.text('https://example.com/health'), findsOneWidget);
      expect(find.text('未找到匹配的集合'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('排序菜单切换：名称升序改变根集合顺序', (tester) async {
      final facade = _facade();
      final beta = facade.store.addCollection(name: 'Beta');
      final alpha = facade.store.addCollection(name: 'Alpha');

      await tester.pumpWidget(
        _host(RequestDebugCollectionSection(facade: facade)),
      );
      await tester.pumpAndSettle();

      double y(String id) => tester
          .getTopLeft(find.byKey(Key('request-debug-collection-$id')))
          .dy;

      // 默认原序：Beta 先于 Alpha。
      expect(y(beta.id) < y(alpha.id), isTrue);

      await tester.tap(find.byKey(const Key('request-debug-collection-sort')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('request-debug-collection-sort-name_asc')),
      );
      await tester.pumpAndSettle();

      // 名称升序：Alpha 先于 Beta。
      expect(y(alpha.id) < y(beta.id), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  // ==================== widget：历史分区 ====================

  group('历史分区搜索', () {
    _RecordingFacade seeded() {
      final facade = _facade();
      appendDebugHistory(
        facade,
        request: _request('r1', url: 'https://example.com/users'),
        response: const DebugResponse(statusCode: 200),
      );
      appendDebugHistory(
        facade,
        request: _request('r2', url: 'https://example.com/health'),
        response: const DebugResponse(statusCode: 200),
      );
      return facade;
    }

    testWidgets('输入关键字只剩匹配；清空恢复；无匹配空态且不崩', (tester) async {
      await tester.pumpWidget(
        _host(RequestDebugHistorySection(facade: seeded())),
      );
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/users'), findsOneWidget);
      expect(find.text('https://example.com/health'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('request-debug-history-search')),
        'health',
      );
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/health'), findsOneWidget);
      expect(find.text('https://example.com/users'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('request-debug-history-search')),
        'no-such-thing',
      );
      await tester.pumpAndSettle();
      expect(find.text('未找到匹配的历史'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.enterText(
        find.byKey(const Key('request-debug-history-search')),
        '',
      );
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/users'), findsOneWidget);
      expect(find.text('https://example.com/health'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ==================== widget：环境分区 ====================

  group('环境分区搜索', () {
    _RecordingFacade seeded() {
      final facade = _facade();
      facade.store.addEnvironment(name: 'prod', vars: {'host': 'p'});
      facade.store.addEnvironment(name: 'dev', vars: {'token': 't'});
      return facade;
    }

    testWidgets('输入关键字只剩匹配；清空恢复；无匹配空态且不崩', (tester) async {
      await tester.pumpWidget(
        _host(RequestDebugEnvironmentSection(facade: seeded())),
      );
      await tester.pumpAndSettle();
      expect(find.text('prod'), findsOneWidget);
      expect(find.text('dev'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('request-debug-environment-search')),
        'token',
      );
      await tester.pumpAndSettle();
      expect(find.text('dev'), findsOneWidget);
      expect(find.text('prod'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('request-debug-environment-search')),
        'no-such-thing',
      );
      await tester.pumpAndSettle();
      expect(find.text('未找到匹配的环境'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.enterText(
        find.byKey(const Key('request-debug-environment-search')),
        '',
      );
      await tester.pumpAndSettle();
      expect(find.text('prod'), findsOneWidget);
      expect(find.text('dev'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ==================== widget：改写规则分区 ====================

  group('改写规则分区搜索', () {
    _RecordingFacade seeded() {
      final port = _FakeRulesPort()
        ..rules = <DebugRewriteRule>[
          const DebugRewriteRule(
            id: 'r1',
            method: 'GET',
            url: 'https://example.com/users',
            kind: DebugRewriteKind.replaceResponse,
          ),
          const DebugRewriteRule(
            id: 'r2',
            method: 'POST',
            url: 'https://example.com/health',
            kind: DebugRewriteKind.localResponse,
          ),
        ];
      return _facade(captureRules: port);
    }

    testWidgets('输入关键字只剩匹配；清空恢复；无匹配空态且不崩', (tester) async {
      await tester.pumpWidget(_host(RequestDebugRulesSection(facade: seeded())));
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/users'), findsOneWidget);
      expect(find.text('https://example.com/health'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('request-debug-rules-search')),
        'health',
      );
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/health'), findsOneWidget);
      expect(find.text('https://example.com/users'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('request-debug-rules-search')),
        'no-such-thing',
      );
      await tester.pumpAndSettle();
      expect(find.text('未找到匹配的规则'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.enterText(
        find.byKey(const Key('request-debug-rules-search')),
        '',
      );
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/users'), findsOneWidget);
      expect(find.text('https://example.com/health'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
