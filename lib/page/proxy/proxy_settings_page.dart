import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_dns_page.dart';
import 'package:gstore/page/proxy/proxy_engine_settings_store.dart';
import 'package:gstore/page/proxy/proxy_shaper_presets.dart';

import 'proxy_settings_facade.dart';

/// 引擎 stack 可选值（与 Rust `core.start` 请求一致）。
const String _kEngineStackGvisor = 'gvisor';
const String _kEngineStackSystem = 'system';

/// Rust 侧拒绝低于此值的 MTU（见 `core.start` 校验）。
const int _kEngineMinMtu = 1280;

/// 弱网自定义编辑方向（上下行独立参数）。
const String _kShaperDirUplink = 'uplink';
const String _kShaperDirDownlink = 'downlink';

/// 代理设置页（Todos 23 / 28，纯展示 / 触发层）。
///
/// 覆盖（按功能区自上而下）：
/// * **连接与引擎**：引擎参数（stack / MTU，应用侧持久化）+ 始终开启 +
///   日志级别；
/// * **分流与入站**：应用分流 + 局域网监听 (LAN)（`lan.get` / `lan.set` /
///   `lan.status`，默认关闭，未配置认证时展示安全警告）；
/// * **域名解析**：DNS 设置入口（跳转 [ProxyDnsPage]）；
/// * **弱网模拟**：`net.shaper.get` / `net.shaper.set`（总开关 + 档位预设 +
///   自定义 rate / delay / jitter / loss，上下行独立）；
/// * **维护与诊断**：重置统计（`stats.domain.reset`）+ 引擎调试信息
///   （`version` / `ping` / `core.get_mode`）。
///
/// **应用分流**：全局 / 仅选中 / 排除选中 + 已安装应用选择器（统一底部弹层）；
/// **始终开启**：应用侧意图开关 + 系统设置引导（应用无法直接切换系统开关）。
///
/// 所有解析 / 网络 / 路由 / 统计逻辑都在 Rust 侧（`gstore_mod_proxy`），本页只
/// 翻译并持久化。门面经构造函数注入，测试无需原生模块 / 平台通道。
class ProxySettingsPage extends StatefulWidget {
  const ProxySettingsPage({super.key, this.facade});

  /// 设置门面（测试可注入假实现；为空时用生产适配器）。
  final ProxySettingsFacade? facade;

  @override
  State<ProxySettingsPage> createState() => _ProxySettingsPageState();
}

class _ProxySettingsPageState extends State<ProxySettingsPage> {
  late final ProxySettingsFacade _facade;

  final TextEditingController _lanPort = TextEditingController();
  final TextEditingController _lanBind = TextEditingController();
  final TextEditingController _lanUser = TextEditingController();
  final TextEditingController _lanPass = TextEditingController();
  final TextEditingController _lanAllowed = TextEditingController();
  final TextEditingController _engineMtu = TextEditingController();
  final TextEditingController _shaperRate = TextEditingController();
  final TextEditingController _shaperDelay = TextEditingController();
  final TextEditingController _shaperJitter = TextEditingController();
  final TextEditingController _shaperLoss = TextEditingController();

  bool _loading = true;
  String? _error;
  bool _busy = false;
  ProxySettingsConfig _config = const ProxySettingsConfig();
  List<InstalledAppOption> _apps = const <InstalledAppOption>[];
  ProxyEngineInfo _engine = const ProxyEngineInfo();
  ProxyLanConfig _lan = const ProxyLanConfig();
  ProxyLanStatus _lanStatus = const ProxyLanStatus();
  ProxyEngineSettings _engineSettings = const ProxyEngineSettings();
  String _engineStack = _kEngineStackGvisor;

  /// 最近一次 `net.shaper.get` / `net.shaper.set` 的冻结快照。
  ProxyShaperSnapshot _shaper = const ProxyShaperSnapshot();

  /// 弱网总开关（与应用侧意图一致，乐观更新 + 失败回滚）。
  bool _shaperEnabled = false;

  /// 当前档位 id（[ProxyShaperPresetIds]；未知回落到 `custom`）。
  String _shaperPresetId = ProxyShaperPresetIds.custom;

  /// 自定义编辑的上下行参数（预设档位也会写入这里，便于切回自定义时回填）。
  ProxyShaperDirection _shaperUplink = const ProxyShaperDirection();
  ProxyShaperDirection _shaperDownlink = const ProxyShaperDirection();

  /// 自定义输入框当前编辑的方向。
  String _shaperCustomDirection = _kShaperDirUplink;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleSettingsFacade();
    _syncLanControllers(_lan);
    _syncEngineControllers(_engineSettings);
    _syncShaperControllers();
    _load();
  }

  @override
  void dispose() {
    _lanPort.dispose();
    _lanBind.dispose();
    _lanUser.dispose();
    _lanPass.dispose();
    _lanAllowed.dispose();
    _engineMtu.dispose();
    _shaperRate.dispose();
    _shaperDelay.dispose();
    _shaperJitter.dispose();
    _shaperLoss.dispose();
    super.dispose();
  }

  void _syncLanControllers(ProxyLanConfig config) {
    _lanPort.text = '${config.port}';
    _lanBind.text = config.bindAddress;
    _lanUser.text = config.authUser;
    _lanPass.text = config.authPass;
    _lanAllowed.text = config.allowedIps.join(', ');
  }

  /// 把引擎设置同步到分段控件 + MTU 输入框（未知 stack 回落 `gvisor`）。
  void _syncEngineControllers(ProxyEngineSettings settings) {
    _engineStack = _normalizeStack(settings.stack);
    _engineMtu.text = '${settings.mtu}';
  }

  /// 归一化 stack：只接受 `gvisor` / `system`，其余回落 `gvisor`。
  String _normalizeStack(String stack) =>
      stack == _kEngineStackSystem ? _kEngineStackSystem : _kEngineStackGvisor;

  // ==================== 弱网模拟 ====================

  /// 当前自定义输入框正在编辑的方向参数。
  ProxyShaperDirection get _activeShaperDirection =>
      _shaperCustomDirection == _kShaperDirDownlink
          ? _shaperDownlink
          : _shaperUplink;

  /// 把当前方向的自定义参数同步到输入框。
  void _syncShaperControllers() {
    final direction = _activeShaperDirection;
    _shaperRate.text = '${direction.rateBps}';
    _shaperDelay.text = '${direction.delayMs}';
    _shaperJitter.text = '${direction.jitterMs}';
    _shaperLoss.text = _formatPct(direction.lossPct);
  }

  /// 百分比回填：整数省略小数位（`2.0` → `2`，`2.5` → `2.5`）。
  String _formatPct(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  /// 由当前 UI 状态构造完整配置（方向参数 + 总开关 + 沿用 seed）。
  ProxyShaperConfig _currentShaperConfig() => ProxyShaperConfig(
        enabled: _shaperEnabled,
        seed: _shaper.config.seed,
        uplink: _shaperUplink,
        downlink: _shaperDownlink,
      );

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await _facade.loadSettings();
      final apps = await _facade.loadInstalledApps();
      final engine = await _facade.loadEngineInfo();
      ProxyLanConfig? lan;
      ProxyLanStatus? lanStatus;
      try {
        lan = await _facade.loadLanConfig();
      } catch (_) {
        // 模块不可用 → 保留默认（LAN 关闭）
      }
      try {
        lanStatus = await _facade.loadLanStatus();
      } catch (_) {
        // 模块不可用 → 保留默认（未监听）
      }
      ProxyEngineSettings engineSettings;
      try {
        engineSettings = await _facade.loadEngineSettings();
      } catch (error) {
        // 持久化异常 → 回落默认（gvisor / 1500），不阻断页面。
        debugPrint('代理设置：读取引擎参数失败，回落默认值：$error');
        engineSettings = const ProxyEngineSettings();
      }
      ProxyShaperSnapshot? shaper;
      try {
        shaper = await _facade.loadShaperConfig();
      } catch (error) {
        // 模块不可用 / 读取失败 → 保留默认（关闭），不阻断页面。
        debugPrint('代理设置：读取弱网配置失败，回落默认值：$error');
      }
      if (!mounted) return;
      setState(() {
        _config = config;
        _apps = apps;
        _engine = engine;
        if (lan != null) _lan = lan;
        if (lanStatus != null) _lanStatus = lanStatus;
        _engineSettings = engineSettings;
        _engineStack = _normalizeStack(engineSettings.stack);
        if (shaper != null) {
          _shaper = shaper;
          _shaperEnabled = shaper.config.enabled;
          _shaperUplink = shaper.config.uplink;
          _shaperDownlink = shaper.config.downlink;
          _shaperPresetId = presetForConfig(shaper.config).id;
        }
        _loading = false;
      });
      _syncLanControllers(_lan);
      _engineMtu.text = '${engineSettings.mtu}';
      _syncShaperControllers();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _refreshEngine() async {
    final engine = await _facade.loadEngineInfo();
    if (!mounted) return;
    setState(() => _engine = engine);
  }

  // ==================== 引擎参数 ====================

  /// 校验并持久化引擎参数（stack / MTU）。
  ///
  /// 客户端校验与 Rust 一致：MTU 必须能解析为整数且 `>= 1280`；非法时提示并
  /// **不保存**。保存成功后提示「下次连接 / 引擎重启生效」。
  Future<void> _saveEngineSettings() async {
    final raw = _engineMtu.text.trim();
    final mtu = int.tryParse(raw);
    if (mtu == null || mtu < _kEngineMinMtu) {
      AppDialogs.showError('MTU 必须是不小于 1280 的整数');
      return;
    }
    final next = _engineSettings.copyWith(stack: _engineStack, mtu: mtu);
    final previous = _engineSettings;
    setState(() {
      _busy = true;
      _engineSettings = next;
    });
    try {
      await _facade.saveEngineSettings(next);
      if (!mounted) return;
      AppDialogs.showSuccess('引擎参数已保存，将在下次连接 / 引擎重启后生效');
    } catch (error) {
      if (!mounted) return;
      setState(() => _engineSettings = previous);
      AppDialogs.showError('引擎参数保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ==================== 域名解析 ====================

  /// 打开 DNS 设置页（Todo 22a）。
  void _openDnsPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProxyDnsPage()),
    );
  }

  // ==================== 应用分流 ====================

  Future<void> _saveSplitTunnel({
    ProxySplitTunnelMode? mode,
    Set<String>? apps,
  }) async {
    final nextMode = mode ?? _config.splitMode;
    final nextApps = apps ?? _config.selectedApps;
    final previous = _config;
    setState(() {
      _busy = true;
      _config = _config.copyWith(splitMode: nextMode, selectedApps: nextApps);
    });
    try {
      await _facade.saveSplitTunnel(mode: nextMode, apps: nextApps);
      if (!mounted) return;
      AppDialogs.showSuccess('分流设置已保存');
    } catch (error) {
      if (!mounted) return;
      setState(() => _config = previous);
      AppDialogs.showError('分流设置保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAppPicker() async {
    final result = await AppSheet.showCustom<Set<String>>(
      context: context,
      builder: (sheetContext) => _AppPickerSheet(
        apps: _apps,
        initial: _config.selectedApps,
      ),
    );
    if (!mounted || result == null) return;
    await _saveSplitTunnel(apps: result);
  }

  // ==================== 始终开启 ====================

  Future<void> _toggleAlwaysOn(bool value) async {
    final previous = _config;
    setState(() => _config = _config.copyWith(alwaysOnIntent: value));
    try {
      await _facade.setAlwaysOnIntent(value);
      if (!mounted) return;
      AppDialogs.showSuccess(value ? '已记录「始终开启」意图' : '已关闭「始终开启」意图');
    } catch (error) {
      if (!mounted) return;
      setState(() => _config = previous);
      AppDialogs.showError('保存失败：$error');
    }
  }

  Future<void> _showAlwaysOnHelp() async {
    await AppDialogs.showAlertSheet(
      title: '系统「始终开启的 VPN」',
      message: '应用无法直接修改系统的「始终开启的 VPN」开关。\n\n'
          '请前往「系统设置 → 网络与互联网 → VPN → GStore」，手动开启'
          '「始终开启的 VPN」。开启后系统会在开机 / 网络切换时以已保存的配置'
          '自动拉起隧道；此处开关仅记录应用侧意图。',
    );
  }

  // ==================== 局域网监听（LAN） ====================

  ProxyLanConfig _lanFromFields() {
    final port = int.tryParse(_lanPort.text.trim()) ?? _lan.port;
    final allowed = _lanAllowed.text
        .split(RegExp(r'[,\s]+'))
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    final bind = _lanBind.text.trim();
    return _lan.copyWith(
      port: port,
      bindAddress: bind.isEmpty ? '0.0.0.0' : bind,
      authUser: _lanUser.text.trim(),
      authPass: _lanPass.text,
      allowedIps: allowed,
    );
  }

  Future<void> _toggleLan(bool value) async {
    setState(() => _lan = _lan.copyWith(enabled: value));
    await _applyLanConfig();
  }

  Future<void> _applyLanConfig() async {
    if (_busy) return;
    final next = _lanFromFields();
    setState(() {
      _busy = true;
      _lan = next;
    });
    try {
      final status = await _facade.saveLanConfig(next);
      if (!mounted) return;
      setState(() {
        _lanStatus = status;
        if (status.config != null) _lan = status.config!;
        _busy = false;
      });
      _syncLanControllers(_lan);
      if (_lan.needsWarning || status.hasWarning) {
        AppDialogs.showWarning('LAN 已启用但未配置认证，同一网络下的任何设备都可使用此代理');
      } else {
        AppDialogs.showSuccess('LAN 设置已保存');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppDialogs.showError('LAN 设置失败：$error');
    }
  }

  Future<String> _copyableLanAddress() async {
    if (_lanStatus.addresses.isEmpty) return '';
    final raw = _lanStatus.addresses.first;
    final separator = raw.lastIndexOf(':');
    final host = separator > 0 ? raw.substring(0, separator) : raw;
    if (host == '0.0.0.0' || host == '::' || host.isEmpty) {
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        for (final interface in interfaces) {
          for (final address in interface.addresses) {
            if (!address.isLoopback) return '${address.address}:${_lan.port}';
          }
        }
      } catch (_) {
        // 受限环境（无网卡枚举）→ 回退到绑定地址
      }
    }
    return raw;
  }

  Future<void> _copyLanAddress() async {
    final text = await _copyableLanAddress();
    if (text.isEmpty || !mounted) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    AppDialogs.showSuccess('已复制到剪贴板');
  }

  // ==================== 弱网模拟（交互） ====================

  /// 总开关：乐观更新 → `net.shaper.set` → 成功提示 / 失败回滚。
  Future<void> _toggleShaper(bool value) async {
    if (_busy) return;
    await _saveShaperConfig(_currentShaperConfig().copyWith(enabled: value));
  }

  /// 下发弱网配置（乐观更新 + 失败回滚，与 [ _saveEngineSettings] 同模式）。
  Future<void> _saveShaperConfig(ProxyShaperConfig next) async {
    if (_busy) return;
    final previousSnapshot = _shaper;
    final previousEnabled = _shaperEnabled;
    final previousPresetId = _shaperPresetId;
    final previousUplink = _shaperUplink;
    final previousDownlink = _shaperDownlink;
    setState(() {
      _busy = true;
      _shaperEnabled = next.enabled;
      _shaper = ProxyShaperSnapshot(
        config: next,
        effective: previousSnapshot.effective,
        applied: previousSnapshot.applied,
        engineRunning: previousSnapshot.engineRunning,
        counters: previousSnapshot.counters,
      );
    });
    try {
      final snapshot = await _facade.saveShaperConfig(next);
      if (!mounted) return;
      setState(() {
        _shaper = snapshot;
        _shaperEnabled = snapshot.config.enabled;
        _shaperUplink = snapshot.config.uplink;
        _shaperDownlink = snapshot.config.downlink;
        _shaperPresetId = presetForConfig(snapshot.config).id;
        _busy = false;
      });
      _syncShaperControllers();
      AppDialogs.showSuccess('弱网配置已应用');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _shaper = previousSnapshot;
        _shaperEnabled = previousEnabled;
        _shaperPresetId = previousPresetId;
        _shaperUplink = previousUplink;
        _shaperDownlink = previousDownlink;
        _busy = false;
      });
      _syncShaperControllers();
      AppDialogs.showError('弱网配置保存失败：$error');
    }
  }

  /// 选择档位：已知档位立即下发（并启用）；`custom` 仅切换编辑态，不发 RPC。
  Future<void> _selectShaperPreset(String id) async {
    if (_busy) return;
    if (id == ProxyShaperPresetIds.custom) {
      setState(() => _shaperPresetId = id);
      _syncShaperControllers();
      return;
    }
    final preset = presetOrCustomById(id);
    final next = preset.config.copyWith(
      enabled: true,
      seed: _shaper.config.seed,
    );
    setState(() {
      _shaperPresetId = id;
      _shaperUplink = preset.config.uplink;
      _shaperDownlink = preset.config.downlink;
    });
    await _saveShaperConfig(next);
  }

  /// 切换自定义编辑方向（先把当前输入提交到当前方向，再回填另一方向）。
  void _selectShaperDirection(String direction) {
    if (_busy || direction == _shaperCustomDirection) return;
    _commitShaperFields();
    setState(() => _shaperCustomDirection = direction);
    _syncShaperControllers();
  }

  /// 把当前输入框内容提交到当前编辑方向（合法才写入；非法静默忽略）。
  void _commitShaperFields() {
    final built = _buildShaperDirectionFromFields(_activeShaperDirection);
    if (built == null) return;
    setState(() {
      if (_shaperCustomDirection == _kShaperDirDownlink) {
        _shaperDownlink = built;
      } else {
        _shaperUplink = built;
      }
    });
  }

  /// 用输入框内容 + [base] 的非编辑字段构造已校验的单方向参数。
  ///
  /// 空值 / 非数字 / 越界（[buildCustomShaperDirection] 返回 `null`）→ `null`，
  /// 调用方**不得**下发 `net.shaper.set`。
  ProxyShaperDirection? _buildShaperDirectionFromFields(
    ProxyShaperDirection base,
  ) {
    final rate = int.tryParse(_shaperRate.text.trim());
    final delay = int.tryParse(_shaperDelay.text.trim());
    final jitter = int.tryParse(_shaperJitter.text.trim());
    final loss = double.tryParse(_shaperLoss.text.trim());
    if (rate == null || delay == null || jitter == null || loss == null) {
      return null;
    }
    return buildCustomShaperDirection(
      rateBps: rate,
      burstBytes: base.burstBytes,
      delayMs: delay,
      jitterMs: jitter,
      jitterDistribution: base.jitterDistribution,
      lossPct: loss,
      lossModel: loss > 0 ? 'random' : 'none',
      lossGoodToBadPct: base.lossGoodToBadPct,
      lossBadToGoodPct: base.lossBadToGoodPct,
      duplicatePct: base.duplicatePct,
      reorderPct: base.reorderPct,
      reorderGap: base.reorderGap,
      order: base.order,
    );
  }

  Future<void> _openShaperPresetPicker() async {
    final result = await AppSheet.showCustom<String>(
      context: context,
      builder: (sheetContext) =>
          _ShaperPresetPickerSheet(selectedId: _shaperPresetId),
    );
    if (!mounted || result == null) return;
    await _selectShaperPreset(result);
  }

  /// 应用按钮：自定义档位校验后下发；已知档位按当前开关重下发。
  Future<void> _applyShaper() async {
    if (_busy) return;
    if (_shaperPresetId != ProxyShaperPresetIds.custom) {
      final preset = presetOrCustomById(_shaperPresetId);
      await _saveShaperConfig(preset.config.copyWith(
        enabled: _shaperEnabled,
        seed: _shaper.config.seed,
      ));
      return;
    }
    final built = _buildShaperDirectionFromFields(_activeShaperDirection);
    if (built == null) {
      AppDialogs.showError(
        '请填写有效数值：限速 0 或 1000–1000000000 bps，延迟 ≤ 60000 ms，'
        '抖动 ≤ 30000 ms，丢包 0–100%',
      );
      return;
    }
    final uplink =
        _shaperCustomDirection == _kShaperDirUplink ? built : _shaperUplink;
    final downlink =
        _shaperCustomDirection == _kShaperDirDownlink ? built : _shaperDownlink;
    final config = buildCustomShaperConfig(
      enabled: _shaperEnabled,
      seed: _shaper.config.seed,
      uplink: uplink,
      downlink: downlink,
    );
    if (config == null) {
      AppDialogs.showError('弱网参数超出允许范围，请检查限速 / 延迟 / 抖动 / 丢包');
      return;
    }
    setState(() {
      _shaperUplink = uplink;
      _shaperDownlink = downlink;
      _shaperPresetId = ProxyShaperPresetIds.custom;
    });
    await _saveShaperConfig(config);
  }

  // ==================== 日志级别 / 统计 ====================

  Future<void> _setLogLevel(ProxyLogLevel level) async {
    final previous = _config;
    setState(() => _config = _config.copyWith(logLevel: level));
    try {
      await _facade.setLogLevel(level);
      if (!mounted) return;
      AppDialogs.showSuccess('日志级别已设为 ${level.wire.toUpperCase()}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _config = previous);
      AppDialogs.showError('级别设置失败：$error');
    }
  }

  Future<void> _resetStats() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '重置域名统计',
      message: '将清空域名聚合与持久化统计行，确定继续吗？',
      confirmText: '重置',
      isDangerous: true,
      icon: const Icon(Icons.restart_alt),
    );
    if (ok != true || !mounted) return;
    try {
      final result = await _facade.resetStats();
      if (!mounted) return;
      AppDialogs.showSuccess('已重置 ${result.cleared} 条统计');
    } on ProxyModuleException catch (error) {
      AppDialogs.showError(error.message, title: '重置失败');
    } catch (error) {
      AppDialogs.showError('重置失败：$error');
    }
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('代理设置'),
        actions: [
          IconButton(
            tooltip: '刷新调试信息',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refreshEngine,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final error = _error;
    if (error != null) {
      return _SettingsMessageState(
        icon: Icons.error_outline,
        title: '设置不可用',
        message: error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: AppSpacing.allLG,
        children: [
          const _RegionHeader(title: '连接与引擎'),
          _buildEngineSettingsCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildAlwaysOnCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildLogLevelCard(context),
          const SizedBox(height: AppSpacing.xxl),
          const _RegionHeader(title: '分流与入站'),
          _buildSplitTunnelCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildLanCard(context),
          const SizedBox(height: AppSpacing.xxl),
          const _RegionHeader(title: '弱网模拟'),
          _buildShaperCard(context),
          const SizedBox(height: AppSpacing.xxl),
          const _RegionHeader(title: '域名解析'),
          _buildDnsTile(context),
          const SizedBox(height: AppSpacing.xxl),
          const _RegionHeader(title: '维护与诊断'),
          _buildStatsCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildEngineCard(context),
        ],
      ),
    );
  }

  Widget _buildEngineSettingsCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _SectionCard(
      icon: Icons.tune_outlined,
      title: '引擎参数',
      children: [
        Text(
          '隧道协议栈',
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: AppSegmentedButton<String>(
            key: const Key('engine_stack_selector'),
            value: _engineStack,
            enabled: !_busy,
            density: AppSegmentedButton.mediumDensity,
            segments: const <AppSegment<String>>[
              AppSegment(value: _kEngineStackGvisor, label: 'gvisor'),
              AppSegment(value: _kEngineStackSystem, label: 'system'),
            ],
            onChanged: (stack) => setState(() => _engineStack = stack),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const Key('engine_mtu_field'),
          controller: _engineMtu,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: const InputDecoration(
            labelText: 'MTU',
            hintText: '1500',
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'MTU 不得小于 1280。修改在下次连接 / 引擎重启后生效，运行中的隧道不会热更新。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('engine_settings_save'),
            onPressed: _busy ? null : _saveEngineSettings,
            icon: const Icon(Icons.save_outlined, size: AppTypography.iconSM),
            label: const Text('保存引擎参数'),
          ),
        ),
      ],
    );
  }

  Widget _buildDnsTile(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: const Key('dns_settings_tile'),
        leading: const Icon(Icons.dns_outlined),
        title: const Text('DNS 设置'),
        subtitle: const Text('解析模式、上游、DoH / DoT'),
        trailing: const Icon(Icons.chevron_right),
        onTap: _openDnsPage,
      ),
    );
  }

  Widget _buildSplitTunnelCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectedCount = _config.selectedApps.length;
    return _SectionCard(
      icon: Icons.apps_outlined,
      title: '应用分流',
      children: [
        // 药丸走统一中等尺寸的 [AppSegmentedButton]，与首页「路由模式」同尺寸同组件。
        // 独立成行（左对齐），不再与标题挤在同一行。
        Align(
          alignment: Alignment.centerLeft,
          child: AppSegmentedButton<ProxySplitTunnelMode>(
            key: const Key('split_mode_selector'),
            value: _config.splitMode,
            enabled: !_busy,
            density: AppSegmentedButton.mediumDensity,
            segments: const <AppSegment<ProxySplitTunnelMode>>[
              AppSegment(value: ProxySplitTunnelMode.full, label: '全局'),
              AppSegment(value: ProxySplitTunnelMode.allow, label: '仅选中'),
              AppSegment(value: ProxySplitTunnelMode.disallow, label: '排除选中'),
            ],
            onChanged: (mode) => _saveSplitTunnel(mode: mode),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_config.splitMode == ProxySplitTunnelMode.full)
          Text(
            '全局模式：所有应用都通过代理。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          Row(
            children: [
              Expanded(
                child: Text(
                  '已选 $selectedCount 个应用',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              TextButton(
                key: const Key('split_apps_button'),
                onPressed: _busy ? null : _openAppPicker,
                child: const Text('选择应用'),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildAlwaysOnCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _SectionCard(
      icon: Icons.power_settings_new_outlined,
      title: '始终开启',
      children: [
        SwitchListTile(
          key: const Key('always_on_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('记录「始终开启」意图'),
          subtitle: const Text('应用无法直接切换系统开关，需在系统设置中手动开启。'),
          value: _config.alwaysOnIntent,
          onChanged: _busy ? null : _toggleAlwaysOn,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('always_on_help'),
            onPressed: _showAlwaysOnHelp,
            icon: const Icon(Icons.help_outline, size: AppTypography.iconSM),
            label: const Text('如何开启系统「始终开启的 VPN」？'),
          ),
        ),
        Text(
          '关闭应用后，系统可能停止隧道。开启系统「始终开启」后，系统会在开机 / '
          '网络切换时按已保存配置自动恢复。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildLanCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showWarning = _lan.needsWarning || _lanStatus.hasWarning;
    return _SectionCard(
      icon: Icons.lan_outlined,
      title: '局域网监听 (LAN)',
      children: [
        SwitchListTile(
          key: const Key('lan_enabled_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('允许局域网设备使用本机代理'),
          subtitle: Text(
            _lanStatus.bound
                ? '监听中：${_lanStatus.addresses.join(', ')}'
                : '未监听（默认关闭）',
          ),
          value: _lan.enabled,
          onChanged: _busy ? null : _toggleLan,
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const Key('lan_port_field'),
                controller: _lanPort,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'LAN 端口',
                  hintText: '1087',
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: TextField(
                key: const Key('lan_bind_field'),
                controller: _lanBind,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: '监听地址',
                  hintText: '0.0.0.0',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const Key('lan_auth_user_field'),
          controller: _lanUser,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '认证用户名（可选）',
            hintText: 'user',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const Key('lan_auth_pass_field'),
          controller: _lanPass,
          enabled: !_busy,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '认证密码（可选）',
            hintText: 'password',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const Key('lan_allowed_ips_field'),
          controller: _lanAllowed,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '允许的 IP / CIDR（逗号分隔，留空=不限）',
            hintText: '192.168.1.0/24',
          ),
        ),
        if (showWarning) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            _lanStatus.warning ?? '已启用但未配置认证：同一网络下的任何设备都可使用此代理。',
            key: const Key('lan_warning_text'),
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: Text(
                _lanStatus.addresses.isEmpty
                    ? '监听地址：未监听'
                    : '监听地址：${_lanStatus.addresses.first}',
                key: const Key('lan_address_text'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              key: const Key('lan_copy_address'),
              onPressed: _lanStatus.bound ? _copyLanAddress : null,
              icon: const Icon(Icons.copy_outlined, size: AppTypography.iconSM),
              tooltip: '复制地址',
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('lan_save_button'),
            onPressed: _busy ? null : _applyLanConfig,
            icon: const Icon(Icons.save_outlined, size: AppTypography.iconSM),
            label: const Text('保存 LAN 设置'),
          ),
        ),
      ],
    );
  }

  Widget _buildShaperCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preset = presetOrCustomById(_shaperPresetId);
    return _SectionCard(
      icon: Icons.speed_outlined,
      title: '弱网模拟',
      children: [
        SwitchListTile(
          key: const Key('shaper_enabled_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('启用弱网模拟'),
          subtitle: Text(_shaperEnabled ? '已启用：对进出流量做整形' : '已关闭（默认）'),
          value: _shaperEnabled,
          onChanged: _busy ? null : _toggleShaper,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '网络档位',
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            key: const Key('shaper_preset_selector'),
            contentPadding: AppSpacing.onlyHorizontalMD,
            title: Text('当前档位：${preset.label}'),
            subtitle: Text(_shaperPresetSubtitle(preset)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _openShaperPresetPicker,
          ),
        ),
        if (preset.isCustom) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            '自定义参数（按方向独立生效）',
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: AppSegmentedButton<String>(
              key: const Key('shaper_direction_selector'),
              value: _shaperCustomDirection,
              enabled: !_busy,
              density: AppSegmentedButton.mediumDensity,
              segments: const <AppSegment<String>>[
                AppSegment(value: _kShaperDirUplink, label: '上行'),
                AppSegment(value: _kShaperDirDownlink, label: '下行'),
              ],
              onChanged: _selectShaperDirection,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('shaper_rate_field'),
                  controller: _shaperRate,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '限速 (bps)',
                    hintText: '0 = 不限速',
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: TextField(
                  key: const Key('shaper_delay_field'),
                  controller: _shaperDelay,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '延迟 (ms)',
                    hintText: '0',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('shaper_jitter_field'),
                  controller: _shaperJitter,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '抖动 (ms)',
                    hintText: '0',
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: TextField(
                  key: const Key('shaper_loss_field'),
                  controller: _shaperLoss,
                  enabled: !_busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '丢包 (%)',
                    hintText: '0',
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('shaper_apply_button'),
            onPressed: _busy ? null : _applyShaper,
            icon: const Icon(Icons.save_outlined, size: AppTypography.iconSM),
            label: const Text('应用弱网参数'),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          _shaperStatusText(),
          key: const Key('shaper_status_text'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 档位副标题：预设展示关键参数摘要；自定义展示说明。
  String _shaperPresetSubtitle(ProxyShaperPreset preset) {
    if (preset.isCustom) return '手动设置限速 / 延迟 / 抖动 / 丢包';
    final direction = preset.config.uplink;
    final buffer = StringBuffer('${direction.rateBps ~/ 1000} kbps');
    buffer.write(' · 延迟 ${direction.delayMs} ms');
    buffer.write(' · 抖动 ${direction.jitterMs} ms');
    if (direction.lossPct > 0) {
      buffer.write(' · 丢包 ${_formatPct(direction.lossPct)}%');
    }
    return buffer.toString();
  }

  /// 运行态说明：区分「未启用 / 已生效 / 待应用 / 引擎未运行」。
  String _shaperStatusText() {
    if (!_shaperEnabled) return '未启用：不会对流量做整形。';
    if (_shaper.applied) return '引擎运行中，弱网参数已生效。';
    if (_shaper.engineRunning) return '引擎运行中，弱网参数待应用。';
    return '引擎未运行：参数将在下次连接后生效。';
  }

  Widget _buildLogLevelCard(BuildContext context) {
    return _SectionCard(
      icon: Icons.article_outlined,
      title: '日志级别',
      children: [
        SegmentedButton<ProxyLogLevel>(
          key: const Key('settings_log_level_selector'),
          segments: const [
            ButtonSegment(value: ProxyLogLevel.debug, label: Text('DEBUG')),
            ButtonSegment(value: ProxyLogLevel.info, label: Text('INFO')),
            ButtonSegment(value: ProxyLogLevel.warn, label: Text('WARN')),
            ButtonSegment(value: ProxyLogLevel.error, label: Text('ERROR')),
          ],
          selected: {_config.logLevel},
          showSelectedIcon: false,
          onSelectionChanged: _busy
              ? null
              : (selection) => _setLogLevel(selection.first),
        ),
      ],
    );
  }

  Widget _buildStatsCard(BuildContext context) {
    final theme = Theme.of(context);
    return _SectionCard(
      icon: Icons.bar_chart_outlined,
      title: '域名统计',
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('stats_reset_button'),
            onPressed: _busy ? null : _resetStats,
            icon: const Icon(Icons.restart_alt, size: AppTypography.iconSM),
            label: const Text('重置域名统计'),
            style: FilledButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '重置会清空域名聚合与持久化统计行，操作不可撤销。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildEngineCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final version = _engine.version;
    final ping = _engine.ping;
    final mode = _engine.mode;
    return _SectionCard(
      icon: Icons.memory_outlined,
      title: '引擎调试信息',
      trailing: IconButton(
        key: const Key('engine_refresh'),
        tooltip: '刷新',
        icon: const Icon(Icons.refresh, size: AppTypography.iconMD),
        onPressed: _refreshEngine,
      ),
      children: [
        if (_engine.isEmpty)
          Text(
            '代理模块不可用，暂无调试信息。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else ...[
          if (version != null) ...[
            _kv(theme, '模块版本', version.moduleVersion),
            _kv(theme, 'API 版本', '${version.apiVersion}'),
            _kv(theme, '宿主 ABI', '${version.minHostAbi} ≤ ${version.hostAbi}'),
            _kv(theme, 'meow 版本', version.meowRev),
            _kv(theme, '目标架构', version.targetArch),
          ],
          if (ping != null) ...[
            _kv(theme, '心跳', ping.pong ? '正常' : '无响应'),
            if (ping.state != null) _kv(theme, '引擎状态', ping.state!.wire),
            if (ping.mode != null) _kv(theme, '引擎模式', ping.mode!.wire),
            if (ping.protectFdPresent != null)
              _kv(theme, 'protect_fd', ping.protectFdPresent! ? '已注入' : '缺失'),
            if (ping.instanceId != null)
              _kv(theme, '实例 ID', '${ping.instanceId}'),
          ],
          if (mode != null) ...[
            _kv(theme, '当前模式', mode.mode.wire),
            _kv(theme, '当前状态', mode.state.wire),
          ],
        ],
      ],
    );
  }

  Widget _kv(ThemeData theme, String label, String value) {
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 通用小节卡片 ====================

/// 功能区标题（区域表头），用于在视觉上把设置页分为若干功能区块。
class _RegionHeader extends StatelessWidget {
  const _RegionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.children,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: AppTypography.iconMD,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall),
                ),
                if (trailing != null)
                  // 尾部药丸限制在行宽 70%（其余留给标题），超宽时整体等比缩小，
                  // 既避免 RenderFlex 溢出，也不会把标题挤成多行。
                  LayoutBuilder(
                    builder: (context, constraints) => ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * 0.7,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: trailing!,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            ...children,
          ],
        ),
      ),
    );
  }
}

// ==================== 应用选择弹层 ====================

/// 已安装应用多选弹层（统一 [AppSheetScaffold] 骨架）。
///
/// 空列表渲染**显式空态**（非空白、不崩溃）；选择结果经 `pop(Set)` 返回。
class _AppPickerSheet extends StatefulWidget {
  const _AppPickerSheet({required this.apps, required this.initial});

  final List<InstalledAppOption> apps;
  final Set<String> initial;

  @override
  State<_AppPickerSheet> createState() => _AppPickerSheetState();
}

class _AppPickerSheetState extends State<_AppPickerSheet> {
  late final Set<String> _selected = <String>{...widget.initial};
  String _query = '';

  List<InstalledAppOption> get _filtered {
    if (_query.isEmpty) return widget.apps;
    final q = _query.toLowerCase();
    return widget.apps
        .where((app) =>
            app.name.toLowerCase().contains(q) ||
            app.packageName.toLowerCase().contains(q))
        .toList();
  }

  void _toggle(String packageName) {
    setState(() {
      if (!_selected.add(packageName)) _selected.remove(packageName);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final filtered = _filtered;
    return AppSheetScaffold(
      title: '选择应用',
      subtitle: widget.apps.isEmpty ? '无可用应用' : '共 ${widget.apps.length} 个已安装应用',
      icon: const Icon(Icons.apps_outlined),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('split_apps_confirm'),
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确定'),
        ),
      ],
      scrollable: false,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('split_app_search'),
            onChanged: (value) => setState(() => _query = value.trim()),
            decoration: const InputDecoration(
              labelText: '搜索',
              hintText: '应用名 / 包名',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (widget.apps.isEmpty)
            Padding(
              key: const Key('split_apps_empty'),
              padding: AppSpacing.onlyVerticalXXL,
              child: Column(
                children: [
                  Icon(Icons.apps_outlined,
                      size: AppTypography.iconXXXL,
                      color: scheme.onSurfaceVariant),
                  const SizedBox(height: AppSpacing.md),
                  Text('未获取到已安装应用', style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '请确认已授予应用列表权限，或稍后重试。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          else if (filtered.isEmpty)
            Padding(
              padding: AppSpacing.onlyVerticalXXL,
              child: Text(
                '没有匹配的应用',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            SizedBox(
              height: 340,
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final app = filtered[index];
                  final checked = _selected.contains(app.packageName);
                  return _AppPickerRow(
                    key: Key('split_app_${app.packageName}'),
                    app: app,
                    checked: checked,
                    onToggle: () => _toggle(app.packageName),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _AppPickerRow extends StatelessWidget {
  const _AppPickerRow({
    super.key,
    required this.app,
    required this.checked,
    required this.onToggle,
  });

  final InstalledAppOption app;
  final bool checked;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: AppSpacing.onlyVerticalXS,
        child: Row(
          children: [
            Checkbox(value: checked, onChanged: (_) => onToggle()),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.name,
                    style: theme.textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    app.packageName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
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

// ==================== 弱网档位选择弹层 ====================

/// 弱网档位选择弹层（统一 [AppSheetScaffold] 骨架），返回选中档位 id。
class _ShaperPresetPickerSheet extends StatelessWidget {
  const _ShaperPresetPickerSheet({required this.selectedId});

  final String selectedId;

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: '选择网络档位',
      icon: const Icon(Icons.speed_outlined),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
      scrollable: false,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final preset in proxyShaperPresets)
            _ShaperPresetRow(
              key: Key('shaper_preset_${preset.id}'),
              label: preset.label,
              selected: preset.id == selectedId,
              onTap: () => Navigator.of(context).pop(preset.id),
            ),
        ],
      ),
    );
  }
}

class _ShaperPresetRow extends StatelessWidget {
  const _ShaperPresetRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: AppSpacing.onlyVerticalSM,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
              ),
            ),
            if (selected)
              Icon(
                Icons.check,
                color: scheme.primary,
                size: AppTypography.iconMD,
              ),
          ],
        ),
      ),
    );
  }
}

// ==================== 空 / 错误态 ====================

class _SettingsMessageState extends StatelessWidget {
  const _SettingsMessageState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppTypography.iconXXXL,
                color: scheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.lg),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
