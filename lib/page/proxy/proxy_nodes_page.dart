import 'dart:async';

import 'package:flutter/material.dart';

import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

import 'proxy_nodes_facade.dart';

/// 节点 / 代理组页面（纯展示 + 触发）。
///
/// **只做展示与转发**：分组/节点模型来自冻结契约 [ProxyGroup] / [ProxyNode]；
/// 切换节点调用 [ProxyNodesFacade.nodeSelect]，`测试全部` 调用
/// [ProxyNodesFacade.nodeDelayTest]，逐节点延迟来自 `proxy.node.delay` 事件。
/// 本页**不含**任何延迟探测 / 解析逻辑（全部在 Rust 侧）。
///
/// 视觉规范：颜色一律取自 `Theme.of(context).colorScheme`，字号取自
/// `Theme.of(context).textTheme`；弹层（选组 / 选节点 / 排序）统一走
/// [AppSheet]；加载态用 [AppLoading]（不直接用 `CircularProgressIndicator`）。
class ProxyNodesPage extends StatefulWidget {
  const ProxyNodesPage({
    super.key,
    required this.nodes,
    this.groups = const <ProxyGroup>[],
    this.facade,
    this.initialGroup,
    this.initialActiveByGroup = const <String, String>{},
  });

  /// 可用于延迟展示 / 选择的节点集合。
  final List<ProxyNode> nodes;

  /// 代理组；为空时自动合成一个「全部节点」伪分组。
  final List<ProxyGroup> groups;

  /// 门面（测试注入假实现；为空时用生产单例适配器）。
  final ProxyNodesFacade? facade;

  /// 默认选中的分组名；非法则回退到第一个分组。
  final String? initialGroup;

  /// 初始「分组 → 活动节点」映射（无选择事件时用于回显）。
  final Map<String, String> initialActiveByGroup;

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

  /// 不可达 / 未完成（0ms）→ 明确按超时呈现。
  bool get isTimeout => !alive || delayMs <= 0 || error != null;
}

class _ProxyNodesPageState extends State<ProxyNodesPage> {
  late final ProxyNodesFacade _facade;
  StreamSubscription<ProxyEvent>? _eventSub;

  late final Map<String, ProxyNode> _nodesByName;
  late final List<ProxyGroup> _groups;
  late final Set<String> _realGroupNames;

  String? _selectedGroup;
  final Map<String, String> _activeByGroup = <String, String>{};
  final Map<String, _DelayState> _delays = <String, _DelayState>{};
  final Set<String> _pending = <String>{};

  bool _testing = false;
  int _testedCount = 0;
  int _testTotal = 0;
  _NodeSort _sort = _NodeSort.name;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleNodesFacade();
    _nodesByName = <String, ProxyNode>{
      for (final ProxyNode node in widget.nodes) node.name: node,
    };
    _realGroupNames = <String>{for (final ProxyGroup g in widget.groups) g.name};
    _groups = widget.groups.isEmpty
        ? <ProxyGroup>[
            ProxyGroup(
              name: '全部节点',
              type: 'select',
              members: _nodesByName.keys.toList(),
            ),
          ]
        : widget.groups;
    _activeByGroup.addAll(widget.initialActiveByGroup);
    final String? requested = widget.initialGroup;
    _selectedGroup = (requested != null && _groupByName(requested) != null)
        ? requested
        : _groups.first.name;
    _eventSub = _facade.events.listen(_onEvent, onError: (_) {});
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  ProxyGroup? _groupByName(String name) {
    for (final ProxyGroup group in _groups) {
      if (group.name == name) return group;
    }
    return null;
  }

  ProxyGroup get _currentGroup =>
      _groupByName(_selectedGroup ?? '') ?? _groups.first;

  bool get _isPseudoGroup => !_realGroupNames.contains(_currentGroup.name);

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
  }

  int? _positiveDelay(String node) {
    final _DelayState? state = _delays[node];
    if (state == null || state.isTimeout) return null;
    return state.delayMs;
  }

  /// 当前分组内按 [_sort] 排序后的成员名。
  List<String> get _sortedMembers {
    final List<String> members = _currentGroup.members.toList();
    switch (_sort) {
      case _NodeSort.name:
        members.sort((String a, String b) => a.compareTo(b));
      case _NodeSort.latencyAsc:
        members.sort((String a, String b) {
          final int? da = _positiveDelay(a);
          final int? db = _positiveDelay(b);
          if (da == null && db == null) return a.compareTo(b);
          if (da == null) return 1;
          if (db == null) return -1;
          final int c = da.compareTo(db);
          return c == 0 ? a.compareTo(b) : c;
        });
      case _NodeSort.latencyDesc:
        members.sort((String a, String b) {
          final int? da = _positiveDelay(a);
          final int? db = _positiveDelay(b);
          if (da == null && db == null) return a.compareTo(b);
          if (da == null) return 1;
          if (db == null) return -1;
          final int c = db.compareTo(da);
          return c == 0 ? a.compareTo(b) : c;
        });
    }
    return members;
  }

  Future<void> _selectNode(String group, String node) async {
    try {
      final NodeSelectResult result = await _facade.nodeSelect(group, node);
      if (!mounted) return;
      setState(() {
        _activeByGroup[group] =
            result.active.isNotEmpty ? result.active : node;
      });
    } on ProxyModuleException catch (error) {
      if (mounted) AppDialogs.showError('切换节点失败：${error.message}');
    } catch (error) {
      if (mounted) AppDialogs.showError('切换节点失败：$error');
    }
  }

  /// `测试全部`：触发 Rust 逐节点探测；响应 + 事件双通道回填，剩余未回的
  /// 节点显式标记为超时（绝不无限 spinner）。
  Future<void> _testAll() async {
    final ProxyGroup group = _currentGroup;
    final List<String> targets =
        group.members.where(_nodesByName.containsKey).toList();
    if (targets.isEmpty) {
      AppDialogs.showInfo('当前分组没有可测试的节点');
      return;
    }
    setState(() {
      _testing = true;
      _testTotal = targets.length;
      _testedCount = 0;
      _pending
        ..clear()
        ..addAll(targets);
      for (final String name in targets) {
        _delays.remove(name);
      }
    });
    try {
      final DelayTestResult result = await _facade.nodeDelayTest(
        NodeDelayTestRequest(group: _isPseudoGroup ? null : group.name),
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
    } on ProxyModuleException catch (error) {
      _finishTestWithError('延迟测试失败：${error.message}');
    } catch (error) {
      _finishTestWithError('延迟测试失败：$error');
    }
  }

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
    AppDialogs.showError(message);
  }

  Future<void> _pickGroup() async {
    final String? selected = await AppSheet.show<String>(
      context: context,
      title: '选择代理组',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final ProxyGroup group in _groups)
            _SheetOption(
              key: Key('proxy_nodes_group_option_${group.name}'),
              label: group.name,
              subtitle: '${group.type} · ${group.members.length} 个成员',
              selected: group.name == _selectedGroup,
              onTap: () => Navigator.of(context).pop(group.name),
            ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _selectedGroup = selected);
  }

  Future<void> _pickNode() async {
    final ProxyGroup group = _currentGroup;
    final String? selected = await AppSheet.show<String>(
      context: context,
      title: '选择节点',
      subtitle: group.name,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final String name in group.members)
            _SheetOption(
              key: Key('proxy_nodes_node_option_$name'),
              label: name,
              subtitle: _nodesByName[name] == null ? '代理组' : null,
              selected: _activeByGroup[group.name] == name,
              onTap: () => Navigator.of(context).pop(name),
            ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    if (!_nodesByName.containsKey(selected)) {
      AppDialogs.showInfo('「$selected」是代理组，暂不支持在本地切换');
      return;
    }
    await _selectNode(group.name, selected);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('节点'),
        actions: <Widget>[
          IconButton(
            key: const Key('proxy_nodes_pick_node'),
            icon: const Icon(Icons.check_circle_outline),
            tooltip: '选择节点',
            onPressed: _pickNode,
          ),
          IconButton(
            key: const Key('proxy_nodes_sort'),
            icon: const Icon(Icons.sort),
            tooltip: '排序',
            onPressed: _pickSort,
          ),
          IconButton(
            key: const Key('proxy_nodes_test_all'),
            icon: const Icon(Icons.speed_outlined),
            tooltip: '测试全部延迟',
            onPressed: _testing ? null : _testAll,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (widget.nodes.isEmpty) {
      return _buildEmpty(context);
    }
    return ListView(
      padding: AppSpacing.allLG,
      children: <Widget>[
        _buildGroupCard(context),
        if (_testing) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _buildProgressCard(context),
        ],
        const SizedBox(height: AppSpacing.md),
        Text(
          '节点（${_sortedMembers.length}）',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: AppSpacing.sm),
        ..._buildMemberTiles(context),
      ],
    );
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
              Icons.dns_outlined,
              size: AppTypography.iconXXXL,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('暂无节点', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '导入订阅后即可在此查看与切换节点',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ProxyGroup group = _currentGroup;
    final String active =
        _activeByGroup[group.name] ?? '（未选择）';
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: const Key('proxy_nodes_group_picker'),
        onTap: _pickGroup,
        leading: Icon(
          Icons.account_tree_outlined,
          color: theme.colorScheme.primary,
        ),
        title: Text(group.name, style: theme.textTheme.titleMedium),
        subtitle: Text(
          '${group.type} · ${group.members.length} 个成员 · 当前：$active',
          style: theme.textTheme.bodySmall,
        ),
        trailing: const Icon(Icons.expand_more),
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

  List<Widget> _buildMemberTiles(BuildContext context) {
    final String groupName = _currentGroup.name;
    return <Widget>[
      for (final String name in _sortedMembers)
        if (_nodesByName[name] == null)
          _buildGroupRefTile(context, name)
        else
          _buildNodeTile(
            context,
            node: _nodesByName[name]!,
            groupName: groupName,
          ),
    ];
  }

  Widget _buildGroupRefTile(BuildContext context, String name) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ListTile(
        leading: Icon(
          Icons.folder_outlined,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(name, style: theme.textTheme.titleSmall),
        subtitle: Text('代理组', style: theme.textTheme.bodySmall),
      ),
    );
  }

  Widget _buildNodeTile(
    BuildContext context, {
    required ProxyNode node,
    required String groupName,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool isActive = _activeByGroup[groupName] == node.name;
    final bool isPending = _pending.contains(node.name);
    final _DelayState? delay = _delays[node.name];

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ListTile(
        key: Key('proxy_nodes_node_${node.name}'),
        onTap: () => _selectNode(groupName, node.name),
        selected: isActive,
        leading: Icon(
          Icons.dns_outlined,
          color: isActive ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: Row(
          children: <Widget>[
            Flexible(
              child: Text(
                node.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (isActive) ...<Widget>[
              const SizedBox(width: AppSpacing.xs),
              Icon(
                Icons.check_circle,
                key: Key('proxy_nodes_active_${node.name}'),
                size: AppTypography.iconMD,
                color: scheme.primary,
              ),
            ],
          ],
        ),
        subtitle: Text(
          _nodeSubtitle(node),
          style: theme.textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: _LatencyBadge(
          key: Key('proxy_nodes_delay_${node.name}'),
          state: delay,
          pending: isPending,
        ),
      ),
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
    if (current.isTimeout) {
      return _badge(
        context,
        color: scheme.error,
        icon: Icons.error_outline,
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
        color: color.withAlpha(AppColors.alphaLowest),
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
    this.subtitle,
  });

  final String label;
  final String? subtitle;
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: selected ? scheme.primary : scheme.onSurface,
                      fontWeight: selected
                          ? AppTypography.weightMedium
                          : AppTypography.weightRegular,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check, size: AppTypography.iconLG, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}
