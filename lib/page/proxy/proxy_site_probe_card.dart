import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';

import 'proxy_site_probe.dart';

/// 代理首页「网站连通性」卡片：手动触发对固定站点清单的可达性 + 延迟探测。
///
/// **纯展示层**：探测逻辑全部在 [SiteProbe]；本组件只负责渲染与触发，
/// 颜色 / 字号 / 间距全部取自主题令牌与设计系统。
///
/// * **不**在页面加载时自动探测，必须用户点按「开始检测」；
/// * 探测遵循当前代理与规则（见卡片说明文案）；
/// * 未注入 [probe] 时使用生产 [SiteProbe]（默认 `dart:io` 适配器）。
class ProxySiteProbeCard extends StatefulWidget {
  const ProxySiteProbeCard({super.key, this.probe});

  /// 探测接缝（测试注入假实现；为空时用生产 [SiteProbe]）。
  final SiteProbe? probe;

  @override
  State<ProxySiteProbeCard> createState() => _ProxySiteProbeCardState();
}

class _ProxySiteProbeCardState extends State<ProxySiteProbeCard> {
  /// 徽标底色透明度（沿用节点页延迟徽标约定）。
  static const double _kBadgeTintAlpha = 0.12;

  /// 延迟列固定宽度，保证各行右边缘对齐。
  static const double _kLatencyWidth = 72;

  late final SiteProbe _probe;

  bool _running = false;

  /// 是否至少启动过一次探测（区分「未检测」的原始态与「检测中」）。
  bool _hasRun = false;

  /// 已完成的逐站结果，按 [SiteProbeTarget.label] 索引。
  final Map<String, SiteProbeResult> _results = <String, SiteProbeResult>{};

  StreamSubscription<SiteProbeResult>? _subscription;

  @override
  void initState() {
    super.initState();
    _probe = widget.probe ?? SiteProbe();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _run() {
    if (_running) return;
    unawaited(_subscription?.cancel());
    setState(() {
      _running = true;
      _hasRun = true;
      _results.clear();
    });
    _subscription = _probe.probeAllStream().listen(
      (SiteProbeResult result) {
        if (!mounted) return;
        setState(() => _results[result.target.label] = result);
      },
      onError: (Object _) {
        // probeAllStream 设计上绝不抛错；收到错误时按完成处理。
        if (!mounted) return;
        setState(() => _running = false);
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _running = false);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<SiteProbeTarget> targets = _probe.targets;
    final int completed = _results.length;
    final int reachable = _results.values.where((r) => r.reachable).length;
    final bool showSummary = _hasRun || _results.isNotEmpty;

    return Card(
      key: const Key('proxy-site-probe-card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  TablerIcons.world_search,
                  size: AppTypography.iconMD,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text('网站连通性', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '检测遵循当前隧道与规则（未连接则直连）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('proxy-site-probe-run'),
                onPressed: _running ? null : _run,
                icon: _running
                    ? const SizedBox(
                        width: AppTypography.iconMD,
                        height: AppTypography.iconMD,
                        child: AppLoading(size: AppLoadingSize.small),
                      )
                    : const Icon(TablerIcons.player_play),
                label: Text(_hasRun ? '重新检测' : '开始检测'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final SiteProbeTarget target in targets)
              _buildRow(theme, scheme, target, _results[target.label]),
            // 首次运行前不显示汇总，避免「0/9 可达」被误读为失败。
            if (showSummary) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _running
                    ? '$completed/${targets.length} · $reachable 可达'
                    : '$reachable/${targets.length} 可达',
                key: const Key('proxy-site-probe-summary'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRow(
    ThemeData theme,
    ColorScheme scheme,
    SiteProbeTarget target,
    SiteProbeResult? result,
  ) {
    final bool pending = _running && result == null;
    final Color color = _verdictColor(scheme, result);
    final int? latency = result?.latencyMs;
    final String badgeText = result != null
        ? _verdictLabel(result)
        : (pending ? '检测中' : '未检测');
    final String latencyText = result != null
        ? (latency == null ? '—' : '$latency ms')
        : (pending ? '…' : '—');
    return Padding(
      key: Key('proxy-site-probe-row-${target.label}'),
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        children: [
          Expanded(
            child: Text(
              target.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          _badge(theme, color: color, text: badgeText),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: _kLatencyWidth,
            child: Text(
              latencyText,
              key: Key('proxy-site-probe-latency-${target.label}'),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(
    ThemeData theme, {
    required Color color,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: _kBadgeTintAlpha),
        borderRadius: AppRadius.allSM,
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: AppTypography.weightMedium,
        ),
      ),
    );
  }

  /// 判定/延迟配色：`ok` 按延迟阈值分档，其余失败态统一 error。
  Color _verdictColor(ColorScheme scheme, SiteProbeResult? result) {
    if (result == null) return scheme.onSurfaceVariant;
    switch (result.verdict) {
      case SiteProbeVerdict.ok:
        final int? ms = result.latencyMs;
        if (ms == null) return scheme.primary;
        if (ms <= 200) return scheme.tertiary;
        if (ms <= 600) return scheme.primary;
        return scheme.error;
      case SiteProbeVerdict.restricted:
      case SiteProbeVerdict.timeout:
      case SiteProbeVerdict.unreachable:
        return scheme.error;
    }
  }

  String _verdictLabel(SiteProbeResult? result) {
    if (result == null) return '未检测';
    switch (result.verdict) {
      case SiteProbeVerdict.ok:
        return '可达';
      case SiteProbeVerdict.restricted:
        return '受限';
      case SiteProbeVerdict.timeout:
        return '超时';
      case SiteProbeVerdict.unreachable:
        return '不可达';
    }
  }
}
