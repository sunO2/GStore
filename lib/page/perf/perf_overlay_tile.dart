import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/perf/perf_overlay_controller.dart';
import 'package:gstore/core/perf/perf_target_store.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';

/// 性能悬浮窗 Tile：原生前台服务叠加系统级 HUD（CPU / 内存 / 电池温度）。
///
/// 从设置页「模块」区块迁出，现嵌入性能页「概览」tab 底部。公开（非下划线）
/// 以便 widget 测试直接挂载；[controller] / [targetStore] / [service] 可注入
/// 以便测试 mock 平台通道与应用列表。开启时若未授权，先拉起系统授权页再复核，
/// 未授权则提示不启动。`监控目标` 选择第三方应用后，悬浮窗展开模式显示该应用
/// CPU / 内存（原生经 Shizuku 读取）。
class PerfOverlayTile extends StatefulWidget {
  const PerfOverlayTile({
    super.key,
    this.controller,
    this.targetStore,
    this.service,
  });

  final PerfOverlayController? controller;

  /// 监控目标持久化（默认 `SharedPrefsPerfTargetStore`）。
  final PerfTargetStore? targetStore;

  /// 已安装应用来源（默认 `ThirdPartyPerfService`）。
  final ThirdPartyPerfService? service;

  @override
  State<PerfOverlayTile> createState() => _PerfOverlayTileState();
}

class _PerfOverlayTileState extends State<PerfOverlayTile> {
  late final PerfOverlayController _controller =
      widget.controller ?? const PerfOverlayController();
  late final PerfTargetStore _targetStore =
      widget.targetStore ?? const SharedPrefsPerfTargetStore();
  late final ThirdPartyPerfService _service =
      widget.service ?? ThirdPartyPerfService();

  bool _loaded = false;
  bool _granted = false;
  bool _running = false;
  bool _busy = false;
  String _mode = PerfOverlayController.modeCompact;

  /// 当前监控目标（来自 [PerfTargetStore]，与服务端持久化一致）。
  PerfPinnedTarget? _target;

  /// 已加载的已安装应用（选择弹层数据源，首次选择时惰性加载）。
  List<AppTarget>? _apps;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadTarget();
  }

  Future<void> _refresh() async {
    final granted = await _controller.isPermissionGranted();
    final running = await _controller.isRunning();
    final mode = await _controller.getMode();
    if (!mounted) return;
    setState(() {
      _granted = granted;
      _running = running;
      _mode = mode;
      _loaded = true;
    });
  }

  Future<void> _loadTarget() async {
    final target = await _targetStore.load();
    if (!mounted) return;
    setState(() => _target = target);
  }

  Future<List<AppTarget>> _loadApps() async {
    final cached = _apps;
    if (cached != null) return cached;
    List<AppTarget> apps;
    try {
      apps = await _service.listInstalledApps();
    } catch (e) {
      debugPrint('PerfOverlayTile: 加载已安装应用失败 - $e');
      apps = const <AppTarget>[];
    }
    if (mounted) setState(() => _apps = apps);
    return apps;
  }

  /// 打开应用选择弹层：选中后持久化目标并同步原生（失败静默，不阻断 UI）。
  Future<void> _pickTarget() async {
    final apps = await _loadApps();
    if (!mounted) return;
    final selected = await AppSheet.showCustom<AppTarget>(
      context: context,
      builder: (_) => _OverlayTargetPickerSheet(apps: apps),
    );
    if (selected == null || !mounted) return;
    final pinned = PerfPinnedTarget(
      package: selected.package,
      label: selected.label,
      isSystem: selected.isSystem,
    );
    await _targetStore.save(pinned);
    await _controller.setTarget(selected.package);
    if (!mounted) return;
    setState(() => _target = pinned);
  }

  String get _subtitle {
    if (_running) return '运行中 · CPU / 内存 / 电池温度实时显示';
    if (!_granted) return '需在系统设置中授予「显示在其他应用上层」权限';
    return '以小窗实时显示 CPU / 内存 / 电池温度，可拖动';
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    AppDialogs.showLoading(message: value ? '正在启动悬浮窗...' : '正在停止悬浮窗...');

    var needPermission = false;
    String? error;
    try {
      if (value) {
        var granted = await _controller.isPermissionGranted();
        if (!granted) {
          await _controller.requestPermission();
          granted = await _controller.isPermissionGranted();
        }
        if (!granted) {
          needPermission = true;
        } else if (!await _controller.start(targetPackage: _target?.package)) {
          error = '启动悬浮窗失败，请重试';
        }
      } else {
        await _controller.stop();
      }
    } catch (e) {
      error = '操作失败: $e';
      debugPrint('PerfOverlayTile: 切换悬浮窗失败 - $e');
    } finally {
      AppDialogs.dismissLoading();
    }

    final granted = await _controller.isPermissionGranted();
    final running = await _controller.isRunning();
    if (!mounted) return;
    setState(() {
      _granted = granted;
      _running = running;
      _loaded = true;
      _busy = false;
    });

    if (needPermission) {
      await AppDialogs.showAlertSheet(
        title: '需要悬浮窗权限',
        message: '请在系统设置中允许 GStore 显示在其他应用上层，然后返回重试。',
      );
    } else if (error != null) {
      AppDialogs.showError(error);
    }
  }

  /// 切换悬浮窗显示模式（紧凑 / 展开）。乐观更新，失败回滚并提示。
  Future<void> _setMode(String mode) async {
    if (_busy || mode == _mode) return;
    final previous = _mode;
    setState(() => _mode = mode);
    if (await _controller.setMode(mode)) return;
    if (!mounted) return;
    setState(() => _mode = previous);
    AppDialogs.showError('切换悬浮窗模式失败，请重试');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final switchTile = SwitchListTile(
      key: const Key('perf_overlay_switch'),
      secondary: Icon(
        TablerIcons.device_desktop,
        size: AppTypography.iconMD,
        color: scheme.primary,
      ),
      title: const Text('悬浮窗监控'),
      subtitle: Text(_subtitle),
      value: _running,
      onChanged: _loaded && !_busy ? _toggle : null,
    );

    // 监控目标：展开模式显示的第三方应用（不选则仅显示系统指标）。
    final targetTile = ListTile(
      key: const Key('perf_overlay_target'),
      leading: Icon(
        TablerIcons.crosshair,
        size: AppTypography.iconMD,
        color: scheme.onSurfaceVariant,
      ),
      title: const Text('监控目标'),
      subtitle: Text(
        _target?.label ?? '未选择（展开模式显示所选应用 CPU / 内存）',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: TextButton(
        key: const Key('perf_overlay_target_pick'),
        onPressed: _busy ? null : _pickTarget,
        child: const Text('选择目标'),
      ),
    );

    return Column(
      children: [
        switchTile,
        if (_running) _buildModeRow(context),
        targetTile,
      ],
    );
  }

  Widget _buildModeRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '显示模式',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          AppSegmentedButton<String>(
            key: const Key('perf_overlay_mode'),
            value: _mode,
            segments: const [
              AppSegment<String>(
                value: PerfOverlayController.modeCompact,
                label: '紧凑',
                key: Key('perf_overlay_mode_compact'),
              ),
              AppSegment<String>(
                value: PerfOverlayController.modeExpanded,
                label: '展开',
                key: Key('perf_overlay_mode_expanded'),
              ),
              AppSegment<String>(
                value: PerfOverlayController.modeTarget,
                label: '目标专注',
                key: Key('perf_overlay_mode_target'),
              ),
              AppSegment<String>(
                value: PerfOverlayController.modeLive,
                label: '前台',
                key: Key('perf_overlay_mode_live'),
              ),
            ],
            onChanged: _setMode,
          ),
        ],
      ),
    );
  }
}

/// 悬浮窗监控目标的应用选择弹层（统一底部弹层骨架 [AppSheetScaffold]）。
class _OverlayTargetPickerSheet extends StatefulWidget {
  const _OverlayTargetPickerSheet({required this.apps});

  final List<AppTarget> apps;

  @override
  State<_OverlayTargetPickerSheet> createState() =>
      _OverlayTargetPickerSheetState();
}

class _OverlayTargetPickerSheetState extends State<_OverlayTargetPickerSheet> {
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
      title: '选择监控目标',
      subtitle: '共 ${widget.apps.length} 个已安装应用',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
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
            // 弹层骨架用 DecoratedBox 承载背景色，ListTile 需要就近的 Material
            // 才能正常绘制水波纹（否则框架会告警「ink splashes may be invisible」）。
            Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: apps.length,
                itemBuilder: (context, index) {
                  final app = apps[index];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      app.isSystem ? TablerIcons.brand_android : TablerIcons.apps,
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
