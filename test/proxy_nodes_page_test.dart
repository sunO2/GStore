import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart' show AppLoading;
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_active_node_store.dart';
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

/// 假「当前选中节点」持久化存储：内存实现。
class _FakeActiveNodeStore implements ProxyActiveNodeStore {
  _FakeActiveNodeStore([this.value]);

  ProxyActiveNode? value;
  int writes = 0;

  @override
  Future<ProxyActiveNode?> read() async => value;

  @override
  Future<void> write(ProxyActiveNode selection) async {
    writes++;
    value = selection;
  }

  @override
  Future<void> clear() async => value = null;
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

/// 分节用：PROXY 里含一个「组引用」成员（AUTO）。
const List<ProxyGroup> _sectionedGroups = <ProxyGroup>[
  ProxyGroup(
    name: 'PROXY',
    type: 'select',
    members: <String>['香港 01', '日本 02', 'AUTO'],
  ),
  ProxyGroup(name: 'AUTO', type: 'url-test', members: <String>['美国 03']),
];

/// 回归用：两个分组各含一个**同名**成员（香港 01）。
const List<ProxyGroup> _duplicateNameGroups = <ProxyGroup>[
  ProxyGroup(name: 'PROXY', type: 'select', members: <String>['香港 01', '日本 02']),
  ProxyGroup(name: 'AUTO', type: 'url-test', members: <String>['香港 01']),
];

Widget _wrap(Widget child) => MaterialApp(home: child);

/// 放大测试视口：分节后多组纵向堆叠，避免下方分组的 SliverGrid 懒加载
/// 把待断言的磁贴挤出可视 / 缓存区（放大视口而非削弱断言）。
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

/// 打开某分组内某个节点磁贴的弹层并点「选择」。
Future<void> _selectNodeViaSheet(
  WidgetTester tester,
  String group,
  String nodeName,
) async {
  await tester.tap(find.byKey(Key('proxy_nodes_member_${group}_$nodeName')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('proxy_nodes_sheet_test')), findsOneWidget);
  await tester.tap(find.byKey(const Key('proxy_nodes_node_select')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('happy：点击节点磁贴 -> 弹层选择 -> active + 持久化 + 事件延迟更新',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    final store = _FakeActiveNodeStore();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _groups,
      facade: facade,
      nodeStore: store,
    )));

    // 初始无 active 标记
    expect(find.byKey(const Key('proxy_nodes_active_PROXY_香港 01')), findsNothing);

    // 点击节点磁贴 -> 弹层 -> 选择 -> node.select -> active 标记
    await _selectNodeViaSheet(tester, 'PROXY', '香港 01');

    expect(
      find.byKey(const Key('proxy_nodes_active_PROXY_香港 01')),
      findsOneWidget,
    );
    expect(facade.selects, <List<String>>[
      <String>['PROXY', '香港 01'],
    ]);
    expect(store.writes, 1);
    expect(store.value?.group, 'PROXY');
    expect(store.value?.node, '香港 01');

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

  testWidgets('分节宫格：每组一个 2 列宫格，子分组在前、节点在后，组间纵向排列',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
    )));

    final Offset proxyHeader =
        tester.getTopLeft(find.byKey(const Key('proxy_nodes_group_PROXY')));
    final Offset subGroup =
        tester.getTopLeft(find.byKey(const Key('proxy_nodes_member_PROXY_AUTO')));
    final Offset firstNode =
        tester.getTopLeft(find.byKey(const Key('proxy_nodes_member_PROXY_日本 02')));
    final Offset secondNode =
        tester.getTopLeft(find.byKey(const Key('proxy_nodes_member_PROXY_香港 01')));

    // 分组标题位于该组全部成员之上。
    expect(proxyHeader.dy, lessThan(subGroup.dy));

    // 子分组（AUTO）排在节点之前。
    expect(
      _comesBefore(
        tester,
        const Key('proxy_nodes_member_PROXY_AUTO'),
        const Key('proxy_nodes_member_PROXY_日本 02'),
      ),
      isTrue,
    );

    // 同组内 2 列：子分组与首个节点同排、分属左右列。
    expect(subGroup.dy, closeTo(firstNode.dy, 1.0));
    expect(subGroup.dx, lessThan(firstNode.dx));

    // 第 3 个成员另起一行。
    expect(secondNode.dy, greaterThan(firstNode.dy));

    // 下一个分组标题排在上一组成员之后（组间纵向分节）。
    final Offset autoHeader =
        tester.getTopLeft(find.byKey(const Key('proxy_nodes_group_AUTO')));
    expect(autoHeader.dy, greaterThan(secondNode.dy));

    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('磁贴：点击分组标题 / 节点磁贴弹出统一底部弹层（不直接切换）',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
    )));

    // 点分组标题 -> 弹层（含 header 测速，不触发选择）。
    await tester.tap(find.byKey(const Key('proxy_nodes_group_PROXY')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('proxy_nodes_sheet_test')), findsOneWidget);
    expect(facade.selects, isEmpty);

    // 关闭弹层。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // 点节点磁贴 -> 弹层（同样不直接切换）。
    await tester.tap(find.byKey(const Key('proxy_nodes_member_PROXY_香港 01')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('proxy_nodes_sheet_test')), findsOneWidget);
    expect(facade.selects, isEmpty);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('分组弹层：组引用成员可点选（选择子分组 = nodeSelect）',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
    )));

    await tester.tap(find.byKey(const Key('proxy_nodes_group_PROXY')));
    await tester.pumpAndSettle();

    // 组引用成员以「代理组」副标题 + 文件夹图标区分，且可选。
    expect(find.byKey(const Key('proxy_nodes_sheet_member_AUTO')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('proxy_nodes_sheet_member_AUTO')),
        matching: find.text('代理组'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_AUTO')));
    await tester.pumpAndSettle();

    expect(facade.selects, <List<String>>[
      <String>['PROXY', 'AUTO'],
    ]);
    // 选择子分组后分组标题高亮显示当前生效项。
    expect(find.textContaining('当前：AUTO'), findsOneWidget);
    expect(find.byKey(const Key('proxy_nodes_group_active_PROXY')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('弹层 header 测速（分组）：触发该组 node.delay_test 并回填延迟',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
    )));

    await tester.tap(find.byKey(const Key('proxy_nodes_group_PROXY')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_test')));
    await tester.pump();

    // 请求限定到该分组（不含 node 参数）。
    expect(facade.lastDelayRequest?.group, 'PROXY');
    expect(facade.lastDelayRequest?.node, isNull);
    expect(find.textContaining('正在测速…'), findsOneWidget);

    facade.delayCompleter!.complete(const DelayTestResult(
      group: 'PROXY',
      results: <DelayResult>[
        DelayResult(node: '香港 01', delayMs: 66, alive: true),
        DelayResult(node: '日本 02', delayMs: 210, alive: true),
      ],
    ));
    await tester.pump();
    await tester.pump();

    expect(
      find.descendant(
        of: find.byKey(const Key('proxy_nodes_sheet_delay_香港 01')),
        matching: find.text('66 ms'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('proxy_nodes_sheet_delay_日本 02')),
        matching: find.text('210 ms'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('弹层 header 测速（单节点）：触发该节点 node.delay_test',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _groups,
      facade: facade,
    )));

    await tester.tap(find.byKey(const Key('proxy_nodes_member_PROXY_日本 02')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_test')));
    await tester.pump();

    expect(facade.lastDelayRequest?.node, '日本 02');
    expect(facade.lastDelayRequest?.group, isNull);

    facade.delayCompleter!.complete(const DelayTestResult(
      results: <DelayResult>[
        DelayResult(node: '日本 02', delayMs: 321, alive: true),
      ],
    ));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const Key('proxy_nodes_sheet_delay_日本 02')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('proxy_nodes_sheet_delay_日本 02')),
        matching: find.text('321 ms'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('profileId：经门面 profile.get 加载订阅节点并展示',
      (WidgetTester tester) async {
    _useTallViewport(tester);
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
    expect(
      find.byKey(const Key('proxy_nodes_member_PROXY_香港 01')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_member_PROXY_日本 02')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('profileId 失败：显式错误态 + 重试后恢复', (WidgetTester tester) async {
    _useTallViewport(tester);
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
    expect(
      find.byKey(const Key('proxy_nodes_member_PROXY_香港 01')),
      findsOneWidget,
    );
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
    _useTallViewport(tester);
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
    _useTallViewport(tester);
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
    _useTallViewport(tester);
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

  testWidgets('排序：AppSheet picker 按延迟从低到高重排节点磁贴', (WidgetTester tester) async {
    _useTallViewport(tester);
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

    // 名称排序：alpha 在 beta 之前（宫格阅读顺序）。
    expect(
      _comesBefore(
        tester,
        const Key('proxy_nodes_member_PROXY_alpha'),
        const Key('proxy_nodes_member_PROXY_beta'),
      ),
      isTrue,
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

    // 延迟升序：beta（100ms）在 alpha（300ms）之前。
    expect(
      _comesBefore(
        tester,
        const Key('proxy_nodes_member_PROXY_beta'),
        const Key('proxy_nodes_member_PROXY_alpha'),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('搜索过滤：按名称仅保留匹配成员 / 分组；分组名匹配保留全部成员',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
    )));

    // 成员匹配：PROXY 只留「香港 01」；AUTO 无匹配成员 → 整节隐藏。
    await tester.enterText(
        find.byKey(const Key('proxy_nodes_search')), '香港');
    await tester.pump();

    expect(
      find.byKey(const Key('proxy_nodes_member_PROXY_香港 01')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_member_PROXY_日本 02')),
      findsNothing,
    );
    expect(find.byKey(const Key('proxy_nodes_member_PROXY_AUTO')), findsNothing);
    expect(find.byKey(const Key('proxy_nodes_group_AUTO')), findsNothing);
    expect(
      find.byKey(const Key('proxy_nodes_member_AUTO_美国 03')),
      findsNothing,
    );
    // PROXY 因成员「香港 01」匹配而保留。
    expect(find.byKey(const Key('proxy_nodes_group_PROXY')), findsOneWidget);

    // 分组名匹配：AUTO 整节保留全部成员（成员名未必匹配）。
    await tester.enterText(
        find.byKey(const Key('proxy_nodes_search')), 'AUTO');
    await tester.pump();

    expect(find.byKey(const Key('proxy_nodes_group_AUTO')), findsOneWidget);
    expect(
      find.byKey(const Key('proxy_nodes_member_AUTO_美国 03')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('proxy_nodes_member_PROXY_AUTO')), findsOneWidget);

    // 清除搜索 → 恢复全部。
    await tester.tap(find.byKey(const Key('proxy_nodes_search_clear')));
    await tester.pump();
    expect(
      find.byKey(const Key('proxy_nodes_member_PROXY_日本 02')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('proxy_nodes_member_PROXY_AUTO')), findsOneWidget);
    expect(
      find.byKey(const Key('proxy_nodes_member_AUTO_美国 03')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('proxy_nodes_group_AUTO')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('重入高亮：持久化选择在初始化时回显', (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    final store = _FakeActiveNodeStore(
      const ProxyActiveNode(group: 'PROXY', node: '香港 01'),
    );
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
      nodeStore: store,
    )));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const Key('proxy_nodes_active_PROXY_香港 01')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_group_active_PROXY')),
      findsOneWidget,
    );
    expect(find.textContaining('当前：香港 01'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('回归：同名节点分属两组时，选择只高亮所属分组（不跨组泄漏）',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    final store = _FakeActiveNodeStore();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp],
      groups: _duplicateNameGroups,
      facade: facade,
      nodeStore: store,
    )));

    // 两个分组都含同名成员「香港 01」。
    expect(
      find.byKey(const Key('proxy_nodes_member_PROXY_香港 01')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_member_AUTO_香港 01')),
      findsOneWidget,
    );

    // 在 PROXY 分组的节点弹层里选择「香港 01」。
    await _selectNodeViaSheet(tester, 'PROXY', '香港 01');
    expect(facade.selects, <List<String>>[
      <String>['PROXY', '香港 01'],
    ]);

    // 仅 PROXY 的磁贴高亮；AUTO 中的同名节点**不得**高亮。
    expect(
      find.byKey(const Key('proxy_nodes_active_PROXY_香港 01')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_active_AUTO_香港 01')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('proxy_nodes_group_active_PROXY')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_group_active_AUTO')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('选择持久化：在弹层内选择后写入 ProxyActiveNodeStore',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    final store = _FakeActiveNodeStore();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
      nodeStore: store,
    )));

    await _selectNodeViaSheet(tester, 'AUTO', '美国 03');

    expect(store.writes, 1);
    expect(store.value?.group, 'AUTO');
    expect(store.value?.node, '美国 03');
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('子分组条目：点击下钻到该子分组自己的弹层（不再误落父组）',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
    )));

    await tester.tap(find.byKey(const Key('proxy_nodes_member_PROXY_AUTO')));
    await tester.pumpAndSettle();

    // 弹层标题为子分组 AUTO，成员为 美国 03（不再列出 PROXY 的成员）。
    expect(find.text('AUTO'), findsWidgets);
    expect(
      find.byKey(const Key('proxy_nodes_sheet_member_美国 03')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_sheet_member_香港 01')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });
}
