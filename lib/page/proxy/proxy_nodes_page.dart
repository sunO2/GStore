import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

import 'proxy_active_node_store.dart';
import 'proxy_nodes_facade.dart';

/// 延迟徽章淡色背景的透明度。
///
/// 无对应语义令牌，沿用仓库既有 `withValues(alpha: 0.12)` 约定（见
/// `lib/page/app_snapshot/widgets.dart`）；一律使用主题 / alpha 令牌，
/// 不引入硬编码颜色或字号。
const double _kBadgeTintAlpha = 0.12;

/// 节点 / 代理组页面（纯展示 + 触发）。
///
/// **只做展示与转发**：分组/节点模型来自冻结契约 [ProxyGroup] / [ProxyNode]；
/// 切换节点调用 [ProxyNodesFacade.nodeSelect]，测速调用
/// [ProxyNodesFacade.nodeDelayTest]，逐节点延迟来自 `proxy.node.delay` 事件。
/// 本页**不含**任何延迟探测 / 解析逻辑（全部在 Rust 侧）。
///
/// 数据来源（二选一）：
/// * 传入 [profileId] → 本页经 [ProxyNodesFacade.profileGet] 加载该订阅的
///   `nodes` / `groups`（加载态 / 错误态 / 空态均显式呈现，绝不崩溃）；
/// * 未传 [profileId] → 直接展示调用方传入的 [nodes] / [groups]（测试 / 嵌入）。
///
/// 展示形态：**按分组分节**（每组一个标题 + 该组一个 2 列宫格），无展开 / 收起；
/// 组内成员子分组在前、节点在后（节点按 [_NodeSort]）。点击分组标题 / 子分组条目
/// 弹出该组统一底部弹层（[AppSheet]），点击节点条目弹出其**父分组**内的节点弹层；
/// 弹层顶部带测速动作。分组标题副标题为 `类型 · N 个成员 [· 当前：<活动成员>]`；
/// 节点磁贴副标题为 `端点 · 类型`，测速后追加延迟徽章。当前生效项以主题 primary
/// 高亮，且**按父分组作用域**判定（同名节点在其它组不会被误高亮）。
///
/// 视觉规范：颜色一律取自 `Theme.of(context).colorScheme`，字号取自
/// `Theme.of(context).textTheme`；弹层统一走 [AppSheet]；加载态一律用
/// [AppLoading]（不使用原生进度圈）。
class ProxyNodesPage extends StatefulWidget {
  const ProxyNodesPage({
    super.key,
    this.nodes = const <ProxyNode>[],
    this.groups = const <ProxyGroup>[],
    this.hasProxyGroups = true,
    this.profileId,
    this.facade,
    this.initialActiveByGroup = const <String, String>{},
    this.nodeStore,
  });

  /// 可直接展示的节点集合（未传 [profileId] 时生效）。
  final List<ProxyNode> nodes;

  /// 可直接展示的代理组（未传 [profileId] 时生效）。
  final List<ProxyGroup> groups;

  /// 配置是否声明了 `proxy-groups`（false = 引擎合成了 `PROXY`，主视图直接列出所有节点）。
  final bool hasProxyGroups;

  /// 要加载的订阅 id；非空时经门面 `profile.get` 拉取该订阅的 nodes/groups。
  final String? profileId;

  /// 门面（测试注入假实现；为空时用生产单例适配器）。
  final ProxyNodesFacade? facade;

  /// 初始「分组 → 活动节点」映射（无选择事件时用于回显）。
  final Map<String, String> initialActiveByGroup;

  /// 选中节点的持久化接缝（测试注入内存实现；为空时用 [ConfigStore]）。
  /// `_selectNode` 成功后写入，重入时用于高亮回显。
  final ProxyActiveNodeStore? nodeStore;

  @override
  State<ProxyNodesPage> createState() => _ProxyNodesPageState();
}

/// 节点排序方式。
enum _NodeSort {
  name('按名称'),
  latencyAsc('延迟从低到高'),
  latencyDesc('延迟从高到低');

  const _NodeSort(this.label);

  final String label;
}

/// 单节点延迟展示态（全部来自 Rust 结果 / 事件，Dart 不探测）。
class _DelayState {
  const _DelayState({required this.delayMs, required this.alive, this.error});

  /// 由 `node.delay_test` 响应项构造。
  factory _DelayState.fromDelayResult(DelayResult result) => _DelayState(
        delayMs: result.delayMs,
        alive: result.alive && result.delayMs > 0,
        error: result.error,
      );

  /// 显式超时（不可达 / 无结果）：不是无限 spinner。
  static const _DelayState timeout =
      _DelayState(delayMs: 0, alive: false, error: 'timeout');

  final int delayMs;
  final bool alive;
  final String? error;

  /// 非超时失败的具体原因（如 `dial: ...`）；超时 / 无错误时为 null。
  String? get failureReason {
    final String? e = error;
    if (e == null || e.isEmpty || e == 'timeout') return null;
    return e;
  }

  /// 后端明确区分的传输 / 拨号失败（非超时）。
  bool get isFailure => failureReason != null;

  /// 不可达 / 未完成（0ms）→ 明确按超时呈现（失败态除外）。
  bool get isTimeout => !isFailure && (!alive || delayMs <= 0 || error != null);
}

class _ProxyNodesPageState extends State<ProxyNodesPage> {
  late final ProxyNodesFacade _facade;
  late final ProxyActiveNodeStore _nodeStore;
  StreamSubscription<ProxyEvent>? _eventSub;

  bool _loading = false;
  String? _loadError;

  Map<String, ProxyNode> _nodesByName = <String, ProxyNode>{};
  List<ProxyGroup> _groups = const <ProxyGroup>[];
  bool _hasProxyGroups = true;

  /// 引擎运行时的实时组信息（`node.list`，best-effort）：用于「当前」回显与
  /// 可选性判定。为空时退回配置类型 + 持久化选择。
  Map<String, NodeGroupInfo> _liveByGroup = <String, NodeGroupInfo>{};

  /// 引擎是否运行（最近一次 `node.list` 的 `engineRunning`；失败 / 停止为 false）。
  ///
  /// 仅在运行且分组未在当前生效配置里时，选择节点前才 best-effort 自动对齐。
  bool _engineRunning = false;

  final Map<String, String> _activeByGroup = <String, String>{};
  final Map<String, _DelayState> _delays = <String, _DelayState>{};
  final Set<String> _pending = <String>{};

  /// 延迟状态版本号：弹层（独立 route）据此在事件 / 测试回填时刷新。
  final ValueNotifier<int> _latencyTick = ValueNotifier<int>(0);

  bool _testing = false;
  int _testedCount = 0;
  int _testTotal = 0;
  _NodeSort _sort = _NodeSort.name;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleNodesFacade();
    _nodeStore = widget.nodeStore ?? const ConfigStoreProxyActiveNodeStore();
    _activeByGroup.addAll(widget.initialActiveByGroup);
    _eventSub = _facade.events.listen(_onEvent, onError: (_) {});
    _restoreActiveSelection();

    final String? profileId = widget.profileId;
    if (profileId == null || profileId.isEmpty) {
      _applyData(widget.nodes, widget.groups, widget.hasProxyGroups);
    } else {
      _load(profileId);
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _latencyTick.dispose();
    super.dispose();
  }

  /// 重入回显：调用方未显式传初始映射时，从持久化接缝读取上次选择
  /// （best-effort，失败静默保持为空）。
  Future<void> _restoreActiveSelection() async {
    if (_activeByGroup.isNotEmpty) return;
    final ProxyActiveNode? selection =
        await _safe<ProxyActiveNode?>(() => _nodeStore.read());
    if (!mounted || selection == null) return;
    if (selection.group.isEmpty || selection.node.isEmpty) return;
    setState(() => _activeByGroup[selection.group] = selection.node);
  }

  /// best-effort：持久化接缝异常不应影响页面。
  ///
  /// [onError] 可选：捕获时回调（如自动对齐失败需要 `debugPrint`），仍返回 null。
  Future<T?> _safe<T>(
    Future<T> Function() run, {
    void Function(Object error)? onError,
  }) async {
    try {
      return await run();
    } catch (error) {
      onError?.call(error);
      return null;
    }
  }

  // ==================== 数据加载 ====================

  /// 把节点 / 分组写入状态；不清空 [_activeByGroup]（单订阅路由，重载保留已选节点）。
  ///
  /// 分组不做任何 Dart 侧合成：配置未声明 `proxy-groups` 时由 [hasProxyGroups]
  /// =false 驱动主视图直接列出所有节点（作用域为 [_implicitGroupName]）。
  void _applyData(
    List<ProxyNode> nodes,
    List<ProxyGroup> groups,
    bool hasProxyGroups,
  ) {
    _nodesByName = <String, ProxyNode>{
      for (final ProxyNode node in nodes) node.name: node,
    };
    _groups = groups;
    _hasProxyGroups = hasProxyGroups;
  }

  /// `profile.get`：加载订阅节点；失败降级为显式错误态（绝不崩溃）。
  Future<void> _load(String profileId) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final StoredProfile stored = await _facade.profileGet(profileId);
      if (!mounted) return;
      setState(() {
        _applyData(
          stored.profile.nodes,
          stored.profile.groups,
          stored.profile.hasProxyGroups,
        );
        _loading = false;
      });
      // best-effort 实时富化：引擎运行时补充「当前」/ 可选性；失败绝不影响页面。
      try {
        final NodeListResult live = await _facade.nodeList();
        if (!mounted) return;
        setState(() {
          _engineRunning = live.engineRunning;
          _liveByGroup = <String, NodeGroupInfo>{
            for (final NodeGroupInfo g in live.groups) g.name: g,
          };
        });
      } catch (_) {
        _engineRunning = false;
      }
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '端子加载失败：$error';
      });
    }
  }

  Future<void> _retry() async {
    final String? profileId = widget.profileId;
    if (profileId != null && profileId.isNotEmpty) {
      await _load(profileId);
    }
  }

  // ==================== 事件 ====================

  /// `proxy.node.delay`：逐节点回填延迟（唯一延迟来源）。
  void _onEvent(ProxyEvent event) {
    if (!mounted || event is! ProxyNodeDelayEvent) return;
    setState(() {
      _delays[event.node] = _DelayState(
        delayMs: event.delayMs,
        alive: event.error == null && event.delayMs > 0,
        error: event.error,
      );
      if (_pending.remove(event.node)) _testedCount++;
    });
    _latencyTick.value++;
  }

  // ==================== 排序 ====================

  int? _positiveDelay(String node) {
    final _DelayState? state = _delays[node];
    // 仅存活的成功延迟参与排序；超时与失败一律视为无延迟。
    if (state == null || !state.alive || state.delayMs <= 0) return null;
    return state.delayMs;
  }

  int _compareByLatency(String a, String b, {required bool ascending}) {
    final int? da = _positiveDelay(a);
    final int? db = _positiveDelay(b);
    if (da == null && db == null) return a.compareTo(b);
    if (da == null) return 1;
    if (db == null) return -1;
    final int c = ascending ? da.compareTo(db) : db.compareTo(da);
    return c == 0 ? a.compareTo(b) : c;
  }

  /// 按 [_sort] 排序后的名字副本。
  List<String> _sortedNames(Iterable<String> names) {
    final List<String> list = names.toList();
    switch (_sort) {
      case _NodeSort.name:
        list.sort((String a, String b) => a.compareTo(b));
      case _NodeSort.latencyAsc:
        list.sort(
          (String a, String b) => _compareByLatency(a, b, ascending: true),
        );
      case _NodeSort.latencyDesc:
        list.sort(
          (String a, String b) => _compareByLatency(a, b, ascending: false),
        );
    }
    return list;
  }

  /// 某个分组内的成员名：组引用在前、叶子节点在后，各组内按 [_sort] 排序。
  List<String> _sortedMembers(ProxyGroup group) {
    final List<String> groupRefs = <String>[];
    final List<String> nodes = <String>[];
    for (final String member in group.members) {
      if (_nodesByName.containsKey(member)) {
        nodes.add(member);
      } else {
        groupRefs.add(member);
      }
    }
    return <String>[..._sortedNames(groupRefs), ..._sortedNames(nodes)];
  }

  // ==================== 选择 / 测试 ====================

  Future<void> _selectNode(String group, String node) async {
    final String? profileId = widget.profileId;
    // 引擎运行中，但该分组不在当前生效配置里（实时映射缺失）→ 先 best-effort
    // 重新应用订阅配置，让新分组落进引擎，再重取实时映射后选择。
    // 引擎停止时不介入（离线 / 未连接路径保持原样）。
    final bool needsReconcile = _engineRunning &&
        profileId != null &&
        profileId.isNotEmpty &&
        !_liveByGroup.containsKey(group);
    if (needsReconcile) {
      await _safe(
        () => _facade.reconcileEngine(profileId),
        onError: (Object error) =>
            debugPrint('代理节点自动对齐失败（group=$group）：$error'),
      );
      // 对齐后重取实时映射（best-effort，失败静默）：无论如何继续尝试选择，
      // 让真实错误（如 404）走下方统一错误呈现。
      await _safe(() async {
        final NodeListResult live = await _facade.nodeList();
        if (!mounted) return;
        setState(() {
          _engineRunning = live.engineRunning;
          _liveByGroup = <String, NodeGroupInfo>{
            for (final NodeGroupInfo g in live.groups) g.name: g,
          };
        });
      });
    }

    try {
      final NodeSelectResult result = await _facade.nodeSelect(group, node);
      if (!mounted) return;
      final String active = result.active.isNotEmpty ? result.active : node;
      setState(() {
        // 单一活动节点模型：切换分组时清掉其它分组的旧高亮，
        // 与重入时（持久化只含一条）行为一致。
        _activeByGroup
          ..clear()
          ..[group] = active;
      });
      // 持久化选择（best-effort）：首页入口卡据此展示，重入时据此高亮。
      await _safe(
        () => _nodeStore.write(ProxyActiveNode(group: group, node: active)),
      );
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      if (error.code == 'PROXY_NODE_NOT_FOUND') {
        AppDialogs.showError('该分组未在当前引擎生效，请重试或重新连接');
      } else {
        AppDialogs.showError('切换端子失败：${error.message}');
      }
    } catch (error) {
      if (mounted) AppDialogs.showError('切换端子失败：$error');
    }
  }

  /// 当前所有分组里可测试的节点名（去重；组引用不算）。
  ///
  /// 无声明分组（引擎合成 `PROXY`）时直接返回全部节点名。
  List<String> get _testTargets {
    if (_groups.isEmpty) return _nodesByName.keys.toList();
    final Set<String> names = <String>{};
    for (final ProxyGroup group in _groups) {
      for (final String member in group.members) {
        if (_nodesByName.containsKey(member)) names.add(member);
      }
    }
    return names.toList();
  }

  /// 统一的延迟测试入口（appbar「测试全部」/ 弹层测速共用）。
  ///
  /// [group] / [node] 限定探测范围（见 `_testAll` / 弹层）；[targets] 是显式
  /// 请求选择器（「测试全部」发送节点名集合，后端据此探测）。[pending] 是本地
  /// 待回填集合，缺省与 [targets] 相同；响应 + 事件双通道回填，剩余未回的节点
  /// 显式标记为超时（绝不无限 spinner）。
  Future<void> _runDelayTest({
    String? group,
    String? node,
    List<String> targets = const <String>[],
    List<String>? pending,
    bool showProgress = false,
  }) async {
    final List<String> pendingList = pending ?? targets;
    if (pendingList.isEmpty) {
      AppDialogs.showInfo('当前没有可测试的端子');
      return;
    }
    setState(() {
      if (showProgress) _testing = true;
      _testTotal = pendingList.length;
      _testedCount = 0;
      _pending
        ..clear()
        ..addAll(pendingList);
      for (final String name in pendingList) {
        _delays.remove(name);
      }
    });
    _latencyTick.value++;
    try {
      final DelayTestResult result = await _facade.nodeDelayTest(
        NodeDelayTestRequest(group: group, node: node, targets: targets),
      );
      if (!mounted) return;
      setState(() {
        for (final DelayResult item in result.results) {
          _delays[item.node] = _DelayState.fromDelayResult(item);
          _pending.remove(item.node);
        }
        // 响应里未出现的节点：显式超时，而非停留在“测试中…”。
        for (final String name in _pending.toList()) {
          _delays[name] = _DelayState.timeout;
        }
        _pending.clear();
        _testedCount = _testTotal;
        _testing = false;
      });
      _latencyTick.value++;
    } on ProxyModuleException catch (error) {
      _finishTestWithError('延迟测试失败：${error.message}');
    } catch (error) {
      _finishTestWithError('延迟测试失败：$error');
    }
  }

  /// `测试全部`：不带 group / node，改为显式发送所有分组里的节点名集合。
  Future<void> _testAll() =>
      _runDelayTest(targets: _testTargets, showProgress: true);

  void _finishTestWithError(String message) {
    if (!mounted) return;
    setState(() {
      for (final String name in _pending.toList()) {
        _delays[name] = _DelayState.timeout;
      }
      _pending.clear();
      _testedCount = _testTotal;
      _testing = false;
    });
    _latencyTick.value++;
    AppDialogs.showError(message);
  }

  Future<void> _pickSort() async {
    final _NodeSort? selected = await AppSheet.show<_NodeSort>(
      context: context,
      title: '排序方式',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final _NodeSort option in _NodeSort.values)
            _SheetOption(
              key: Key('proxy_nodes_sort_option_${option.name}'),
              label: option.label,
              selected: option == _sort,
              onTap: () => Navigator.of(context).pop(option),
            ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _sort = selected);
  }

  // ==================== 弹层 ====================

  /// 打开分组弹层：列出该组全部成员（叶子节点与组引用均可选），顶部带测速。
  ///
  /// 只读组（[load-balance]/[relay]/未知类型）仍可列出成员与测速，但点击成员
  /// 不会触发 `node.select`。
  Future<void> _openGroupSheet(ProxyGroup group) async {
    final List<String> members = _sortedMembers(group);
    final List<String> targets =
        members.where(_nodesByName.containsKey).toList();
    final List<_PickerEntry> entries = <_PickerEntry>[
      for (final String name in members)
        _PickerEntry(
          name: name,
          subtitle: _nodesByName[name] == null
              ? '端子组'
              : _nodeSubtitle(_nodesByName[name]!),
          isGroupRef: _nodesByName[name] == null,
        ),
    ];
    await AppSheet.showCustom<void>(
      context: context,
      builder: (BuildContext sheetContext) => _NodePickerSheet(
        title: group.name,
        subtitle:
            '${_groupTypeLabel(group.type)} · ${group.members.length} 个成员',
        icon: TablerIcons.sitemap,
        entries: entries,
        activeName: _activeByGroup[group.name],
        selectable: _groupSelectable(group),
        revision: _latencyTick,
        delayOf: (String n) => _delays[n],
        isPending: _pending.contains,
        onTest: () => _runDelayTest(targets: targets, pending: targets),
        onSelect: (String n) => _selectNode(group.name, n),
      ),
    );
  }

  /// 打开节点弹层：展示节点信息 + 单节点测速 + 底部「选择」动作。
  ///
  /// [parentGroup] 是该节点所在分节的分组名（同名节点可属多组，必须显式传入）。
  Future<void> _openNodeSheet(ProxyNode node, String parentGroup) async {
    final ProxyGroup? parent = _groupByName(parentGroup);
    final bool selectable = parent == null ? true : _groupSelectable(parent);
    await AppSheet.showCustom<void>(
      context: context,
      builder: (BuildContext sheetContext) => _NodePickerSheet(
        title: node.name,
        subtitle: _nodeSubtitle(node),
        icon: TablerIcons.server,
        nodeMode: true,
        entries: <_PickerEntry>[
          _PickerEntry(
            name: node.name,
            subtitle: _nodeSubtitle(node),
            isGroupRef: false,
          ),
        ],
        activeName: _activeByGroup[parentGroup],
        selectable: selectable,
        revision: _latencyTick,
        delayOf: (String n) => _delays[n],
        isPending: _pending.contains,
        onTest: () =>
            _runDelayTest(node: node.name, pending: <String>[node.name]),
        onSelect: (String n) => _selectNode(parentGroup, n),
      ),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('网络选择'),
        actions: <Widget>[
          IconButton(
            key: const Key('proxy_nodes_sort'),
            icon: const Icon(TablerIcons.arrows_sort),
            tooltip: '排序',
            onPressed: _pickSort,
          ),
          IconButton(
            key: const Key('proxy_nodes_test_all'),
            icon: const Icon(TablerIcons.gauge),
            tooltip: '测试全部延迟',
            onPressed: _testing ? null : _testAll,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final String? error = _loadError;
    if (error != null) {
      return _buildError(context, error);
    }
    if (_nodesByName.isEmpty) {
      return _buildEmpty(context);
    }

    final bool groupsMode = _hasProxyGroups;
    final List<ProxyGroup> groups =
        groupsMode ? _visibleGroups : const <ProxyGroup>[];
    final List<String> names = groupsMode ? const <String>[] : _visibleNodeNames;
    if (groupsMode ? groups.isEmpty : names.isEmpty) {
      return _buildEmpty(context);
    }

    return CustomScrollView(
      slivers: <Widget>[
        if (_testing)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              0,
            ),
            sliver: SliverToBoxAdapter(child: _buildProgressCard(context)),
          ),
        // 声明了 proxy-groups：仅 2 列分组宫格（成员在弹层内列出）。
        // 未声明：仅 2 列节点宫格（作用域为引擎合成的隐式组）。
        if (groupsMode)
          SliverPadding(
            padding: AppSpacing.pageHorizontalPadding,
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: AppSpacing.md,
                crossAxisSpacing: AppSpacing.md,
                mainAxisExtent: 120,
              ),
              delegate: SliverChildBuilderDelegate(
                (BuildContext context, int index) =>
                    _buildGroupTile(groups[index]),
                childCount: groups.length,
              ),
            ),
          )
        else
          SliverPadding(
            padding: AppSpacing.pageHorizontalPadding,
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: AppSpacing.md,
                crossAxisSpacing: AppSpacing.md,
                mainAxisExtent: 120,
              ),
              delegate: SliverChildBuilderDelegate(
                // 作用域为隐式组；names 均来自 _nodesByName，必分派到节点磁贴。
                (BuildContext context, int index) =>
                    _buildMemberTile(_implicitGroupName, names[index]),
                childCount: names.length,
              ),
            ),
          ),
      ],
    );
  }

  /// 可见节点名：全部节点，按 [_sort] 排序。
  List<String> get _visibleNodeNames => _sortedNames(_nodesByName.keys);

  /// 分组磁贴：点击打开该组成员弹层（含测速与（可选）选择）。
  Widget _buildGroupTile(ProxyGroup group) {
    final bool active = (_activeByGroup[group.name] ?? '').isNotEmpty;
    return _GridTile(
      key: Key('proxy_nodes_group_${group.name}'),
      icon: TablerIcons.sitemap,
      active: active,
      activeKey: Key('proxy_nodes_group_active_${group.name}'),
      title: group.name,
      subtitle: _groupSubtitle(group),
      onTap: () => _openGroupSheet(group),
    );
  }

  /// 可见分组：全部声明分组。
  List<ProxyGroup> get _visibleGroups => _groups;

  /// 按名字查找分组（子分组条目跳转用）。
  ProxyGroup? _groupByName(String name) {
    for (final ProxyGroup group in _groups) {
      if (group.name == name) return group;
    }
    return null;
  }

  /// 无声明代理组时，选择作用域使用的隐式组名（引擎合成的 `PROXY`）。
  String get _implicitGroupName =>
      _groups.isNotEmpty ? _groups.first.name : 'PROXY';

  /// 组是否允许手动选择（pin）：优先用实时 `selectable`，否则按配置类型推断。
  ///
  /// `select` / `url-test` / `fallback` 可手动选择；`load-balance` / `relay` /
  /// 未知类型为只读（成员可列出、可测速，但不可选择）。
  bool _groupSelectable(ProxyGroup group) {
    final NodeGroupInfo? live = _liveByGroup[group.name];
    if (live != null) return live.selectable;
    switch (group.type.toLowerCase()) {
      case 'select':
      case 'url-test':
      case 'fallback':
        return true;
      default:
        return false;
    }
  }

  /// 组类型的中文标签（未知类型原样回显）。
  String _groupTypeLabel(String type) {
    switch (type.toLowerCase()) {
      case 'select':
        return '手动选择';
      case 'url-test':
        return '自动测速';
      case 'fallback':
        return '故障转移';
      case 'load-balance':
        return '负载均衡';
      case 'relay':
        return '链式转发';
      default:
        return type;
    }
  }

  /// 组的当前出站成员：优先实时 `now`，否则退回持久化选择。
  String _groupCurrent(ProxyGroup group) {
    final String? now = _liveByGroup[group.name]?.now;
    if (now != null && now.isNotEmpty) return now;
    return _activeByGroup[group.name] ?? '';
  }

  /// 组磁贴副标题：`类型 · N 个成员[ · 当前：<活动成员>]`（只读组不显示当前）。
  String _groupSubtitle(ProxyGroup group) {
    final String base = '${_groupTypeLabel(group.type)} · ${group.members.length} 个成员';
    final String cur = _groupSelectable(group) ? _groupCurrent(group) : '';
    return cur.isEmpty ? base : '$base · 当前：$cur';
  }

  Widget _buildEmpty(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: AppSpacing.allXXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              TablerIcons.server,
              size: AppTypography.iconXXXL,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('暂无端子', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '导入网络组后即可在此查看与切换端子',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context, String message) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: AppSpacing.allXXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              TablerIcons.alert_circle,
              size: AppTypography.iconXXXL,
              color: scheme.error,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('端子加载失败', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message.isEmpty ? '未知错误' : message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              key: const Key('proxy_nodes_retry'),
              onPressed: _retry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Row(
          children: <Widget>[
            const AppLoading(size: AppLoadingSize.small),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                '正在测试延迟 $_testedCount/$_testTotal',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 组内成员磁贴：按父分组分派到节点 / 子分组磁贴。
  Widget _buildMemberTile(String parentGroup, String member) {
    final ProxyNode? node = _nodesByName[member];
    if (node != null) return _buildNodeTile(node, parentGroup);
    return _buildSubGroupTile(parentGroup, member);
  }

  /// 节点磁贴：标题节点名，副标题端点 / 类型，测速后附延迟徽章。
  ///
  /// 高亮严格限定在 [parentGroup] 内（同名节点在其它组不会误高亮）。
  Widget _buildNodeTile(ProxyNode node, String parentGroup) {
    final bool isActive = _activeByGroup[parentGroup] == node.name;
    return _GridTile(
      key: Key('proxy_nodes_member_${parentGroup}_${node.name}'),
      icon: TablerIcons.server,
      active: isActive,
      activeKey: Key('proxy_nodes_active_${parentGroup}_${node.name}'),
      title: node.name,
      subtitle: _nodeSubtitle(node),
      badge: _LatencyBadge(
        key: Key('proxy_nodes_delay_${parentGroup}_${node.name}'),
        state: _delays[node.name],
        pending: _pending.contains(node.name),
      ),
      onTap: () => _openNodeSheet(node, parentGroup),
    );
  }

  /// 子分组成员磁贴：点击下钻到该子分组自己的弹层。
  ///
  /// 高亮同样限定在 [parentGroup] 内（组当前成员恰为该子分组时）。
  Widget _buildSubGroupTile(String parentGroup, String member) {
    final bool isActive = _activeByGroup[parentGroup] == member;
    final ProxyGroup? target = _groupByName(member);
    return _GridTile(
      key: Key('proxy_nodes_member_${parentGroup}_$member'),
      icon: TablerIcons.folder,
      active: isActive,
      activeKey: Key('proxy_nodes_active_${parentGroup}_$member'),
      title: member,
      subtitle: '端子组',
      // 悬空组引用（无同名分组）无可下钻目标：保持可渲染但无动作。
      onTap: target == null ? () {} : () => _openGroupSheet(target),
    );
  }

  String _nodeSubtitle(ProxyNode node) {
    final String endpoint = node.server.isEmpty
        ? ''
        : '${node.server}${node.port > 0 ? ':${node.port}' : ''}';
    if (endpoint.isEmpty) return node.type;
    return '$endpoint · ${node.type}';
  }
}

/// 宫格磁贴（分组 / 节点共用）：图标 + 标题 + 副标题 +（可选）延迟徽章，
/// 当前生效项用主题 primary / primaryContainer 高亮。
class _GridTile extends StatelessWidget {
  const _GridTile({
    super.key,
    required this.icon,
    required this.active,
    required this.activeKey,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final bool active;
  final Key activeKey;
  final String title;
  final String subtitle;
  final Widget? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color fg = active ? scheme.onPrimaryContainer : scheme.onSurface;

    return Card(
      margin: EdgeInsets.zero,
      color: active ? scheme.primaryContainer : null,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.allLG,
        side: BorderSide(
          color: active ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.allLG,
        child: Padding(
          padding: AppSpacing.allMD,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    icon,
                    size: AppTypography.iconMD,
                    color: active ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const Spacer(),
                  if (active)
                    Icon(
                      TablerIcons.circle_check_filled,
                      key: activeKey,
                      size: AppTypography.iconMD,
                      color: scheme.primary,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(color: fg),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: active
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
              if (badge != null) ...<Widget>[
                const SizedBox(height: AppSpacing.xs),
                Align(alignment: Alignment.centerLeft, child: badge!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 统一弹层内的选择项（分组弹层的成员行 / 节点弹层的单节点行）。
class _PickerEntry {
  const _PickerEntry({
    required this.name,
    required this.subtitle,
    required this.isGroupRef,
  });

  final String name;
  final String subtitle;

  /// 组引用（成员是另一个代理组）→ 以文件夹图标 / 「代理组」副标题区分。
  final bool isGroupRef;
}

/// 宫格磁贴点击后的统一底部弹层。
///
/// 标题行尾部（[AppSheetScaffold.headerTrailing]，固定不随列表滚动）带**测速**
/// 按钮，右对齐并与标题+副标题块垂直居中（调用方经 [onTest] 触发）。
/// 列表项点击即选择并关闭；节点模式另在底部提供显式「选择」动作。
/// 延迟状态来自页面（[revision] 变更时重建），不在此重复探测逻辑。
class _NodePickerSheet extends StatelessWidget {
  const _NodePickerSheet({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.entries,
    required this.activeName,
    required this.revision,
    required this.delayOf,
    required this.isPending,
    required this.onTest,
    required this.onSelect,
    this.selectable = true,
    this.nodeMode = false,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final List<_PickerEntry> entries;
  final String? activeName;
  final ValueListenable<int> revision;
  final _DelayState? Function(String node) delayOf;
  final bool Function(String node) isPending;
  final Future<void> Function() onTest;
  final Future<void> Function(String name) onSelect;

  /// 组是否允许手动选择：只读组（load-balance / relay / 未知）为 false，
  /// 此时成员仅可查看 / 测速，点击不触发选择也不关闭弹层。
  final bool selectable;
  final bool nodeMode;

  Future<void> _select(BuildContext context, String name) async {
    if (!selectable) return;
    await onSelect(name);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // 整个弹层随 [revision] 重建：头部「测速」与列表延迟徽标同步刷新。
    return ValueListenableBuilder<int>(
      valueListenable: revision,
      builder: (BuildContext context, int _, __) {
        final bool testing = entries.any((_PickerEntry e) => isPending(e.name));
        return AppSheetScaffold(
          title: title,
          subtitle: subtitle,
          icon: Icon(icon),
          contentPadding: AppSpacing.onlyHorizontalXL,
          // 测速按钮：钉在标题行尾部，右对齐且相对标题块垂直居中，不随列表滚动。
          headerTrailing: FilledButton.tonalIcon(
            key: const Key('proxy_nodes_sheet_test'),
            onPressed: testing ? null : () => onTest(),
            icon: const Icon(TablerIcons.gauge, size: AppTypography.iconMD),
            label: Text(testing ? '正在测速…' : '测速'),
          ),
          actions: nodeMode
              ? <Widget>[
                  FilledButton(
                    key: const Key('proxy_nodes_node_select'),
                    onPressed: selectable
                        ? () => _select(context, entries.first.name)
                        : null,
                    child: const Text('选择'),
                  ),
                ]
              : const <Widget>[],
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final _PickerEntry entry in entries)
                _buildEntry(context, entry),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEntry(BuildContext context, _PickerEntry entry) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool selected = entry.name == activeName;
    return InkWell(
      key: Key(
        nodeMode
            ? 'proxy_nodes_sheet_node'
            : 'proxy_nodes_sheet_member_${entry.name}',
      ),
      onTap: selectable ? () => _select(context, entry.name) : null,
      borderRadius: AppRadius.allSM,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              entry.isGroupRef ? TablerIcons.folder : TablerIcons.server,
              size: AppTypography.iconMD,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: selected ? scheme.primary : scheme.onSurface,
                      fontWeight: selected
                          ? AppTypography.weightMedium
                          : AppTypography.weightRegular,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            if (!entry.isGroupRef)
              _LatencyBadge(
                key: Key('proxy_nodes_sheet_delay_${entry.name}'),
                state: delayOf(entry.name),
                pending: isPending(entry.name),
              ),
            if (selected && selectable)
              Padding(
                padding: AppSpacing.onlyLeftSM,
                child: Icon(
                  TablerIcons.circle_check_filled,
                  size: AppTypography.iconMD,
                  color: scheme.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 逐节点延迟徽标：按阈值映射到主题色；超时显式文案（不是 spinner）。
class _LatencyBadge extends StatelessWidget {
  const _LatencyBadge({super.key, required this.state, required this.pending});

  final _DelayState? state;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final _DelayState? current = state;

    if (current == null) {
      final String text = pending ? '测试中…' : '未测试';
      return Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    if (current.isFailure) {
      // 非超时失败：紧凑徽标 + 原因挂在 tooltip，与超时区分。
      return Tooltip(
        message: current.failureReason!,
        child: _badge(
          context,
          color: scheme.error,
          icon: TablerIcons.alert_triangle,
          text: '失败',
        ),
      );
    }
    if (current.isTimeout) {
      return _badge(
        context,
        color: scheme.error,
        icon: TablerIcons.alert_circle,
        text: '超时',
      );
    }
    // 阈值配色：低延迟 → tertiary，中 → primary，高 → error。
    final Color color = current.delayMs <= 200
        ? scheme.tertiary
        : current.delayMs <= 600
            ? scheme.primary
            : scheme.error;
    return _badge(context, color: color, text: '${current.delayMs} ms');
  }

  Widget _badge(
    BuildContext context, {
    required Color color,
    required String text,
    IconData? icon,
  }) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: _kBadgeTintAlpha),
        borderRadius: AppRadius.allSM,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: AppTypography.iconSM, color: color),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            text,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: AppTypography.weightMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// 统一弹层内的可选行（选中态用主题 primary 打勾）。
class _SheetOption extends StatelessWidget {
  const _SheetOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: selected ? scheme.primary : scheme.onSurface,
                  fontWeight: selected
                      ? AppTypography.weightMedium
                      : AppTypography.weightRegular,
                ),
              ),
            ),
            if (selected)
              Icon(TablerIcons.check,
                  size: AppTypography.iconLG, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}
