/// Scene 风格**概览 hero**（性能监控页本地组件，plan batch-2 前置）。
///
/// 复刻 Scene 首页（`fragment_home.xml`）的核心卡片组合，但**全部数据复用既有
/// `perfMonitorProvider`（[PerfPageState]）**——本组件是**纯展示 + 模式接线**，
/// 不新建状态存储、不触达 FFI：
/// * 内存 / 交换分区环形仪表（RAM / SWAP）；
/// * GPU / CPU 环形仪表（占用 + 频率 / 调速器）；
/// * 逐核网格（每核占用 + 频率）；
/// * 电池 / 温度卡片；
/// * Scene 经典四档快捷按钮（省电 / 均衡 / 性能 / 极速）。
///
/// ## 四档模式接线（复用既有路径，**不新建 store / engine**）
/// 按钮经既有 [applyPerfModeToAllProfiles] 把所选 [PerfMode] 写入全部按应用档案
/// （[PerfProfileStore]，生产 [ConfigPerfProfileStore]），由既有自动模式引擎在
/// 下次前台 / 刷新收敛。生效模式经 [commonPerfModeOf]（[PerfProfileStore.loadAll]）
/// 高亮。**能力门禁**：显式探测到无任何可写类别（[PerfControlCapabilities]，
/// fail-closed）时四按钮禁用并给出**可见原因**；未探测（`null`）不阻断。
///
/// ## 可注入 seam（测试无需真机 / Shizuku / 原生模块）
/// [state]（数据）、[store]（档案存储）、[capabilities] / [capabilityLoader]
/// （能力）、[onModeApplied]（应用回调捕获）。
///
/// ## 颜色
/// 仅用 `Theme.of(context).colorScheme` / `textTheme` + perf 本地 Scene 强调色
/// （[ScenePerfStyle]）；无其它硬编码颜色 / 字号（AGENTS.md）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/perf_profile.dart';
import 'package:gstore/core/perf/perf_profile_store.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

import 'perf_common.dart';
import 'perf_profiles_tile.dart';
import 'scene_perf_style.dart';
import 'scene_ring_gauge.dart';
import 'state.dart';

/// 能力加载器（`null` = 不自动探测；生产可注入 `PerfCapabilityProbe.probe`）。
typedef SceneHeroCapabilityLoader = Future<PerfControlCapabilities?> Function();

/// 模式应用结果回调（测试捕获；生产可留空）。
typedef SceneHeroModeApplied = void Function(PerfMode mode, int? appliedCount);

/// 四档模式 → 图标（文案取 [PerfMode.label]，顺序固定为枚举顺序）。
const Map<PerfMode, IconData> _kModeIcons = <PerfMode, IconData>{
  PerfMode.powersave: TablerIcons.leaf,
  PerfMode.balance: TablerIcons.activity,
  PerfMode.performance: TablerIcons.rocket,
  PerfMode.fast: TablerIcons.flame,
};

/// Scene 风格概览 hero。
class SceneDashboardHero extends StatefulWidget {
  const SceneDashboardHero({
    super.key,
    this.state,
    this.store,
    this.capabilities,
    this.capabilityLoader,
    this.onModeApplied,
  });

  /// 数据 seam：性能页状态（生产由调用方传 `ref.watch(perfMonitorProvider)`）。
  /// `null` → 全部指标降级为占位（「—」），绝不崩溃。
  final PerfPageState? state;

  /// 档案存储 seam；`null` → 生产 [ConfigPerfProfileStore]。
  final PerfProfileStore? store;

  /// 已探测能力 seam（显式传入且无任一可写类别 → 禁用）。
  final PerfControlCapabilities? capabilities;

  /// 异步能力加载器 seam（失败 / 返回 `null` → 视为未知，不阻断）。
  final SceneHeroCapabilityLoader? capabilityLoader;

  /// 应用结果回调（可选）。
  final SceneHeroModeApplied? onModeApplied;

  @override
  State<SceneDashboardHero> createState() => _SceneDashboardHeroState();
}

class _SceneDashboardHeroState extends State<SceneDashboardHero> {
  PerfProfileStore get _store => widget.store ?? const ConfigPerfProfileStore();

  PerfControlCapabilities? _capabilities;
  PerfMode? _selectedMode;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _capabilities = widget.capabilities;
    if (widget.capabilityLoader != null) {
      Future<void>.microtask(_loadCapabilities);
    }
    Future<void>.microtask(_loadCommonMode);
  }

  /// 从既有档案推导共享模式（无档案 / 模式不一致 → 不高亮）。
  Future<void> _loadCommonMode() async {
    try {
      final all = await _store.loadAll();
      final mode = commonPerfModeOf(all);
      if (!mounted || mode == null) return;
      setState(() => _selectedMode = mode);
    } catch (error) {
      debugPrint('SceneDashboardHero: 读取共享模式失败（忽略）- $error');
    }
  }

  /// 经注入加载器探测能力（best-effort；失败 → `null` = 未知，不阻断）。
  Future<void> _loadCapabilities() async {
    PerfControlCapabilities? caps;
    try {
      caps = await widget.capabilityLoader!.call();
    } catch (error) {
      debugPrint('SceneDashboardHero: 能力探测失败（视为未知）- $error');
    }
    if (!mounted || caps == null) return;
    setState(() => _capabilities = caps);
  }

  /// 是否被能力门禁阻断（仅显式「无任一可写类别」为真；未知不阻断）。
  bool get _blocked {
    final caps = _capabilities;
    if (caps == null) return false;
    return !PerfControlCategory.values.any(caps.isCategoryAvailable);
  }

  /// 禁用原因（仅在 [_blocked] 时非空）。
  String? get _disabledReason =>
      _blocked ? '当前设备无可用性能控制类别（需 Shizuku 授权且节点可写），模式切换已禁用。' : null;

  /// 应用模式到全部按应用档案（复用既有路径；绝不抛）。
  Future<void> _applyMode(PerfMode mode) async {
    if (_busy || _blocked) return;
    setState(() => _busy = true);
    final count = await applyPerfModeToAllProfiles(_store, mode);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (count == null) {
        _status = '保存「${mode.label}」模式失败，请重试';
      } else {
        _selectedMode = mode;
        _status = count == 0
            ? '尚无按应用性能档案，「${mode.label}」模式偏好未持久化'
            : '已应用「${mode.label}」到 $count 个档案';
      }
    });
    widget.onModeApplied?.call(mode, count);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _overviewCard(context),
        const SizedBox(height: AppSpacing.sm),
        _perCoreCard(context),
        const SizedBox(height: AppSpacing.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: _batteryCard(context)),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: _temperatureCard(context)),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        _modeCard(context),
      ],
    );
  }

  // ==================== 概览环形仪表 ====================

  Widget _overviewCard(BuildContext context) {
    final PerfPageState? s = widget.state;
    final MemoryReport? mem = s?.memory;
    final GpuReport? gpu = s?.gpu;
    final CpuReport? cpu = s?.cpu;
    final double? ramPct = mem?.usedPercent;
    final double? swapPct = mem?.swapPercent;
    final double? gpuPct = gpu?.busyPercent;
    final double? cpuPct = cpu?.usagePercent;

    return Card(
      key: const Key('scene_hero_rings'),
      child: Padding(
        padding: ScenePerfStyle.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ScenePerfStyle.sectionHeader(
              context,
              TablerIcons.activity,
              '概览',
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                Expanded(
                  child: _ring(
                    context,
                    id: 'ram',
                    percent: ramPct,
                    isRam: true,
                    label: '内存',
                    sublabel: _humanOrDash(mem?.usedHuman, mem?.usedKb),
                  ),
                ),
                Expanded(
                  child: _ring(
                    context,
                    id: 'swap',
                    percent: swapPct,
                    isRam: true,
                    label: '交换',
                    sublabel: _humanOrDash(
                      mem?.swapUsedHuman,
                      mem?.swapUsedKb,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                Expanded(
                  child: _ring(
                    context,
                    id: 'gpu',
                    percent: gpuPct,
                    isRam: false,
                    label: 'GPU',
                    sublabel: gpu?.freqMhz == null
                        ? '—'
                        : '${perfNum(gpu!.freqMhz)} MHz',
                  ),
                ),
                Expanded(
                  child: _ring(
                    context,
                    id: 'cpu',
                    percent: cpuPct,
                    isRam: false,
                    label: 'CPU',
                    sublabel: _cpuSublabel(cpu),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _ring(
    BuildContext context, {
    required String id,
    required double? percent,
    required bool isRam,
    required String label,
    required String sublabel,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final Color color;
    if (percent == null) {
      color = ScenePerfStyle.unavailableColor(scheme);
    } else if (isRam) {
      color = ScenePerfStyle.ramColor(scheme, percent);
    } else {
      color = ScenePerfStyle.cpuColor(scheme, percent);
    }
    return Center(
      child: SceneRingGauge(
        key: Key('scene_hero_ring_$id'),
        value: percent ?? 0,
        tierColor: color,
        label: label,
        valueText: _percent(percent),
        sublabel: sublabel,
      ),
    );
  }

  // ==================== 逐核网格 ====================

  Widget _perCoreCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final CpuReport? cpu = widget.state?.cpu;
    final List<double> usage = cpu?.perCoreUsage ?? const <double>[];
    final List<PerfCpuCore> cores = (cpu?.cores.isNotEmpty ?? false)
        ? cpu!.cores
        : <PerfCpuCore>[
            for (var i = 0; i < usage.length; i++) PerfCpuCore(id: i),
          ];

    return Card(
      key: const Key('scene_hero_per_core'),
      child: Padding(
        padding: ScenePerfStyle.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ScenePerfStyle.sectionHeader(
              context,
              TablerIcons.cpu_2,
              '逐核',
              trailing: Text(
                cores.isEmpty ? '—' : '${cores.length} 核',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (cores.isEmpty)
              Text(
                '暂无可用的逐核数据',
                key: const Key('scene_hero_per_core_empty'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: <Widget>[
                  for (var i = 0; i < cores.length; i++)
                    _coreTile(
                      context,
                      id: cores[i].id,
                      usage: i < usage.length ? usage[i] : 0,
                      freqMhz: cores[i].freqMhz,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _coreTile(
    BuildContext context, {
    required int id,
    required double usage,
    required double? freqMhz,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = ScenePerfStyle.cpuColor(scheme, usage);
    return Container(
      key: Key('scene_hero_core_$id'),
      width: ScenePerfStyle.coreTileWidth,
      padding: ScenePerfStyle.compactPadding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.allSM,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '核$id',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          Text(
            '${usage.toStringAsFixed(0)}%',
            style: theme.textTheme.titleSmall?.copyWith(
              color: color,
              fontWeight: AppTypography.weightSemiBold,
            ),
          ),
          Text(
            freqMhz == null ? '—' : '${freqMhz.toStringAsFixed(0)}MHz',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 电池 / 温度 ====================

  Widget _batteryCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final BatteryReport? b = widget.state?.battery;
    final present = b?.present ?? false;
    final double? cap = b?.capacityPercent;
    final Color color = cap == null
        ? ScenePerfStyle.unavailableColor(scheme)
        : ScenePerfStyle.ramColor(scheme, cap);

    return Card(
      key: const Key('scene_hero_battery'),
      child: Padding(
        padding: ScenePerfStyle.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ScenePerfStyle.sectionHeader(
              context,
              present ? TablerIcons.battery_charging : TablerIcons.battery,
              '电池',
              trailing: Text(
                present ? _percent(cap) : '无电池',
                style: ScenePerfStyle.sectionTitle(context).copyWith(
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            perfPercentBar(context, cap ?? 0,
                enabled: cap != null, color: color),
            const SizedBox(height: AppSpacing.sm),
            perfKv(context, '状态',
                (b?.status?.isNotEmpty ?? false) ? b!.status! : '—'),
            perfKv(context, '电流',
                b?.currentMa == null ? '—' : '${perfNum(b!.currentMa)} mA'),
            perfKv(context, '电压',
                b?.voltageV == null ? '—' : '${perfNum(b!.voltageV)} V'),
          ],
        ),
      ),
    );
  }

  Widget _temperatureCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ThermalReport? t = widget.state?.thermal;
    final double? maxTemp = t?.maxTempC;
    final Color color = maxTemp == null
        ? ScenePerfStyle.unavailableColor(scheme)
        : ScenePerfStyle.temperatureColor(scheme, maxTemp);
    final List<ThermalZone> zones = t?.zones ?? const <ThermalZone>[];

    return Card(
      key: const Key('scene_hero_temperature'),
      child: Padding(
        padding: ScenePerfStyle.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ScenePerfStyle.sectionHeader(
              context,
              TablerIcons.temperature,
              '温度',
              trailing: Text(
                maxTemp == null ? '—' : '最高 ${perfNum(maxTemp)} °C',
                style: ScenePerfStyle.sectionTitle(context).copyWith(
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (zones.isEmpty)
              Text(
                '暂无热区数据',
                key: const Key('scene_hero_thermal_empty'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              for (final ThermalZone zone in zones.take(6))
                perfThermalRow(context, zone, maxTemp),
          ],
        ),
      ),
    );
  }

  // ==================== 四档模式 ====================

  Widget _modeCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blocked = _blocked;
    final reason = _disabledReason;
    const modes = PerfMode.values;

    return Card(
      key: const Key('scene_hero_mode'),
      child: Padding(
        padding: ScenePerfStyle.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ScenePerfStyle.sectionHeader(context, TablerIcons.bolt, '场景模式'),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                for (var i = 0; i < modes.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(width: AppSpacing.xs),
                  Expanded(child: _modeButton(context, modes[i], blocked)),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _status ?? reason ?? '选择模式后应用到全部按应用档案',
              key: const Key('scene_hero_mode_status'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: blocked ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeButton(BuildContext context, PerfMode mode, bool blocked) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedMode == mode;
    return OutlinedButton(
      key: Key('scene_hero_mode_${mode.wireName}'),
      onPressed: (blocked || _busy) ? null : () => _applyMode(mode),
      style: selected
          ? OutlinedButton.styleFrom(
              backgroundColor: scheme.secondaryContainer,
              foregroundColor: scheme.onSecondaryContainer,
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            selected ? TablerIcons.check : _kModeIcons[mode]!,
            size: AppTypography.iconMD,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            mode.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  // ==================== 辅助 ====================

  String _cpuSublabel(CpuReport? cpu) {
    if (cpu == null) return '—';
    final governor = cpu.governor;
    if (governor != null && governor.isNotEmpty) return governor;
    return '${cpu.coreCount} 核';
  }

  String _percent(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(0)}%';

  String _humanOrDash(String? human, int? kb) {
    if (human != null && human.isNotEmpty) return human;
    return kb == null ? '—' : perfKbHuman(kb);
  }
}
