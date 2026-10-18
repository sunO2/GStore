import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_auto_export_settings.dart';
import 'package:gstore/core/perf/perf_export_service.dart';
import 'package:gstore/core/perf/perf_report.dart';
import 'package:gstore/core/perf/perf_report_store.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/compent/line_chart.dart';

import 'logic.dart';
import 'state.dart';
import 'third_party_section.dart';

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

    return Scaffold(
      appBar: AppBar(
        title: const Text('性能监控'),
        actions: [
          IconButton(
            key: const Key('perf_export'),
            icon: const Icon(TablerIcons.download, size: AppTypography.iconMD),
            tooltip: '导出报告',
            onPressed: () => _exportPerfReport(context, ref, state),
          ),
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
          ..._buildModuleArea(context, notifier, state),
          const SizedBox(height: AppSpacing.md),
          const _AutoExportCard(),
          const SizedBox(height: AppSpacing.md),
          const _RecentReportsCard(),
          const SizedBox(height: AppSpacing.md),
          const ThirdPartyAppSection(),
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
            _sectionHeader(
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
                _metric(
                  context,
                  '平均帧',
                  '${stats.avgTotalMs.toStringAsFixed(2)} ms',
                ),
                _metric(
                  context,
                  'P90',
                  '${stats.p90TotalMs.toStringAsFixed(2)} ms',
                ),
                _metric(
                  context,
                  'P99',
                  '${stats.p99TotalMs.toStringAsFixed(2)} ms',
                ),
                _metric(
                  context,
                  '最慢帧',
                  '${stats.maxTotalMs.toStringAsFixed(2)} ms',
                ),
                _metric(
                  context,
                  'Jank',
                  '${stats.jankCount}',
                  sub: '${(stats.jankRatio * 100).toStringAsFixed(1)}%',
                  accent: stats.jankCount > 0,
                ),
                _metric(
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
            _sectionHeader(context, TablerIcons.chart_line, '指标趋势'),
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
                          : _rateHuman(state.network!.rxBytesPerSec),
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
                          : _rateHuman(state.network!.txBytesPerSec),
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

  // ==================== 模块区域 ====================

  List<Widget> _buildModuleArea(
    BuildContext context,
    PerfMonitorNotifier notifier,
    PerfPageState state,
  ) {
    if (state.modulePreparing) {
      return [_buildPreparingCard(context, state)];
    }
    if (!state.moduleReady) {
      return [_buildUnavailableCard(context, notifier, state)];
    }
    final widgets = <Widget>[
      if (state.error != null) _buildErrorCard(context, state.error!),
    ];
    if (state.loading && state.cpu == null) {
      widgets.add(_buildLoadingCard(context));
      return widgets;
    }
    widgets
      ..add(_buildCpuCard(context, state))
      ..add(_buildCpuFreqResidencyCard(context, state))
      ..add(_buildMemoryCard(context, state))
      ..add(_buildPressureCard(context, state))
      ..add(_buildBatteryCard(context, state))
      ..add(_buildBatteryHealthCard(context, state))
      ..add(_buildThermalCard(context, state))
      ..add(_buildCoolingCard(context, state))
      ..add(_buildGpuCard(context, state))
      ..add(_buildNetworkCard(context, state))
      ..add(_buildNetworkErrorCard(context, state))
      ..add(_buildStorageCard(context, state))
      ..add(_buildProcessCard(context, notifier, state));
    return widgets;
  }

  Widget _buildUnavailableCard(
    BuildContext context,
    PerfMonitorNotifier notifier,
    PerfPageState state,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final description = switch (state.availability) {
      PerfAvailability.failed =>
        '原生性能模块当前不可用。可点击重试；若反复失败，请在「模块管理」中检查插件状态。',
      PerfAvailability.downloading => '正在下载原生性能模块…',
      PerfAvailability.initializing => '原生性能模块正在准备…',
      _ =>
        '原生性能模块尚未安装（首次使用需下载）。安装后即可查看 CPU / 内存 / 电池 / 温度 / GPU / 网络 / 进程；上方的 FPS 数据无需模块，已可用。',
    };
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
                  TablerIcons.alert_triangle,
                  size: AppTypography.iconMD,
                  color: scheme.error,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '原生性能模块未就绪',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const Key('perf_retry'),
                onPressed: notifier.retryInstall,
                icon: const Icon(TablerIcons.download,
                    size: AppTypography.iconMD),
                label: const Text('安装 / 重试'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreparingCard(BuildContext context, PerfPageState state) {
    final theme = Theme.of(context);
    final label = state.availability == PerfAvailability.downloading
        ? '正在下载原生性能模块…'
        : '原生性能模块正在准备…';
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Row(
          children: [
            const AppLoading(size: AppLoadingSize.small),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(label, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingCard(BuildContext context) {
    return const Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Row(
          children: [
            AppLoading(size: AppLoadingSize.small),
            SizedBox(width: AppSpacing.md),
            Expanded(child: Text('正在读取性能数据…')),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard(BuildContext context, String message) {
    final theme = Theme.of(context);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              TablerIcons.alert_circle,
              size: AppTypography.iconMD,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== CPU ====================

  Widget _buildCpuCard(BuildContext context, PerfPageState state) {
    final report = state.cpu;
    if (report == null) {
      return _emptyCard(context, TablerIcons.cpu, 'CPU', '暂无数据');
    }
    final theme = Theme.of(context);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, TablerIcons.cpu, 'CPU'),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                _metric(context, '核心数', '${report.coreCount}'),
                _metric(
                  context,
                  '当前频率',
                  report.maxFreqMhz == null
                      ? '—'
                      : '${report.maxFreqMhz!.toStringAsFixed(0)} MHz',
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            ClipRRect(
              borderRadius: AppRadius.allSM,
              child: LinearProgressIndicator(
                value: (report.usagePercent / 100).clamp(0.0, 1.0),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            _kv(context, '调速器', report.governor ?? '未知'),
            _kv(
              context,
              '频率范围',
              report.minFreqMhz == null && report.maxFreqMhz == null
                  ? '未知'
                  : '${report.minFreqMhz?.toStringAsFixed(0) ?? '—'} ~ '
                      '${report.maxFreqMhz?.toStringAsFixed(0) ?? '—'} MHz',
            ),
            if (report.loadavg != null)
              _kv(
                context,
                '负载 (1/5/15)',
                '${report.loadavg!.load1.toStringAsFixed(2)} / '
                    '${report.loadavg!.load5.toStringAsFixed(2)} / '
                    '${report.loadavg!.load15.toStringAsFixed(2)}',
              ),
            if (report.perCoreUsage.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text('各核心', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (var i = 0; i < report.perCoreUsage.length; i++)
                    _coreChip(
                      context,
                      i,
                      report.perCoreUsage[i],
                      i < report.frequenciesMhz.length
                          ? report.frequenciesMhz[i]
                          : null,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _coreChip(
    BuildContext context,
    int index,
    double usage,
    double? freqMhz,
  ) {
    final theme = Theme.of(context);
    final parts = <String>[
      '核$index',
      '${usage.toStringAsFixed(0)}%',
      if (freqMhz != null) '${freqMhz.toStringAsFixed(0)}MHz',
    ];
    return Container(
      padding: AppSpacing.horizontalSM_verticalXS,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.allSM,
      ),
      child: Text(parts.join('  '), style: theme.textTheme.bodySmall),
    );
  }

  // ==================== 内存 ====================

  Widget _buildMemoryCard(BuildContext context, PerfPageState state) {
    final report = state.memory;
    if (report == null) {
      return _emptyCard(context, TablerIcons.device_desktop, '内存', '暂无数据');
    }
    final total = report.totalHuman.isNotEmpty
        ? report.totalHuman
        : _kbHuman(report.totalKb);
    final used =
        report.usedHuman.isNotEmpty ? report.usedHuman : _kbHuman(report.usedKb);
    final available = report.availableHuman.isNotEmpty
        ? report.availableHuman
        : _kbHuman(report.availableKb);
    final swapTotal = report.swapTotalHuman.isNotEmpty
        ? report.swapTotalHuman
        : _kbHuman(report.swapTotalKb);
    final swapUsed = report.swapUsedHuman.isNotEmpty
        ? report.swapUsedHuman
        : _kbHuman(report.swapUsedKb);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, TablerIcons.device_desktop, '内存'),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                _metric(context, '使用', '$used / $total'),
                _metric(context, '可用', available),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            ClipRRect(
              borderRadius: AppRadius.allSM,
              child: LinearProgressIndicator(
                value: (report.usedPercent / 100).clamp(0.0, 1.0),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            _kv(
              context,
              'Swap',
              '$swapUsed / $swapTotal'
                  '${report.swapPercent > 0 ? ' (${report.swapPercent.toStringAsFixed(1)}%)' : ''}',
            ),
            _kv(context, '缓存 (Cached)', _kbHuman(report.cachedKb)),
            _kv(context, '缓冲 (Buffers)', _kbHuman(report.buffersKb)),
            _kv(context, 'Slab', _kbHuman(report.slabKb)),
            _kv(context, '脏页 (Dirty)', _kbHuman(report.dirtyKb)),
            if (report.zramTotalKb > 0)
              _kv(
                context,
                'ZRAM',
                '${_kbHuman(report.zramUsedKb)} / ${_kbHuman(report.zramTotalKb)}',
              ),
            if (report.shmemKb > 0)
              _kv(context, '共享内存', _kbHuman(report.shmemKb)),
          ],
        ),
      ),
    );
  }

  // ==================== 电池 ====================

  Widget _buildBatteryCard(BuildContext context, PerfPageState state) {
    final report = state.battery;
    if (report == null) {
      return _emptyCard(context, TablerIcons.battery, '电池', '暂无数据');
    }
    if (!report.present) {
      return _emptyCard(context, TablerIcons.battery, '电池', '未检测到电池');
    }
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, TablerIcons.battery, '电池'),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                _metric(
                  context,
                  '电量',
                  report.capacityPercent == null
                      ? '—'
                      : '${report.capacityPercent!.toStringAsFixed(0)}%',
                ),
                _metric(
                  context,
                  '电压',
                  report.voltageV == null
                      ? '—'
                      : '${report.voltageV!.toStringAsFixed(2)} V',
                ),
                _metric(
                  context,
                  '温度',
                  report.temperatureC == null
                      ? '—'
                      : '${report.temperatureC!.toStringAsFixed(1)} °C',
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _kv(context, '状态', report.status ?? '未知'),
            _kv(context, '健康', report.health ?? '未知'),
            if (report.technology != null)
              _kv(context, '材质', report.technology!),
          ],
        ),
      ),
    );
  }

  // ==================== 温度 ====================

  Widget _buildThermalCard(BuildContext context, PerfPageState state) {
    final report = state.thermal;
    if (report == null || report.zones.isEmpty) {
      return _emptyCard(context, TablerIcons.temperature, '温度', '暂无数据');
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final maxTemp = report.maxTempC;
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(
              context,
              TablerIcons.temperature,
              '温度',
              trailing: maxTemp == null
                  ? null
                  : Text(
                      '最高 ${maxTemp.toStringAsFixed(1)} °C',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.error,
                        fontWeight: AppTypography.weightSemiBold,
                      ),
                    ),
            ),
            const SizedBox(height: AppSpacing.md),
            for (final zone in report.zones)
              _thermalRow(context, zone, maxTemp),
          ],
        ),
      ),
    );
  }

  Widget _thermalRow(
    BuildContext context,
    ThermalZone zone,
    double? maxTemp,
  ) {
    final theme = Theme.of(context);
    final isMax = maxTemp != null && zone.tempC >= maxTemp;
    final label = zone.kind?.isNotEmpty == true ? zone.kind! : zone.zone;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: isMax ? theme.colorScheme.error : null,
                fontWeight:
                    isMax ? AppTypography.weightSemiBold : null,
              ),
            ),
          ),
          Text(
            '${zone.tempC.toStringAsFixed(1)} °C',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: isMax ? theme.colorScheme.error : null,
              fontWeight: isMax ? AppTypography.weightSemiBold : null,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== GPU ====================

  Widget _buildGpuCard(BuildContext context, PerfPageState state) {
    final report = state.gpu;
    if (report == null ||
        (report.name == null &&
            report.freqMhz == null &&
            report.busyPercent == null)) {
      return _emptyCard(context, TablerIcons.gauge, 'GPU', '暂无 GPU 数据');
    }
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, TablerIcons.gauge, 'GPU'),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                _metric(context, '型号', report.name ?? '未知'),
                _metric(
                  context,
                  '频率',
                  report.freqMhz == null
                      ? '—'
                      : '${report.freqMhz!.toStringAsFixed(0)} MHz',
                ),
                _metric(
                  context,
                  '忙率',
                  report.busyPercent == null
                      ? '—'
                      : '${report.busyPercent!.toStringAsFixed(1)}%',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 网络 ====================

  Widget _buildNetworkCard(BuildContext context, PerfPageState state) {
    final report = state.network;
    if (report == null) {
      return _emptyCard(context, TablerIcons.wifi, '网络', '暂无数据');
    }
    final theme = Theme.of(context);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, TablerIcons.wifi, '网络'),
            const SizedBox(height: AppSpacing.md),
            _kv(context, '累计接收', _bytesHuman(report.rxBytes.toDouble())),
            _kv(context, '累计发送', _bytesHuman(report.txBytes.toDouble())),
            if (report.interfaces.isNotEmpty) ...[
              const Divider(height: AppSpacing.xxl),
              Text('接口', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              for (final iface in report.interfaces)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          iface.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      Text(
                        '↓ ${_rateHuman(iface.rxBytesPerSec)}  ↑ ${_rateHuman(iface.txBytesPerSec)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // ==================== 进程 ====================

  Widget _buildProcessCard(
    BuildContext context,
    PerfMonitorNotifier notifier,
    PerfPageState state,
  ) {
    final report = state.processes;
    final theme = Theme.of(context);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(
              context,
              TablerIcons.list_details,
              '进程',
              trailing: AppSegmentedButton<PerfProcessSort>(
                value: state.processSort,
                enabled: state.moduleReady,
                segments: [
                  for (final sort in PerfProcessSort.values)
                    AppSegment(
                      value: sort,
                      label: sort.label,
                      key: Key('perf_process_sort_${sort.value}'),
                    ),
                ],
                onChanged: notifier.setProcessSort,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (report == null || report.processes.isEmpty)
              Text(
                '暂无数据',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              Text(
                '共 ${report.total} 个进程 · 按 ${
                    report.sort == PerfProcessSort.rss.value ? '内存' : 'CPU'
                } 排序',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final process in report.processes)
                _processRow(context, process),
            ],
          ],
        ),
      ),
    );
  }

  Widget _processRow(BuildContext context, PerfProcessInfo process) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${process.name} (${process.pid})',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            '${process.cpuPercent.toStringAsFixed(1)}%',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: AppTypography.weightMedium,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          SizedBox(
            width: AppSpacing.huge * 2,
            child: Text(
              _kbHuman(process.rssKb),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== PSI 压力 ====================

  Widget _buildPressureCard(BuildContext context, PerfPageState state) {
    final theme = Theme.of(context);
    final report = state.pressure;
    final unavailable = report == null ||
        (report.cpuSome == null &&
            report.memorySome == null &&
            report.ioSome == null);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, TablerIcons.gauge, 'PSI 压力'),
            const SizedBox(height: AppSpacing.md),
            if (unavailable)
              Text(
                '不可用（内核未开启 PSI）',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              _pressureRow(context, 'CPU', report.cpuSome, report.cpuFull),
              _pressureRow(context, '内存', report.memorySome, report.memoryFull),
              _pressureRow(context, 'IO', report.ioSome, report.ioFull),
            ],
          ],
        ),
      ),
    );
  }

  /// 单资源压力行：`some.avg10`（+ `avg60` / `full.avg10`）+ 0–100 条。
  Widget _pressureRow(
    BuildContext context,
    String label,
    PerfPressureSample? some,
    PerfPressureSample? full,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = some == null
        ? '不可用'
        : 'some ${some.avg10.toStringAsFixed(2)}% · 60s '
            '${some.avg60.toStringAsFixed(2)}%'
            '${full == null ? '' : ' · full ${full.avg10.toStringAsFixed(2)}%'}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: AppSpacing.huge,
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          _percentBar(context, some?.avg10 ?? 0, enabled: some != null),
        ],
      ),
    );
  }

  // ==================== 散热设备 ====================

  Widget _buildCoolingCard(BuildContext context, PerfPageState state) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = state.cooling;
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(
              context,
              TablerIcons.temperature,
              '散热设备',
              trailing: report == null || report.count == 0
                  ? null
                  : Text(
                      '${report.count} 个',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (report == null || report.devices.isEmpty)
              Text(
                '不可用',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              for (final device in report.devices)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          device.device.isEmpty ? '(未知设备)' : device.device,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        '${device.type.isEmpty ? '未知' : device.type} • '
                        '${device.curState}/${device.maxState}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  // ==================== 电池健康 ====================

  Widget _buildBatteryHealthCard(BuildContext context, PerfPageState state) {
    final report = state.batteryHealth;
    if (report == null || !report.present) {
      return _emptyCard(
        context,
        TablerIcons.battery,
        '电池健康',
        report == null ? '不可用' : '未检测到电池',
      );
    }
    final health = report.healthPercent;
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, TablerIcons.battery, '电池健康'),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                _metric(context, '满电容量', _uahMah(report.chargeFullUah)),
                _metric(context, '设计容量', _uahMah(report.chargeFullDesignUah)),
                _metric(
                  context,
                  '健康度',
                  health == null ? '不可用' : '${health.toStringAsFixed(0)}%',
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _kv(context, '循环次数', report.cycleCount?.toString() ?? '不可用'),
            _kv(context, '健康', report.health ?? '未知'),
            _kv(context, '状态', report.status ?? '未知'),
            _kv(context, '材质', report.technology ?? '未知'),
            _kv(
              context,
              '温度',
              report.temperatureC == null
                  ? '不可用'
                  : '${report.temperatureC!.toStringAsFixed(1)} °C',
            ),
            if (report.capacityPercent != null)
              _kv(
                context,
                '电量',
                '${report.capacityPercent!.toStringAsFixed(0)}%',
              ),
            if (report.voltageV != null)
              _kv(context, '电压', '${report.voltageV!.toStringAsFixed(2)} V'),
          ],
        ),
      ),
    );
  }

  // ==================== 存储 ====================

  Widget _buildStorageCard(BuildContext context, PerfPageState state) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = state.storage;
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, TablerIcons.database, '存储'),
            const SizedBox(height: AppSpacing.md),
            if (report == null || report.volumes.isEmpty)
              Text(
                '不可用',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              for (final volume in report.volumes) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        volume.mount.isEmpty ? '(未知挂载点)' : volume.mount,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: AppTypography.weightMedium,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      '${_kbHuman(volume.usedKb)} / ${_kbHuman(volume.totalKb)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                _percentBar(context, volume.usedPercent),
                const SizedBox(height: AppSpacing.md),
              ],
          ],
        ),
      ),
    );
  }

  // ==================== CPU 频率驻留 ====================

  Widget _buildCpuFreqResidencyCard(BuildContext context, PerfPageState state) {
    final entries = state.cpu?.freqResidency ?? const <PerfFreqResidency>[];
    if (entries.isEmpty) {
      return _emptyCard(context, TablerIcons.cpu, 'CPU 频率驻留', '不可用');
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totalTicks =
        entries.fold<int>(0, (sum, e) => sum + (e.ticks > 0 ? e.ticks : 0));
    final sorted = List<PerfFreqResidency>.of(entries)
      ..sort((a, b) => a.freqMhz.compareTo(b.freqMhz));
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, TablerIcons.cpu, 'CPU 频率驻留'),
            const SizedBox(height: AppSpacing.md),
            for (final entry in sorted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  children: [
                    SizedBox(
                      width: AppSpacing.massive * 2,
                      child: Text(
                        '${entry.freqMhz.toStringAsFixed(0)} MHz',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: _percentBar(
                        context,
                        totalTicks <= 0
                            ? 0
                            : entry.ticks / totalTicks * 100,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    SizedBox(
                      width: AppSpacing.massive,
                      child: Text(
                        totalTicks <= 0
                            ? '—'
                            : '${(entry.ticks / totalTicks * 100).toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ==================== 网卡错误 ====================

  Widget _buildNetworkErrorCard(BuildContext context, PerfPageState state) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = state.network;
    final faulty = report == null
        ? const <NetworkInterface>[]
        : report.interfaces.where((i) => i.hasErrors).toList(growable: false);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, TablerIcons.alert_circle, '网卡错误'),
            const SizedBox(height: AppSpacing.md),
            if (report == null)
              Text(
                '不可用',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else if (faulty.isEmpty)
              Text(
                '无错误计数',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              for (final iface in faulty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          iface.name.isEmpty ? '(未知接口)' : iface.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        '错误 ${iface.rxErrors}/${iface.txErrors} · '
                        '丢包 ${iface.rxDropped}/${iface.txDropped}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  /// 0–100 百分比条（[enabled] 为 false 时画空轨道）。
  Widget _percentBar(
    BuildContext context,
    double percent, {
    bool enabled = true,
    Color? color,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: AppRadius.allSM,
      child: LinearProgressIndicator(
        value: enabled ? (percent / 100).clamp(0.0, 1.0) : 0.0,
        color: color,
        backgroundColor: scheme.surfaceContainerHighest,
      ),
    );
  }

  // ==================== 通用小组件 ====================

  Widget _sectionHeader(    BuildContext context,
    IconData icon,
    String title, {
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: AppTypography.iconMD, color: theme.colorScheme.primary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: AppTypography.weightSemiBold,
            ),
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _metric(
    BuildContext context,
    String label,
    String value, {
    String? sub,
    bool accent = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: AppSpacing.massive * 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: AppTypography.weightSemiBold,
              color: accent ? scheme.error : null,
            ),
          ),
          if (sub != null)
            Text(
              sub,
              style: theme.textTheme.bodySmall?.copyWith(
                color: accent ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: AppSpacing.massive * 2,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  Widget _emptyCard(
    BuildContext context,
    IconData icon,
    String title,
    String message,
  ) {
    final theme = Theme.of(context);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, icon, title),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 单位格式化（纯函数） ====================

/// KiB → 人类可读字节串（内存 / 进程 RSS 兜底，模块未给 human 串时使用）。
String _kbHuman(int kb) => _bytesHuman(kb * 1024.0);

/// 字节 → 人类可读（B / KB / MB / GB / TB）。
String _bytesHuman(double bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes;
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  final digits = index == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[index]}';
}

/// 字节/秒 → 速率串。
String _rateHuman(double bytesPerSec) => '${_bytesHuman(bytesPerSec)}/s';

/// µAh → mAh 串（`null` → 「不可用」）。
String _uahMah(int? uah) =>
    uah == null ? '不可用' : '${(uah / 1000).toStringAsFixed(0)} mAh';

/// 数值格式化（1 位小数；`null` → 「—」）。
String _num(double? value) => value == null ? '—' : value.toStringAsFixed(1);

// ==================== 导出报告 ====================

/// 导出动作（分享 / 复制）。
enum _ReportAction { share, copy }

/// 导出当前性能报告：选择 JSON / CSV → 落盘 → 分享或复制。
Future<void> _exportPerfReport(
  BuildContext context,
  WidgetRef ref,
  PerfPageState state,
) async {
  final format = await AppSheet.showCustom<PerfReportFormat>(
    context: context,
    builder: (sheetContext) => AppSheetScaffold(
      title: '导出报告',
      subtitle: '选择导出格式',
      icon: const Icon(TablerIcons.download),
      content: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('perf_export_json'),
              leading: const Icon(TablerIcons.braces),
              title: const Text('JSON'),
              subtitle: const Text('结构化完整报告'),
              onTap: () => Navigator.of(sheetContext).pop(PerfReportFormat.json),
            ),
            const Divider(height: 1),
            ListTile(
              key: const Key('perf_export_csv'),
              leading: const Icon(TablerIcons.table),
              title: const Text('CSV'),
              subtitle: const Text('扁平指标表格'),
              onTap: () => Navigator.of(sheetContext).pop(PerfReportFormat.csv),
            ),
          ],
        ),
      ),
    ),
  );
  if (format == null || !context.mounted) return;

  final store = ref.read(perfReportStoreProvider);
  final target = await ref.read(perfTargetStoreProvider).load();
  final timestamp = DateTime.now();
  final stats = state.effectiveFrameStats;
  final content = format == PerfReportFormat.json
      ? const JsonEncoder.withIndent('  ').convert(
          buildPerfReportJson(
            timestamp: timestamp,
            cpu: state.cpu,
            memory: state.memory,
            battery: state.battery,
            thermal: state.thermal,
            gpu: state.gpu,
            network: state.network,
            frameStats: stats,
            targetLabel: target?.label,
          ),
        )
      : buildPerfReportCsv(
          timestamp: timestamp,
          cpu: state.cpu,
          memory: state.memory,
          battery: state.battery,
          thermal: state.thermal,
          gpu: state.gpu,
          network: state.network,
          frameStats: stats,
          targetLabel: target?.label,
        );
  if (!context.mounted) return;

  final SavedPerfReport saved;
  try {
    saved = await store.saveReport(
      format: format,
      content: content,
      timestamp: timestamp,
    );
  } catch (error) {
    debugPrint('[PerfMonitor] 保存报告失败: $error');
    if (context.mounted) AppDialogs.showError('保存报告失败，请检查存储权限');
    return;
  }
  if (!context.mounted) return;

  final action = await AppSheet.showCustom<_ReportAction>(
    context: context,
    builder: (sheetContext) => AppSheetScaffold(
      title: '报告已保存',
      subtitle: saved.fileName,
      icon: const Icon(TablerIcons.circle_check),
      content: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('perf_export_share'),
              leading: const Icon(TablerIcons.share),
              title: const Text('分享'),
              onTap: () => Navigator.of(sheetContext).pop(_ReportAction.share),
            ),
            const Divider(height: 1),
            ListTile(
              key: const Key('perf_export_copy'),
              leading: const Icon(TablerIcons.copy),
              title: const Text('复制'),
              onTap: () => Navigator.of(sheetContext).pop(_ReportAction.copy),
            ),
          ],
        ),
      ),
    ),
  );
  if (action == null || !context.mounted) return;

  switch (action) {
    case _ReportAction.copy:
      try {
        await Clipboard.setData(ClipboardData(text: content));
      } catch (error) {
        debugPrint('[PerfMonitor] 复制报告失败: $error');
      }
      if (context.mounted) AppDialogs.showSuccess('报告已复制到剪贴板');
    case _ReportAction.share:
      final ok = await PerfExportService.instance.shareReport(
        path: saved.path,
        content: content,
        mimeType: format.mimeType,
        title: '分享性能报告',
      );
      if (!context.mounted) return;
      if (ok) {
        AppDialogs.showSuccess('已打开分享面板');
      } else {
        AppDialogs.showInfo('已保存到 ${saved.path}');
      }
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
                  ? '基线 ${_num(d.baseline)} → 当前 ${_num(d.current)}'
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

// ==================== 自动导出 ====================

/// 自动导出配置行（图标 + 标题 + 当前值 + 可点编辑）。
class _AutoExportRow extends StatelessWidget {
  const _AutoExportRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      enabled: enabled,
      leading: Icon(
        icon,
        size: AppTypography.iconMD,
        color: enabled ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(title, style: theme.textTheme.bodyMedium),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Icon(
            TablerIcons.chevron_right,
            size: AppTypography.iconSM,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
      onTap: enabled ? onTap : null,
    );
  }
}

/// 自动导出配置卡：开关 + 间隔 + 格式 + 保留份数。
///
/// 同步把 [PerfAutoExportService] 接到页面「实时刷新 / 后台采样」态：仅当两者
/// 之一处于运行且设置启用时启动周期导出，否则停止；设置变更会重启定时器。
class _AutoExportCard extends ConsumerStatefulWidget {
  const _AutoExportCard();

  @override
  ConsumerState<_AutoExportCard> createState() => _AutoExportCardState();
}

class _AutoExportCardState extends ConsumerState<_AutoExportCard> {
  bool? _appliedRunning;
  String? _appliedSignature;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settings = ref.watch(perfAutoExportSettingsProvider);
    final perfState = ref.watch(perfMonitorProvider);
    final pageActive = perfState.live || perfState.sampling;
    final shouldRun = pageActive && settings.enabled;
    final signature = '${settings.enabled}|${settings.intervalMinutes}'
        '|${settings.format.value}|${settings.maxKeep}';
    _syncService(shouldRun: shouldRun, signature: signature);

    final status = !settings.enabled
        ? '关闭（默认）'
        : shouldRun
            ? '运行中 · 每 ${settings.intervalMinutes} 分钟导出'
            : '已开启 · 需「实时刷新」或「后台采样」运行时生效';
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          SwitchListTile(
            key: const Key('perf_auto_export_switch'),
            secondary: Icon(
              TablerIcons.calendar_stats,
              size: AppTypography.iconMD,
              color: scheme.primary,
            ),
            title: const Text('自动导出'),
            subtitle: Text(status),
            value: settings.enabled,
            onChanged: (value) => _save(settings.copyWith(enabled: value)),
          ),
          const Divider(height: AppSpacing.md),
          _AutoExportRow(
            key: const Key('perf_auto_export_interval'),
            icon: TablerIcons.clock,
            title: '导出间隔',
            value: '每 ${settings.intervalMinutes} 分钟',
            enabled: settings.enabled,
            onTap: () => _editInterval(settings),
          ),
          _AutoExportRow(
            key: const Key('perf_auto_export_format'),
            icon: TablerIcons.file_description,
            title: '导出格式',
            value: settings.format.label,
            enabled: settings.enabled,
            onTap: () => _editFormat(settings),
          ),
          _AutoExportRow(
            key: const Key('perf_auto_export_keep'),
            icon: TablerIcons.stack,
            title: '保留份数',
            value: '最近 ${settings.maxKeep} 份',
            enabled: settings.enabled,
            onTap: () => _editKeep(settings),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '自动导出仅在「实时刷新」或「后台采样」运行时按间隔执行；'
                '超出保留份数的最旧报告会被自动删除。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 把服务的运行态对齐到「页面活跃 + 设置启用」；签名变化时重启定时器。
  void _syncService({required bool shouldRun, required String signature}) {
    if (_appliedRunning == shouldRun && _appliedSignature == signature) {
      return;
    }
    final restart = _appliedSignature != null && _appliedSignature != signature;
    _appliedRunning = shouldRun;
    _appliedSignature = signature;
    final service = ref.read(perfAutoExportServiceProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (shouldRun) {
        if (restart) service.stop();
        service.start();
      } else {
        service.stop();
      }
    });
  }

  Future<void> _save(PerfAutoExportSettings settings) =>
      ref.read(perfAutoExportSettingsProvider.notifier).save(settings);

  Future<void> _editInterval(PerfAutoExportSettings settings) async {
    final minutes = await AppSheet.showCustom<int>(
      context: context,
      builder: (sheetContext) => _AutoExportIntSheet(
        title: '导出间隔',
        subtitle: '自动导出的时间间隔（分钟，最小 1）',
        initial: settings.intervalMinutes,
        minValue: kPerfAutoExportMinIntervalMinutes,
        suffix: '分钟',
        keyPrefix: 'perf_auto_export_interval',
      ),
    );
    if (minutes == null || !mounted) return;
    await _save(settings.copyWith(intervalMinutes: minutes));
  }

  Future<void> _editKeep(PerfAutoExportSettings settings) async {
    final keep = await AppSheet.showCustom<int>(
      context: context,
      builder: (sheetContext) => _AutoExportIntSheet(
        title: '保留份数',
        subtitle: '保留最近 N 份报告（最小 1，超出删除最旧）',
        initial: settings.maxKeep,
        minValue: kPerfAutoExportMinMaxKeep,
        suffix: '份',
        keyPrefix: 'perf_auto_export_keep',
      ),
    );
    if (keep == null || !mounted) return;
    await _save(settings.copyWith(maxKeep: keep));
  }

  Future<void> _editFormat(PerfAutoExportSettings settings) async {
    final selected = await AppSheet.showCustom<PerfAutoExportFormat>(
      context: context,
      builder: (sheetContext) => AppSheetScaffold(
        title: '导出格式',
        subtitle: '选择自动导出的文件格式',
        icon: const Icon(TablerIcons.file_description),
        content: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < PerfAutoExportFormat.values.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  key: Key(
                    'perf_auto_export_format_'
                    '${PerfAutoExportFormat.values[i].value}',
                  ),
                  title: Text(PerfAutoExportFormat.values[i].label),
                  trailing: settings.format == PerfAutoExportFormat.values[i]
                      ? Icon(
                          TablerIcons.check,
                          color: Theme.of(sheetContext).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.of(sheetContext)
                      .pop(PerfAutoExportFormat.values[i]),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await _save(settings.copyWith(format: selected));
  }
}

/// 整数编辑弹层（间隔 / 保留份数共用）：保存 `pop(int)`，取消 `pop(null)`。
class _AutoExportIntSheet extends StatefulWidget {
  const _AutoExportIntSheet({
    required this.title,
    required this.subtitle,
    required this.initial,
    required this.minValue,
    required this.suffix,
    required this.keyPrefix,
  });

  final String title;
  final String subtitle;
  final int initial;
  final int minValue;
  final String suffix;
  final String keyPrefix;

  @override
  State<_AutoExportIntSheet> createState() => _AutoExportIntSheetState();
}

class _AutoExportIntSheetState extends State<_AutoExportIntSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial.toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = int.tryParse(_controller.text.trim());
    if (value == null || value < widget.minValue) {
      AppDialogs.showError('请输入不小于 ${widget.minValue} 的整数');
      return;
    }
    Navigator.of(context).pop<int>(value);
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: widget.title,
      subtitle: widget.subtitle,
      content: TextField(
        key: Key('${widget.keyPrefix}_input'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(suffixText: widget.suffix, isDense: true),
      ),
      actions: [
        TextButton(
          key: Key('${widget.keyPrefix}_cancel'),
          onPressed: () => Navigator.of(context).pop<int>(null),
          child: const Text('取消'),
        ),
        FilledButton(
          key: Key('${widget.keyPrefix}_save'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

// ==================== 最近报告 ====================

/// 最近报告条目（报告元信息 + 近似字节大小）。
class _ReportEntry {
  const _ReportEntry(this.report, this.sizeBytes);

  final SavedPerfReport report;
  final int sizeBytes;
}

/// 报告条目操作。
enum _RecentReportAction { view, share, copy }

/// 最近报告列表卡：列出已保存报告（时间 + 文件名 + 大小），支持查看 / 分享 /
/// 复制 / 删除（滑动或菜单）与「全部清除」。
class _RecentReportsCard extends ConsumerStatefulWidget {
  const _RecentReportsCard();

  @override
  ConsumerState<_RecentReportsCard> createState() => _RecentReportsCardState();
}

class _RecentReportsCardState extends ConsumerState<_RecentReportsCard> {
  List<_ReportEntry> _entries = const <_ReportEntry>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(perfReportStoreProvider);
    var entries = const <_ReportEntry>[];
    try {
      final reports = await store.listReports();
      final built = <_ReportEntry>[];
      for (final report in reports) {
        final content = await store.readReport(report.path);
        built.add(
          _ReportEntry(report, content == null ? 0 : utf8.encode(content).length),
        );
      }
      entries = built;
    } catch (error) {
      debugPrint('[PerfMonitor] 读取最近报告失败: $error');
    }
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
                  TablerIcons.history,
                  size: AppTypography.iconMD,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '最近报告',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                ),
                if (_entries.isNotEmpty)
                  TextButton(
                    key: const Key('perf_reports_clear_all'),
                    onPressed: _clearAll,
                    child: const Text('全部清除'),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (_loading)
              const Row(
                children: [
                  AppLoading(size: AppLoadingSize.small),
                  SizedBox(width: AppSpacing.md),
                  Expanded(child: Text('读取中…')),
                ],
              )
            else if (_entries.isEmpty)
              Text(
                '暂无报告（开启自动导出或点击右上角「导出报告」后在此查看）',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              Column(
                children: [
                  for (final entry in _entries) _reportTile(context, entry),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _reportTile(BuildContext context, _ReportEntry entry) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = entry.report;
    final ts = report.timestamp.millisecondsSinceEpoch;
    return Dismissible(
      key: ValueKey<String>('perf_report_dismiss_$ts'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: AppSpacing.onlyHorizontalLG,
        color: scheme.errorContainer,
        child: Icon(
          TablerIcons.trash,
          size: AppTypography.iconMD,
          color: scheme.onErrorContainer,
        ),
      ),
      confirmDismiss: (_) => _confirmDelete(report),
      onDismissed: (_) => _delete(report),
      child: ListTile(
        key: Key('perf_report_$ts'),
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          report.format == PerfReportFormat.json
              ? TablerIcons.braces
              : TablerIcons.table,
          size: AppTypography.iconMD,
          color: scheme.primary,
        ),
        title: Text(
          _formatReportTime(report.timestamp),
          style: theme.textTheme.bodyMedium,
        ),
        subtitle: Text(
          '${report.fileName} · ${_bytesHuman(entry.sizeBytes.toDouble())}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        onTap: () => _openActions(report),
        trailing: PopupMenuButton<String>(
          key: Key('perf_report_menu_$ts'),
          onSelected: (value) {
            switch (value) {
              case 'view':
                _openActions(report);
              case 'delete':
                _deleteWithConfirm(report);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem<String>(value: 'view', child: Text('查看 / 分享')),
            PopupMenuItem<String>(value: 'delete', child: Text('删除')),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(SavedPerfReport report) async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除报告？',
      message: '将删除 ${report.fileName}，此操作无法撤销。',
      confirmText: '删除',
      isDangerous: true,
    );
    return ok ?? false;
  }

  Future<void> _deleteWithConfirm(SavedPerfReport report) async {
    if (await _confirmDelete(report)) await _delete(report);
  }

  Future<void> _delete(SavedPerfReport report) async {
    final ok = await ref.read(perfReportStoreProvider).deleteReport(report.path);
    if (!mounted) return;
    if (ok) {
      AppDialogs.showInfo('已删除报告');
    } else {
      AppDialogs.showError('删除报告失败');
    }
    await _load();
  }

  Future<void> _clearAll() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清除全部报告？',
      message: '将删除最近报告中的全部文件，此操作无法撤销。',
      confirmText: '全部清除',
      isDangerous: true,
    );
    if (ok != true || !mounted) return;
    final store = ref.read(perfReportStoreProvider);
    for (final entry in _entries) {
      await store.deleteReport(entry.report.path);
    }
    if (!mounted) return;
    AppDialogs.showInfo('已清除全部报告');
    await _load();
  }

  Future<void> _openActions(SavedPerfReport report) async {
    final action = await AppSheet.showCustom<_RecentReportAction>(
      context: context,
      builder: (sheetContext) => AppSheetScaffold(
        title: '报告操作',
        subtitle: report.fileName,
        icon: const Icon(TablerIcons.file_description),
        content: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const Key('perf_report_view'),
                leading: const Icon(TablerIcons.eye),
                title: const Text('查看'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_RecentReportAction.view),
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('perf_report_share'),
                leading: const Icon(TablerIcons.share),
                title: const Text('分享'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_RecentReportAction.share),
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('perf_report_copy'),
                leading: const Icon(TablerIcons.copy),
                title: const Text('复制'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_RecentReportAction.copy),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    final store = ref.read(perfReportStoreProvider);
    final content = await store.readReport(report.path);
    if (!mounted) return;
    if (content == null) {
      AppDialogs.showError('报告已不存在');
      await _load();
      return;
    }
    switch (action) {
      case _RecentReportAction.view:
        await _showContent(report, content);
      case _RecentReportAction.copy:
        try {
          await Clipboard.setData(ClipboardData(text: content));
        } catch (error) {
          debugPrint('[PerfMonitor] 复制报告失败: $error');
        }
        if (mounted) AppDialogs.showSuccess('报告已复制到剪贴板');
      case _RecentReportAction.share:
        final ok = await PerfExportService.instance.shareReport(
          path: report.path,
          content: content,
          mimeType: report.format.mimeType,
          title: '分享性能报告',
        );
        if (!mounted) return;
        if (ok) {
          AppDialogs.showSuccess('已打开分享面板');
        } else {
          AppDialogs.showInfo('已保存到 ${report.path}');
        }
    }
  }

  Future<void> _showContent(SavedPerfReport report, String content) {
    return AppSheet.showCustom<void>(
      context: context,
      builder: (sheetContext) => AppSheetScaffold(
        title: '报告内容',
        subtitle: '${report.fileName} · ${report.format.extension.toUpperCase()}',
        icon: const Icon(TablerIcons.file_description),
        content: Material(
          type: MaterialType.transparency,
          child: SelectableText(
            content,
            style: Theme.of(sheetContext).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}

/// 时间 → `yyyy-MM-dd HH:mm:ss`（本地时区，零依赖）。
String _formatReportTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

