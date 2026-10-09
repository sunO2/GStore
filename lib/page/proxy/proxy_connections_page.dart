/// 实时连接页（Todo 21，纯展示 / 触发层）。
///
/// 展示 `conn.list` 的活动连接（分页 + 域名 / 出站筛选），并支持单条
/// `conn.close` 与全部 `conn.close_all`。连接表、容量截断、排序与关闭动作全部在
/// Rust 侧（`API.md` §2.10）；Dart 只做「拉取 → 展示 → 触发」。
///
/// **只读契约**：经窄接口 [ProxyConnectionsFacade] 消费冻结的 `conn.*`，不改动
/// 冻结的 [ProxyFacade]。
///
/// 门面与事件流均经构造函数注入，测试无需原生模块（[facade] 默认适配
/// [ProxyModule]，[events] 默认取 [ProxyModule.instance] 的事件流）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/utils/unit.dart';

import 'proxy_connections_facade.dart';

/// 单次 `conn.list` 拉取上限（契约默认 256；分页由「加载更多」推进）。
const int _pageLimit = 256;

/// 实时连接页。
class ProxyConnectionsPage extends StatefulWidget {
  const ProxyConnectionsPage({
    super.key,
    this.facade,
    this.events,
    this.initialLive = true,
  });

  /// 连接页门面（测试可注入假实现；为空时用生产适配器）。
  final ProxyConnectionsFacade? facade;

  /// 类型化代理事件流（测试可注入；为空时用 [ProxyModule.instance]）。
  final Stream<ProxyEvent>? events;

  /// 是否监听 `proxy.conn` 事件自动刷新（测试可关闭）。
  final bool initialLive;

  @override
  State<ProxyConnectionsPage> createState() => _ProxyConnectionsPageState();
}

class _ProxyConnectionsPageState extends State<ProxyConnectionsPage> {
  late final ProxyConnectionsFacade _facade;
  late final Stream<ProxyEvent> _events;

  StreamSubscription<ProxyEvent>? _eventSub;

  final TextEditingController _domainController = TextEditingController();
  final TextEditingController _outboundController = TextEditingController();

  bool _live = true;
  bool _loading = true;
  bool _loadingMore = false;
  bool _closingAll = false;

  List<ConnInfo> _connections = const <ConnInfo>[];
  int _count = 0;
  int _capacity = 0;
  bool _hasMore = false;
  String? _error;

  String _domainQuery = '';
  String _outboundQuery = '';

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleConnectionsFacade();
    _events = widget.events ?? ProxyModule.instance.events;
    _live = widget.initialLive;
    if (_live) {
      _eventSub = _events.listen(_onEvent);
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _eventSub = null;
    _domainController.dispose();
    _outboundController.dispose();
    super.dispose();
  }

  /// `proxy.conn`（开 / 闭）→ 拉取刷新（拉取为准）。
  void _onEvent(ProxyEvent event) {
    if (!mounted || !_live) return;
    if (event is ProxyConnEvent) {
      unawaited(_fetch(reset: true, silent: true));
    }
  }

  // ==================== 加载 ====================

  /// 首屏 / 筛选变化 / 重试：整页 loading（保留空态判定）。
  Future<void> _load() => _fetch(reset: true);

  /// 「加载更多」：按已加载条数作 offset 追加下一页。
  Future<void> _loadMore() => _fetch(reset: false, silent: true);

  Future<void> _fetch({required bool reset, bool silent = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      if (_loadingMore || !_hasMore) return;
      setState(() => _loadingMore = true);
    }
    try {
      final page = await _facade.connList(
        ConnListRequest(
          offset: reset ? 0 : _connections.length,
          limit: _pageLimit,
          domain: _domainQuery.isEmpty ? null : _domainQuery,
          outbound: _outboundQuery.isEmpty ? null : _outboundQuery,
        ),
      );
      if (!mounted) return;
      setState(() {
        _connections = reset
            ? List<ConnInfo>.of(page.connections)
            : <ConnInfo>[..._connections, ...page.connections];
        _count = page.count;
        _capacity = page.capacity;
        _hasMore = page.hasMore;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } on ProxyModuleException catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _error = error.message;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _error = '连接列表加载失败：$error';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// 筛选变化：转发到 `conn.list`（域名子串 / 出站精确由 Rust 侧执行）。
  void _applyFilters() {
    _domainQuery = _domainController.text.trim();
    _outboundQuery = _outboundController.text.trim();
    unawaited(_load());
  }

  // ==================== 断开 ====================

  Future<void> _closeOne(ConnInfo conn) async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '断开连接',
      message: conn.domain.isEmpty
          ? '确定断开 ${conn.dst} 吗？'
          : '确定断开 ${conn.domain} 吗？',
      confirmText: '断开',
      isDangerous: true,
      icon: const Icon(TablerIcons.plug_connected),
    );
    if (ok != true || !mounted) return;
    try {
      await _facade.connClose(conn.id);
      if (!mounted) return;
      AppDialogs.showSuccess('已断开连接');
      await _load();
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      AppDialogs.showError(error.message, title: '断开失败');
    } catch (error) {
      if (!mounted) return;
      AppDialogs.showError('断开失败：$error');
    }
  }

  Future<void> _closeAll() async {
    if (_closingAll || _connections.isEmpty) return;
    final ok = await AppDialogs.showConfirmSheet(
      title: '断开全部连接',
      message: '将断开当前全部活动连接，且无法撤销。确定继续吗？',
      confirmText: '全部断开',
      isDangerous: true,
      icon: const Icon(TablerIcons.plug_off),
    );
    if (ok != true || !mounted) return;
    setState(() => _closingAll = true);
    try {
      final result = await _facade.connCloseAll();
      if (!mounted) return;
      setState(() => _closingAll = false);
      AppDialogs.showSuccess('已断开 ${result.closed} 个连接');
      await _load();
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() => _closingAll = false);
      AppDialogs.showError(error.message, title: '断开失败');
    } catch (error) {
      if (!mounted) return;
      setState(() => _closingAll = false);
      AppDialogs.showError('断开失败：$error');
    }
  }

  // ==================== 渲染 ====================

  bool get _hasActiveFilters =>
      _domainQuery.isNotEmpty || _outboundQuery.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('活动连接'),
        actions: [
          IconButton(
            key: const Key('connections_refresh'),
            tooltip: '刷新',
            icon: const Icon(TablerIcons.refresh),
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            key: const Key('connections_close_all'),
            tooltip: '全部断开',
            icon: const Icon(TablerIcons.plug_off),
            onPressed:
                (_closingAll || _connections.isEmpty) ? null : _closeAll,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _connections.isEmpty && _error == null) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final error = _error;
    if (error != null) {
      return _ErrorState(
        message: error,
        onRetry: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: AppSpacing.allLG,
        children: [
          _buildSummary(context),
          const SizedBox(height: AppSpacing.md),
          _buildSearchBar(context),
          const SizedBox(height: AppSpacing.md),
          if (_connections.isEmpty)
            _EmptyState(hasFilters: _hasActiveFilters)
          else ...[
            for (final conn in _connections)
              _ConnectionCard(
                key: ValueKey<String>('conn_row_${conn.id}'),
                conn: conn,
                onClose: () => _closeOne(conn),
              ),
            if (_hasMore)
              Padding(
                padding: AppSpacing.onlyVerticalMD,
                child: Center(
                  child: _loadingMore
                      ? const AppLoading(size: AppLoadingSize.small)
                      : OutlinedButton(
                          key: const Key('connections_load_more'),
                          onPressed: _loadMore,
                          child: const Text('加载更多'),
                        ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummary(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final capacitySuffix = _capacity > 0 ? ' · 容量 $_capacity' : '';
    return Row(
      children: [
        ColoredAliIcon(
          icon: TablerIcons.plug_connected,
          size: AppTypography.iconLG,
          color: scheme.primary,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            '共 $_count 个活动连接 · 已加载 ${_connections.length}$capacitySuffix',
            key: const Key('connections_summary'),
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('connections_domain_search'),
            controller: _domainController,
            onChanged: (_) => _applyFilters(),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '域名子串',
              prefixIcon: Icon(TablerIcons.search),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: TextField(
            key: const Key('connections_outbound_search'),
            controller: _outboundController,
            onChanged: (_) => _applyFilters(),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '出站（精确）',
              prefixIcon: Icon(TablerIcons.arrows_split),
            ),
          ),
        ),
      ],
    );
  }
}

/// 单条连接卡片：域名 / 出站 / 网络 / 目标 / 字节 + 单条断开按钮。
class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    super.key,
    required this.conn,
    required this.onClose,
  });

  final ConnInfo conn;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final domain = conn.domain.isEmpty ? '(未知域名)' : conn.domain;
    final total = conn.uploadBytes + conn.downloadBytes;
    final meta = <String>[
      if (conn.outbound.isNotEmpty) conn.outbound,
      if (conn.network.isNotEmpty) conn.network,
      if (conn.dst.isNotEmpty) conn.dst,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ListTile(
        leading: ColoredAliIcon(
          icon: TablerIcons.arrows_exchange,
          size: AppTypography.iconMD,
          color: scheme.primary,
        ),
        title: Text(
          domain,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (meta.isNotEmpty)
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '↑ ${byteSize(conn.uploadBytes)} · ↓ ${byteSize(conn.downloadBytes)}'
              ' · 共 ${byteSize(total)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        trailing: IconButton(
          key: Key('conn_close_${conn.id}'),
          tooltip: '断开',
          icon: Icon(TablerIcons.plug_off, color: scheme.error),
          onPressed: onClose,
        ),
      ),
    );
  }
}

/// 空态：无连接 / 筛选无匹配。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasFilters});

  final bool hasFilters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: AppSpacing.allXXL,
      child: Column(
        children: [
          Icon(
            hasFilters ? TablerIcons.filter_off : TablerIcons.plug_off,
            size: AppTypography.iconXXXL,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            hasFilters ? '无匹配连接' : '暂无活动连接',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            hasFilters ? '当前筛选条件没有匹配的活动连接。' : '调试引擎当前没有活动连接。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 错误态：模块不可用 / 加载失败 → 显式失败 + 重试。
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              TablerIcons.alert_circle,
              size: AppTypography.iconXXXL,
              color: scheme.error,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('活动连接不可用', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              key: const Key('connections_retry'),
              onPressed: onRetry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
