import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart' show AppLoading;
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
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

  /// 非空时 `node.select` 以该错误失败（用于自动对齐后仍 404 的回归）。
  Object? nodeSelectError;

  /// `config.apply`（自动对齐）调用记录。
  final List<String> reconcileCalls = <String>[];

  /// 非空时 `reconcileEngine` 以该错误失败。
  Object? reconcileError;

  /// 自动对齐成功时的回调：测试可在此更新后续 `node.list` 返回值。
  Future<void> Function()? onReconcile;

  /// `node.list` 调用计数（用于断言对齐后会重取一次）。
  int nodeListCalls = 0;

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
    final error = nodeSelectError;
    if (error != null) throw error;
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

  /// `node.list` 返回值（默认空：页面回退到类型推断 + 持久化选择）。
  NodeListResult nodeListResult = const NodeListResult();

  @override
  Future<NodeListResult> nodeList() async {
    nodeListCalls++;
    return nodeListResult;
  }

  @override
  Future<void> reconcileEngine(String profileId) async {
    reconcileCalls.add(profileId);
    final error = reconcileError;
    if (error != null) throw error;
    await onReconcile?.call();
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

/// 自动对齐回归用：订阅只声明 AUTO 组（单节点）。
const StoredProfile _autoProfile = StoredProfile(
  id: 'p1',
  profile: ImportedProfile(
    name: '订阅',
    format: 'clash',
    nodes: <ProxyNode>[_us],
    groups: <ProxyGroup>[
      ProxyGroup(name: 'AUTO', type: 'url-test', members: <String>['美国 03']),
    ],
  ),
);

/// 引擎运行且 AUTO 已在实时映射中。
const NodeListResult _autoLive = NodeListResult(
  engineRunning: true,
  groups: <NodeGroupInfo>[
    NodeGroupInfo(
      name: 'AUTO',
      type: 'url-test',
      now: '美国 03',
      members: <String>['美国 03'],
      selectable: true,
    ),
  ],
);

Widget _wrap(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

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
      hasProxyGroups: false,
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

  testWidgets('分组宫格：仅渲染分组磁贴（成员在弹层内），按分组顺序 2 列排列',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
    )));

    // 分组磁贴均在；成员磁贴不再内联到主视图。
    expect(find.byKey(const Key('proxy_nodes_group_PROXY')), findsOneWidget);
    expect(find.byKey(const Key('proxy_nodes_group_AUTO')), findsOneWidget);
    expect(
      find.byKey(const Key('proxy_nodes_member_PROXY_香港 01')),
      findsNothing,
    );
    expect(find.byKey(const Key('proxy_nodes_member_PROXY_AUTO')), findsNothing);
    expect(
      find.byKey(const Key('proxy_nodes_member_AUTO_美国 03')),
      findsNothing,
    );

    // 宫格顺序：PROXY 在 AUTO 之前（同一行左列）。
    expect(
      _comesBefore(
        tester,
        const Key('proxy_nodes_group_PROXY'),
        const Key('proxy_nodes_group_AUTO'),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('磁贴：点击分组磁贴弹出统一底部弹层（不直接切换）',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
    )));

    // 点分组磁贴 -> 弹层（含 header 测速，不触发选择）。
    await tester.tap(find.byKey(const Key('proxy_nodes_group_PROXY')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('proxy_nodes_sheet_test')), findsOneWidget);
    expect(facade.selects, isEmpty);

    // 关闭弹层。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // 点另一个分组磁贴 -> 同样只弹层、不直接切换。
    await tester.tap(find.byKey(const Key('proxy_nodes_group_AUTO')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('proxy_nodes_sheet_test')), findsOneWidget);
    expect(facade.selects, isEmpty);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('分组弹层：测速按钮钉在标题行（右对齐、不随列表滚动）',
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

    final Finder testButton = find.byKey(const Key('proxy_nodes_sheet_test'));

    // 固定不滚动：测速按钮不在内容滚动区，成员行在滚动区内（对照）。
    expect(
      find.ancestor(of: testButton, matching: find.byType(SingleChildScrollView)),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.byKey(const Key('proxy_nodes_sheet_member_AUTO')),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );

    // 与标题同排：测速按钮所在的 Row 同时也是标题文本的祖先。
    final Finder headerRow = find.ancestor(
      of: testButton,
      matching: find.byType(Row),
    );
    final Finder headerTitle = find.descendant(
      of: headerRow,
      matching: find.text('PROXY'),
    );
    expect(headerTitle, findsOneWidget);

    // 右对齐：按钮水平位置在标题右侧。
    expect(
      tester.getTopLeft(testButton).dx,
      greaterThan(tester.getTopLeft(headerTitle).dx),
    );

    // 垂直居中：按钮中心落在标题 + 副标题块的高度范围内。
    final Finder headerSubtitle = find.descendant(
      of: headerRow,
      matching: find.text('手动选择 · 3 个成员'),
    );
    expect(headerSubtitle, findsOneWidget);
    final double blockTop = tester.getTopLeft(headerTitle).dy;
    final double blockBottom = tester.getBottomLeft(headerSubtitle).dy;
    final double buttonCenter = tester.getCenter(testButton).dy;
    expect(buttonCenter, greaterThanOrEqualTo(blockTop));
    expect(buttonCenter, lessThanOrEqualTo(blockBottom));

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

    // 显式发送该组成员的节点名（不带 group，避免后端按名解析分组失败）。
    expect(facade.lastDelayRequest?.group, isNull);
    expect(facade.lastDelayRequest?.node, isNull);
    expect(
      facade.lastDelayRequest?.targets,
      unorderedEquals(<String>['香港 01', '日本 02']),
    );
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
      hasProxyGroups: false,
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
    // 声明了 proxy-groups：主视图仅分组宫格。
    expect(find.byKey(const Key('proxy_nodes_group_PROXY')), findsOneWidget);
    expect(find.byKey(const Key('proxy_nodes_group_AUTO')), findsOneWidget);
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
    expect(find.byKey(const Key('proxy_nodes_group_PROXY')), findsOneWidget);
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
      hasProxyGroups: false,
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
    // 测试全部覆盖所有分组的节点 → 发送显式 targets，且不带 group / node。
    expect(facade.lastDelayRequest?.group, isNull);
    expect(facade.lastDelayRequest?.node, isNull);
    expect(
      facade.lastDelayRequest?.targets,
      unorderedEquals(<String>['香港 01', '日本 02', '美国 03']),
    );
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
      hasProxyGroups: false,
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

  testWidgets('failure：非 timeout 的传输错误显示「失败」并保留原因（非超时）',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _groups,
      facade: facade,
      hasProxyGroups: false,
    )));

    await tester.tap(find.byKey(const Key('proxy_nodes_test_all')));
    await tester.pump();
    facade.delayCompleter!.complete(const DelayTestResult(
      group: 'PROXY',
      results: <DelayResult>[
        DelayResult(
          node: '香港 01',
          alive: false,
          error: 'dial: connection refused',
        ),
        DelayResult(node: '日本 02', alive: false, error: 'timeout'),
        DelayResult(node: '美国 03', delayMs: 88, alive: true),
      ],
    ));
    await tester.pump();

    // 非 timeout 的 error → 失败；error == 'timeout' → 超时；不混淆。
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('超时'), findsOneWidget);
    expect(find.text('88 ms'), findsOneWidget);
    // 失败原因可经 Tooltip 访问。
    final Tooltip tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.text('失败'),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, 'dial: connection refused');
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
      hasProxyGroups: false,
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
      hasProxyGroups: false,
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

  testWidgets('搜索已移除：无搜索框，全部分组磁贴均渲染',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
    )));

    // 搜索功能整体移除：输入框与清除按钮均不存在。
    expect(find.byKey(const Key('proxy_nodes_search')), findsNothing);
    expect(find.byKey(const Key('proxy_nodes_search_clear')), findsNothing);

    // 无过滤：所有分组磁贴都渲染。
    expect(find.byKey(const Key('proxy_nodes_group_PROXY')), findsOneWidget);
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

    // 分组模式：active 标记在分组磁贴上（节点磁贴不在主视图）。
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

    // 两个分组的分组磁贴都在（成员在弹层内列出）。
    expect(find.byKey(const Key('proxy_nodes_group_PROXY')), findsOneWidget);
    expect(find.byKey(const Key('proxy_nodes_group_AUTO')), findsOneWidget);

    // 在 PROXY 分组弹层里选择「香港 01」。
    await tester.tap(find.byKey(const Key('proxy_nodes_group_PROXY')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_香港 01')));
    await tester.pumpAndSettle();

    expect(facade.selects, <List<String>>[
      <String>['PROXY', '香港 01'],
    ]);

    // 仅 PROXY 分组磁贴高亮；AUTO 不得高亮（作用域互不泄漏）。
    expect(
      find.byKey(const Key('proxy_nodes_group_active_PROXY')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_group_active_AUTO')),
      findsNothing,
    );

    // AUTO 弹层里的同名成员不显示选中勾。
    await tester.tap(find.byKey(const Key('proxy_nodes_group_AUTO')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('proxy_nodes_sheet_member_香港 01')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('proxy_nodes_sheet_member_香港 01')),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('回归：同会话切换分组选择后，旧分组高亮立即清除（只保留最新）',
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

    // 在 PROXY 分组弹层里选择「香港 01」：仅 PROXY 高亮。
    await tester.tap(find.byKey(const Key('proxy_nodes_group_PROXY')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_香港 01')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('proxy_nodes_group_active_PROXY')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_group_active_AUTO')),
      findsNothing,
    );

    // 不重挂载页面，直接在 AUTO 分组弹层里选择「美国 03」。
    await tester.tap(find.byKey(const Key('proxy_nodes_group_AUTO')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_美国 03')));
    await tester.pumpAndSettle();

    // 切换后 AUTO 高亮，且 PROXY 的旧高亮立即消失（与重入行为一致）。
    expect(
      find.byKey(const Key('proxy_nodes_group_active_AUTO')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_group_active_PROXY')),
      findsNothing,
    );
    expect(facade.selects, <List<String>>[
      <String>['PROXY', '香港 01'],
      <String>['AUTO', '美国 03'],
    ]);

    // 弹层内节点行高亮同样不跨组残留：复开 PROXY 弹层不再勾选旧节点。
    await tester.tap(find.byKey(const Key('proxy_nodes_group_PROXY')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('proxy_nodes_sheet_member_香港 01')),
        matching: find.byIcon(Icons.check_circle),
      ),
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

    await tester.tap(find.byKey(const Key('proxy_nodes_group_AUTO')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_美国 03')));
    await tester.pumpAndSettle();

    expect(facade.selects, <List<String>>[
      <String>['AUTO', '美国 03'],
    ]);
    expect(store.writes, 1);
    expect(store.value?.group, 'AUTO');
    expect(store.value?.node, '美国 03');
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('分组弹层：组引用成员与节点成员图标区分（主视图不再内联下钻）',
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

    // 组引用成员（AUTO）用文件夹图标；节点成员用节点图标。
    expect(
      find.descendant(
        of: find.byKey(const Key('proxy_nodes_sheet_member_AUTO')),
        matching: find.byIcon(Icons.folder_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('proxy_nodes_sheet_member_香港 01')),
        matching: find.byIcon(Icons.dns_outlined),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('分组弹层：组引用成员排在节点成员之前', (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: _sectionedGroups,
      facade: facade,
    )));

    await tester.tap(find.byKey(const Key('proxy_nodes_group_PROXY')));
    await tester.pumpAndSettle();

    // AUTO 是组引用 → 排在叶子节点（香港 01 / 日本 02）之前。
    expect(
      _comesBefore(
        tester,
        const Key('proxy_nodes_sheet_member_AUTO'),
        const Key('proxy_nodes_sheet_member_香港 01'),
      ),
      isTrue,
    );
    expect(
      _comesBefore(
        tester,
        const Key('proxy_nodes_sheet_member_AUTO'),
        const Key('proxy_nodes_sheet_member_日本 02'),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('nodes 模式（hasProxyGroups=false）：仅节点宫格，弹层选择 nodeSelect',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    final store = _FakeActiveNodeStore();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp, _us],
      groups: const <ProxyGroup>[
        ProxyGroup(
          name: 'PROXY',
          type: 'select',
          members: <String>['香港 01', '日本 02', '美国 03'],
        ),
      ],
      hasProxyGroups: false,
      facade: facade,
      nodeStore: store,
    )));

    // 所有节点都渲染为节点磁贴；不渲染分组磁贴。
    expect(
      find.byKey(const Key('proxy_nodes_member_PROXY_香港 01')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_member_PROXY_日本 02')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_member_PROXY_美国 03')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('proxy_nodes_group_PROXY')), findsNothing);

    // 点节点磁贴 -> 节点弹层 -> 「选择」 -> nodeSelect('PROXY', <node>)。
    await tester.tap(find.byKey(const Key('proxy_nodes_member_PROXY_香港 01')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('proxy_nodes_node_select')), findsOneWidget);
    await tester.tap(find.byKey(const Key('proxy_nodes_node_select')));
    await tester.pumpAndSettle();

    expect(facade.selects, <List<String>>[
      <String>['PROXY', '香港 01'],
    ]);
    expect(
      find.byKey(const Key('proxy_nodes_active_PROXY_香港 01')),
      findsOneWidget,
    );
    expect(store.writes, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('url-test 可 pin：实时 selectable=true 时点成员触发 nodeSelect',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade()
      ..storedResult = const StoredProfile(
        id: 'p1',
        profile: ImportedProfile(
          name: '订阅',
          format: 'clash',
          nodes: <ProxyNode>[_us],
          groups: <ProxyGroup>[
            ProxyGroup(
              name: 'AUTO',
              type: 'url-test',
              members: <String>['美国 03'],
            ),
          ],
        ),
      )
      ..nodeListResult = const NodeListResult(
        engineRunning: true,
        groups: <NodeGroupInfo>[
          NodeGroupInfo(
            name: 'AUTO',
            type: 'url-test',
            now: '美国 03',
            members: <String>['美国 03'],
            selectable: true,
          ),
        ],
      );

    await tester.pumpWidget(_wrap(ProxyNodesPage(
      profileId: 'p1',
      facade: facade,
    )));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // 实时 now 仅驱动分组副标题的「当前」；高亮不来自引擎实时值。
    expect(find.byKey(const Key('proxy_nodes_group_AUTO')), findsOneWidget);
    expect(find.textContaining('当前：美国 03'), findsOneWidget);
    expect(
      find.byKey(const Key('proxy_nodes_group_active_AUTO')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('proxy_nodes_group_AUTO')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_美国 03')));
    await tester.pumpAndSettle();

    expect(facade.selects, <List<String>>[
      <String>['AUTO', '美国 03'],
    ]);
    // 显式选择后分组磁贴才高亮。
    expect(
      find.byKey(const Key('proxy_nodes_group_active_AUTO')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('load-balance 只读：弹层列出成员但点选不触发 nodeSelect',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade()
      ..storedResult = const StoredProfile(
        id: 'p1',
        profile: ImportedProfile(
          name: '订阅',
          format: 'clash',
          nodes: <ProxyNode>[_hk, _jp],
          groups: <ProxyGroup>[
            ProxyGroup(
              name: 'BAL',
              type: 'load-balance',
              members: <String>['香港 01', '日本 02'],
            ),
          ],
        ),
      )
      ..nodeListResult = const NodeListResult(
        engineRunning: true,
        groups: <NodeGroupInfo>[
          NodeGroupInfo(
            name: 'BAL',
            type: 'load-balance',
            members: <String>['香港 01', '日本 02'],
            selectable: false,
          ),
        ],
      );

    await tester.pumpWidget(_wrap(ProxyNodesPage(
      profileId: 'p1',
      facade: facade,
    )));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('proxy_nodes_group_BAL')), findsOneWidget);
    await tester.tap(find.byKey(const Key('proxy_nodes_group_BAL')));
    await tester.pumpAndSettle();

    // 成员仍全部列出（只读 ≠ 隐藏）。
    expect(
      find.byKey(const Key('proxy_nodes_sheet_member_香港 01')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('proxy_nodes_sheet_member_日本 02')),
      findsOneWidget,
    );

    // 只读：点成员不触发选择，弹层保持打开。
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_香港 01')));
    await tester.pumpAndSettle();
    expect(facade.selects, isEmpty);
    expect(find.byKey(const Key('proxy_nodes_sheet_test')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('load-balance 只读：节点弹层「选择」按钮禁用（nodes 模式）',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade();
    await tester.pumpWidget(_wrap(ProxyNodesPage(
      nodes: const <ProxyNode>[_hk, _jp],
      groups: const <ProxyGroup>[
        ProxyGroup(
          name: 'BAL',
          type: 'load-balance',
          members: <String>['香港 01', '日本 02'],
        ),
      ],
      hasProxyGroups: false,
      facade: facade,
    )));

    await tester.tap(find.byKey(const Key('proxy_nodes_member_BAL_香港 01')));
    await tester.pumpAndSettle();

    final FilledButton select = tester.widget<FilledButton>(
      find.byKey(const Key('proxy_nodes_node_select')),
    );
    expect(select.onPressed, isNull);
    await tester.tap(find.byKey(const Key('proxy_nodes_node_select')));
    await tester.pumpAndSettle();
    expect(facade.selects, isEmpty);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('自动对齐：引擎运行且分组缺失 -> reconcileEngine 一次 + 重取 nodeList + 选择生效高亮',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade()
      ..storedResult = _autoProfile
      // 初始实时映射为空（AUTO 不在引擎生效配置里），引擎运行中。
      ..nodeListResult = const NodeListResult(engineRunning: true);
    facade.onReconcile = () async {
      // 对齐（config.apply）后，引擎里出现 AUTO 组。
      facade.nodeListResult = _autoLive;
    };

    await tester.pumpWidget(
      _wrap(ProxyNodesPage(profileId: 'p1', facade: facade)),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(facade.reconcileCalls, isEmpty);
    final int listCallsBefore = facade.nodeListCalls;

    await tester.tap(find.byKey(const Key('proxy_nodes_group_AUTO')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_美国 03')));
    await tester.pumpAndSettle();

    // 缺失分组 -> 恰好一次自动对齐；随后重取 nodeList；选择成功且高亮。
    expect(facade.reconcileCalls, <String>['p1']);
    expect(facade.nodeListCalls, listCallsBefore + 1);
    expect(facade.selects, <List<String>>[
      <String>['AUTO', '美国 03'],
    ]);
    expect(
      find.byKey(const Key('proxy_nodes_group_active_AUTO')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('自动对齐失败：reconcileEngine 抛错不崩溃，后续 nodeSelect 404 显示清晰提示',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade()
      ..storedResult = _autoProfile
      ..nodeListResult = const NodeListResult(engineRunning: true)
      ..reconcileError = const ProxyModuleException(
        code: 'PROXY_CONFIG_APPLY_FAILED',
        message: '应用配置失败',
      )
      ..nodeSelectError = const ProxyModuleException(
        code: 'PROXY_NODE_NOT_FOUND',
        message: '分组不存在',
      );

    await tester.pumpWidget(
      _wrap(ProxyNodesPage(profileId: 'p1', facade: facade)),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('proxy_nodes_group_AUTO')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_美国 03')));
    await tester.pumpAndSettle();

    // 对齐尝试过（失败被 best-effort 吞掉、不崩溃）；选择仍被尝试并 404。
    expect(facade.reconcileCalls, <String>['p1']);
    expect(facade.selects, <List<String>>[
      <String>['AUTO', '美国 03'],
    ]);
    expect(find.text('该分组未在当前引擎生效，请重试或重新连接'), findsOneWidget);
    // 不再暴露原始错误消息。
    expect(find.textContaining('切换节点失败'), findsNothing);
    expect(find.text('分组不存在'), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('引擎停止：不触发 reconcileEngine，离线选择路径仍记录选择',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade()
      ..storedResult = _autoProfile
      // 引擎停止：即使分组不在实时映射里也不得自动对齐。
      ..nodeListResult = const NodeListResult(engineRunning: false);

    await tester.pumpWidget(
      _wrap(ProxyNodesPage(profileId: 'p1', facade: facade)),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('proxy_nodes_group_AUTO')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_美国 03')));
    await tester.pumpAndSettle();

    expect(facade.reconcileCalls, isEmpty);
    expect(facade.selects, <List<String>>[
      <String>['AUTO', '美国 03'],
    ]);
    expect(
      find.byKey(const Key('proxy_nodes_group_active_AUTO')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('分组已在实时映射：不触发 reconcileEngine（直接选择）',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final facade = _FakeNodesFacade()
      ..storedResult = _autoProfile
      ..nodeListResult = _autoLive;

    await tester.pumpWidget(
      _wrap(ProxyNodesPage(profileId: 'p1', facade: facade)),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('proxy_nodes_group_AUTO')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('proxy_nodes_sheet_member_美国 03')));
    await tester.pumpAndSettle();

    expect(facade.reconcileCalls, isEmpty);
    expect(facade.selects, <List<String>>[
      <String>['AUTO', '美国 03'],
    ]);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });
}
