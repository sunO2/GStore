import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

import 'logic.dart';
import 'perf_common.dart';
import 'state.dart';

/// 性能「硬件详情」页（Riverpod）。
///
/// 独立路由页面，承载原 `PerfMonitorPage` 模块区的全部设备卡片：CPU（含频率驻留）、
/// 内存、PSI 压力、电池、电池健康、温度、散热设备、GPU、网络（含网卡错误）、存储、进程。
/// 模块未安装时降级为友好的「安装 / 重试」卡片，绝不崩溃；卡片实现逐字沿用原页面，
/// 行为 / Key / 文案不变。
///
/// 全部颜色 / 文字走 [Theme] 令牌，间距 / 圆角走设计令牌（AGENTS.md）。
class PerfHardwarePage extends ConsumerWidget {
  const PerfHardwarePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(perfMonitorProvider);
    final notifier = ref.read(perfMonitorProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('硬件详情'),
        actions: [
          IconButton(
            key: const Key('perf_hardware_refresh'),
            icon: const Icon(TablerIcons.refresh, size: AppTypography.iconMD),
            tooltip: '刷新',
            onPressed: notifier.refresh,
          ),
        ],
      ),
      body: ListView(children: _buildModuleArea(context, notifier, state)),
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
      return perfEmptyCard(context, TablerIcons.cpu, 'CPU', '暂无数据');
    }
    final theme = Theme.of(context);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            perfSectionHeader(context, TablerIcons.cpu, 'CPU'),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                perfMetric(context, '核心数', '${report.coreCount}'),
                perfMetric(
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
            perfKv(context, '调速器', report.governor ?? '未知'),
            perfKv(
              context,
              '频率范围',
              report.minFreqMhz == null && report.maxFreqMhz == null
                  ? '未知'
                  : '${report.minFreqMhz?.toStringAsFixed(0) ?? '—'} ~ '
                      '${report.maxFreqMhz?.toStringAsFixed(0) ?? '—'} MHz',
            ),
            if (report.loadavg != null)
              perfKv(
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
                    perfCoreChip(
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

  // ==================== 内存 ====================

  Widget _buildMemoryCard(BuildContext context, PerfPageState state) {
    final report = state.memory;
    if (report == null) {
      return perfEmptyCard(context, TablerIcons.device_desktop, '内存', '暂无数据');
    }
    final total = report.totalHuman.isNotEmpty
        ? report.totalHuman
        : perfKbHuman(report.totalKb);
    final used =
        report.usedHuman.isNotEmpty ? report.usedHuman : perfKbHuman(report.usedKb);
    final available = report.availableHuman.isNotEmpty
        ? report.availableHuman
        : perfKbHuman(report.availableKb);
    final swapTotal = report.swapTotalHuman.isNotEmpty
        ? report.swapTotalHuman
        : perfKbHuman(report.swapTotalKb);
    final swapUsed = report.swapUsedHuman.isNotEmpty
        ? report.swapUsedHuman
        : perfKbHuman(report.swapUsedKb);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            perfSectionHeader(context, TablerIcons.device_desktop, '内存'),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                perfMetric(context, '使用', '$used / $total'),
                perfMetric(context, '可用', available),
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
            perfKv(
              context,
              'Swap',
              '$swapUsed / $swapTotal'
                  '${report.swapPercent > 0 ? ' (${report.swapPercent.toStringAsFixed(1)}%)' : ''}',
            ),
            perfKv(context, '缓存 (Cached)', perfKbHuman(report.cachedKb)),
            perfKv(context, '缓冲 (Buffers)', perfKbHuman(report.buffersKb)),
            perfKv(context, 'Slab', perfKbHuman(report.slabKb)),
            perfKv(context, '脏页 (Dirty)', perfKbHuman(report.dirtyKb)),
            if (report.zramTotalKb > 0)
              perfKv(
                context,
                'ZRAM',
                '${perfKbHuman(report.zramUsedKb)} / ${perfKbHuman(report.zramTotalKb)}',
              ),
            if (report.shmemKb > 0)
              perfKv(context, '共享内存', perfKbHuman(report.shmemKb)),
          ],
        ),
      ),
    );
  }

  // ==================== 电池 ====================

  Widget _buildBatteryCard(BuildContext context, PerfPageState state) {
    final report = state.battery;
    if (report == null) {
      return perfEmptyCard(context, TablerIcons.battery, '电池', '暂无数据');
    }
    if (!report.present) {
      return perfEmptyCard(context, TablerIcons.battery, '电池', '未检测到电池');
    }
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            perfSectionHeader(context, TablerIcons.battery, '电池'),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                perfMetric(
                  context,
                  '电量',
                  report.capacityPercent == null
                      ? '—'
                      : '${report.capacityPercent!.toStringAsFixed(0)}%',
                ),
                perfMetric(
                  context,
                  '电压',
                  report.voltageV == null
                      ? '—'
                      : '${report.voltageV!.toStringAsFixed(2)} V',
                ),
                perfMetric(
                  context,
                  '温度',
                  report.temperatureC == null
                      ? '—'
                      : '${report.temperatureC!.toStringAsFixed(1)} °C',
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            perfKv(context, '状态', report.status ?? '未知'),
            perfKv(context, '健康', report.health ?? '未知'),
            if (report.technology != null)
              perfKv(context, '材质', report.technology!),
          ],
        ),
      ),
    );
  }

  // ==================== 温度 ====================

  Widget _buildThermalCard(BuildContext context, PerfPageState state) {
    final report = state.thermal;
    if (report == null || report.zones.isEmpty) {
      return perfEmptyCard(context, TablerIcons.temperature, '温度', '暂无数据');
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
            perfSectionHeader(
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
              perfThermalRow(context, zone, maxTemp),
          ],
        ),
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
      return perfEmptyCard(context, TablerIcons.gauge, 'GPU', '暂无 GPU 数据');
    }
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            perfSectionHeader(context, TablerIcons.gauge, 'GPU'),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                perfMetric(context, '型号', report.name ?? '未知'),
                perfMetric(
                  context,
                  '频率',
                  report.freqMhz == null
                      ? '—'
                      : '${report.freqMhz!.toStringAsFixed(0)} MHz',
                ),
                perfMetric(
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
      return perfEmptyCard(context, TablerIcons.wifi, '网络', '暂无数据');
    }
    final theme = Theme.of(context);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            perfSectionHeader(context, TablerIcons.wifi, '网络'),
            const SizedBox(height: AppSpacing.md),
            perfKv(context, '累计接收', perfBytesHuman(report.rxBytes.toDouble())),
            perfKv(context, '累计发送', perfBytesHuman(report.txBytes.toDouble())),
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
                        '↓ ${perfRateHuman(iface.rxBytesPerSec)}  ↑ ${perfRateHuman(iface.txBytesPerSec)}',
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
            perfSectionHeader(
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
                perfProcessRow(context, process),
            ],
          ],
        ),
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
            perfSectionHeader(context, TablerIcons.gauge, 'PSI 压力'),
            const SizedBox(height: AppSpacing.md),
            if (unavailable)
              Text(
                '不可用（内核未开启 PSI）',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              perfPressureRow(context, 'CPU', report.cpuSome, report.cpuFull),
              perfPressureRow(context, '内存', report.memorySome, report.memoryFull),
              perfPressureRow(context, 'IO', report.ioSome, report.ioFull),
            ],
          ],
        ),
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
            perfSectionHeader(
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
      return perfEmptyCard(
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
            perfSectionHeader(context, TablerIcons.battery, '电池健康'),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                perfMetric(context, '满电容量', perfUahMah(report.chargeFullUah)),
                perfMetric(context, '设计容量', perfUahMah(report.chargeFullDesignUah)),
                perfMetric(
                  context,
                  '健康度',
                  health == null ? '不可用' : '${health.toStringAsFixed(0)}%',
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            perfKv(context, '循环次数', report.cycleCount?.toString() ?? '不可用'),
            perfKv(context, '健康', report.health ?? '未知'),
            perfKv(context, '状态', report.status ?? '未知'),
            perfKv(context, '材质', report.technology ?? '未知'),
            perfKv(
              context,
              '温度',
              report.temperatureC == null
                  ? '不可用'
                  : '${report.temperatureC!.toStringAsFixed(1)} °C',
            ),
            if (report.capacityPercent != null)
              perfKv(
                context,
                '电量',
                '${report.capacityPercent!.toStringAsFixed(0)}%',
              ),
            if (report.voltageV != null)
              perfKv(context, '电压', '${report.voltageV!.toStringAsFixed(2)} V'),
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
            perfSectionHeader(context, TablerIcons.database, '存储'),
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
                      '${perfKbHuman(volume.usedKb)} / ${perfKbHuman(volume.totalKb)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                perfPercentBar(context, volume.usedPercent),
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
      return perfEmptyCard(context, TablerIcons.cpu, 'CPU 频率驻留', '不可用');
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
            perfSectionHeader(context, TablerIcons.cpu, 'CPU 频率驻留'),
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
                      child: perfPercentBar(
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
            perfSectionHeader(context, TablerIcons.alert_circle, '网卡错误'),
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
}
