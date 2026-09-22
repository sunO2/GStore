import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart' show AppLoading;
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_nodes_facade.dart';
import 'package:gstore/page/proxy/proxy_nodes_page.dart';

/// 假门面：无需原生模块，可受控返回选择/延迟/订阅结果并推送类型化事件。
class _FakeNodesFacade implements ProxyNodesFacade {
  // 与生产门面一致：同步广播，事件在 add 时立即投递。
  final StreamController<ProxyEvent> controller =
      StreamController<ProxyEvent>.broadcast(sync: true);

  final List<List<String>> selects = <List<String>>[];
  NodeDelayTestRequest? lastDelayRequest;
  bool delayThrows = false;

  /// `profile.get` 调用计数 + 最近一次 id。
  int profileGetCalls = 0;
  String? lastProfileId;

  /// 非空时 `profile.get` 以该错误失败。
  Object? profileGetError;

  /// `profile.get` 成功时返回的订阅（默认空）。
  StoredProfile storedResult = const StoredProfile(
    id: 'p1',
    profile: ImportedProfile(name: '订阅', format: 'clash'),
  );

  /// 测试通过它手动控制 `node.delay_test` 的完成时机（以便断言进行中态）。
  Completer<DelayTestResult>? delayCompleter;

  @override
  Stream<ProxyEvent> get events => controller.stream;

  @override
  Future<StoredProfile> profileGet(String id) async {
    profileGetCalls++;
    lastProfileId = id;
    final error = profileGetError;
    if (error != null) throw error;
    return storedResult;
  }

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

/// 分组分节用：PROXY 里含一个「组引用」成员（AUTO）。
const List<ProxyGroup> _sectionedGroups = <ProxyGroup>[
  ProxyGroup(
    name: 'PROXY',
    type: 'select',
    members: <String>['香港 01', '日本 02', 'AUTO'],
  ),
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

  testWidgets('分组分节：每组一节，节点与组引用分别渲染，节点可点选',
      (WidgetTester tester) async {
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
    )));

    // 两个分组各一节（组名 + 类型 + 成员数）。
    expect(find.byKey(const Key('proxy_nodes_group_PROXY')), findsOneWidget);
    expect(find.byKey(const Key('proxy_nodes_group_AUTO')), findsOneWidget);
    expect(find.text('select · 3 个成员'), findsOneWidget);
    expect(find.text('url-test · 1 个成员'), findsOneWidget);

    // 两组各自的节点都渲染。
    expect(find.byKey(const Key('proxy_nodes_node_香港 01')), findsOneWidget);
    expect(find.byKey(const Key('proxy_nodes_node_美国 03')), findsOneWidget);

    // 组引用成员渲染为不可选的引用行（无 onTap）。
    final groupRef =
        tester.widget<ListTile>(find.byKey(const Key('proxy_nodes_groupref_AUTO')));
    expect(groupRef.onTap, isNull);
    expect(find.text('代理组'), findsOneWidget);

    // 点选节点触发 node.select（分组名正确）。
    await tester.tap(find.byKey(const Key('proxy_nodes_node_美国 03')));
    await tester.pumpAndSettle();
    expect(facade.selects, <List<String>>[
      <String>['AUTO', '美国 03'],
    ]);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('profileId：经门面 profile.get 加载订阅节点并展示',
      (WidgetTester tester) async {
    final facade = _FakeNodesFacade()
      ..storedResult = const StoredProfile(
        id: 'sub-1',
        profile: ImportedProfile(
          name: '订阅一',
          format: 'clash',
          nodeCount: 2,
          nodes: <ProxyNode>[_hk, _jp],
          groups: _groups,
        ),
      );

    await tester.pumpWidget(_wrap(ProxyNodesPage(
      profileId: 'sub-1',
      facade: facade,
    )));
    // 初始加载态（AppLoading 无限动画，固定帧推进）
    expect(find.byType(AppLoading), findsOneWidget);
    await tester.pump();
    await tester.pump();

    expect(facade.profileGetCalls, 1);
    expect(facade.lastProfileId, 'sub-1');
    expect(find.byKey(const Key('proxy_nodes_node_香港 01')), findsOneWidget);
    expect(find.byKey(const Key('proxy_nodes_node_日本 02')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('profileId 失败：显式错误态 + 重试后恢复', (WidgetTester tester) async {
    final facade = _FakeNodesFacade()
      ..profileGetError = const ProxyModuleException(
        code: 'PROXY_PROFILE_NOT_FOUND',
        message: '订阅不存在',
      );

    await tester.pumpWidget(_wrap(ProxyNodesPage(
      profileId: 'missing',
      facade: facade,
    )));
    await tester.pump();
    await tester.pump();

    expect(find.text('节点加载失败'), findsOneWidget);
    expect(find.text('订阅不存在'), findsOneWidget);
    expect(find.byKey(const Key('proxy_nodes_retry')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 重试：清除错误后加载成功。
    facade.profileGetError = null;
    facade.storedResult = const StoredProfile(
      id: 'missing',
      profile: ImportedProfile(
        name: '订阅',
        format: 'clash',
        nodeCount: 1,
        nodes: <ProxyNode>[_hk],
        groups: _groups,
      ),
    );
    await tester.tap(find.byKey(const Key('proxy_nodes_retry')));
    await tester.pump();
    await tester.pump();

    expect(facade.profileGetCalls, 2);
    expect(find.byKey(const Key('proxy_nodes_node_香港 01')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('profileId 为空订阅：显式「暂无节点」空态', (WidgetTester tester) async {
    final facade = _FakeNodesFacade()
      ..storedResult = const StoredProfile(
        id: 'empty',
        profile: ImportedProfile(name: '空', format: 'clash'),
      );

    await tester.pumpWidget(_wrap(ProxyNodesPage(
      profileId: 'empty',
      facade: facade,
    )));
    await tester.pump();
    await tester.pump();

    expect(find.text('暂无节点'), findsOneWidget);
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
    // 测试全部覆盖所有分组的节点 → 不带 group 参数。
    expect(facade.lastDelayRequest?.group, isNull);
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

    expect(find.text('超时'), findsNWidgets(2)); // 香港 01 失败 + 美国 03 未回填
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

    expect(find.text('超时'), findsNWidgets(3));
    expect(find.byType(AppLoading), findsNothing);
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
