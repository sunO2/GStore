// Todo 21 tests：实时连接页（`conn.list` / `conn.close` / `conn.close_all`）。
//
// 全部密闭式：门面经假网关（facade 单测）或假门面（widget 测试）注入，
// 不触碰 FFI / 原生模块。弹层宿主复用生产全局通道 `appNavigatorKey` +
// `AppDialogs.scaffoldMessengerKey`，因此走真实的 `AppSheet` 呈现路径。
//
// 覆盖（Todo 21 验收）：
// * 列出活动连接；
// * 域名 / 出站筛选把过滤条件转发到 `conn.list` 且只渲染返回结果；
// * 单条断开调用 `conn.close`；全部断开调用 `conn.close_all`；
// * 空态渲染；
// * 错误态（模块不可用 → 显式失败 + 重试恢复）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_connections_facade.dart';
import 'package:gstore/page/proxy/proxy_connections_page.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

// ==================== 假网关（facade 单测） ====================

/// 假网关：受控返回信封响应并记录方法名 / 载荷；**不触碰 FFI**。
class _FakeGateway implements ProxyModuleGateway {
  _FakeGateway(this.responses);

  final Map<String, Uint8List> responses;
  final List<String> methods = <String>[];
  final Map<String, Uint8List?> payloads = <String, Uint8List?>{};

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    methods.add(method);
    payloads[method] = payload;
    final response = responses[method];
    if (response == null) {
      throw StateError('no stub for $method');
    }
    return response;
  }

  @override
  Stream<ProxyRawEvent> get events => const Stream<ProxyRawEvent>.empty();
}

Uint8List _okEnvelope(Map<String, dynamic> data) => Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );

Map<String, dynamic> _decode(Uint8List? bytes) =>
    jsonDecode(utf8.decode(bytes!)) as Map<String, dynamic>;

// ==================== 假门面（widget 测试） ====================

ConnInfo _conn(
  String id, {
  String domain = 'example.com',
  String outbound = 'DIRECT',
  String dst = '1.2.3.4:443',
}) =>
    ConnInfo(
      id: id,
      src: '10.10.0.2:40000',
      dst: dst,
      domain: domain,
      network: 'tcp',
      rule: 'DOMAIN-SUFFIX',
      rulePayload: domain,
      outbound: outbound,
      uploadBytes: 128,
      downloadBytes: 4096,
      startedAtMs: 1700000000000,
    );

class _FakeConnectionsFacade implements ProxyConnectionsFacade {
  _FakeConnectionsFacade({this.page = const ConnPage()});

  ConnPage page;
  bool failList = false;
  bool failClose = false;
  bool failCloseAll = false;
  ConnPage Function(ConnListRequest request)? onList;

  int listCalls = 0;
  int closeCalls = 0;
  int closeAllCalls = 0;
  ConnListRequest? lastList;
  String? lastClosedId;

  @override
  Future<ConnPage> connList(ConnListRequest request) async {
    listCalls++;
    lastList = request;
    if (failList) {
      throw ProxyModuleUnavailableException();
    }
    final handler = onList;
    if (handler != null) return handler(request);
    return page;
  }

  @override
  Future<ConnCloseResult> connClose(String id) async {
    closeCalls++;
    lastClosedId = id;
    if (failClose) {
      throw const ProxyModuleException(code: 'CLOSE_FAIL', message: '断开失败');
    }
    return ConnCloseResult(
      ok: true,
      id: id,
      closed: true,
      alreadyClosed: false,
    );
  }

  @override
  Future<ConnCloseAllResult> connCloseAll() async {
    closeAllCalls++;
    if (failCloseAll) {
      throw const ProxyModuleException(code: 'CLOSE_ALL_FAIL', message: '全部断开失败');
    }
    return const ConnCloseAllResult(ok: true, closed: 2);
  }
}

// ==================== facade 单测 ====================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProxyModuleConnectionsFacade', () {
    test('转发 conn.list/close/close_all 并按契约解码与透传请求字段', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        ProxyMethods.connList: _okEnvelope(<String, dynamic>{
          'connections': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'c1',
              'src': '10.10.0.2:40000',
              'dst': '1.2.3.4:443',
              'domain': 'example.com',
              'network': 'tcp',
              'rule': 'DOMAIN-SUFFIX',
              'rulePayload': 'example.com',
              'outbound': 'proxy-a',
              'uploadBytes': 10,
              'downloadBytes': 20,
              'startedAtMs': 1234,
            },
          ],
          'count': 5,
          'returned': 1,
          'total': 9,
          'offset': 0,
          'limit': 256,
          'hasMore': true,
          'capacity': 1024,
        }),
        ProxyMethods.connClose: _okEnvelope(<String, dynamic>{
          'ok': true,
          'id': 'c1',
          'closed': true,
          'alreadyClosed': false,
        }),
        ProxyMethods.connCloseAll: _okEnvelope(<String, dynamic>{
          'ok': true,
          'closed': 3,
        }),
      });
      final ProxyConnectionsFacade facade =
          ProxyModuleConnectionsFacade(ProxyModule(gateway: gateway));

      final page = await facade.connList(
        const ConnListRequest(
          offset: 0,
          limit: 50,
          domain: 'example',
          outbound: 'proxy-a',
        ),
      );
      final closed = await facade.connClose('c1');
      final all = await facade.connCloseAll();

      expect(gateway.methods, <String>[
        ProxyMethods.connList,
        ProxyMethods.connClose,
        ProxyMethods.connCloseAll,
      ]);
      // 请求字段透传到线缆（domain/outbound 过滤由 Rust 侧执行）。
      final listPayload = _decode(gateway.payloads[ProxyMethods.connList]);
      expect(listPayload['offset'], 0);
      expect(listPayload['limit'], 50);
      expect(listPayload['domain'], 'example');
      expect(listPayload['outbound'], 'proxy-a');
      expect(
        _decode(gateway.payloads[ProxyMethods.connClose])['id'],
        'c1',
      );
      expect(gateway.payloads[ProxyMethods.connCloseAll], isNull);

      // 类型化解码。
      expect(page.connections, hasLength(1));
      final conn = page.connections.single;
      expect(conn.id, 'c1');
      expect(conn.domain, 'example.com');
      expect(conn.outbound, 'proxy-a');
      expect(conn.uploadBytes, 10);
      expect(conn.downloadBytes, 20);
      expect(conn.startedAtMs, 1234);
      expect(page.count, 5);
      expect(page.total, 9);
      expect(page.hasMore, isTrue);
      expect(page.capacity, 1024);

      expect(closed.closed, isTrue);
      expect(closed.id, 'c1');
      expect(all.closed, 3);
    });

    test('缺字段 / 空响应不崩溃（解码为默认值）', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        ProxyMethods.connList: _okEnvelope(const <String, dynamic>{}),
        ProxyMethods.connClose: _okEnvelope(const <String, dynamic>{}),
        ProxyMethods.connCloseAll: _okEnvelope(const <String, dynamic>{}),
      });
      final ProxyConnectionsFacade facade =
          ProxyModuleConnectionsFacade(ProxyModule(gateway: gateway));

      final page = await facade.connList(const ConnListRequest());
      final closed = await facade.connClose('x');
      final all = await facade.connCloseAll();

      expect(page.connections, isEmpty);
      expect(page.total, 0);
      expect(page.hasMore, isFalse);
      expect(closed.closed, isFalse);
      expect(all.closed, 0);
    });
  });

  // ==================== widget 测试 ====================

  Widget page(_FakeConnectionsFacade facade) => _host(
        ProxyConnectionsPage(
          facade: facade,
          events: const Stream<ProxyEvent>.empty(),
          initialLive: false,
        ),
      );

  testWidgets('列出活动连接：域名 / 出站 / 字节渲染', (tester) async {
    final facade = _FakeConnectionsFacade(
      page: ConnPage(
        connections: <ConnInfo>[
          _conn('c1', domain: 'example.com', outbound: 'proxy-a'),
          _conn('c2', domain: 'api.test.io', outbound: 'DIRECT'),
        ],
        count: 2,
        returned: 2,
        total: 2,
        hasMore: false,
      ),
    );
    await tester.pumpWidget(page(facade));
    await _flush(tester);

    expect(facade.listCalls, 1);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('api.test.io'), findsOneWidget);
    expect(find.textContaining('proxy-a'), findsWidgets);
    expect(find.textContaining('DIRECT'), findsWidgets);
    expect(find.byKey(const Key('conn_close_c1')), findsOneWidget);
    expect(find.byKey(const Key('conn_close_c2')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('域名筛选转发到 conn.list 且只渲染返回结果', (tester) async {
    final facade = _FakeConnectionsFacade(
      page: ConnPage(
        connections: <ConnInfo>[_conn('c1', domain: 'example.com')],
        count: 2,
        returned: 1,
        total: 2,
        hasMore: false,
      ),
    );
    facade.onList = (request) {
      if (request.domain == 'api') {
        return ConnPage(
          connections: <ConnInfo>[_conn('c2', domain: 'api.test.io')],
          count: 1,
          returned: 1,
          total: 2,
          hasMore: false,
        );
      }
      return facade.page;
    };
    await tester.pumpWidget(page(facade));
    await _flush(tester);
    expect(find.text('example.com'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('connections_domain_search')),
      'api',
    );
    await _flush(tester);

    expect(facade.lastList!.domain, 'api');
    expect(find.text('api.test.io'), findsOneWidget);
    expect(find.text('example.com'), findsNothing);
  });

  testWidgets('单条断开：确认后调用 conn.close 并刷新', (tester) async {
    final facade = _FakeConnectionsFacade(
      page: ConnPage(
        connections: <ConnInfo>[_conn('c1')],
        count: 1,
        returned: 1,
        total: 1,
        hasMore: false,
      ),
    );
    await tester.pumpWidget(page(facade));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('conn_close_c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('断开'));
    await tester.pumpAndSettle();

    expect(facade.closeCalls, 1);
    expect(facade.lastClosedId, 'c1');
    // 断开后刷新列表。
    expect(facade.listCalls, greaterThanOrEqualTo(2));
  });

  testWidgets('全部断开：确认后调用 conn.close_all', (tester) async {
    final facade = _FakeConnectionsFacade(
      page: ConnPage(
        connections: <ConnInfo>[_conn('c1'), _conn('c2')],
        count: 2,
        returned: 2,
        total: 2,
        hasMore: false,
      ),
    );
    await tester.pumpWidget(page(facade));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('connections_close_all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部断开'));
    await tester.pumpAndSettle();

    expect(facade.closeAllCalls, 1);
  });

  testWidgets('空态渲染', (tester) async {
    final facade = _FakeConnectionsFacade(page: const ConnPage());
    await tester.pumpWidget(page(facade));
    await _flush(tester);

    expect(find.text('暂无活动连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('错误态：模块不可用显式失败并可重试恢复', (tester) async {
    final facade = _FakeConnectionsFacade()..failList = true;
    await tester.pumpWidget(page(facade));
    await _flush(tester);

    expect(find.text('活动连接不可用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 重试：模块恢复后列出连接。
    facade.failList = false;
    facade.page = ConnPage(
      connections: <ConnInfo>[_conn('c9', domain: 'recovered.io')],
      count: 1,
      returned: 1,
      total: 1,
      hasMore: false,
    );
    await tester.tap(find.text('重试'));
    await _flush(tester);

    expect(find.text('recovered.io'), findsOneWidget);
    expect(find.text('活动连接不可用'), findsNothing);
  });
}
