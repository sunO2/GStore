/// 按应用性能档案编辑器页（plan todo 25）。
///
/// 职责：
/// * 列出已配置的每应用性能档案（[PerfProfileStore.loadAll]）并支持新增 / 编辑 /
///   删除（加载体面，删除走 [AppDialogs.showConfirmSheet] 危险确认）；
/// * 新增 / 编辑时**惰性**拉取已安装应用（[ThirdPartyPerfService.listInstalledApps]）
///   与设备可调项（[TunablesReport]）+ 能力探测结果（[PerfControlCapabilities]）
///   —— **绝不在 `initState` 触达 `installed_apps` / Shizuku / FFI 通道**
///   （无宿主的 widget 测试会挂起）；
/// * 按能力探测（todo 15）**fail-closed** 禁用不可用控件，并给出可见原因；
/// * 频率等取值必须落在 `perf.tunables` 暴露的可用列表内，否则**就地**拒绝保存。
///
/// 弹层一律走统一骨架（[AppSheet] / [AppDialogs]），**禁止**
/// `Get.defaultDialog` / `showDialog` / 裸 `showModalBottomSheet`。
/// 颜色 / 文字走 [Theme] 令牌，间距 / 圆角走设计令牌（AGENTS.md）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/perf_profile.dart';
import 'package:gstore/core/perf/perf_profile_store.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 设备可调项加载器（生产经 `PerfModule.instance.tunables`；测试注入罐头报告）。
typedef PerfProfilesTunablesLoader = Future<TunablesReport> Function();

/// 控制能力探测器（基于已加载的 tunables；测试注入罐头能力图）。
typedef PerfProfilesCapabilitiesLoader = Future<PerfControlCapabilities?>
    Function(TunablesReport tunables);

/// 按应用性能档案编辑器页面（可注入 store / service / 加载器，便于测试）。
class PerfProfilesPage extends StatefulWidget {
  const PerfProfilesPage({
    super.key,
    this.store,
    this.service,
    this.tunablesLoader,
    this.capabilitiesLoader,
  });

  /// 档案持久化存储；`null` 时用 [ConfigPerfProfileStore]（配置键 `perf.profiles`）。
  final PerfProfileStore? store;

  /// 已安装应用来源；`null` 时用生产 [ThirdPartyPerfService]（惰性调用）。
  final ThirdPartyPerfService? service;

  /// 设备可调项加载器；`null` 时用生产 `PerfModule.instance.tunables`。
  final PerfProfilesTunablesLoader? tunablesLoader;

  /// 控制能力加载器；`null` 时用 [PerfCapabilityProbe]（经 privileged shell）。
  final PerfProfilesCapabilitiesLoader? capabilitiesLoader;

  @override
  State<PerfProfilesPage> createState() => _PerfProfilesPageState();
}

class _PerfProfilesPageState extends State<PerfProfilesPage> {
  late final PerfProfileStore _store;
  late final ThirdPartyPerfService _service;
  late final PerfProfilesTunablesLoader _tunablesLoader;
  late final PerfProfilesCapabilitiesLoader _capabilitiesLoader;

  bool _loading = true;
  Map<String, PerfProfile> _profiles = <String, PerfProfile>{};

  /// 惰性加载的已安装应用（首次新增时才拉取；`initState` 绝不触达通道）。
  List<AppTarget>? _apps;
  bool _loadingApps = false;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? const ConfigPerfProfileStore();
    _service = widget.service ?? ThirdPartyPerfService();
    _tunablesLoader =
        widget.tunablesLoader ?? (() => PerfModule.instance.tunables());
    _capabilitiesLoader = widget.capabilitiesLoader ?? _probeCapabilities;
    _reload();
  }

  /// 生产能力探测：以已加载的 tunables 推导候选节点后 fail-closed 探测。
  Future<PerfControlCapabilities?> _probeCapabilities(
    TunablesReport tunables,
  ) {
    final probe = PerfCapabilityProbe(shell: PrivilegedShell());
    return probe.probe(tunables);
  }

  Future<void> _reload() async {
    if (mounted) setState(() => _loading = true);
    final profiles = await _store.loadAll();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _loading = false;
    });
  }

  /// 惰性加载已安装应用（仅用户显式触发；避免 widget 测试挂起在缺失通道上）。
  Future<void> _ensureApps() async {
    if (_apps != null || _loadingApps) return;
    setState(() => _loadingApps = true);
    var loaded = const <AppTarget>[];
    try {
      loaded = await _service.listInstalledApps();
    } catch (error) {
      debugPrint('[PerfProfiles] 加载已安装应用失败（按空列表处理）: $error');
    }
    if (!mounted) return;
    setState(() {
      _apps = loaded;
      _loadingApps = false;
    });
  }

  String _labelFor(String package) {
    final apps = _apps;
    if (apps != null) {
      for (final app in apps) {
        if (app.package == package) return app.label;
      }
    }
    return package;
  }

  // ==================== 动作 ====================

  Future<void> _onAdd() async {
    await _ensureApps();
    if (!mounted) return;
    final selected = await AppSheet.showCustom<AppTarget>(
      context: context,
      builder: (_) => _AppPickerSheet(apps: _apps ?? const <AppTarget>[]),
    );
    if (selected == null || !mounted) return;
    await _openEditor(
      package: selected.package,
      label: selected.label,
      existing: _profiles[selected.package],
    );
  }

  Future<void> _onEdit(PerfProfile profile) async {
    await _ensureApps();
    if (!mounted) return;
    await _openEditor(
      package: profile.package,
      label: _labelFor(profile.package),
      existing: profile,
    );
  }

  /// 打开编辑器：先惰性加载设备可调项 + 能力探测（失败一律降级为不可用），
  /// 再以统一弹层呈现；保存则写入 store 并刷新列表。任何失败绝不抛出。
  Future<void> _openEditor({
    required String package,
    required String label,
    PerfProfile? existing,
  }) async {
    TunablesReport? tunables;
    try {
      tunables = await _tunablesLoader();
    } catch (error) {
      debugPrint('[PerfProfiles] 加载设备可调项失败（按不可用处理）: $error');
    }

    PerfControlCapabilities? capabilities;
    if (tunables != null) {
      try {
        capabilities = await _capabilitiesLoader(tunables);
      } catch (error) {
        debugPrint('[PerfProfiles] 能力探测失败（fail-closed）: $error');
      }
    }
    if (!mounted) return;

    final result = await AppSheet.showCustom<PerfProfile>(
      context: context,
      builder: (_) => _PerfProfileEditorSheet(
        package: package,
        label: label,
        initial: existing ?? PerfProfile(package: package),
        tunables: tunables,
        capabilities: capabilities,
      ),
    );
    if (result == null || !mounted) return;

    final ok = await _store.save(result);
    if (!mounted) return;
    if (!ok) AppDialogs.showError('保存失败，请重试');
    await _reload();
  }

  Future<void> _onToggleEnabled(PerfProfile profile, bool value) async {
    final ok = await _store.save(profile.copyWith(enabled: value));
    if (!mounted) return;
    if (!ok) AppDialogs.showError('保存失败，请重试');
    await _reload();
  }

  Future<void> _onDelete(PerfProfile profile) async {
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '删除性能档案？',
      message: '将删除「${_labelFor(profile.package)}」的按应用性能档案，此操作无法撤销。',
      confirmText: '删除',
      cancelText: '取消',
      isDangerous: true,
      icon: const Icon(TablerIcons.trash),
    );
    if (confirmed != true || !mounted) return;
    final ok = await _store.remove(profile.package);
    if (!mounted) return;
    if (!ok) AppDialogs.showError('删除失败，请重试');
    await _reload();
  }

  // ==================== 视图 ====================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profiles = _profiles.values.toList()
      ..sort((a, b) => a.package.compareTo(b.package));
    return Scaffold(
      appBar: AppBar(title: const Text('按应用性能档案')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('perf_profiles_add'),
        onPressed: _loadingApps ? null : _onAdd,
        icon: _loadingApps
            ? const AppLoading(size: AppLoadingSize.small)
            : const Icon(TablerIcons.plus, size: AppTypography.iconMD),
        label: const Text('新增档案'),
      ),
      body: _loading
          ? const Center(child: AppLoading())
          : profiles.isEmpty
              ? _emptyState(context, theme)
              : ListView(
                  padding: AppSpacing.allLG,
                  children: [
                    for (final profile in profiles) ...[
                      _profileTile(context, theme, profile),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    const SizedBox(height: AppSpacing.massive),
                  ],
                ),
    );
  }

  Widget _emptyState(BuildContext context, ThemeData theme) {
    return Center(
      child: Padding(
        padding: AppSpacing.allXXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              TablerIcons.apps,
              size: AppTypography.iconGiant,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '尚未配置按应用性能档案',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '为某个应用保存一组 CPU / GPU / cpuset / thermal 覆盖，'
              '进入该应用前台时自动应用。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _profileTile(
    BuildContext context,
    ThemeData theme,
    PerfProfile profile,
  ) {
    final scheme = theme.colorScheme;
    final clusters = profile.cpuClusters.length;
    final parts = <String>[
      if (clusters > 0) '$clusters 簇',
      if (profile.gpuLevel != null) 'GPU ${profile.gpuLevel}',
      if (profile.cpuset != null) 'cpuset ${profile.cpuset}',
      if (profile.thermalEnabled != null)
        profile.thermalEnabled! ? '散热开' : '散热关',
    ];
    final summary = parts.isEmpty ? '未配置覆盖项' : parts.join(' · ');
    return Card(
      child: ListTile(
        key: Key('perf_profile_tile_${profile.package}'),
        onTap: () => _onEdit(profile),
        leading: Icon(
          TablerIcons.apps,
          size: AppTypography.iconXL,
          color: scheme.primary,
        ),
        title: Text(
          _labelFor(profile.package),
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: AppTypography.weightSemiBold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              profile.package,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              summary,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              key: Key('perf_profile_enabled_${profile.package}'),
              value: profile.enabled,
              onChanged: (value) => _onToggleEnabled(profile, value),
            ),
            IconButton(
              key: Key('perf_profile_edit_${profile.package}'),
              tooltip: '编辑',
              onPressed: () => _onEdit(profile),
              icon: const Icon(
                TablerIcons.edit,
                size: AppTypography.iconMD,
              ),
            ),
            IconButton(
              key: Key('perf_profile_delete_${profile.package}'),
              tooltip: '删除',
              onPressed: () => _onDelete(profile),
              icon: const Icon(
                TablerIcons.trash,
                size: AppTypography.iconMD,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 应用选择弹层 ====================

/// 可搜索的应用选择弹层（经 [AppSheet.showCustom] 呈现的 [AppSheetScaffold]）。
///
/// 与 `third_party_section.dart` 的同类弹层一致：`ListTile` 需要就近 `Material`
/// 才能绘制水波纹（否则框架告警「ink splashes may be invisible」）。
class _AppPickerSheet extends StatefulWidget {
  const _AppPickerSheet({required this.apps});

  final List<AppTarget> apps;

  @override
  State<_AppPickerSheet> createState() => _AppPickerSheetState();
}

class _AppPickerSheetState extends State<_AppPickerSheet> {
  String _keyword = '';

  List<AppTarget> get _filtered {
    if (_keyword.isEmpty) return widget.apps;
    final kw = _keyword.toLowerCase();
    return widget.apps
        .where(
          (app) =>
              app.label.toLowerCase().contains(kw) ||
              app.package.toLowerCase().contains(kw),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final apps = _filtered;
    return AppSheetScaffold(
      title: '选择应用',
      subtitle: '共 ${widget.apps.length} 个已安装应用',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('perf_profile_picker_search'),
            autofocus: false,
            onChanged: (value) => setState(() => _keyword = value),
            decoration: const InputDecoration(
              hintText: '搜索应用名或包名…',
              prefixIcon: Icon(TablerIcons.search),
              isDense: true,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (widget.apps.isEmpty)
            Padding(
              padding: AppSpacing.allLG,
              child: Text(
                '未找到已安装应用',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: apps.length,
                itemBuilder: (context, index) {
                  final app = apps[index];
                  return ListTile(
                    key: Key('perf_profile_picker_item_${app.package}'),
                    dense: true,
                    leading: Icon(
                      app.isSystem
                          ? TablerIcons.brand_android
                          : TablerIcons.apps,
                      size: AppTypography.iconMD,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      app.label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    subtitle: Text(
                      app.package,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    onTap: () => Navigator.of(context).pop<AppTarget>(app),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ==================== 档案编辑弹层 ====================

/// 单档案编辑弹层：能力不可用的控件一律 [onChanged]/`enabled` 置空（fail-closed），
/// 频率取值必须命中 `perf.tunables` 的可用列表，否则**就地**报错不关闭。
class _PerfProfileEditorSheet extends StatefulWidget {
  const _PerfProfileEditorSheet({
    required this.package,
    required this.label,
    required this.initial,
    required this.tunables,
    required this.capabilities,
  });

  final String package;
  final String label;
  final PerfProfile initial;

  /// 设备可调项；`null` = 未加载（全部控件禁用）。
  final TunablesReport? tunables;

  /// 能力探测结果；`null` = 未探测 / 探测失败（全部控件禁用）。
  final PerfControlCapabilities? capabilities;

  @override
  State<_PerfProfileEditorSheet> createState() =>
      _PerfProfileEditorSheetState();
}

class _PerfProfileEditorSheetState extends State<_PerfProfileEditorSheet> {
  late bool _enabled;
  late bool _thermal;

  /// 每个 CPU 簇的编辑态（governor / 最低 / 最高频率文本）。
  final Map<String, String?> _governors = <String, String?>{};
  final Map<String, TextEditingController> _minControllers =
      <String, TextEditingController>{};
  final Map<String, TextEditingController> _maxControllers =
      <String, TextEditingController>{};

  late final TextEditingController _gpuController;
  String? _cpuset;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _enabled = initial.enabled;
    _thermal = initial.thermalEnabled ?? true;
    for (final cluster in widget.tunables?.cpuClusters ?? const <PerfCpuCluster>[]) {
      final saved = initial.cpuClusters[cluster.policy];
      _governors[cluster.policy] = saved?.governor;
      _minControllers[cluster.policy] = TextEditingController(
        text: _formatNumber(saved?.minFreqMhz),
      );
      _maxControllers[cluster.policy] = TextEditingController(
        text: _formatNumber(saved?.maxFreqMhz),
      );
    }
    _gpuController = TextEditingController(
      text: initial.gpuLevel?.toString() ?? '',
    );
    _cpuset = initial.cpuset;
  }

  @override
  void dispose() {
    for (final controller in _minControllers.values) {
      controller.dispose();
    }
    for (final controller in _maxControllers.values) {
      controller.dispose();
    }
    _gpuController.dispose();
    super.dispose();
  }

  // ---- 能力门禁（fail-closed：只有显式 true 才可用） ----

  bool _cpuNode(String policy, String leaf) =>
      widget.capabilities?.isNodeAvailable(
        '/sys/devices/system/cpu/cpufreq/$policy/$leaf',
      ) ??
      false;

  bool _category(PerfControlCategory category) =>
      widget.capabilities?.isCategoryAvailable(category) ?? false;

  bool get _gpuAvailable =>
      _category(PerfControlCategory.gpu) &&
      widget.tunables != null &&
      (widget.tunables!.gpu.availableFrequenciesMhz.isNotEmpty ||
          widget.tunables!.gpu.powerLevels != null);

  bool get _cpusetAvailable =>
      _category(PerfControlCategory.cpuset) &&
      (widget.tunables?.cpusets.isNotEmpty ?? false);

  bool get _thermalAvailable => _category(PerfControlCategory.thermal);

  static String? _formatNumber(double? value) {
    if (value == null || !value.isFinite) return null;
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }

  // ==================== 保存 / 校验 ====================

  void _submit() {
    final tunables = widget.tunables;
    final clusters = <String, PerfCpuClusterProfile>{};

    if (tunables != null) {
      for (final cluster in tunables.cpuClusters) {
        final policy = cluster.policy;
        final governor = _governors[policy];
        final minText = _minControllers[policy]?.text.trim() ?? '';
        final maxText = _maxControllers[policy]?.text.trim() ?? '';

        final minFreq = _parseFreq(minText);
        final maxFreq = _parseFreq(maxText);

        if ((minFreq != null && !_isAvailableFreq(cluster, minFreq)) ||
            (maxFreq != null && !_isAvailableFreq(cluster, maxFreq))) {
          _fail('频率必须来自可用列表（${_availableFreqText(cluster)}）');
          return;
        }
        if (minFreq != null && maxFreq != null && minFreq > maxFreq) {
          _fail('最低频率不能高于最高频率');
          return;
        }
        if ((minText.isNotEmpty && minFreq == null) ||
            (maxText.isNotEmpty && maxFreq == null)) {
          _fail('频率需为有效数字（MHz）');
          return;
        }

        final profile = PerfCpuClusterProfile(
          governor: governor,
          minFreqMhz: minFreq,
          maxFreqMhz: maxFreq,
        );
        if (!profile.isEmpty) clusters[policy] = profile;
      }
    }

    int? gpuLevel;
    final gpuText = _gpuController.text.trim();
    if (gpuText.isNotEmpty) {
      gpuLevel = int.tryParse(gpuText);
      if (gpuLevel == null || gpuLevel < 0) {
        _fail('GPU 档位需为非负整数');
        return;
      }
    }

    Navigator.of(context).pop<PerfProfile>(
      PerfProfile(
        package: widget.package,
        enabled: _enabled,
        cpuClusters: clusters,
        gpuLevel: gpuLevel,
        cpuset: _cpuset,
        thermalEnabled: _thermalAvailable ? _thermal : widget.initial.thermalEnabled,
      ),
    );
  }

  double? _parseFreq(String text) {
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null || !value.isFinite || value < 0) return null;
    return value;
  }

  bool _isAvailableFreq(PerfCpuCluster cluster, double value) {
    final available = cluster.availableFrequenciesMhz;
    if (available.isEmpty) return true;
    return available.any((freq) => (freq - value).abs() < 0.5);
  }

  String _availableFreqText(PerfCpuCluster cluster) {
    final available = cluster.availableFrequenciesMhz;
    if (available.isEmpty) return '任意值';
    return available.map(_formatNumber).join(' / ');
  }

  void _fail(String message) {
    setState(() => _error = message);
  }

  // ==================== 视图 ====================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tunables = widget.tunables;
    return AppSheetScaffold(
      title: '编辑性能档案',
      subtitle: '${widget.label} · ${widget.package}',
      icon: const Icon(TablerIcons.settings),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _switchRow(
            rowKey: const Key('perf_profile_editor_enabled'),
            title: '启用自动应用',
            subtitle: '进入该应用前台时自动应用此档案',
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          const Divider(height: AppSpacing.xxl),
          if (widget.capabilities == null)
            _hint(
              context,
              '控制能力未探测（Shizuku 不可用或探测失败），'
              '所有调优控件已禁用（fail-closed）。',
            ),
          if (tunables == null)
            _hint(context, '未能读取设备可调项（perf.tunables），暂无可编辑的调优项。')
          else ...[
            _sectionLabel(context, theme, 'CPU 频率 / 调度'),
            for (final cluster in tunables.cpuClusters)
              _cpuClusterBlock(context, theme, cluster),
            _sectionLabel(context, theme, 'GPU'),
            _gpuBlock(context, theme),
            _sectionLabel(context, theme, 'cpuset / 亲和'),
            _cpusetBlock(context, theme, tunables),
            _sectionLabel(context, theme, '散热'),
            _thermalBlock(context),
          ],
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              _error!,
              key: const Key('perf_profile_editor_error'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('perf_profile_editor_cancel'),
          onPressed: () => Navigator.of(context).pop<PerfProfile>(null),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('perf_profile_editor_save'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _cpuClusterBlock(
    BuildContext context,
    ThemeData theme,
    PerfCpuCluster cluster,
  ) {
    final policy = cluster.policy;
    final governorEnabled = _cpuNode(policy, 'scaling_governor');
    final minEnabled = _cpuNode(policy, 'scaling_min_freq');
    final maxEnabled = _cpuNode(policy, 'scaling_max_freq');
    final governors = cluster.availableGovernors;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            cluster.policy,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: AppTypography.weightSemiBold,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<String>(
            key: Key('perf_profile_editor_governor_$policy'),
            initialValue: _governors[policy],
            decoration: InputDecoration(
              labelText: 'governor',
              isDense: true,
              helperText: governorEnabled
                  ? null
                  : '不可用：节点不可写（Shizuku 未授权 / 不适用）',
            ),
            items: [
              for (final governor in governors)
                DropdownMenuItem<String>(
                  value: governor,
                  child: Text(governor),
                ),
            ],
            onChanged:
                governorEnabled && governors.isNotEmpty
                    ? (value) => setState(() => _governors[policy] = value)
                    : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: Key('perf_profile_editor_min_$policy'),
                  controller: _minControllers[policy],
                  enabled: minEnabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '最低频率 (MHz)',
                    isDense: true,
                    helperText: minEnabled
                        ? '可用：${_availableFreqText(cluster)}'
                        : '不可用',
                    helperMaxLines: 2,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: TextField(
                  key: Key('perf_profile_editor_max_$policy'),
                  controller: _maxControllers[policy],
                  enabled: maxEnabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '最高频率 (MHz)',
                    isDense: true,
                    helperText: maxEnabled ? '同上' : '不可用',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _gpuBlock(BuildContext context, ThemeData theme) {
    final available = _gpuAvailable;
    final powerLevels = widget.tunables?.gpu.powerLevels;
    return TextField(
      key: const Key('perf_profile_editor_gpu'),
      controller: _gpuController,
      enabled: available,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: 'GPU 功率档位',
        isDense: true,
        helperText: available
            ? (powerLevels == null ? '任意档位' : '0 – ${powerLevels - 1}')
            : '不可用：GPU 控制不可写（Shizuku 未授权 / 不适用）',
        helperMaxLines: 2,
      ),
    );
  }

  Widget _cpusetBlock(BuildContext context, ThemeData theme, TunablesReport tunables) {
    final available = _cpusetAvailable;
    final names = tunables.cpusets.map((c) => c.name).toList();
    return DropdownButtonFormField<String>(
      key: const Key('perf_profile_editor_cpuset'),
      initialValue: names.contains(_cpuset) ? _cpuset : null,
      decoration: InputDecoration(
        labelText: 'cpuset / 亲和组',
        isDense: true,
        helperText: available ? null : '不可用：cpuset 控制不可写',
      ),
      items: [
        for (final name in names)
          DropdownMenuItem<String>(value: name, child: Text(name)),
      ],
      onChanged: available && names.isNotEmpty
          ? (value) => setState(() => _cpuset = value)
          : null,
    );
  }

  Widget _thermalBlock(BuildContext context) {
    return _switchRow(
      rowKey: const Key('perf_profile_editor_thermal'),
      title: '散热启用',
      subtitle: _thermalAvailable
          ? '关闭会带来过热风险（应用时需二次确认）'
          : '不可用：thermal 控制不可写（Shizuku 未授权 / 不适用）',
      value: _thermal,
      onChanged: _thermalAvailable
          ? (value) => setState(() => _thermal = value)
          : null,
    );
  }

  Widget _switchRow({
    required Key rowKey,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.bodyMedium),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Switch(key: rowKey, value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.xs),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _hint(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
