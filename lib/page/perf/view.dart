import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_report_store.dart';
import 'package:gstore/compent/line_chart.dart';

import 'logic.dart';
import 'perf_common.dart';
import 'state.dart';

/// 性能监控页（Riverpod）。
///
/// 「渲染 / FPS」区纯 Dart、恒可用；原生模块区（CPU / 内存 / 电池 / 温度 / GPU /
/// 网络 / 进程）在模块未安装时降级为友好的「安装 / 重试」卡片，绝不崩溃。
///
/// 全部颜色 / 文字走 [Theme] 令牌，间距 / 圆角走设计令牌（AGENTS.md）。
class PerfMonitorPage extends ConsumerWidget {
  const PerfMonitorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(perfMonitorProvider);
    final notifier = ref.read(perfMonitorProvider.notifier);
    // keep-alive: provider drives auto-export start/stop (概览页切换「采样 / 实时」
    // 时仍驱动服务，即使「性能报告」页未挂载)。
    ref.watch(perfAutoExportServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('性能监控'),
        actions: [
          IconButton(
            key: const Key('perf_refresh'),
            icon: const Icon(TablerIcons.refresh, size: AppTypography.iconMD),
            tooltip: '刷新',
            onPressed: notifier.refresh,
          ),
        ],
      ),
      body: ListView(
        children: [
          _buildFrameSection(context, notifier, state),
          const SizedBox(height: AppSpacing.md),
          _buildTrendSection(context, state),
          const SizedBox(height: AppSpacing.md),
          _buildSamplingCard(context, notifier, state),
          const SizedBox(height: AppSpacing.md),
          const _BaselineCard(),
          const SizedBox(height: AppSpacing.md),
          const _NavSectionCard(),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }

  // ==================== 渲染 / FPS ====================

  Widget _buildFrameSection(
    BuildContext context,
    PerfMonitorNotifier notifier,
    PerfPageState state,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stats = state.effectiveFrameStats;
    final running = state.frameMonitorRunning;

    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            perfSectionHeader(
              context,
              TablerIcons.activity,
              '渲染 / FPS',
              trailing: FilledButton.tonalIcon(
                key: const Key('perf_frame_toggle'),
                onPressed: notifier.toggleFrameMonitor,
                icon: Icon(
                  running ? TablerIcons.player_stop : TablerIcons.player_play,
                  size: AppTypography.iconMD,
                ),
                label: Text(running ? '停止' : '开始'),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              running ? '采集中…' : '已停止（点击「开始」实时采集帧时序）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  stats.fps.toStringAsFixed(1),
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: AppTypography.weightBold,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Padding(
                  padding: AppSpacing.onlyBottomSM,
                  child: Text(
                    'FPS',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            LineChart(
              values: state.fpsHistory,
              color: scheme.primary,
              minY: 0,
              gridLines: 3,
              height: AppSpacing.massive + AppSpacing.md,
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                perfMetric(
                  context,
                  '平均帧',
                  '${stats.avgTotalMs.toStringAsFixed(2)} ms',
                ),
                perfMetric(
                  context,
                  'P90',
                  '${stats.p90TotalMs.toStringAsFixed(2)} ms',
                ),
                perfMetric(
                  context,
                  'P99',
                  '${stats.p99TotalMs.toStringAsFixed(2)} ms',
                ),
                perfMetric(
                  context,
                  '最慢帧',
                  '${stats.maxTotalMs.toStringAsFixed(2)} ms',
                ),
                perfMetric(
                  context,
                  'Jank',
                  '${stats.jankCount}',
                  sub: '${(stats.jankRatio * 100).toStringAsFixed(1)}%',
                  accent: stats.jankCount > 0,
                ),
                perfMetric(
                  context,
                  '窗口 Jank',
                  '${stats.windowJankCount}',
                  sub: '${stats.sampledFrames}/${stats.windowSize} 帧',
                  accent: stats.windowJankCount > 0,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '单帧预算 ${stats.budgetMs.toStringAsFixed(2)} ms · '
              'jank 阈值 ${stats.jankThresholdMs.toStringAsFixed(2)} ms · '
              '窗口 ${stats.windowSize} 帧',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (stats.worstFrames.isNotEmpty) ...[
              const Divider(height: AppSpacing.xxl),
              Text('最差帧（Top ${stats.worstFrames.length}）',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              for (var i = 0; i < stats.worstFrames.length; i++)
                _worstFrameRow(context, i + 1, stats.worstFrames[i]),
            ],
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: notifier.resetFrameStats,
                icon: const Icon(TablerIcons.refresh, size: AppTypography.iconSM),
                label: const Text('重置统计'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _worstFrameRow(BuildContext context, int rank, FrameSample frame) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: AppSpacing.xxl,
            child: Text(
              '#$rank',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              '${frame.totalMs.toStringAsFixed(2)} ms',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Text(
            'UI ${frame.buildMs.toStringAsFixed(1)} / GPU ${frame.rasterMs.toStringAsFixed(1)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 后台采样 ====================

  Widget _buildSamplingCard(
    BuildContext context,
    PerfMonitorNotifier notifier,
    PerfPageState state,
  ) {
    final theme = Theme.of(context);
    final ready = state.moduleReady;
    final subtitle = !ready
        ? '模块就绪后可用'
        : state.sampling
            ? '采样中 · 已收 ${state.sampleCount} 条'
            : '关闭（默认）';
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          SwitchListTile(
            key: const Key('perf_sampling_switch'),
            secondary: Icon(
              TablerIcons.bolt,
              size: AppTypography.iconMD,
              color: theme.colorScheme.primary,
            ),
            title: const Text('后台实时采样'),
            subtitle: Text(subtitle),
            value: state.sampling,
            onChanged: ready ? (value) => notifier.toggleSampling(value) : null,
          ),
          const Divider(height: AppSpacing.md),
          SwitchListTile(
            key: const Key('perf_live_switch'),
            secondary: Icon(
              TablerIcons.chart_line,
              size: AppTypography.iconMD,
              color: theme.colorScheme.tertiary,
            ),
            title: const Text('实时刷新趋势'),
            subtitle: Text(state.live ? '每 1 秒刷新一次' : '关闭（默认）'),
            value: state.live,
            onChanged: notifier.setLive,
          ),
        ],
      ),
    );
  }

  // ==================== 指标趋势（自绘 sparkline） ====================

  Widget _buildTrendSection(BuildContext context, PerfPageState state) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            perfSectionHeader(context, TablerIcons.chart_line, '指标趋势'),
            const SizedBox(height: AppSpacing.md),
            LayoutBuilder(
              builder: (context, constraints) {
                const double gap = AppSpacing.md;
                const double minTileWidth = 200;
                final double tileWidth =
                    constraints.maxWidth >= minTileWidth * 2 + gap
                        ? (constraints.maxWidth - gap) / 2
                        : constraints.maxWidth;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    _metricChartTile(
                      context,
                      width: tileWidth,
                      label: 'CPU',
                      value: state.cpu == null
                          ? null
                          : '${state.cpu!.usagePercent.toStringAsFixed(1)}%',
                      unit: '',
                      values: state.cpuUsageHistory,
                      color: scheme.primary,
                      icon: TablerIcons.cpu,
                      minY: 0,
                      maxY: 100,
                      gauge: state.cpu?.usagePercent,
                    ),
                    _metricChartTile(
                      context,
                      width: tileWidth,
                      label: '内存',
                      value: state.memory == null
                          ? null
                          : '${state.memory!.usedPercent.toStringAsFixed(1)}%',
                      unit: '',
                      values: state.memoryUsedHistory,
                      color: scheme.tertiary,
                      icon: TablerIcons.device_desktop,
                      minY: 0,
                      maxY: 100,
                      gauge: state.memory?.usedPercent,
                    ),
                    _metricChartTile(
                      context,
                      width: tileWidth,
                      label: '温度',
                      value: state.thermal?.maxTempC == null
                          ? null
                          : state.thermal!.maxTempC!.toStringAsFixed(1),
                      unit: '°C',
                      values: state.thermalMaxHistory,
                      color: scheme.error,
                      icon: TablerIcons.temperature,
                    ),
                    _metricChartTile(
                      context,
                      width: tileWidth,
                      label: '电池电流',
                      value: state.battery?.present == true &&
                              state.battery?.currentMa != null
                          ? state.battery!.currentMa!.toStringAsFixed(0)
                          : null,
                      unit: 'mA',
                      values: state.batteryCurrentHistory,
                      color: scheme.secondary,
                      icon: TablerIcons.battery,
                    ),
                    _metricChartTile(
                      context,
                      width: tileWidth,
                      label: '网络下行',
                      value: state.network == null
                          ? null
                          : perfRateHuman(state.network!.rxBytesPerSec),
                      unit: '',
                      values: state.networkRxHistory,
                      color: scheme.tertiary,
                      icon: TablerIcons.arrow_down,
                    ),
                    _metricChartTile(
                      context,
                      width: tileWidth,
                      label: '网络上行',
                      value: state.network == null
                          ? null
                          : perfRateHuman(state.network!.txBytesPerSec),
                      unit: '',
                      values: state.networkTxHistory,
                      color: scheme.primary,
                      icon: TablerIcons.arrow_up,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 单个指标图表卡片：大数值 + 单位 + sparkline（无可选弧形仪表盘）。
  Widget _metricChartTile(
    BuildContext context, {
    required double width,
    required String label,
    required String? value,
    required String unit,
    required List<double> values,
    required Color color,
    required IconData icon,
    double? minY,
    double? maxY,
    double? gauge,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: width,
      child: Container(
        padding: AppSpacing.allMD,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: AppRadius.allMD,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (gauge != null) ...[
                  GaugeChart(
                    value: gauge,
                    color: color,
                    size: AppSpacing.huge,
                    strokeWidth: AppSpacing.xs,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ] else ...[
                  Icon(icon, size: AppTypography.iconSM, color: color),
                  const SizedBox(width: AppSpacing.xs),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      if (value == null)
                        Text(
                          '等待数据',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      else
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Flexible(
                              child: Text(
                                value,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: color,
                                  fontWeight: AppTypography.weightSemiBold,
                                ),
                              ),
                            ),
                            if (unit.isNotEmpty) ...[
                              const SizedBox(width: AppSpacing.xs),
                              Padding(
                                padding: AppSpacing.onlyBottomXS,
                                child: Text(
                                  unit,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            LineChart(
              values: values,
              color: color,
              minY: minY,
              maxY: maxY,
              gridLines: 3,
              height: AppSpacing.massive,
            ),
          ],
        ),
      ),
    );
  }

}


// ==================== 更多功能导航卡 ====================

/// 概览页底的「更多功能」导航卡：4 个入口分别跳转到拆出的硬件 / 控制 /
/// 报告 / 第三方应用页。
class _NavSectionCard extends StatelessWidget {
  const _NavSectionCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: AppSpacing.allLG,
            child: perfSectionHeader(context, TablerIcons.apps, '更多功能'),
          ),
          const Divider(height: 1),
          ListTile(
            key: const Key('perf_nav_perfHardware'),
            leading: const Icon(TablerIcons.cpu, size: AppTypography.iconMD),
            title: const Text('硬件详情'),
            trailing: const Icon(
              TablerIcons.chevron_right,
              size: AppTypography.iconSM,
            ),
            onTap: () => context.push(AppRoute.perfHardware),
          ),
          const Divider(height: 1),
          ListTile(
            key: const Key('perf_nav_perfControl'),
            leading: const Icon(
              TablerIcons.adjustments,
              size: AppTypography.iconMD,
            ),
            title: const Text('控制 / 调优'),
            trailing: const Icon(
              TablerIcons.chevron_right,
              size: AppTypography.iconSM,
            ),
            onTap: () => context.push(AppRoute.perfControl),
          ),
          const Divider(height: 1),
          ListTile(
            key: const Key('perf_nav_perfReports'),
            leading: const Icon(
              TablerIcons.file_description,
              size: AppTypography.iconMD,
            ),
            title: const Text('性能报告'),
            trailing: const Icon(
              TablerIcons.chevron_right,
              size: AppTypography.iconSM,
            ),
            onTap: () => context.push(AppRoute.perfReports),
          ),
          const Divider(height: 1),
          ListTile(
            key: const Key('perf_nav_perfThirdParty'),
            leading: const Icon(TablerIcons.apps, size: AppTypography.iconMD),
            title: const Text('第三方应用'),
            trailing: const Icon(
              TablerIcons.chevron_right,
              size: AppTypography.iconSM,
            ),
            onTap: () => context.push(AppRoute.perfThirdParty),
          ),
        ],
      ),
    );
  }
}


// ==================== 基线对比卡 ====================

/// 基线卡：设为基线 / 清除 / 对比（CPU%、内存%、温度、FPS、jank%）。
class _BaselineCard extends ConsumerStatefulWidget {
  const _BaselineCard();

  @override
  ConsumerState<_BaselineCard> createState() => _BaselineCardState();
}

class _BaselineCardState extends ConsumerState<_BaselineCard> {
  Map<String, dynamic>? _baseline;
  bool _loaded = false;
  bool _showDeltas = false;

  @override
  void initState() {
    super.initState();
    _loadBaseline();
  }

  Future<void> _loadBaseline() async {
    final store = ref.read(perfReportStoreProvider);
    final baseline = await store.loadBaseline();
    if (!mounted) return;
    setState(() {
      _baseline = baseline;
      _loaded = true;
    });
  }

  Future<void> _setBaseline() async {
    final state = ref.read(perfMonitorProvider);
    final metrics = buildBaselineMetrics(
      cpu: state.cpu,
      memory: state.memory,
      thermal: state.thermal,
      frameStats: state.frameStats,
      timestamp: DateTime.now(),
    );
    await ref.read(perfReportStoreProvider).saveBaseline(metrics);
    if (!mounted) return;
    setState(() {
      _baseline = metrics;
      _showDeltas = false;
    });
    AppDialogs.showSuccess('已设为基线');
  }

  Future<void> _clearBaseline() async {
    await ref.read(perfReportStoreProvider).clearBaseline();
    if (!mounted) return;
    setState(() {
      _baseline = null;
      _showDeltas = false;
    });
    AppDialogs.showInfo('已清除基线');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = ref.watch(perfMonitorProvider);
    final baseline = _baseline;
    final current = buildBaselineMetrics(
      cpu: state.cpu,
      memory: state.memory,
      thermal: state.thermal,
      frameStats: state.frameStats,
    );
    final deltas = _showDeltas && baseline != null
        ? compareToBaseline(current, baseline)
        : const <PerfMetricDelta>[];
    final status = !_loaded
        ? '读取中…'
        : baseline == null
            ? '未设置基线（点击「设为基线」保存当前指标）'
            : '已设置基线${_baselineTimeText(baseline)}';
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  TablerIcons.ruler_measure,
                  size: AppTypography.iconMD,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '基线对比',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('perf_baseline_set'),
                  onPressed: _loaded ? _setBaseline : null,
                  icon: const Icon(TablerIcons.flag, size: AppTypography.iconSM),
                  label: const Text('设为基线'),
                ),
                OutlinedButton.icon(
                  key: const Key('perf_baseline_clear'),
                  onPressed: (_loaded && baseline != null) ? _clearBaseline : null,
                  icon: const Icon(TablerIcons.trash, size: AppTypography.iconSM),
                  label: const Text('清除'),
                ),
                FilledButton.icon(
                  key: const Key('perf_baseline_compare'),
                  onPressed: (_loaded && baseline != null)
                      ? () => setState(() => _showDeltas = !_showDeltas)
                      : null,
                  icon: const Icon(
                    TablerIcons.arrows_diff,
                    size: AppTypography.iconSM,
                  ),
                  label: Text(_showDeltas ? '隐藏对比' : '对比'),
                ),
              ],
            ),
            if (deltas.isNotEmpty) ...[
              const Divider(height: AppSpacing.xxl),
              for (final delta in deltas) _deltaRow(context, delta),
            ],
          ],
        ),
      ),
    );
  }

  Widget _deltaRow(BuildContext context, PerfMetricDelta d) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final delta = d.delta;
    final color = delta == null
        ? scheme.onSurfaceVariant
        : (delta > 0 ? scheme.error : scheme.primary);
    final String change;
    if (!d.comparable) {
      change = '—';
    } else {
      final sign = delta! >= 0 ? '+' : '';
      final percent = d.deltaPercent;
      change = '$sign${delta.toStringAsFixed(2)}'
          '${percent == null ? '' : ' (${percent >= 0 ? '+' : ''}${percent.toStringAsFixed(1)}%)'}';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: AppSpacing.massive,
            child: Text(d.label, style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: Text(
              d.comparable
                  ? '基线 ${perfNum(d.baseline)} → 当前 ${perfNum(d.current)}'
                  : '数据不足',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            change,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: AppTypography.weightSemiBold,
            ),
          ),
        ],
      ),
    );
  }

  String _baselineTimeText(Map<String, dynamic> baseline) {
    final ts = baseline[kPerfBaselineTsKey];
    if (ts is num) {
      final time = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
      return '（${time.toIso8601String()}）';
    }
    return '';
  }
}
