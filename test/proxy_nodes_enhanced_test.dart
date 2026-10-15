import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_nodes_facade.dart';
import 'package:gstore/page/proxy/proxy_nodes_page.dart';

/// 假门面：无需原生模块，记录选择并受控返回。
class _FakeNodesFacade implements ProxyNodesFacade {
  final StreamController<ProxyEvent> controller =
      StreamController<ProxyEvent>.broadcast(sync: true);

  final List<List<String>> selects = <List<String>>[];

  @override
  Stream<ProxyEvent> get events => controller.stream;

  @override
  Future<StoredProfile> profileGet(String id) async => const StoredProfile(
        id: 'p1',
        profile: ImportedProfile(name: '订阅', format: 'clash'),
      );

  @override
  Future<NodeSelectResult> nodeSelect(String group, String node) async {
    selects.add(<String>[group, node]);
    return NodeSelectResult(ok: true, group: group, node: node, active: node);
  }

  @override
  Future<DelayTestResult> nodeDelayTest(NodeDelayTestRequest request) async =>
      const DelayTestResult();

  @override
  Future<NodeListResult> nodeList() async => const NodeListResult();

  @override
  Future<void> reconcileEngine(String profileId) async {}
}

const ProxyNode _alpha = ProxyNode(
  name: 'alpha',
  type: 'ss',
  server: '1.1.1.1',
  port: 443,
  cipher: 'aes-256-gcm',
);

const ProxyNode _beta = ProxyNode(
  name: 'beta',
  type: 'vmess',
  server: '2.2.2.2',
  port: 8443,
);

const List<ProxyGroup> _groups = <ProxyGroup>[
  ProxyGroup(
    name: 'PROXY',
    type: 'select',
    members: <String>['alpha', 'beta'],
  ),
];

/// 两个分组各含一个**同名但不同服务器**的节点：不得互相串用。
const ProxyNode _xProxy = ProxyNode(
  name: 'X',
  type: 'ss',
  server: '10.0.0.1',
  port: 443,
  groups: <String>['PROXY'],
);

const ProxyNode _xAuto = ProxyNode(
  name: 'X',
  type: 'vmess',
  server: '10.0.0.2',
  port: 8443,
  groups: <String>['AUTO'],
);

const List<ProxyGroup> _dupGroups = <ProxyGroup>[
  ProxyGroup(name: 'PROXY', type: 'select', members: <String>['X']),
  ProxyGroup(name: 'AUTO', type: 'url-test', members: <String>['X']),
];

Widget _wrap(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      home: child,
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 宫格阅读顺序：先按 y（行），同一行再按 x（列）。
bool _comesBefore(WidgetTester tester, Key a, Key b) {
  final Offset oa = tester.getTopLeft(find.byKey(a));
  final Offset ob = tester.getTopLeft(find.byKey(b));
  if (oa.dy != ob.dy) return oa.dy < ob.dy;
  return oa.dx < ob.dx;
}

Key _nodeTile(String name) => Key('proxy_nodes_member_PROXY_$name');

void main() {
  testWidgets('搜索：按名称/端点过滤，清空恢复（nodes 模式）',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_alpha, _beta],
      groups: _groups,
      hasProxyGroups: false,
      facade: facade,
    )));

    expect(find.byKey(_nodeTile('alpha')), findsOneWidget);
    expect(find.byKey(_nodeTile('beta')), findsOneWidget);

    // 名称过滤：只剩 beta。
    await tester.enterText(find.byKey(const Key('proxy_nodes_search')), 'beta');
    await tester.pump();
    expect(find.byKey(_nodeTile('alpha')), findsNothing);
    expect(find.byKey(_nodeTile('beta')), findsOneWidget);

    // 端点过滤：只剩 alpha。
    await tester.enterText(
      find.byKey(const Key('proxy_nodes_search')),
      '1.1.1.1',
    );
    await tester.pump();
    expect(find.byKey(_nodeTile('alpha')), findsOneWidget);
    expect(find.byKey(_nodeTile('beta')), findsNothing);

    // 清空恢复全部。
    await tester.tap(find.byKey(const Key('proxy_nodes_search_clear')));
    await tester.pump();
    expect(find.byKey(_nodeTile('alpha')), findsOneWidget);
    expect(find.byKey(_nodeTile('beta')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('收藏：收藏节点置顶（nodes 模式）', (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_alpha, _beta],
      groups: _groups,
      hasProxyGroups: false,
      facade: facade,
    )));

    // 名称排序：alpha 在 beta 之前。
    expect(
      _comesBefore(tester, _nodeTile('alpha'), _nodeTile('beta')),
      isTrue,
    );

    // 打开 beta 节点弹层：底部已无收藏动作，收藏改由节点行左滑露出。
    await tester.tap(find.byKey(_nodeTile('beta')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('proxy_nodes_sheet_node')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_row_favorite_beta')));
    await tester.pumpAndSettle();

    // 关闭弹层。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // 收藏后 beta 置顶（排在 alpha 之前）。
    expect(
      _comesBefore(tester, _nodeTile('beta'), _nodeTile('alpha')),
      isTrue,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('重名节点：各分组解析各自节点（不串用）且独立选择',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_xProxy, _xAuto],
      groups: _dupGroups,
      facade: facade,
    )));

    // PROXY 弹层：X 必须是 10.0.0.1（而非 AUTO 的 10.0.0.2）。
    await tester.tap(find.byKey(const Key('proxy_nodes_group_PROXY')));
    await tester.pumpAndSettle();
    expect(find.textContaining('10.0.0.1'), findsWidgets);
    expect(find.textContaining('10.0.0.2'), findsNothing);
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_X')));
    await tester.pumpAndSettle();
    expect(facade.selects.last, <String>['PROXY', 'X']);

    // AUTO 弹层：X 必须是 10.0.0.2（而非 PROXY 的 10.0.0.1）。
    await tester.tap(find.byKey(const Key('proxy_nodes_group_AUTO')));
    await tester.pumpAndSettle();
    expect(find.textContaining('10.0.0.2'), findsWidgets);
    expect(find.textContaining('10.0.0.1'), findsNothing);
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_X')));
    await tester.pumpAndSettle();
    expect(facade.selects.last, <String>['AUTO', 'X']);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('复制：复制节点地址写入剪贴板', (WidgetTester tester) async {
    _useTallViewport(tester);
    final List<MethodCall> calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_alpha, _beta],
      groups: _groups,
      hasProxyGroups: false,
      facade: facade,
    )));

    await tester.tap(find.byKey(_nodeTile('alpha')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_node_copy')));
    await tester.pumpAndSettle();

    final List<MethodCall> clipboard = calls
        .where((MethodCall c) => c.method == 'Clipboard.setData')
        .toList();
    expect(clipboard, isNotEmpty);
    expect(
      (clipboard.last.arguments as Map<Object?, Object?>)['text'],
      '1.1.1.1:443',
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('详情：展示契约已有字段（类型/服务器/端口/加密）',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_alpha, _beta],
      groups: _groups,
      hasProxyGroups: false,
      facade: facade,
    )));

    await tester.tap(find.byKey(_nodeTile('alpha')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_node_detail')));
    await tester.pumpAndSettle();

    final Finder detail = find.byKey(const Key('proxy_nodes_detail'));
    expect(detail, findsOneWidget);
    expect(
      find.descendant(of: detail, matching: find.text('ss')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: detail, matching: find.textContaining('1.1.1.1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: detail, matching: find.text('443')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: detail, matching: find.text('aes-256-gcm')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });
}
