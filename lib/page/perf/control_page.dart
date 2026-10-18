import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

import 'perf_control_actions.dart';

/// 性能「控制 / 调优」页（Riverpod）。
///
/// 独立路由页面，容纳原 `PerfMonitorPage` 模块区中的控制 / 调优卡片：
/// CPU 逐簇 governor·频率、GPU、cpuset 归属、热控开关。
/// 内部 [_ControlSection] 逐字沿用原实现，行为 / Key 不变。
class PerfControlPage extends ConsumerWidget {
  const PerfControlPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('控制 / 调优')),
      body: ListView(
        children: const [
          _ControlSection(),
        ],
      ),
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

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  @override
  void dispose() {
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
            else if (_error != null)
              Text(
                _error!,
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
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

  // ==================== 通用 ====================

  Future<void> _refresh() async {
    if (_applying) return;
    await _load(refresh: true);
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
