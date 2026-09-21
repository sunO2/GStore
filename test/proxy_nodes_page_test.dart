import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart' show AppLoading;
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_nodes_facade.dart';
import 'package:gstore/page/proxy/proxy_nodes_page.dart';

/// 假门面：无需原生模块，可受控返回选择/延迟结果并推送类型化事件。
class _FakeNodesFacade implements ProxyNodesFacade {
  // 与生产门面一致：同步广播，事件在 add 时立即投递。
  final StreamController<ProxyEvent> controller =
      StreamController<ProxyEvent>.broadcast(sync: true);

  final List<List<String>> selects = <List<String>>[];
  NodeDelayTestRequest? lastDelayRequest;
  bool delayThrows = false;

  /// 测试通过它手动控制 `node.delay_test` 的完成时机（以便断言进行中态）。
  Completer<DelayTestResult>? delayCompleter;

  @override
  Stream<ProxyEvent> get events => controller.stream;

  @override
  Future<NodeSelectResult> nodeSelect(String group, String node) async {
    selects.add(<String>[group, node]);
    return NodeSelectResult(ok: true, group: group, node: node, active: node);
  }

  @override
  Future<DelayTestResult> nodeDelayTest(NodeDelayTestRequest request) {
    lastDelayRequest = request;
    if (delayThrows) {
      return Future<DelayTestResult>.error(const ProxyModuleException(
        code: 'PROXY_NODE_NOT_FOUND',
        message: '分组不存在',
      ));
    }
    final completer = Completer<DelayTestResult>();
    delayCompleter = completer;
    return completer.future;
  }
}

const ProxyNode _hk = ProxyNode(
  name: '香港 01',
  type: 'ss',
  server: '1.1.1.1',
  port: 443,
);

const ProxyNode _jp = ProxyNode(
  name: '日本 02',
  type: 'vmess',
  server: '2.2.2.2',
  port: 443,
);

const ProxyNode _us = ProxyNode(
  name: '美国 03',
  type: 'trojan',
  server: '3.3.3.3',
  port: 443,
);

const List<ProxyGroup> _groups = <ProxyGroup>[
  ProxyGroup(name: 'PROXY', type: 'select', members: <String>['香港 01', '日本 02']),
  ProxyGroup(name: 'AUTO', type: 'url-test', members: <String>['美国 03']),
];

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('happy：选择节点出现 active 标记 + 事件驱动延迟更新', (WidgetTester tester) async {
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _groups,
      facade: facade,
    )));

    // 初始无 active 标记
    expect(find.byKey(const Key('proxy_nodes_active_香港 01')), findsNothing);

    // 点击节点 -> node.select -> 出现 active 标记
    await tester.tap(find.byKey(const Key('proxy_nodes_node_香港 01')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('proxy_nodes_active_香港 01')), findsOneWidget);
    expect(facade.selects, <List<String>>[
      <String>['PROXY', '香港 01'],
    ]);

    // 事件驱动的延迟更新（唯一延迟来源）
    facade.controller.add(const ProxyNodeDelayEvent(
      group: 'PROXY',
      node: '香港 01',
      delayMs: 88,
    ));
    await tester.pump();

    expect(find.text('88 ms'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('happy：测试全部展示进度，响应后逐节点回填延迟', (WidgetTester tester) async {
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _groups,
      facade: facade,
    )));

    await tester.tap(find.byKey(const Key('proxy_nodes_test_all')));
    await tester.pump(); // 进入测试态（进度），future 仍挂起
    expect(find.textContaining('正在测试延迟'), findsOneWidget);

    facade.delayCompleter!.complete(const DelayTestResult(
      group: 'PROXY',
      results: <DelayResult>[
        DelayResult(node: '香港 01', delayMs: 120, alive: true),
        DelayResult(node: '日本 02', delayMs: 450, alive: true),
      ],
    ));
    await tester.pump(); // 响应返回并回填
    expect(find.text('120 ms'), findsOneWidget);
    expect(find.text('450 ms'), findsOneWidget);
    expect(find.byType(AppLoading), findsNothing);
    expect(facade.lastDelayRequest?.group, 'PROXY');
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('failure：不可达节点显示「超时」而非崩溃或无限 spinner', (WidgetTester tester) async {
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _groups,
      facade: facade,
    )));

    await tester.tap(find.byKey(const Key('proxy_nodes_test_all')));
    await tester.pump();
    facade.delayCompleter!.complete(const DelayTestResult(
      group: 'PROXY',
      results: <DelayResult>[
        DelayResult(node: '香港 01', alive: false, error: 'timeout'),
        DelayResult(node: '日本 02', delayMs: 90, alive: true),
      ],
    ));
    await tester.pump();

    expect(find.text('超时'), findsOneWidget);
    expect(find.text('90 ms'), findsOneWidget);
    // 测试结束后不再有加载指示（不是无限 spinner）
    expect(find.byType(AppLoading), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('failure：延迟测试抛模块异常时全部标记超时且不崩溃', (WidgetTester tester) async {
    final facade = _FakeNodesFacade()..delayThrows = true;
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _groups,
      facade: facade,
    )));

    await tester.tap(find.byKey(const Key('proxy_nodes_test_all')));
    await tester.pump();
    await tester.pump();

    expect(find.text('超时'), findsNWidgets(2));
    expect(find.byType(AppLoading), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('分组选择：AppSheet picker 切换分组并刷新节点列表', (WidgetTester tester) async {
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _groups,
      facade: facade,
    )));

    expect(find.byKey(const Key('proxy_nodes_node_美国 03')), findsNothing);

    await tester.tap(find.byKey(const Key('proxy_nodes_group_picker')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('proxy_nodes_group_option_AUTO')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('proxy_nodes_group_option_AUTO')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('proxy_nodes_node_美国 03')), findsOneWidget);
    expect(find.byKey(const Key('proxy_nodes_node_香港 01')), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('排序：AppSheet picker 按延迟从低到高重排节点', (WidgetTester tester) async {
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[
        ProxyNode(name: 'alpha', type: 'ss', server: '1.1.1.1', port: 443),
        ProxyNode(name: 'beta', type: 'ss', server: '2.2.2.2', port: 443),
      ],
      groups: const <ProxyGroup>[
        ProxyGroup(name: 'PROXY', type: 'select', members: <String>['alpha', 'beta']),
      ],
      facade: facade,
    )));

    // 名称排序：alpha 在 beta 之上
    expect(
      tester.getTopLeft(find.byKey(const Key('proxy_nodes_node_alpha'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('proxy_nodes_node_beta'))).dy),
    );

    // 事件回填：alpha=300ms，beta=100ms
    facade.controller.add(const ProxyNodeDelayEvent(
      group: 'PROXY',
      node: 'alpha',
      delayMs: 300,
    ));
    facade.controller.add(const ProxyNodeDelayEvent(
      group: 'PROXY',
      node: 'beta',
      delayMs: 100,
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('proxy_nodes_sort')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('proxy_nodes_sort_option_latencyAsc')),
    );
    await tester.pumpAndSettle();

    // 延迟升序：beta（100ms）在 alpha（300ms）之上
    expect(
      tester.getTopLeft(find.byKey(const Key('proxy_nodes_node_beta'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('proxy_nodes_node_alpha'))).dy),
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });
}
