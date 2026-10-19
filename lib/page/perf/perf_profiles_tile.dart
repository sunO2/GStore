import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';

/// 控制能力加载器（返回 `null` = 尚未探测 → 不阻断开关，引擎侧 fail-closed）。
typedef PerfProfilesCapabilityLoader = Future<PerfControlCapabilities?> Function();

/// 读取「按应用性能模式」总开关（测试注入；生产走 [ConfigStore]）。
typedef PerfProfilesBoolReader = Future<bool?> Function();

/// 写入「按应用性能模式」总开关（测试注入；返回是否写入成功）。
typedef PerfProfilesBoolWriter = Future<bool> Function(bool value);

/// 每应用性能档案设置 Tile：全局「按应用性能模式」开关 + 进入档案编辑页。
///
/// 从设置页「模块」区块迁出，现嵌入性能页「概览」tab 底部。
///
/// 行为约束：
/// * 全局开关默认 **OFF**，持久化于配置键 `ConfigKeys.perfProfilesEnabled`
///   （`perf.profiles.enabled`），被自动应用引擎（todo 24）/ 接线（todo 30）消费；
/// * 开启前必须经危险/说明确认弹层（[AppDialogs.showConfirmSheet]），**绝不静默开启**；
/// * 显式探测到设备**无任何可用控制能力**时，开关与入口同时禁用并给出原因
///   （fail-closed）；未知（尚未探测）不阻断，由引擎侧在应用时兜底。
class PerfProfilesTile extends StatefulWidget {
  const PerfProfilesTile({
    super.key,
    this.capabilities,
    this.capabilityLoader,
    this.enabledReader,
    this.enabledWriter,
    this.openProfiles,
  });

  /// 已探测控制能力；显式传入且所有类别均不可用 → 禁用并给出原因。
  final PerfControlCapabilities? capabilities;

  /// 异步能力加载器（可选）；失败 / 返回 `null` → 视为未知（不阻断）。
  final PerfProfilesCapabilityLoader? capabilityLoader;

  /// 开关读取（默认经 [ConfigStore] 读 [ConfigKeys.perfProfilesEnabled]）。
  final PerfProfilesBoolReader? enabledReader;

  /// 开关写入（默认经 [ConfigStore] 写 [ConfigKeys.perfProfilesEnabled]）。
  final PerfProfilesBoolWriter? enabledWriter;

  /// 打开档案编辑页（默认 go_router `push` [AppRoute.perfProfiles]；测试注入捕获）。
  final VoidCallback? openProfiles;

  @override
  State<PerfProfilesTile> createState() => _PerfProfilesTileState();
}

class _PerfProfilesTileState extends State<PerfProfilesTile> {
  bool _enabled = false;
  bool _loaded = false;
  bool _busy = false;
  PerfControlCapabilities? _capabilities;

  @override
  void initState() {
    super.initState();
    _capabilities = widget.capabilities;
    _loadEnabled();
    _loadCapabilities();
  }

  Future<bool?> _readEnabled() =>
      ConfigStore.instance.readBool(ConfigKeys.perfProfilesEnabled);

  Future<bool> _writeEnabled(bool value) =>
      ConfigStore.instance.write(ConfigKeys.perfProfilesEnabled, value);

  Future<void> _loadEnabled() async {
    var value = false;
    try {
      final raw = await (widget.enabledReader ?? _readEnabled)();
      value = raw ?? false;
    } catch (e) {
      debugPrint('PerfProfilesTile: 读取按应用性能模式开关失败 - $e');
    }
    if (!mounted) return;
    setState(() {
      _enabled = value;
      _loaded = true;
    });
  }

  Future<void> _loadCapabilities() async {
    final loader = widget.capabilityLoader;
    if (loader == null) return;
    PerfControlCapabilities? caps;
    try {
      caps = await loader();
    } catch (e) {
      debugPrint('PerfProfilesTile: 能力探测失败（视为未知）- $e');
    }
    if (!mounted || caps == null) return;
    setState(() => _capabilities = caps);
  }

  /// 是否有任一可用控制能力；`null` 能力视为未知（不阻断）。
  bool get _blocked {
    final caps = _capabilities;
    if (caps == null) return false;
    return !PerfControlCategory.values.any(caps.isCategoryAvailable);
  }

  Future<void> _toggle(bool value) async {
    if (_busy || _blocked) return;
    if (value) {
      final confirmed = await AppDialogs.showConfirmSheet(
        title: '开启按应用性能模式',
        message: '开启后，前台应用切换时将自动对该应用应用其已启用的性能档案'
            '（CPU / GPU / cpuset / 散热等），离开前台或关闭开关时恢复。'
            '这会修改系统性能参数，可能导致发热或耗电变化，请确认了解风险。',
        confirmText: '开启',
        isDangerous: true,
      );
      // 未确认 → 保持关闭，绝不静默开启。
      if (confirmed != true || !mounted) return;
    }
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await (widget.enabledWriter ?? _writeEnabled)(value);
    } catch (e) {
      debugPrint('PerfProfilesTile: 写入按应用性能模式开关失败 - $e');
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _enabled = value;
    });
    if (!ok) {
      AppDialogs.showError('保存「按应用性能模式」开关失败，请重试');
    }
  }

  void _openProfiles() {
    final custom = widget.openProfiles;
    if (custom != null) {
      custom();
      return;
    }
    try {
      context.push(AppRoute.perfProfiles);
    } catch (e) {
      debugPrint('PerfProfilesTile: 打开档案编辑页失败 - $e');
      AppDialogs.showError('档案编辑页暂不可用（路由未就绪）');
    }
  }

  String _subtitle(bool blocked) {
    if (blocked) {
      return '当前设备无可用性能控制能力（需 Shizuku 授权且控制节点可写），已禁用';
    }
    if (_enabled) return '已开启 · 前台应用切换时自动应用其性能档案';
    return '默认关闭 · 开启前需确认风险';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = _blocked;

    final switchTile = SwitchListTile(
      key: const Key('perf_profiles_switch'),
      secondary: Icon(
        TablerIcons.gauge,
        size: AppTypography.iconMD,
        color: blocked ? scheme.onSurfaceVariant : scheme.primary,
      ),
      title: const Text('按应用性能模式'),
      subtitle: Text(_subtitle(blocked)),
      value: _enabled,
      onChanged: (!_loaded || _busy || blocked) ? null : _toggle,
    );

    final entryTile = ListTile(
      key: const Key('perf_profiles_entry'),
      enabled: !blocked,
      leading: Icon(
        TablerIcons.adjustments,
        size: AppTypography.iconMD,
        color: scheme.onSurfaceVariant,
      ),
      title: const Text('每应用性能档案'),
      subtitle: Text(
        blocked ? '设备无可用控制能力，暂不可编辑' : '为单个应用配置 CPU / GPU / cpuset / 散热',
      ),
      trailing:
          const Icon(TablerIcons.chevron_right, size: AppTypography.iconSM),
      onTap: blocked ? null : _openProfiles,
    );

    return Column(
      children: [switchTile, entryTile],
    );
  }
}
