import 'dart:async';

import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/utils/unit.dart';

import 'proxy_stats_facade.dart';

/// 统计排序键（`stats.domain.get` 的 `sort` + 本地列方向）。
enum _StatSort {
  bytes('流量', 'bytes'),
  connections('连接数', 'connections'),
  upload('上传', 'bytes'),
  download('下载', 'bytes'),
  lastSeen('最近', 'lastSeen'),
  outbound('策略', 'bytes'),
  domain('域名', 'domain');

  const _StatSort(this.label, this.wire);

  final String label;

  /// 转发给 Rust 的排序键（`bytes|connections|lastSeen|domain`）。
  final String wire;
}

/// 时间范围选项。
class _RangeOption {
  const _RangeOption(this.label, this.rangeMs);

  final String label;
  final int rangeMs;
}

const List<_RangeOption> _rangeOptions = [
  _RangeOption('全部', 0),
  _RangeOption('5 分钟', 5 * 60 * 1000),
  _RangeOption('1 小时', 60 * 60 * 1000),
  _RangeOption('24 小时', 24 * 60 * 60 * 1000),
];

/// 域名列表请求上限。
const int _domainLimit = 200;

/// 总览 Top 域名请求 / 展示条数。
const int _topDomainLimit = 5;

/// 实时刷新周期。
const Duration _liveInterval = Duration(seconds: 2);

/// 域名统计看板（纯展示 / 触发层）。
///
/// * 顶部**流量总览**：拉取 `stats.traffic.get` 展示后端聚合的上/下行总量、
///   速率（`/s`）、活动连接与 Top 域名；**不聚合任何总量**。
/// * 域名列表：拉取 `stats.domain.get`（`sort` / `rangeMs`）并按单行字段展示
///   域名、连接数、上/下行字节、最近时间与出站/规则。
/// * **实时刷新**：开关打开后每 ~2s 重拉 `stats.traffic.get` +
///   `stats.domain.get`；[dispose] 取消定时器。
/// * 重置走 [AppDialogs.showConfirmSheet]（危险操作）后 `stats.domain.reset`。
///
/// 字节等口径由 Rust 计算，Dart 仅用 [byteSize] 格式化单值。
class ProxyStatsPage extends StatefulWidget {
  const ProxyStatsPage({super.key, this.facade});

  /// 统计门面（测试可注入假实现；为空时用生产适配器）。
  final ProxyStatsFacade? facade;

  @override
  State<ProxyStatsPage> createState() => _ProxyStatsPageState();
}

class _ProxyStatsPageState extends State<ProxyStatsPage> {
  late final ProxyStatsFacade _facade;

  bool _loading = true;
  TrafficSnapshot? _traffic;
  String? _trafficError;
  DomainPage? _page;
  String? _domainError;
  _StatSort _sort = _StatSort.bytes;
  bool _ascending = false;
  int _rangeMs = 0;

  bool _live = false;
  Timer? _liveTimer;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleStatsFacade();
    _load();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _liveTimer = null;
    super.dispose();
  }

  /// 手动 / 首屏加载：整页 loading，随后并行拉取总览 + 域名。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _trafficError = null;
      _domainError = null;
    });
    await _reload();
  }

  /// 拉取总览 + 域名（并行、互不阻塞）；**不**切换整页 loading（供实时刷新）。
  Future<void> _reload() async {
    await Future.wait<void>([_loadTraffic(), _loadDomains()]);
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _loadTraffic() async {
    try {
      final traffic = await _facade.statsTrafficGet(
        const StatsTrafficGetRequest(topDomains: _topDomainLimit),
      );
      if (!mounted) return;
      setState(() {
        _traffic = traffic;
        _trafficError = null;
      });
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() => _trafficError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _trafficError = '流量总览加载失败：$error');
    }
  }

  Future<void> _loadDomains() async {
    try {
      final page = await _facade.statsDomainGet(
        StatsDomainGetRequest(
          rangeMs: _rangeMs == 0 ? null : _rangeMs,
          sort: _sort.wire,
          limit: _domainLimit,
        ),
      );
      if (!mounted) return;
      setState(() {
        _page = page;
        _domainError = null;
      });
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() => _domainError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _domainError = '统计加载失败：$error');
    }
  }

  /// 开关实时刷新：打开后每 [_liveInterval] 重拉总览 + 域名。
  void _toggleLive() {
    setState(() => _live = !_live);
    _liveTimer?.cancel();
    _liveTimer = null;
    if (_live) {
      _liveTimer = Timer.periodic(
        _liveInterval,
        (_) => unawaited(_reload()),
      );
    }
  }

  void _onSortSelected(_StatSort sort) {
    setState(() {
      if (_sort == sort) {
        _ascending = !_ascending;
      } else {
        _sort = sort;
        _ascending = false;
      }
    });
    _load();
  }

  void _onRangeSelected(_RangeOption option) {
    if (_rangeMs == option.rangeMs) return;
    setState(() => _rangeMs = option.rangeMs);
    _load();
  }

  /// 本地排序：仅比较**单行**字段（不聚合）；`bytes` 信任后端降序，
  /// 升序时直接反转后端顺序。
  List<DomainStat> get _sortedDomains {
    final domains = List<DomainStat>.of(_page?.domains ?? const <DomainStat>[]);
    if (domains.isEmpty) return domains;
    switch (_sort) {
      case _StatSort.bytes:
        return _ascending ? domains.reversed.toList() : domains;
      case _StatSort.connections:
        domains.sort((a, b) => a.connections.compareTo(b.connections));
      case _StatSort.upload:
        domains.sort((a, b) => a.uploadBytes.compareTo(b.uploadBytes));
      case _StatSort.download:
        domains.sort((a, b) => a.downloadBytes.compareTo(b.downloadBytes));
      case _StatSort.lastSeen:
        domains.sort((a, b) => a.lastSeenMs.compareTo(b.lastSeenMs));
      case _StatSort.domain:
        domains.sort((a, b) => a.domain.toLowerCase().compareTo(
              b.domain.toLowerCase(),
            ));
      case _StatSort.outbound:
        domains.sort((a, b) {
          final byOutbound = a.outbound.compareTo(b.outbound);
          if (byOutbound != 0) return byOutbound;
          return a.rule.compareTo(b.rule);
        });
    }
    // 本地比较器一律升序；降序在此统一反转（bytes 已信任后端降序并提前返回）。
    return _ascending ? domains : domains.reversed.toList();
  }

  Future<void> _confirmReset() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '重置域名统计',
      message: '将清空全部域名聚合数据，且无法撤销。确定继续吗？',
      confirmText: '重置',
      isDangerous: true,
      icon: const Icon(Icons.delete_outline),
    );
    if (ok != true || !mounted) return;
    try {
      final result = await _facade.statsDomainReset();
      if (!mounted) return;
      AppDialogs.showSuccess('已重置 ${result.cleared} 条统计');
      await _load();
    } on ProxyModuleException catch (error) {
      AppDialogs.showError(error.message, title: '重置失败');
    } catch (error) {
      AppDialogs.showError('重置失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('域名统计'),
        actions: [
          IconButton(
            tooltip: '重置统计',
            icon: const Icon(Icons.delete_outline),
            onPressed: _page == null ? null : _confirmReset,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    // 首屏：总览与表格都还没有数据时展示整页 loading。
    if (_loading && _traffic == null && _page == null) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildTrafficOverview(context)),
          SliverToBoxAdapter(child: _buildControls(context)),
          ..._buildDomainSlivers(context),
        ],
      ),
    );
  }

  /// 流量总览（`stats.traffic.get`）：总量 / 速率 / 活动连接 / Top 域名。
  Widget _buildTrafficOverview(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final traffic = _traffic;
    final error = _trafficError;

    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
      ),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: AppSpacing.allMD,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ColoredAliIcon(
                    icon: Icons.storage,
                    size: AppTypography.iconMD,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text('流量总览', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  FilterChip(
                    key: const Key('stats_live_toggle'),
                    label: const Text('实时'),
                    selected: _live,
                    onSelected: (_) => _toggleLive(),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (error != null)
                _OverviewError(message: error, onRetry: _loadTraffic)
              else if (traffic == null)
                const Padding(
                  padding: AppSpacing.topBottomSM,
                  child: Center(child: AppLoading(size: AppLoadingSize.small)),
                )
              else
                _TrafficOverviewBody(traffic: traffic),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final theme = Theme.of(context);
    final domains = _sortedDomains;
    return Padding(
      padding: AppSpacing.allLG,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final option in _rangeOptions)
                ChoiceChip(
                  key: Key('stats_range_${option.rangeMs}'),
                  label: Text(option.label),
                  selected: _rangeMs == option.rangeMs,
                  onSelected: (_) => _onRangeSelected(option),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Text('排序', style: theme.textTheme.labelMedium),
              const SizedBox(width: AppSpacing.xs),
              Icon(
                _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                size: AppTypography.iconSM,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                _ascending ? '升序' : '降序',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              ColoredAliIcon(
                icon: Icons.storage,
                size: AppTypography.iconSM,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '${domains.length} 个域名',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final sort in _StatSort.values)
                ChoiceChip(
                  key: Key('stats_sort_${sort.name}'),
                  label: Text(sort.label),
                  selected: _sort == sort,
                  onSelected: (_) => _onSortSelected(sort),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 域名列表（含空态 / 错误态）。
  List<Widget> _buildDomainSlivers(BuildContext context) {
    final error = _domainError;
    if (error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyState(
            icon: Icons.error_outline,
            title: '统计不可用',
            message: error,
            actionLabel: '重试',
            onAction: _load,
          ),
        ),
      ];
    }
    final domains = _sortedDomains;
    if (domains.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyState(
            icon: Icons.storage_outlined,
            title: '暂无域名统计',
            message: '当前时间范围内没有可展示的域名记录。',
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: AppSpacing.onlyHorizontalLG,
        sliver: SliverList.builder(
          itemCount: domains.length,
          itemBuilder: (context, index) => _DomainStatCard(
            key: ValueKey('stat_row_${domains[index].domain}'),
            stat: domains[index],
          ),
        ),
      ),
    ];
  }
}

/// 总览指标区（后端聚合值，仅展示，不计算）。
class _TrafficOverviewBody extends StatelessWidget {
  const _TrafficOverviewBody({required this.traffic});

  final TrafficSnapshot traffic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final top = traffic.topDomains.take(_topDomainLimit).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.xl,
          runSpacing: AppSpacing.md,
          children: [
            _OverviewMetric(
              icon: Icons.arrow_upward,
              label: '上传',
              value: byteSize(traffic.uploadBytes),
              sub: '${byteSize(traffic.upBps)}/s',
            ),
            _OverviewMetric(
              icon: Icons.arrow_downward,
              label: '下载',
              value: byteSize(traffic.downloadBytes),
              sub: '${byteSize(traffic.downBps)}/s',
            ),
            _OverviewMetric(
              icon: Icons.swap_vert,
              label: '活动连接',
              value: '${traffic.activeConns}',
            ),
            _OverviewMetric(
              icon: Icons.dns_outlined,
              label: '域名',
              value: '${traffic.domainCount}',
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Top 域名',
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        if (top.isEmpty)
          Text(
            '暂无 Top 域名',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          for (final domain in top) _TopDomainRow(stat: domain),
      ],
    );
  }
}

/// 单个总览指标（图标 + 标签 + 值 + 可选副值）。
class _OverviewMetric extends StatelessWidget {
  const _OverviewMetric({
    required this.icon,
    required this.label,
    required this.value,
    this.sub,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppTypography.iconXS, color: scheme.primary),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(value, style: theme.textTheme.titleSmall),
        if (sub != null)
          Text(
            sub!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// Top 域名紧凑行（上/下行分别展示后端字段，不做求和）。
class _TopDomainRow extends StatelessWidget {
  const _TopDomainRow({required this.stat});

  final DomainStat stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        children: [
          Expanded(
            child: Text(
              stat.domain.isEmpty ? '(未知域名)' : stat.domain,
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(
            Icons.arrow_upward,
            size: AppTypography.iconXXS,
            color: scheme.primary,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(byteSize(stat.uploadBytes), style: theme.textTheme.labelSmall),
          const SizedBox(width: AppSpacing.sm),
          Icon(
            Icons.arrow_downward,
            size: AppTypography.iconXXS,
            color: scheme.primary,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(byteSize(stat.downloadBytes), style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// 总览内联错误（不遮挡域名表格）。
class _OverviewError extends StatelessWidget {
  const _OverviewError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Icon(
          Icons.error_outline,
          size: AppTypography.iconSM,
          color: scheme.error,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    );
  }
}

class _DomainStatCard extends StatelessWidget {
  const _DomainStatCard({super.key, required this.stat});

  final DomainStat stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: AppSpacing.onlyVerticalXS,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    stat.domain.isEmpty ? '(未知域名)' : stat.domain,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!stat.domainKnown)
                  Container(
                    padding: AppSpacing.horizontalSM_verticalXS,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: AppRadius.allMD,
                    ),
                    child: Text(
                      '未知',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _strategyText(stat),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.lg,
              runSpacing: AppSpacing.xs,
              children: [
                _metric(context, Icons.swap_vert, '${stat.connections} 连接'),
                _metric(context, Icons.arrow_upward, byteSize(stat.uploadBytes)),
                _metric(
                  context,
                  Icons.arrow_downward,
                  byteSize(stat.downloadBytes),
                ),
                _metric(context, Icons.schedule, _formatSeen(stat.lastSeenMs)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _strategyText(DomainStat stat) {
    final parts = <String>[
      if (stat.outbound.isNotEmpty) stat.outbound,
      if (stat.rule.isNotEmpty) stat.rule,
      if (stat.rulePayload.isNotEmpty) stat.rulePayload,
    ];
    return parts.isEmpty ? '未匹配规则' : parts.join(' · ');
  }

  Widget _metric(BuildContext context, IconData icon, String value) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: AppTypography.iconXS, color: theme.colorScheme.primary),
        const SizedBox(width: AppSpacing.xs),
        Text(value, style: theme.textTheme.labelMedium),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

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
            ColoredAliIcon(
              icon: Icons.storage,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.lg),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

String _formatSeen(int tsMs) {
  if (tsMs <= 0) return '—';
  final time = DateTime.fromMillisecondsSinceEpoch(tsMs).toLocal();
  return '${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')} '
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}
