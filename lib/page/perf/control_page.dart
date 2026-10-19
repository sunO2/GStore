import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/control_refresh_rate.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/refresh_auto_engine.dart';
import 'package:gstore/core/perf/refresh_auto_store.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

import 'perf_control_actions.dart';

/// 性能「控制 / 调优」内容部件（Riverpod）。
///
/// 容纳并入 [PerfMonitorPage]「控制」tab 的控制 / 调优卡片：
/// CPU 逐簇 governor·频率、GPU、cpuset 归属、热控开关。
/// 内部 [_ControlSection] 逐字沿用原实现，行为 / Key 不变。
///
/// **纯内容部件**：不含 Scaffold / AppBar，返回可滚动内容供页面 tab body 直接复用。
class PerfControlPage extends ConsumerWidget {
  const PerfControlPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      children: const [
        _ControlSection(),
      ],
    );
  }
}

// ==================== 控制 / 调优区（Wave 6 · todo 28） ====================

/// 控制 / 调优卡片：CPU 逐簇 governor·频率、GPU、cpuset 归属、热控开关。
///
/// * 展示值来自 `perf.tunables`；应用成功后就地刷新展示值（对抗陈旧态）。
/// * 每个类别的可用性来自 todo 15 的能力探测；不可用 / 未探测 → 禁用 + 原因。
/// * 每次写入都经 [AppDialogs.showConfirmSheet]（危险确认）授权。
class _ControlSection extends ConsumerStatefulWidget {
  const _ControlSection();

  @override
  ConsumerState<_ControlSection> createState() => _ControlSectionState();
}

class _ControlSectionState extends ConsumerState<_ControlSection> {
  bool _loading = true;
  bool _applying = false;
  String? _error;
  TunablesReport? _tunables;
  PerfControlCapabilities? _capabilities;
  PerfControlActions? _actions;

  // 应用成功后的就地展示值（真机 tunables 不自动刷新）。
  final Map<String, String> _governorApplied = <String, String>{};
  final Map<String, double?> _minApplied = <String, double?>{};
  final Map<String, double?> _maxApplied = <String, double?>{};

  // 用户选择态（待写入的请求值）。
  final Map<String, String> _selectedGovernor = <String, String>{};
  final Map<String, double?> _selectedMin = <String, double?>{};
  final Map<String, double?> _selectedMax = <String, double?>{};

  double? _selectedGpuMin;
  double? _selectedGpuMax;
  final TextEditingController _cpusetController = TextEditingController();
  String? _selectedCpuset;
  bool _thermalEnabled = true;

  // 屏幕刷新率（WS-B）：独立于 tunables / 能力图的 Shizuku `settings` 组。
  RefreshRateController? _refreshController;
  RefreshRateState? _refreshState;
  bool _refreshLoading = true;

  // 每应用自动刷新率（WS-D）：配置 + 引擎生命周期（引擎仅经 RefreshRateController）。
  RefreshAutoStore? _autoStore;
  RefreshAutoConfig _autoConfig = const RefreshAutoConfig();
  bool _autoLoading = true;
  RefreshAutoDriver? _autoDriver;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
    Future<void>.microtask(_loadRefresh);
    Future<void>.microtask(_loadRefreshAuto);
  }

  @override
  void dispose() {
    _autoDriver?.dispose();
    _cpusetController.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tunables = await ref.read(perfControlTunablesLoaderProvider)();
      final capabilities =
          await ref.read(perfControlCapabilitiesLoaderProvider)(refresh: refresh);
      final actions =
          ref.read(perfControlActionsFactoryProvider)(tunables, capabilities);
      if (!mounted) return;
      _seedSelections(tunables);
      setState(() {
        _tunables = tunables;
        _capabilities = capabilities;
        _actions = actions;
        _loading = false;
      });
    } catch (error) {
      debugPrint('[PerfControl] 加载控制能力失败（fail-closed 禁用）: $error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '控制能力加载失败（fail-closed，已禁用）';
      });
    }
  }

  /// 独立加载「屏幕刷新率」状态（经 Shizuku `settings get`）。
  ///
  /// 与 [_load] 解耦：刷新率失败**不**影响 CPU/GPU/cpuset/thermal 组；任一失败
  /// 都降级为不可用快照（fail-closed 禁用 + 可见原因）。
  Future<void> _loadRefresh() async {
    if (!mounted) return;
    setState(() => _refreshLoading = true);
    final controller = ref.read(perfRefreshRateControllerProvider);
    RefreshRateState next;
    try {
      next = await controller.read();
    } catch (error) {
      debugPrint('[PerfControl] 刷新率读取失败（禁用）: $error');
      next = RefreshRateState.unavailable('刷新率读取失败（Shizuku 不可用）');
    }
    if (!mounted) return;
    setState(() {
      _refreshController = controller;
      _refreshState = next;
      _refreshLoading = false;
    });
  }

  void _seedSelections(TunablesReport tunables) {
    for (final cluster in tunables.cpuClusters) {
      final policy = cluster.policy;
      if (policy.isEmpty) continue;
      final governors = cluster.availableGovernors;
      _selectedGovernor[policy] = _governorApplied[policy] ??
          cluster.governor ??
          (governors.isNotEmpty ? governors.first : '');
      final freqs = cluster.availableFrequenciesMhz;
      _selectedMin[policy] = _minApplied[policy] ??
          _pickFreq(freqs, cluster.minFreqMhz);
      _selectedMax[policy] = _maxApplied[policy] ??
          _pickFreq(freqs, cluster.maxFreqMhz, last: true);
    }
    final gpuFreqs = tunables.gpu.availableFrequenciesMhz;
    if (gpuFreqs.isNotEmpty) {
      _selectedGpuMin ??= gpuFreqs.first;
      _selectedGpuMax ??= gpuFreqs.last;
    }
    if (tunables.cpusets.isNotEmpty) {
      _selectedCpuset ??= tunables.cpusets.first.name;
    } else {
      _selectedCpuset ??= kDefaultCpusetNames.isNotEmpty
          ? kDefaultCpusetNames.first
          : null;
    }
  }

  // ==================== 可用性 ====================

  bool _nodeAvailable(String path) =>
      _capabilities?.isNodeAvailable(path) ?? false;

  bool _categoryAvailable(PerfControlCategory category) {
    final caps = _capabilities;
    return caps != null && caps.isCategoryAvailable(category);
  }

  String _unavailableReason(PerfControlCategory category) {
    if (_capabilities == null) {
      return '控制能力未探测 / 不可用（需 Shizuku 授权且控制节点可写）';
    }
    return '本设备当前不支持${_categoryLabel(category)}调优（探测判定不可用）';
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      key: const Key('perf_control_section'),
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  TablerIcons.adjustments,
                  size: AppTypography.iconMD,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '控制 / 调优',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('perf_control_refresh'),
                  icon: const Icon(
                    TablerIcons.refresh,
                    size: AppTypography.iconMD,
                  ),
                  tooltip: '重新探测控制能力',
                  onPressed: (_loading || _applying) ? null : _refresh,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (_loading)
              const Row(
                children: [
                  AppLoading(size: AppLoadingSize.small),
                  SizedBox(width: AppSpacing.md),
                  Expanded(child: Text('正在探测控制能力…')),
                ],
              )
            else ...[
              if (_error != null)
                Text(
                  _error!,
                  style:
                      theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
                )
              else if (_tunables == null)
                Text(
                  '可控面不可用（模块未提供 perf.tunables）',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                )
              else ...[
                _notice(
                  context,
                  _capabilities == null
                      ? '控制能力未探测 / 不可用（需 Shizuku 授权且控制节点可写），所有控制已禁用'
                      : _capabilitySummary(_capabilities!),
                ),
                const SizedBox(height: AppSpacing.md),
                ..._cpuControls(context),
                const SizedBox(height: AppSpacing.md),
                ..._gpuControls(context),
                const SizedBox(height: AppSpacing.md),
                ..._cpusetControls(context),
                const SizedBox(height: AppSpacing.md),
                ..._thermalControls(context),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '所有写入经 Shizuku 并在应用后回读校验；可通过控制会话还原。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              // 屏幕刷新率组独立于 tunables / 能力图：即使控制面不可用也展示
              // （数据来自 `settings get/put system min/peak_refresh_rate`）。
              _refreshControls(context),
            ],
          ],
        ),
      ),
    );
  }

  // ==================== CPU ====================

  List<Widget> _cpuControls(BuildContext context) {
    final theme = Theme.of(context);
    final tunables = _tunables;
    final clusters = tunables?.cpuClusters ?? const <PerfCpuCluster>[];
    final widgets = <Widget>[
      Text(
        'CPU 调速 / 频率',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: AppTypography.weightSemiBold,
        ),
      ),
      const SizedBox(height: AppSpacing.xs),
    ];
    var any = false;
    for (final cluster in clusters) {
      if (cluster.policy.isEmpty) continue;
      any = true;
      widgets.add(_cpuClusterBlock(context, cluster));
    }
    if (!any) {
      widgets.add(
        Text(
          '无 CPU 调控节点（perf.tunables 未枚举到策略簇）',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _cpuClusterBlock(BuildContext context, PerfCpuCluster cluster) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final policy = cluster.policy;
    final base = '/sys/devices/system/cpu/cpufreq/$policy';
    final governorEnabled = _nodeAvailable('$base/scaling_governor');
    final minEnabled = _nodeAvailable('$base/scaling_min_freq');
    final maxEnabled = _nodeAvailable('$base/scaling_max_freq');
    final anyEnabled = governorEnabled || minEnabled || maxEnabled;

    final governor = _governorApplied[policy] ?? cluster.governor;
    final min = _minApplied[policy] ?? cluster.minFreqMhz;
    final max = _maxApplied[policy] ?? cluster.maxFreqMhz;
    final freqs = cluster.availableFrequenciesMhz;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$policy · 核心 ${_cpusLabel(cluster.relatedCpus)}',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: AppTypography.weightMedium,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '当前：${governor ?? '未知'} · ${_freqRange(min, max)}',
            key: Key('perf_control_cpu_current_$policy'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (!anyEnabled)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: _reasonLine(context, _unavailableReason(PerfControlCategory.cpu)),
            ),
          if (cluster.availableGovernors.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _dropdown<String>(
              key: Key('perf_control_cpu_governor_$policy'),
              label: '调速器',
              initialValue: cluster.availableGovernors.contains(
                _selectedGovernor[policy],
              )
                  ? _selectedGovernor[policy]
                  : cluster.availableGovernors.first,
              items: cluster.availableGovernors,
              itemLabel: (value) => value,
              onChanged: governorEnabled
                  ? (value) => setState(
                        () => _selectedGovernor[policy] = value ?? '',
                      )
                  : null,
            ),
          ],
          if (freqs.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: _dropdown<double>(
                    key: Key('perf_control_cpu_min_$policy'),
                    label: '最低频率',
                    initialValue: _selectedMin[policy],
                    items: freqs,
                    itemLabel: _mhz,
                    onChanged: minEnabled
                        ? (value) => setState(
                              () => _selectedMin[policy] = value ?? freqs.first,
                            )
                        : null,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _dropdown<double>(
                    key: Key('perf_control_cpu_max_$policy'),
                    label: '最高频率',
                    initialValue: _selectedMax[policy],
                    items: freqs,
                    itemLabel: _mhz,
                    onChanged: maxEnabled
                        ? (value) => setState(
                              () =>
                                  _selectedMax[policy] = value ?? freqs.last,
                            )
                        : null,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              key: Key('perf_control_cpu_apply_$policy'),
              onPressed: (anyEnabled && !_applying)
                  ? () => _applyCpu(cluster)
                  : null,
              icon: const Icon(TablerIcons.check, size: AppTypography.iconSM),
              label: const Text('应用'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyCpu(PerfCpuCluster cluster) async {
    final actions = _actions;
    if (actions == null) return;
    final policy = cluster.policy;
    final base = '/sys/devices/system/cpu/cpufreq/$policy';
    final governor = _nodeAvailable('$base/scaling_governor')
        ? _selectedGovernor[policy]
        : null;
    final minFreq =
        _nodeAvailable('$base/scaling_min_freq') ? _selectedMin[policy] : null;
    final maxFreq =
        _nodeAvailable('$base/scaling_max_freq') ? _selectedMax[policy] : null;

    final confirmed = await AppDialogs.showConfirmSheet(
      title: '应用 CPU 策略？',
      message: '将对 $policy 写入：governor=${governor ?? '不变'}，'
          '最低=${minFreq == null ? '不变' : _mhz(minFreq)}，'
          '最高=${maxFreq == null ? '不变' : _mhz(maxFreq)}。'
          '写入经 Shizuku 执行并回读校验，可通过控制会话还原。',
      confirmText: '确认应用',
      isDangerous: true,
    );
    if (confirmed != true || !mounted) return;

    setState(() => _applying = true);
    final result = await actions.applyCpu(
      cluster: policy,
      governor: governor,
      minFreqMhz: minFreq,
      maxFreqMhz: maxFreq,
    );
    if (!mounted) return;
    setState(() {
      _applying = false;
      if (result.ok) {
        if (governor != null) _governorApplied[policy] = governor;
        if (minFreq != null) _minApplied[policy] = minFreq;
        if (maxFreq != null) _maxApplied[policy] = maxFreq;
      }
    });
    _report(result.ok, 'CPU 策略', policy, result.status, result.message);
  }

  // ==================== GPU ====================

  List<Widget> _gpuControls(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final gpu = _tunables?.gpu ?? const PerfGpuTunables();
    final enabled = _categoryAvailable(PerfControlCategory.gpu);
    final freqs = gpu.availableFrequenciesMhz;
    return <Widget>[
      Text(
        'GPU 调优',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: AppTypography.weightSemiBold,
        ),
      ),
      const SizedBox(height: AppSpacing.xs),
      Text(
        '当前 governor：${gpu.governor ?? '未知'} · '
        '可用频率 ${freqs.isEmpty ? '未枚举' : '${freqs.length} 档'}',
        key: const Key('perf_control_gpu_current'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      if (!enabled)
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xs),
          child: _reasonLine(context, _unavailableReason(PerfControlCategory.gpu)),
        ),
      if (freqs.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: _dropdown<double>(
                key: const Key('perf_control_gpu_min'),
                label: '最低频率',
                initialValue: _selectedGpuMin,
                items: freqs,
                itemLabel: _mhz,
                onChanged: enabled
                    ? (value) => setState(
                          () => _selectedGpuMin = value ?? freqs.first,
                        )
                    : null,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _dropdown<double>(
                key: const Key('perf_control_gpu_max'),
                label: '最高频率',
                initialValue: _selectedGpuMax,
                items: freqs,
                itemLabel: _mhz,
                onChanged: enabled
                    ? (value) => setState(
                          () => _selectedGpuMax = value ?? freqs.last,
                        )
                    : null,
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: AppSpacing.xs),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.tonalIcon(
          key: const Key('perf_control_gpu_apply'),
          onPressed: (enabled && !_applying && freqs.isNotEmpty)
              ? _applyGpu
              : null,
          icon: const Icon(TablerIcons.check, size: AppTypography.iconSM),
          label: const Text('应用'),
        ),
      ),
    ];
  }

  Future<void> _applyGpu() async {
    final actions = _actions;
    if (actions == null) return;
    final policy = GpuPolicy(
      minFreqMhz: _selectedGpuMin,
      maxFreqMhz: _selectedGpuMax,
    );
    if (policy.isEmpty) {
      AppDialogs.showInfo('未选择任何 GPU 旋钮');
      return;
    }
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '应用 GPU 策略？',
      message: '将写入 GPU 频率：最低=${_selectedGpuMin == null ? '不变' : _mhz(_selectedGpuMin!)}，'
          '最高=${_selectedGpuMax == null ? '不变' : _mhz(_selectedGpuMax!)}。'
          '写入经 Shizuku 执行并回读校验。',
      confirmText: '确认应用',
      isDangerous: true,
    );
    if (confirmed != true || !mounted) return;

    setState(() => _applying = true);
    final result = await actions.applyGpu(policy);
    if (!mounted) return;
    setState(() => _applying = false);
    _report(
      result.applied,
      'GPU 策略',
      'gpu',
      result.status.name,
      result.reason,
    );
  }

  // ==================== cpuset ====================

  List<Widget> _cpusetControls(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = _categoryAvailable(PerfControlCategory.cpuset);
    final names = _tunables?.cpusets.map((c) => c.name).toList() ??
        const <String>[];
    final options = names.isEmpty ? kDefaultCpusetNames : names;
    return <Widget>[
      Text(
        'cpuset / 亲和归属',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: AppTypography.weightSemiBold,
        ),
      ),
      const SizedBox(height: AppSpacing.xs),
      Text(
        '把目标进程归属到指定 cpuset（写入其 tasks 成员表）。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      if (!enabled)
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xs),
          child:
              _reasonLine(context, _unavailableReason(PerfControlCategory.cpuset)),
        ),
      const SizedBox(height: AppSpacing.sm),
      TextField(
        key: const Key('perf_control_cpuset_pkg'),
        controller: _cpusetController,
        enabled: enabled,
        decoration: const InputDecoration(
          labelText: '包名 / pid',
          isDense: true,
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: AppSpacing.sm),
      _dropdown<String>(
        key: const Key('perf_control_cpuset_select'),
        label: 'cpuset',
        initialValue: options.contains(_selectedCpuset)
            ? _selectedCpuset
            : (options.isNotEmpty ? options.first : null),
        items: options,
        itemLabel: (value) => value,
        onChanged: enabled
            ? (value) => setState(() => _selectedCpuset = value)
            : null,
      ),
      const SizedBox(height: AppSpacing.xs),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.tonalIcon(
          key: const Key('perf_control_cpuset_apply'),
          onPressed: (enabled && !_applying) ? _applyCpuset : null,
          icon: const Icon(TablerIcons.check, size: AppTypography.iconSM),
          label: const Text('应用'),
        ),
      ),
    ];
  }

  Future<void> _applyCpuset() async {
    final actions = _actions;
    final cpuset = _selectedCpuset;
    if (actions == null || cpuset == null) return;
    final pkgOrPid = _cpusetController.text.trim();
    if (pkgOrPid.isEmpty) {
      AppDialogs.showError('请输入包名或 pid');
      return;
    }
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '应用 cpuset 归属？',
      message: '将把 $pkgOrPid 归属到 cpuset「$cpuset」'
          '（写 /dev/cpuset/$cpuset/tasks）。写入经 Shizuku 执行并回读校验。',
      confirmText: '确认应用',
      isDangerous: true,
    );
    if (confirmed != true || !mounted) return;

    setState(() => _applying = true);
    final result = await actions.applyCpuset(pkgOrPid: pkgOrPid, cpuset: cpuset);
    if (!mounted) return;
    setState(() => _applying = false);
    _report(result.ok, 'cpuset 归属', pkgOrPid, result.status, result.message);
  }

  // ==================== 热控 ====================

  List<Widget> _thermalControls(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = _categoryAvailable(PerfControlCategory.thermal);
    return <Widget>[
      Text(
        '热控 / 散热',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: AppTypography.weightSemiBold,
        ),
      ),
      const SizedBox(height: AppSpacing.xs),
      Text(
        enabled
            ? '关闭热控降温存在过热风险，应用时需危险确认。'
            : _unavailableReason(PerfControlCategory.thermal),
        key: const Key('perf_control_thermal_reason'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: enabled ? scheme.onSurfaceVariant : scheme.error,
        ),
      ),
      const SizedBox(height: AppSpacing.xs),
      SwitchListTile(
        key: const Key('perf_control_thermal_switch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('保持热控降温'),
        subtitle: Text(_thermalEnabled ? 'enabled（安全方向）' : 'disabled（过热风险）'),
        value: _thermalEnabled,
        onChanged: (enabled && !_applying) ? _applyThermal : null,
      ),
    ];
  }

  Future<void> _applyThermal(bool enabled) async {
    final actions = _actions;
    if (actions == null) return;
    final confirmed = await AppDialogs.showConfirmSheet(
      title: enabled ? '恢复热控降温？' : '关闭热控降温？',
      message: enabled
          ? '将把热区 mode 写回 enabled（安全方向）。'
          : '将把热区 mode 写为 disabled——关闭热保护存在过热风险，请谨慎操作。',
      confirmText: '确认',
      isDangerous: true,
    );
    if (confirmed != true || !mounted) return;

    setState(() => _applying = true);
    final result = await actions.setThermal(enabled, confirmed: true);
    if (!mounted) return;
    setState(() {
      _applying = false;
      if (result.ok) _thermalEnabled = enabled;
    });
    _report(result.ok, '热控', 'thermal', result.error ?? 'ok', result.detail);
  }

  // ==================== 屏幕刷新率（WS-B） ====================

  /// 「屏幕刷新率」控制组：展示当前 min/peak + 档位按钮。
  ///
  /// 数据来自 `settings get system min_refresh_rate` / `peak_refresh_rate`（经
  /// Shizuku）；档位来自 `dumpsys display` 解析（退化 60/90/120）。Shizuku 不可用
  /// / 读取失败 → 全部档位按钮禁用并给出可见原因（fail-closed）。
  Widget _refreshControls(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = _refreshState;
    final available = state?.available ?? false;
    final levels = (state != null && state.levels.isNotEmpty)
        ? state.levels
        : RefreshRateController.fallbackLevels;
    return Column(
      key: const Key('perf_refresh_group'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '屏幕刷新率',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: AppTypography.weightSemiBold,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        if (_refreshLoading && state == null)
          const Row(
            children: [
              AppLoading(size: AppLoadingSize.small),
              SizedBox(width: AppSpacing.md),
              Expanded(child: Text('正在读取屏幕刷新率…')),
            ],
          )
        else ...[
          Text(
            _refreshCurrentText(state),
            key: const Key('perf_refresh_current'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: available ? scheme.onSurfaceVariant : scheme.error,
            ),
          ),
          if (state != null && !available)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: _reasonLine(
                context,
                state.reason ?? '刷新率控制不可用（Shizuku 未授权或被拒）',
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final level in levels)
                FilledButton.tonal(
                  key: Key('perf_refresh_set_$level'),
                  onPressed: (available && !_applying)
                      ? () => _applyRefresh(level, level, '$level Hz')
                      : null,
                  child: Text('$level Hz'),
                ),
              FilledButton.tonal(
                key: const Key('perf_refresh_set_max'),
                onPressed: (available && !_applying && levels.isNotEmpty)
                    ? () => _applyRefresh(
                          levels.last,
                          levels.last,
                          '最大 ${levels.last} Hz',
                        )
                    : null,
                child: const Text('最大'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '经 Shizuku 写 settings.min/peak_refresh_rate 并回读校验；仅改系统设置。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        // 每应用自动刷新率（WS-D）：开关 + 已配置应用列表 + 默认恢复值。
        _refreshAutoControls(context, available, levels),
      ],
    );
  }

  /// 应用一组刷新率：确认弹层（普通确认，非危险色）→ Shizuku 写入 + 回读校验。
  Future<void> _applyRefresh(int min, int peak, String label) async {
    final controller = _refreshController;
    if (controller == null) return;
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '应用屏幕刷新率？',
      message: '将把 min_refresh_rate / peak_refresh_rate 写为 $label。'
          '写入经 Shizuku 执行并回读校验，可随时改回其它档位。',
      confirmText: '确认应用',
      isDangerous: false,
    );
    if (confirmed != true || !mounted) return;

    setState(() => _applying = true);
    final result = await controller.apply(min: min, peak: peak);
    // 无论成败都回读当前值（对账，避免陈旧态）。
    final refreshed = await _readRefreshState(controller);
    if (!mounted) return;
    setState(() {
      _applying = false;
      if (refreshed != null) _refreshState = refreshed;
    });
    _report(result.ok, '屏幕刷新率', label, result.status, result.message);
  }

  Future<RefreshRateState?> _readRefreshState(
    RefreshRateController controller,
  ) async {
    try {
      return await controller.read();
    } catch (error) {
      debugPrint('[PerfControl] 刷新率回读失败: $error');
      return null;
    }
  }

  static String _refreshCurrentText(RefreshRateState? state) {
    if (state == null) return '当前：读取中…';
    if (!state.available) return '当前：不可用';
    final min = state.min == null ? '默认' : '${state.min} Hz';
    final peak = state.peak == null ? '默认' : '${state.peak} Hz';
    return '当前：min $min · peak $peak';
  }

  // ==================== 每应用自动刷新率（WS-D） ====================

  /// 读取自动刷新率配置；已启用则拉起引擎轮询（幂等）。
  Future<void> _loadRefreshAuto() async {
    if (!mounted) return;
    final store = ref.read(perfRefreshAutoStoreProvider);
    RefreshAutoConfig next;
    try {
      next = await store.load();
    } catch (error) {
      debugPrint('[PerfControl] 自动刷新率配置读取失败: $error');
      next = const RefreshAutoConfig();
    }
    if (!mounted) return;
    setState(() {
      _autoStore = store;
      _autoConfig = next;
      _autoLoading = false;
    });
    if (next.enabled) _ensureAutoDriverRunning();
  }

  /// 拉起引擎（复用既有 driver 实例；首次经工厂构造）。幂等。
  void _ensureAutoDriverRunning() {
    if (_autoDriver != null && _autoDriver!.isRunning) return;
    final RefreshAutoStore store =
        _autoStore ?? ref.read(perfRefreshAutoStoreProvider);
    final driver = _autoDriver ??
        ref.read(perfRefreshAutoDriverFactoryProvider)(
          controller: ref.read(perfRefreshRateControllerProvider),
          store: store,
        );
    _autoStore = store;
    _autoDriver = driver;
    driver.start();
  }

  /// 停止引擎轮询（保留实例，可再次启用）。
  void _stopAutoDriver() => _autoDriver?.stop();

  /// 切换「按前台自动切换」开关并持久化；启用即拉起引擎，禁用即停止。
  Future<void> _setAutoEnabled(bool enabled) async {
    final RefreshAutoStore store =
        _autoStore ?? ref.read(perfRefreshAutoStoreProvider);
    setState(() => _autoConfig = _autoConfig.copyWith(enabled: enabled));
    try {
      await store.setEnabled(enabled);
      _autoStore = store;
    } catch (error) {
      debugPrint('[PerfControl] 保存自动刷新率开关失败: $error');
    }
    if (!mounted) return;
    if (enabled) {
      _ensureAutoDriverRunning();
    } else {
      _stopAutoDriver();
    }
    setState(() {});
  }

  /// 重新读取配置（编辑 / 删除后刷新 UI）。
  Future<void> _reloadAutoConfig() async {
    final RefreshAutoStore store =
        _autoStore ?? ref.read(perfRefreshAutoStoreProvider);
    final next = await store.load();
    if (!mounted) return;
    setState(() {
      _autoStore = store;
      _autoConfig = next;
    });
  }

  /// 新增 / 编辑单个应用配置（底部弹层）。
  Future<void> _editAutoEntry(
    RefreshAutoEntry? existing,
    List<int> levels,
  ) async {
    final store = _autoStore;
    if (store == null) return;
    final entry = await AppSheet.showCustom<RefreshAutoEntry>(
      context: context,
      builder: (sheetContext) => _AutoEntrySheet(
        levels: levels,
        existing: existing,
      ),
      isDismissible: true,
      enableDrag: true,
    );
    if (entry == null || !mounted) return;
    try {
      await store.upsert(entry);
    } catch (error) {
      debugPrint('[PerfControl] 保存应用刷新率配置失败: $error');
    }
    await _reloadAutoConfig();
  }

  /// 删除单个应用配置（危险确认）。
  Future<void> _deleteAutoEntry(RefreshAutoEntry entry) async {
    final store = _autoStore;
    if (store == null) return;
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '删除应用配置？',
      message: '将移除「${entry.label}」的自动刷新率配置'
          '（min ${entry.min} Hz · peak ${entry.peak} Hz）。',
      confirmText: '删除',
      isDangerous: true,
    );
    if (confirmed != true || !mounted) return;
    try {
      await store.remove(entry.package);
    } catch (error) {
      debugPrint('[PerfControl] 删除应用刷新率配置失败: $error');
    }
    await _reloadAutoConfig();
  }

  /// 编辑默认恢复值（底部弹层）。
  Future<void> _editAutoDefaults(List<int> levels) async {
    final store = _autoStore;
    if (store == null) return;
    final result = await AppSheet.showCustom<({int? min, int? peak})>(
      context: context,
      builder: (sheetContext) => _AutoDefaultsSheet(
        levels: levels,
        initialMin: _autoConfig.defaultMin,
        initialPeak: _autoConfig.defaultPeak,
      ),
      isDismissible: true,
      enableDrag: true,
    );
    if (result == null || !mounted) return;
    try {
      await store.setDefaults(min: result.min, peak: result.peak);
    } catch (error) {
      debugPrint('[PerfControl] 保存默认刷新率失败: $error');
    }
    await _reloadAutoConfig();
  }

  /// 「按前台自动切换」控件组（开关 + 已配置应用列表 + 默认恢复值）。
  Widget _refreshAutoControls(
    BuildContext context,
    bool available,
    List<int> levels,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = _autoConfig.entries.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return Column(
      key: const Key('perf_refresh_auto_group'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: AppSpacing.xl, color: scheme.outlineVariant),
        SwitchListTile(
          key: const Key('perf_refresh_auto_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('按前台自动切换刷新率'),
          subtitle: Text(
            _autoConfig.enabled ? '已启用（前台变化时自动应用 / 恢复）' : '已关闭',
          ),
          value: _autoConfig.enabled,
          onChanged: (available && !_autoLoading) ? _setAutoEnabled : null,
        ),
        if (!available)
          _reasonLine(context, '自动刷新率不可用（Shizuku 未授权或被拒）'),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Expanded(
              child: Text(
                '已配置应用',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
            ),
            TextButton.icon(
              key: const Key('perf_refresh_auto_add'),
              onPressed: (available && !_autoLoading)
                  ? () => _editAutoEntry(null, levels)
                  : null,
              icon: const Icon(TablerIcons.plus, size: AppTypography.iconSM),
              label: Text(entries.isEmpty ? '添加' : '添加 / 变更'),
            ),
          ],
        ),
        if (_autoLoading)
          const Row(
            children: [
              AppLoading(size: AppLoadingSize.small),
              SizedBox(width: AppSpacing.md),
              Expanded(child: Text('正在读取自动刷新率配置…')),
            ],
          )
        else
          Column(
            key: const Key('perf_refresh_auto_list'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entries.isEmpty)
                Text(
                  '尚未配置任何应用。前台进入已配置应用时自动应用其 min/peak，'
                  '离开时恢复默认。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                )
              else
                for (final entry in entries) _autoEntryRow(
                  context,
                  entry,
                  available,
                  levels,
                ),
            ],
          ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Expanded(
              child: Text(
                _autoDefaultsText(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton.icon(
              key: const Key('perf_refresh_auto_default'),
              onPressed: (available && !_autoLoading)
                  ? () => _editAutoDefaults(levels)
                  : null,
              icon: const Icon(TablerIcons.settings, size: AppTypography.iconSM),
              label: const Text('默认恢复值'),
            ),
          ],
        ),
        Text(
          '自动切换仅经 Shizuku 写 settings.min/peak_refresh_rate；'
          '关闭开关即停止轮询，不改变当前刷新率。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _autoEntryRow(
    BuildContext context,
    RefreshAutoEntry entry,
    bool available,
    List<int> levels,
  ) {
    final theme = Theme.of(context);
    return ListTile(
      key: Key('perf_refresh_auto_item_${entry.package}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(entry.label, style: theme.textTheme.bodyMedium),
      subtitle: Text(
        '${entry.package} · min ${entry.min} Hz · peak ${entry.peak} Hz',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('perf_refresh_auto_edit_${entry.package}'),
            icon: const Icon(TablerIcons.edit, size: AppTypography.iconSM),
            tooltip: '编辑',
            onPressed: available
                ? () => _editAutoEntry(entry, levels)
                : null,
          ),
          IconButton(
            key: Key('perf_refresh_auto_delete_${entry.package}'),
            icon: const Icon(TablerIcons.trash, size: AppTypography.iconSM),
            tooltip: '删除',
            onPressed: available
                ? () => _deleteAutoEntry(entry)
                : null,
          ),
        ],
      ),
    );
  }

  String _autoDefaultsText() {
    final min = _autoConfig.defaultMin;
    final peak = _autoConfig.defaultPeak;
    if (min == null || peak == null) {
      return '默认恢复值：未设置（离开已配置应用时不改变刷新率）';
    }
    return '默认恢复值：min $min Hz · peak $peak Hz';
  }

  // ==================== 通用 ====================

  Future<void> _refresh() async {
    if (_applying) return;
    await _load(refresh: true);
    await _loadRefresh();
  }

  void _report(
    bool ok,
    String label,
    String target,
    String status,
    String? detail,
  ) {
    if (ok) {
      AppDialogs.showSuccess('$label 已应用（$target）');
    } else {
      AppDialogs.showError(
        '$label 应用失败（$target）：$status'
        '${detail == null || detail.isEmpty ? '' : ' · $detail'}',
      );
    }
  }

  String _capabilitySummary(PerfControlCapabilities caps) {
    final available = <String>[];
    final disabled = <String>[];
    for (final category in PerfControlCategory.values) {
      if (category == PerfControlCategory.binderLevers) continue;
      (caps.isCategoryAvailable(category) ? available : disabled)
          .add(_categoryLabel(category));
    }
    final parts = <String>[];
    if (available.isNotEmpty) parts.add('可用：${available.join('、')}');
    if (disabled.isNotEmpty) {
      parts.add('不可用：${disabled.join('、')}（探测 fail-closed 已禁用）');
    }
    return '控制能力：${parts.isEmpty ? '无' : parts.join(' · ')}';
  }

  Widget _notice(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: AppSpacing.horizontalMD_verticalSM,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.allSM,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _reasonLine(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          TablerIcons.alert_triangle,
          size: AppTypography.iconSM,
          color: theme.colorScheme.error,
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }

  Widget _dropdown<T>({
    required Key key,
    required String label,
    required T? initialValue,
    required List<T> items,
    required String Function(T value) itemLabel,
    required ValueChanged<T?>? onChanged,
  }) {
    final T? value = (initialValue != null && items.contains(initialValue))
        ? initialValue
        : null;
    return DropdownButtonFormField<T>(
      key: key,
      initialValue: value,
      isDense: true,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final item in items)
          DropdownMenuItem<T>(
            value: item,
            child: Text(itemLabel(item), overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }

  static String _categoryLabel(PerfControlCategory category) =>
      switch (category) {
        PerfControlCategory.cpu => 'CPU',
        PerfControlCategory.gpu => 'GPU',
        PerfControlCategory.cpuset => 'cpuset',
        PerfControlCategory.thermal => '热控',
        PerfControlCategory.binderLevers => 'Binder 杠杆',
      };

  static double? _pickFreq(
    List<double> options,
    double? preferred, {
    bool last = false,
  }) {
    if (options.isEmpty) return preferred;
    if (preferred != null &&
        options.any((f) => (f - preferred).abs() < 1e-6)) {
      return preferred;
    }
    return last ? options.last : options.first;
  }

  static String _cpusLabel(List<int> cpus) {
    if (cpus.isEmpty) return '—';
    return cpus.join(',');
  }

  static String _mhz(double value) => '${value.toStringAsFixed(0)} MHz';

  static String _freqRange(double? min, double? max) {
    if (min == null && max == null) return '频率未知';
    final lo = min == null ? '—' : min.toStringAsFixed(0);
    final hi = max == null ? '—' : max.toStringAsFixed(0);
    return '$lo ~ $hi MHz';
  }
}

// ==================== 每应用自动刷新率弹层（WS-D） ====================

/// 新增 / 编辑单个应用刷新率配置的底部弹层。
///
/// 内容：包名 + 名称（可选）+ min/peak 档位选择；「保存」经 `Navigator.pop`
/// 返回 [RefreshAutoEntry]（未确认前不写 store）。自持 [TextEditingController]，
/// 随弹层路由销毁而释放（避免 pop 动画期间 use-after-dispose）。
class _AutoEntrySheet extends StatefulWidget {
  const _AutoEntrySheet({required this.levels, this.existing});

  final List<int> levels;
  final RefreshAutoEntry? existing;

  @override
  State<_AutoEntrySheet> createState() => _AutoEntrySheetState();
}

class _AutoEntrySheetState extends State<_AutoEntrySheet> {
  late final TextEditingController _packageController;
  late final TextEditingController _labelController;
  late int _min;
  late int _peak;

  List<int> get _levels =>
      widget.levels.isEmpty ? RefreshRateController.fallbackLevels : widget.levels;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _packageController = TextEditingController(text: existing?.package ?? '');
    _labelController = TextEditingController(text: existing?.label ?? '');
    final levels = _levels;
    _min = _normalize(existing?.min, levels, last: false);
    _peak = _normalize(existing?.peak, levels, last: true);
  }

  @override
  void dispose() {
    _packageController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  /// 把值归一到档位集合内（不在集合中则取首 / 末档）。
  static int _normalize(int? value, List<int> levels, {required bool last}) {
    if (value != null && levels.contains(value)) return value;
    if (levels.isEmpty) return value ?? RefreshRateController.minHz;
    return last ? levels.last : levels.first;
  }

  void _save() {
    final pkg = _packageController.text.trim();
    if (pkg.isEmpty) {
      AppDialogs.showError('请输入包名');
      return;
    }
    final label = _labelController.text.trim();
    Navigator.of(context).pop(
      RefreshAutoEntry(
        package: pkg,
        label: label.isEmpty ? pkg : label,
        min: _min,
        peak: _peak,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final levels = _levels;
    final theme = Theme.of(context);
    return AppSheetScaffold(
      title: widget.existing == null ? '添加自动刷新率应用' : '编辑自动刷新率应用',
      subtitle: '前台进入该应用时应用此 min/peak（Hz）。',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('perf_refresh_auto_pkg_field'),
            controller: _packageController,
            enabled: widget.existing == null,
            textInputAction: TextInputAction.next,
            style: theme.textTheme.bodyMedium,
            decoration: const InputDecoration(
              labelText: '包名',
              hintText: 'com.example.app',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            key: const Key('perf_refresh_auto_label_field'),
            controller: _labelController,
            textInputAction: TextInputAction.done,
            style: theme.textTheme.bodyMedium,
            decoration: const InputDecoration(
              labelText: '名称（可选，缺省用包名）',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _levelDropdown(
                  key: const Key('perf_refresh_auto_min'),
                  label: 'min（Hz）',
                  levels: levels,
                  value: _min,
                  onChanged: (value) {
                    if (value != null) setState(() => _min = value);
                  },
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _levelDropdown(
                  key: const Key('perf_refresh_auto_peak'),
                  label: 'peak（Hz）',
                  levels: levels,
                  value: _peak,
                  onChanged: (value) {
                    if (value != null) setState(() => _peak = value);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('perf_refresh_auto_save'),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 编辑「默认恢复值」的底部弹层（`null` = 不恢复，保持现状）。
class _AutoDefaultsSheet extends StatefulWidget {
  const _AutoDefaultsSheet({
    required this.levels,
    this.initialMin,
    this.initialPeak,
  });

  final List<int> levels;
  final int? initialMin;
  final int? initialPeak;

  @override
  State<_AutoDefaultsSheet> createState() => _AutoDefaultsSheetState();
}

class _AutoDefaultsSheetState extends State<_AutoDefaultsSheet> {
  int? _min;
  int? _peak;

  List<int> get _levels =>
      widget.levels.isEmpty ? RefreshRateController.fallbackLevels : widget.levels;

  @override
  void initState() {
    super.initState();
    _min = widget.initialMin;
    _peak = widget.initialPeak;
  }

  void _save() {
    final min = _min;
    final peak = _peak;
    if ((min == null) != (peak == null)) {
      AppDialogs.showError('min 与 peak 需同时设置或同时留空（不恢复）');
      return;
    }
    if (min != null && peak != null && min > peak) {
      AppDialogs.showError('min 不能大于 peak');
      return;
    }
    Navigator.of(context).pop((min: min, peak: peak));
  }

  @override
  Widget build(BuildContext context) {
    final levels = _levels;
    return AppSheetScaffold(
      title: '默认恢复值',
      subtitle: '离开已配置应用 / 前台无配置时恢复到的 min/peak（Hz）。'
          '留空则不改变刷新率。',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _levelDropdown(
                  key: const Key('perf_refresh_auto_default_min'),
                  label: 'min（Hz）',
                  levels: levels,
                  value: _min,
                  allowNull: true,
                  onChanged: (value) => setState(() => _min = value),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _levelDropdown(
                  key: const Key('perf_refresh_auto_default_peak'),
                  label: 'peak（Hz）',
                  levels: levels,
                  value: _peak,
                  allowNull: true,
                  onChanged: (value) => setState(() => _peak = value),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('perf_refresh_auto_default_save'),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 档位下拉（复用 [RefreshRateController] 的可用档位；`allowNull` 时提供「不恢复」）。
Widget _levelDropdown({
  required Key key,
  required String label,
  required List<int> levels,
  required int? value,
  required ValueChanged<int?> onChanged,
  bool allowNull = false,
}) {
  final options = <int?>[if (allowNull) null, ...levels];
  final effective = options.contains(value) ? value : null;
  return DropdownButtonFormField<int?>(
    key: key,
    initialValue: effective,
    isDense: true,
    decoration: InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
    ),
    items: [
      for (final option in options)
        DropdownMenuItem<int?>(
          value: option,
          child: Text(option == null ? '不恢复' : '$option Hz'),
        ),
    ],
    onChanged: onChanged,
  );
}
