/// Scene 式首页性能仪表盘（plan todo 7）。
///
/// 渲染 Scene 首页（`fragment_home.xml`，见 `.omo/evidence/task-2-scene-reference.md`
/// §3）的核心卡片：
/// * 物理内存 / SWAP（含 SwapCached / Buffers / Dirty）；
/// * CPU / GPU；
/// * 逐核频率 / 负载；
/// * 电池 / 温度（含逐热区）。
///
/// **数据来源**：复用既有 `perfMonitorProvider`（`lib/page/perf/`，纯 Dart 帧监控 +
/// 原生 `perf` 模块），**不新建状态存储**。基础展示**不依赖 Shizuku**——原生模块
/// 未就绪时卡片降级为占位（「—」），绝不崩溃。
///
/// **四档模式快捷按钮**：本 todo 仅渲染 **capability-gated 禁用占位**，**不引用
/// 场景模式枚举**（实际接线由 todo 29 完成）。能力经 `PerfCapabilityProbe` 判定：
/// 无任何可写类别（cpu/gpu/cpuset/thermal/binderLevers）时禁用并显示可见原因。
///
/// **阈值**：卡片色档阈值集中在 `lib/core/perf/scene_thresholds.dart`
/// （plan todo 23；出处 `.omo/evidence/task-2-scene-reference.md` §4）；
/// 颜色仅取主题令牌
/// （[ColorScheme.error] / [ColorScheme.tertiary] / [ColorScheme.primary]），
/// **无硬编码颜色 / 字号**（AGENTS.md）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/perf/scene_thresholds.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';
import 'package:gstore/page/perf/perf_common.dart';
import 'package:gstore/page/perf/state.dart';

// ==================== 阈值常量 ====================
//
// Scene 色档 / 统计阈值已集中到 `lib/core/perf/scene_thresholds.dart`（todo 23），
// 出处：task-2-scene-reference.md §4。此处只消费共享常量 / 档位解析，
// **不再保留本地字面量**。注意：这些是**颜色档位**阈值，与
// `perf_alert_settings.dart` 的**告警**阈值语义不同（task-2 §4.5）。

// ==================== 注入点 ====================

/// 设备可调项加载器（生产经 `PerfModule.instance.tunables`；测试注入罐头报告）。
typedef DashboardTunablesLoader = Future<TunablesReport> Function();

/// 控制能力探测器（基于已加载的 tunables；测试注入罐头能力图）。
///
/// 与 `PerfProfilesPage` 的同名注入点一致，**复用既有模式**（不新建状态存储）。
typedef DashboardCapabilitiesLoader = Future<PerfControlCapabilities?> Function(
  TunablesReport tunables,
);

/// 四档模式快捷按钮的静态描述（**仅占位**，不涉及任何场景模式枚举）。
class _ModeButtonSpec {
  const _ModeButtonSpec({
    required this.id,
    required this.label,
    required this.icon,
  });

  final String id;
  final String label;
  final IconData icon;
}

/// 四档模式：省电 / 均衡 / 性能 / 极速（文案出处 `strings.xml:286-289`）。
const List<_ModeButtonSpec> _kModeButtons = <_ModeButtonSpec>[
  _ModeButtonSpec(id: 'powersave', label: '省电', icon: TablerIcons.leaf),
  _ModeButtonSpec(id: 'balance', label: '均衡', icon: TablerIcons.activity),
  _ModeButtonSpec(id: 'performance', label: '性能', icon: TablerIcons.rocket),
  _ModeButtonSpec(id: 'fast', label: '极速', icon: TablerIcons.flame),
];

// ==================== 页面 ====================

/// Scene 式仪表盘页（首页 tab 内容）。
///
/// [tunablesLoader] / [capabilitiesLoader] 可注入，便于 widget 测试在**无 Shizuku /
/// 无原生模块**下验证能力门禁；`null` 时走生产实现。
class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({
    super.key,
    this.tunablesLoader,
    this.capabilitiesLoader,
  });

  /// 设备可调项加载器；`null` 时用生产 `PerfModule.instance.tunables`。
  final DashboardTunablesLoader? tunablesLoader;

  /// 控制能力加载器；`null` 时用 [PerfCapabilityProbe]（经 privileged shell）。
  final DashboardCapabilitiesLoader? capabilitiesLoader;

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  late final DashboardTunablesLoader _tunablesLoader;
  late final DashboardCapabilitiesLoader _capabilitiesLoader;

  /// 最近一次能力探测结果（`null` = 未探测 / 探测失败）。
  ///
  /// **仅用于四档模式占位按钮的门禁**；基础卡片不读取本字段。
  PerfControlCapabilities? _capabilities;

  /// 能力探测是否已尝试（区分「进行中」与「失败」）。
  bool _probed = false;

  @override
  void initState() {
    super.initState();
    _tunablesLoader =
        widget.tunablesLoader ?? () => PerfModule.instance.tunables();
    _capabilitiesLoader = widget.capabilitiesLoader ?? _probeCapabilities;
    Future<void>.microtask(_probeCapabilitiesIfNeeded);
  }

  /// 生产能力探测：以已加载的 tunables 推导候选节点后 fail-closed 探测。
  Future<PerfControlCapabilities?> _probeCapabilities(TunablesReport tunables) {
    final probe = PerfCapabilityProbe(shell: PrivilegedShell());
    return probe.probe(tunables);
  }

  /// 探测能力（best-effort；任何失败都降级为 `null`，绝不崩溃）。
  Future<void> _probeCapabilitiesIfNeeded() async {
    if (_probed) return;
    _probed = true;
    try {
      final tunables = await _tunablesLoader();
      final capabilities = await _capabilitiesLoader(tunables);
      if (!mounted) return;
      setState(() => _capabilities = capabilities);
    } catch (error) {
      debugPrint('[Dashboard] 控制能力探测失败（fail-closed）: $error');
      if (!mounted) return;
      setState(() => _capabilities = null);
    }
  }

  /// 四档模式按钮的禁用原因（**始终禁用**；本 todo 不接线）。
  String get _modeDisabledReason {
    if (!_probed) return '正在探测控制能力…';
    final capabilities = _capabilities;
    if (capabilities == null) {
      return '控制能力未探测（Shizuku 不可用或探测失败），模式切换已禁用。';
    }
    final anyWritable = PerfControlCategory.values
        .any(capabilities.isCategoryAvailable);
    if (!anyWritable) {
      return '当前设备无可写控制类别（Shizuku 未授权 / 不适用），模式切换不可用。';
    }
    return '模式切换将在后续版本接入（当前为占位）。';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(perfMonitorProvider);
    final theme = Theme.of(context);

    // 首屏无任何数据时展示 loading（避免瞬时空卡片闪烁）。
    final hasData = state.cpu != null ||
        state.memory != null ||
        state.battery != null ||
        state.thermal != null ||
        state.gpu != null;
    final showLoading = state.loading && !hasData;

    return Scaffold(
      appBar: AppBar(title: const Text('首页')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(perfMonitorProvider.notifier).refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            top: AppSpacing.lg,
            // 底部避让悬浮导航胶囊（与 MinePage 一致）。
            bottom: 80 + MediaQuery.of(context).padding.bottom,
          ),
          children: <Widget>[
            if (showLoading)
              const Padding(
                padding: AppSpacing.allXXL,
                child: Center(child: AppLoading()),
              )
            else ...<Widget>[
              if (!state.moduleReady) _moduleHint(context, theme, state),
              _ramCard(context, theme, state),
              const SizedBox(height: AppSpacing.md),
              _swapCard(context, theme, state),
              const SizedBox(height: AppSpacing.md),
              _cpuCard(context, theme, state),
              const SizedBox(height: AppSpacing.md),
              _gpuCard(context, theme, state),
              const SizedBox(height: AppSpacing.md),
              _perCoreCard(context, theme, state),
              const SizedBox(height: AppSpacing.md),
              _batteryCard(context, theme, state),
              const SizedBox(height: AppSpacing.md),
              _temperatureCard(context, theme, state),
              const SizedBox(height: AppSpacing.md),
              _modeCard(context, theme),
            ],
          ],
        ),
      ),
    );
  }

  // ==================== 提示 ====================

  Widget _moduleHint(BuildContext context, ThemeData theme, PerfPageState state) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Row(
          children: <Widget>[
            Icon(
              TablerIcons.info_circle,
              size: AppTypography.iconMD,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                state.error ?? '原生性能模块未就绪，部分指标暂不可用。',
                key: const Key('dashboard_module_hint'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 卡片 ====================

  Widget _ramCard(BuildContext context, ThemeData theme, PerfPageState state) {
    final scheme = theme.colorScheme;
    final memory = state.memory;
    final usedPercent = memory?.usedPercent;
    final color = usedPercent == null
        ? null
        : _loadColor(scheme, sceneRamLoadTier(usedPercent));
    return Card(
      key: const Key('dashboard_card_ram'),
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            perfSectionHeader(
              context,
              TablerIcons.database,
              '物理内存',
              trailing: Text(
                _percent(usedPercent),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            perfPercentBar(context, usedPercent ?? 0,
                enabled: usedPercent != null, color: color),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                perfMetric(context, '已用',
                    _humanOrDash(memory?.usedHuman, memory?.usedKb)),
                perfMetric(context, '可用',
                    _humanOrDash(memory?.availableHuman, memory?.availableKb)),
                perfMetric(context, '总量',
                    _humanOrDash(memory?.totalHuman, memory?.totalKb)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _swapCard(BuildContext context, ThemeData theme, PerfPageState state) {
    final scheme = theme.colorScheme;
    final memory = state.memory;
    final swapPercent = memory?.swapPercent;
    final color = swapPercent == null
        ? null
        : _loadColor(scheme, sceneRamLoadTier(swapPercent));
    return Card(
      key: const Key('dashboard_card_swap'),
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            perfSectionHeader(
              context,
              TablerIcons.server,
              '交换分区',
              trailing: Text(
                _percent(swapPercent),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            perfPercentBar(context, swapPercent ?? 0,
                enabled: swapPercent != null, color: color),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                perfMetric(context, '已用',
                    _humanOrDash(memory?.swapUsedHuman, memory?.swapUsedKb)),
                perfMetric(context, '总量',
                    _humanOrDash(memory?.swapTotalHuman, memory?.swapTotalKb)),
              ],
            ),
            const Divider(height: AppSpacing.xl),
            perfKv(context, 'SwapCached', _kbHumanOrDash(memory?.swapCachedKb)),
            perfKv(context, 'Buffers', _kbHumanOrDash(memory?.buffersKb)),
            perfKv(context, 'Dirty', _kbHumanOrDash(memory?.dirtyKb)),
          ],
        ),
      ),
    );
  }

  Widget _cpuCard(BuildContext context, ThemeData theme, PerfPageState state) {
    final scheme = theme.colorScheme;
    final cpu = state.cpu;
    final usage = cpu?.usagePercent;
    final color = usage == null
        ? null
        : _loadColor(scheme, sceneCpuLoadTier(usage));
    return Card(
      key: const Key('dashboard_card_cpu'),
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            perfSectionHeader(
              context,
              TablerIcons.cpu,
              'CPU',
              trailing: Text(
                _percent(usage),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            perfPercentBar(context, usage ?? 0,
                enabled: usage != null, color: color),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                perfMetric(context, '核心数',
                    cpu == null ? '—' : '${cpu.coreCount}'),
                perfMetric(context, '调速器',
                    (cpu?.governor?.isNotEmpty ?? false) ? cpu!.governor! : '—'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _gpuCard(BuildContext context, ThemeData theme, PerfPageState state) {
    final scheme = theme.colorScheme;
    final gpu = state.gpu;
    final busy = gpu?.busyPercent;
    final color = busy == null
        ? null
        : _loadColor(scheme, sceneCpuLoadTier(busy));
    return Card(
      key: const Key('dashboard_card_gpu'),
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            perfSectionHeader(
              context,
              TablerIcons.device_desktop,
              'GPU',
              trailing: Text(
                _percent(busy),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            perfPercentBar(context, busy ?? 0,
                enabled: busy != null, color: color),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                perfMetric(context, '频率',
                    gpu?.freqMhz == null ? '—' : '${perfNum(gpu!.freqMhz)} MHz'),
                perfMetric(context, '型号',
                    (gpu?.name?.isNotEmpty ?? false) ? gpu!.name! : '—'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _perCoreCard(
    BuildContext context,
    ThemeData theme,
    PerfPageState state,
  ) {
    final cpu = state.cpu;
    final usage = cpu?.perCoreUsage ?? const <double>[];
    final cores = (cpu?.cores.isNotEmpty ?? false)
        ? cpu!.cores
        : <PerfCpuCore>[
            for (var i = 0; i < usage.length; i++) PerfCpuCore(id: i),
          ];
    return Card(
      key: const Key('dashboard_card_per_core'),
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            perfSectionHeader(
              context,
              TablerIcons.cpu_2,
              '逐核',
              trailing: Text(
                cores.isEmpty ? '—' : '${cores.length} 核',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (cores.isEmpty)
              Text(
                '暂无可用的逐核数据',
                key: const Key('dashboard_per_core_empty'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: <Widget>[
                  for (var i = 0; i < cores.length; i++)
                    perfCoreChip(
                      context,
                      cores[i].id,
                      i < usage.length ? usage[i] : 0,
                      cores[i].freqMhz,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _batteryCard(
    BuildContext context,
    ThemeData theme,
    PerfPageState state,
  ) {
    final scheme = theme.colorScheme;
    final battery = state.battery;
    final present = battery?.present ?? false;
    final capacity = battery?.capacityPercent;
    final color = capacity == null
        ? null
        : _loadColor(scheme, sceneRamLoadTier(capacity));
    return Card(
      key: const Key('dashboard_card_battery'),
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            perfSectionHeader(
              context,
              present ? TablerIcons.battery_charging : TablerIcons.battery,
              '电池',
              trailing: Text(
                present ? _percent(capacity) : '无电池',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            perfPercentBar(context, capacity ?? 0,
                enabled: capacity != null, color: color),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                perfMetric(context, '状态',
                    (battery?.status?.isNotEmpty ?? false) ? battery!.status! : '—'),
                perfMetric(context, '电流',
                    battery?.currentMa == null
                        ? '—'
                        : '${perfNum(battery!.currentMa)} mA'),
                perfMetric(context, '电压',
                    battery?.voltageV == null
                        ? '—'
                        : '${perfNum(battery!.voltageV)} V'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _temperatureCard(
    BuildContext context,
    ThemeData theme,
    PerfPageState state,
  ) {
    final scheme = theme.colorScheme;
    final thermal = state.thermal;
    final maxTemp = thermal?.maxTempC;
    final color = maxTemp == null ? null : _tempColor(scheme, maxTemp);
    final zones = thermal?.zones ?? const <ThermalZone>[];
    return Card(
      key: const Key('dashboard_card_temperature'),
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            perfSectionHeader(
              context,
              TablerIcons.temperature,
              '温度',
              trailing: Text(
                maxTemp == null ? '—' : '最高 ${perfNum(maxTemp)} °C',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (zones.isEmpty)
              Text(
                '暂无热区数据',
                key: const Key('dashboard_thermal_empty'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              for (final zone in zones)
                perfThermalRow(context, zone, maxTemp),
          ],
        ),
      ),
    );
  }

  /// 四档模式快捷按钮卡片（**capability-gated 禁用占位**）。
  ///
  /// 四个按钮**恒为禁用**（本 todo 占位；接线在 todo 29）。能力不可用 /
  /// 无可写类别时在按钮下显示可见原因（fail-closed）。
  Widget _modeCard(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    return Card(
      key: const Key('dashboard_card_mode'),
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            perfSectionHeader(context, TablerIcons.bolt, '场景模式'),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                for (var i = 0; i < _kModeButtons.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: Key('dashboard_mode_${_kModeButtons[i].id}'),
                      // 占位：恒禁用（接线由 todo 29 完成）。
                      onPressed: null,
                      icon: Icon(
                        _kModeButtons[i].icon,
                        size: AppTypography.iconSM,
                      ),
                      label: Text(
                        _kModeButtons[i].label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _modeDisabledReason,
              key: const Key('dashboard_mode_reason'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 辅助 ====================

  /// 负载 / 占用色档 → 主题角色：veryHigh → error；high → tertiary；否则 primary。
  ///
  /// 档位边界由 [sceneCpuLoadTier] / [sceneRamLoadTier] 集中给出
  /// （`lib/core/perf/scene_thresholds.dart`），此处只做档位→主题令牌映射。
  Color _loadColor(ColorScheme scheme, SceneLoadTier tier) {
    return switch (tier) {
      SceneLoadTier.veryHigh => scheme.error,
      SceneLoadTier.high => scheme.tertiary,
      SceneLoadTier.normal => scheme.primary,
    };
  }

  /// 温度色档 → 主题角色：veryHigh / high → error；mid → tertiary；否则 primary。
  ///
  /// Scene 的「高」与「最高」两档均取更强的主题角色（error）；档位边界由
  /// [sceneTempTier] 集中给出（`lib/core/perf/scene_thresholds.dart`）。
  Color _tempColor(ColorScheme scheme, double tempC) {
    return switch (sceneTempTier(tempC)) {
      SceneTempTier.veryHigh || SceneTempTier.high => scheme.error,
      SceneTempTier.mid => scheme.tertiary,
      SceneTempTier.normal => scheme.primary,
    };
  }

  String _percent(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(0)}%';

  String _kbHumanOrDash(int? kb) => kb == null ? '—' : perfKbHuman(kb);

  /// 模块 human 串优先；缺失 / 空串时回退按 KiB 格式化；两者皆缺为「—」。
  String _humanOrDash(String? human, int? kb) =>
      (human != null && human.isNotEmpty) ? human : _kbHumanOrDash(kb);
}
