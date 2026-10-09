import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_dns_page.dart';
import 'package:gstore/page/proxy/proxy_diagnostics_page.dart';
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

/// 设置页 `ListView` 的预构建缓存高度（逻辑像素）。
///
/// 用于让「弱网模拟」锚点在初始 load 后始终已挂载，供
/// [ProxySettingsPage.scrollToShaper] 的 `Scrollable.ensureVisible` 使用；仅影响
/// 懒构建窗口，不参与任何视觉尺寸。
const double _kSettingsPrebuildExtent = 10000;

/// 各小节骨架屏的近似高度（逻辑像素）。
///
/// 仅用于「渐进式渲染」期间占位、避免数据到达后页面大幅跳动，非主题尺寸；全部
/// 大于骨架内容自然高度以避免 RenderFlex 溢出。
const double _kSkeletonEngineSettings = 340;
const double _kSkeletonAlwaysOn = 200;
const double _kSkeletonLogLevel = 160;
const double _kSkeletonSplitTunnel = 180;
const double _kSkeletonLan = 520;
const double _kSkeletonShaper = 620;
const double _kSkeletonEngine = 240;

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
  const ProxySettingsPage({super.key, this.facade, this.scrollToShaper = false});

  /// 设置门面（测试可注入假实现；为空时用生产适配器）。
  final ProxySettingsFacade? facade;

  /// 为真时在**初始 [_load] 完成后**自动滚动到「弱网模拟」小节（由首页状态卡
  /// 的弱网模拟徽标点击触发）。该小节在 load 前不存在，故必须在 load 解析后触发。
  final bool scrollToShaper;

  @override
  State<ProxySettingsPage> createState() => _ProxySettingsPageState();
}

class _ProxySettingsPageState extends State<ProxySettingsPage> {
  late final ProxySettingsFacade _facade;

  /// 「弱网模拟」区域表头的锚点（仅用于 [widget.scrollToShaper] 的自动滚动）。
  final GlobalKey _shaperSectionKey = GlobalKey();

  /// 自动滚动只执行一次（`_load` 也可由下拉刷新 / 重试再次触发）。
  bool _didAutoScrollToShaper = false;

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
  final TextEditingController _shaperBurst = TextEditingController();
  final TextEditingController _shaperLossGoodToBad = TextEditingController();
  final TextEditingController _shaperLossBadToGood = TextEditingController();
  final TextEditingController _shaperDuplicate = TextEditingController();
  final TextEditingController _shaperReorderPct = TextEditingController();
  final TextEditingController _shaperReorderGap = TextEditingController();
  final TextEditingController _shaperSeed = TextEditingController();

  /// 各独立小节的就绪标志：加载中为 `true`，该小节解析完成（含回退默认值）后
  /// 立即清为 `false`。用于「渐进式渲染」——页面外壳先出，各小节用骨架占位。
  bool _configLoading = true;
  bool _engineLoading = true;
  bool _engineSettingsLoading = true;
  bool _lanLoading = true;
  bool _shaperLoading = true;

  /// 是否仍有任一独立小节在加载（`AppBar` 刷新按钮禁用态 / 下拉刷新判定）。
  bool get _loading =>
      _configLoading ||
      _engineLoading ||
      _engineSettingsLoading ||
      _lanLoading ||
      _shaperLoading;

  String? _error;
  bool _busy = false;
  ProxySettingsConfig _config = const ProxySettingsConfig();

  /// 已安装应用缓存（`null` = 尚未加载；首次打开选择器时按需枚举）。
  List<InstalledAppOption>? _appsCache;

  /// 首次枚举是否进行中（用于禁用按钮 + 内联 loading）。
  bool _appsLoading = false;

  /// 进行中的枚举（并发调用去重；完成后清空）。
  Future<List<InstalledAppOption>>? _appsInFlight;
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

  /// 自定义编辑的枚举选择（与当前编辑方向同步；编辑时显式下发，不再反推）。
  String _shaperJitterDistribution = 'uniform';
  String _shaperLossModel = 'none';
  String _shaperOrder = 'preserve';

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
    _shaperBurst.dispose();
    _shaperLossGoodToBad.dispose();
    _shaperLossBadToGood.dispose();
    _shaperDuplicate.dispose();
    _shaperReorderPct.dispose();
    _shaperReorderGap.dispose();
    _shaperSeed.dispose();
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
    // UI 以 kbps 展示 / 编辑；模型仍是 bps，仅在边界换算。
    _shaperRate.text = '${direction.rateBps ~/ 1000}';
    _shaperDelay.text = '${direction.delayMs}';
    _shaperJitter.text = '${direction.jitterMs}';
    _shaperLoss.text = _formatPct(direction.lossPct);
    _shaperBurst.text = '${direction.burstBytes}';
    _shaperJitterDistribution = direction.jitterDistribution;
    _shaperLossModel = direction.lossModel;
    _shaperLossGoodToBad.text = _formatPct(direction.lossGoodToBadPct);
    _shaperLossBadToGood.text = _formatPct(direction.lossBadToGoodPct);
    _shaperDuplicate.text = _formatPct(direction.duplicatePct);
    _shaperReorderPct.text = _formatPct(direction.reorderPct);
    _shaperReorderGap.text = '${direction.reorderGap}';
    _shaperOrder = direction.order;
    _shaperSeed.text = _shaper.config.seed?.toString() ?? '';
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

  /// 并发加载所有独立小节。
  ///
  /// 改造前是「顺序 await」：任一慢调用会阻塞后续全部小节。现在：
  /// * 所有独立小节用 [Future.wait] **同时启动**（列表求值时各调用已同步进入自身
  ///   首个 `await`，即「先全部启动、再等待」）；
  /// * 每个小节解析后**只更新自己的状态**并清掉自己的就绪标志（最佳努力失败回落
  ///   默认值，同样清标志），互不阻塞；
  /// * [ProxySettingsFacade.loadSettings] 仍是唯一致命调用：抛错 → 错误态（行为
  ///   与改造前一致）。
  ///
  /// 已安装应用列表保持惰性（[_ensureApps]），不在此处枚举。
  Future<void> _load() async {
    setState(() {
      _error = null;
      _configLoading = true;
      _engineLoading = true;
      _engineSettingsLoading = true;
      _lanLoading = true;
      _shaperLoading = true;
    });

    await Future.wait<void>(<Future<void>>[
      _loadConfig(),
      _loadEngine(),
      _loadEngineSettings(),
      _loadLan(),
      _loadShaper(),
    ]);

    if (!mounted) return;
    _maybeScrollToShaper();
  }

  /// 加载分流 / 始终开启 / 日志级别配置（唯一致命小节）。
  Future<void> _loadConfig() async {
    try {
      final config = await _facade.loadSettings();
      if (!mounted) return;
      setState(() {
        _config = config;
        _configLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _configLoading = false;
      });
    }
  }

  /// 加载引擎调试信息（与改造前一致：读取失败视为致命 → 错误态）。
  Future<void> _loadEngine() async {
    try {
      final engine = await _facade.loadEngineInfo();
      if (!mounted) return;
      setState(() {
        _engine = engine;
        _engineLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _engineLoading = false;
      });
    }
  }

  /// 加载引擎参数（stack / MTU）；持久化异常回落默认（gvisor / 1500），不阻断页面。
  Future<void> _loadEngineSettings() async {
    ProxyEngineSettings engineSettings;
    try {
      engineSettings = await _facade.loadEngineSettings();
    } catch (error) {
      debugPrint('代理设置：读取引擎参数失败，回落默认值：$error');
      engineSettings = const ProxyEngineSettings();
    }
    if (!mounted) return;
    setState(() {
      _engineSettings = engineSettings;
      _engineStack = _normalizeStack(engineSettings.stack);
      _engineSettingsLoading = false;
    });
    _engineMtu.text = '${engineSettings.mtu}';
  }

  /// 并发加载 LAN 配置 + 监听状态；模块不可用各自回落默认，不阻断页面。
  Future<void> _loadLan() async {
    Future<ProxyLanConfig?> loadConfig() async {
      try {
        return await _facade.loadLanConfig();
      } catch (_) {
        return null; // 模块不可用 → 保留默认（LAN 关闭）
      }
    }

    Future<ProxyLanStatus?> loadStatus() async {
      try {
        return await _facade.loadLanStatus();
      } catch (_) {
        return null; // 模块不可用 → 保留默认（未监听）
      }
    }

    final values = await Future.wait<Object?>(<Future<Object?>>[
      loadConfig(),
      loadStatus(),
    ]);
    if (!mounted) return;
    final lan = values[0] as ProxyLanConfig?;
    final lanStatus = values[1] as ProxyLanStatus?;
    setState(() {
      if (lan != null) _lan = lan;
      if (lanStatus != null) _lanStatus = lanStatus;
      _lanLoading = false;
    });
    _syncLanControllers(_lan);
  }

  /// 加载弱网配置快照；模块不可用 / 读取失败回落默认（关闭），不阻断页面。
  Future<void> _loadShaper() async {
    ProxyShaperSnapshot? shaper;
    try {
      shaper = await _facade.loadShaperConfig();
    } catch (error) {
      debugPrint('代理设置：读取弱网配置失败，回落默认值：$error');
    }
    if (!mounted) return;
    final snapshot = shaper;
    setState(() {
      if (snapshot != null) {
        _shaper = snapshot;
        _shaperEnabled = snapshot.config.enabled;
        _shaperUplink = snapshot.config.uplink;
        _shaperDownlink = snapshot.config.downlink;
        _shaperPresetId = presetForConfig(snapshot.config).id;
      }
      _shaperLoading = false;
    });
    _syncShaperControllers();
  }

  /// 初始 load 完成后，若 [ProxySettingsPage.scrollToShaper] 为真则把「弱网模拟」
  /// 区域表头滚入视口（仅一次）。
  ///
  /// 用 post-frame 回调确保锚点已在 `ListView` 中完成布局；`mounted` / context
  /// 双重兜底，绝不因滚动失败而崩溃。
  void _maybeScrollToShaper() {
    if (!widget.scrollToShaper || _didAutoScrollToShaper) return;
    _didAutoScrollToShaper = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anchor = _shaperSectionKey.currentContext;
      if (anchor == null) return;
      Scrollable.ensureVisible(
        anchor,
        duration: const Duration(milliseconds: 300),
        alignment: 0.1,
      );
    });
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

  /// 按需加载已安装应用（页面生命周期内缓存，仅首次枚举）。
  ///
  /// 并发调用复用同一 in-flight Future（去重）；加载期间 [_appsLoading] 为真，
  /// 供按钮禁用 + 内联 loading 反馈。失败时由调用方兜底为空列表。
  Future<List<InstalledAppOption>> _ensureApps() {
    final cached = _appsCache;
    if (cached != null) return Future<List<InstalledAppOption>>.value(cached);
    final inFlight = _appsInFlight;
    if (inFlight != null) return inFlight;

    setState(() => _appsLoading = true);
    final future = _facade.loadInstalledApps().then((apps) {
      _appsCache = apps;
      return apps;
    }).whenComplete(() {
      _appsInFlight = null;
      _appsLoading = false;
      if (mounted) setState(() {});
    });
    _appsInFlight = future;
    return future;
  }

  Future<void> _openAppPicker() async {
    List<InstalledAppOption> apps;
    try {
      apps = await _ensureApps();
    } catch (error) {
      // 权限被拒 / 平台异常 → 回落空列表（选择器展示空态，不崩溃）。
      debugPrint('代理设置：读取已安装应用失败，回落空列表：$error');
      apps = const <InstalledAppOption>[];
    }
    if (!mounted) return;
    final result = await AppSheet.showCustom<Set<String>>(
      context: context,
      builder: (sheetContext) => _AppPickerSheet(
        apps: apps,
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
        AppDialogs.showWarning('LAN 已启用但未配置认证，同一网络下的任何设备都可使用此网络');
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
    final built = _buildShaperDirectionFromFields();
    if (built == null) return;
    setState(() {
      if (_shaperCustomDirection == _kShaperDirDownlink) {
        _shaperDownlink = built;
      } else {
        _shaperUplink = built;
      }
    });
  }

  /// 用输入框内容构造已校验的单方向参数（完整参数面，Todo 29）。
  ///
  /// 空值 / 非数字 / 越界（[buildShaperDirectionFromStrings] 返回 `null`）→
  /// `null`，调用方**不得**下发 `net.shaper.set`。
  ///
  /// `lossModel` 由选择器显式给出；仅当模型为 `none` 且丢包 > 0 时沿用历史
  /// 行为自动按 `random` 下发——**绝不**在模型已是 `gilbertElliot` / `random`
  /// 时把它重置。
  ProxyShaperDirection? _buildShaperDirectionFromFields() {
    final loss = double.tryParse(_shaperLoss.text.trim()) ?? 0;
    final lossModel = _shaperLossModel == 'none' && loss > 0
        ? 'random'
        : _shaperLossModel;
    return buildShaperDirectionFromStrings(
      rateKbps: _shaperRate.text,
      delayMs: _shaperDelay.text,
      jitterMs: _shaperJitter.text,
      burstBytes: _shaperBurst.text,
      jitterDistribution: _shaperJitterDistribution,
      lossPct: _shaperLoss.text,
      lossModel: lossModel,
      lossGoodToBadPct: _shaperLossGoodToBad.text,
      lossBadToGoodPct: _shaperLossBadToGood.text,
      duplicatePct: _shaperDuplicate.text,
      reorderPct: _shaperReorderPct.text,
      reorderGap: _shaperReorderGap.text,
      order: _shaperOrder,
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
    final built = _buildShaperDirectionFromFields();
    if (built == null) {
      AppDialogs.showError(
        '请填写有效数值：限速 0 或 1–1000000 kbps，burst 1500–65535，'
        '延迟 ≤ 60000 ms，抖动 ≤ 30000 ms，各百分比 0–100%，重排 gap ≤ 255',
      );
      return;
    }
    final seedText = _shaperSeed.text.trim();
    final int? seed = seedText.isEmpty ? null : int.tryParse(seedText);
    if (seedText.isNotEmpty && (seed == null || seed < 0)) {
      AppDialogs.showError('seed 必须是非负整数（留空表示按时间熵自动派生）');
      return;
    }
    final uplink =
        _shaperCustomDirection == _kShaperDirUplink ? built : _shaperUplink;
    final downlink =
        _shaperCustomDirection == _kShaperDirDownlink ? built : _shaperDownlink;
    final config = buildCustomShaperConfig(
      enabled: _shaperEnabled,
      seed: seed,
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
      icon: const Icon(TablerIcons.reload),
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
        title: const Text('调试设置'),
        actions: [
          IconButton(
            tooltip: '刷新调试信息',
            icon: const Icon(TablerIcons.refresh),
            onPressed: _loading ? null : _refreshEngine,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final error = _error;
    if (error != null) {
      return _SettingsMessageState(
        icon: TablerIcons.alert_circle,
        title: '设置不可用',
        message: error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    // 渐进式渲染：页面外壳（区域表头 + 静态小节）立即渲染，各独立小节数据未就绪
    // 时用 [_SectionSkeleton] 占位，解析后原地替换为真实卡片。区域表头始终挂载，
    // 因此 `scrollToShaper` 的锚点即使在占位态也能被 `Scrollable.ensureVisible`
    // 解析。
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        // 预构建全部小节：设置页内容有限，且 [`ProxySettingsPage.scrollToShaper`]
        // 依赖「弱网模拟」锚点在 `Scrollable.ensureVisible` 前已挂载——默认懒构建
        // 会使其落在 cacheExtent 之外导致 `currentContext` 为空、滚动静默失效。
        // 该值只是懒构建窗口（非视觉尺寸），取足够覆盖整页内容的高度即可。
        scrollCacheExtent:
            const ScrollCacheExtent.pixels(_kSettingsPrebuildExtent),
        padding: AppSpacing.allLG,
        children: [
          const _RegionHeader(title: '连接与引擎'),
          if (_engineSettingsLoading)
            const _SectionSkeleton(
              key: Key('section_skeleton_engine_settings'),
              height: _kSkeletonEngineSettings,
            )
          else
            _buildEngineSettingsCard(context),
          const SizedBox(height: AppSpacing.lg),
          if (_configLoading)
            const _SectionSkeleton(
              key: Key('section_skeleton_always_on'),
              height: _kSkeletonAlwaysOn,
            )
          else
            _buildAlwaysOnCard(context),
          const SizedBox(height: AppSpacing.lg),
          if (_configLoading)
            const _SectionSkeleton(
              key: Key('section_skeleton_log_level'),
              height: _kSkeletonLogLevel,
            )
          else
            _buildLogLevelCard(context),
          const SizedBox(height: AppSpacing.xxl),
          const _RegionHeader(title: '分流与入站'),
          if (_configLoading)
            const _SectionSkeleton(
              key: Key('section_skeleton_split_tunnel'),
              height: _kSkeletonSplitTunnel,
            )
          else
            _buildSplitTunnelCard(context),
          const SizedBox(height: AppSpacing.lg),
          if (_lanLoading)
            const _SectionSkeleton(
              key: Key('section_skeleton_lan'),
              height: _kSkeletonLan,
            )
          else
            _buildLanCard(context),
          const SizedBox(height: AppSpacing.xxl),
          _RegionHeader(key: _shaperSectionKey, title: '弱网模拟'),
          if (_shaperLoading)
            const _SectionSkeleton(
              key: Key('section_skeleton_shaper'),
              height: _kSkeletonShaper,
            )
          else
            _buildShaperCard(context),
          const SizedBox(height: AppSpacing.xxl),
          const _RegionHeader(title: '域名解析'),
          _buildDnsTile(context),
          const SizedBox(height: AppSpacing.xxl),
          const _RegionHeader(title: '维护与诊断'),
          _buildStatsCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildDiagnosticsTile(context),
          const SizedBox(height: AppSpacing.lg),
          if (_engineLoading)
            const _SectionSkeleton(
              key: Key('section_skeleton_engine'),
              height: _kSkeletonEngine,
            )
          else
            _buildEngineCard(context),
        ],
      ),
    );
  }

  Widget _buildEngineSettingsCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _SectionCard(
      icon: TablerIcons.adjustments,
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
            icon: const Icon(TablerIcons.device_floppy, size: AppTypography.iconSM),
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
        leading: const Icon(TablerIcons.server),
        title: const Text('DNS 设置'),
        subtitle: const Text('解析模式、上游、DoH / DoT'),
        trailing: const Icon(TablerIcons.chevron_right),
        onTap: _openDnsPage,
      ),
    );
  }

  Widget _buildSplitTunnelCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectedCount = _config.selectedApps.length;
    return _SectionCard(
      icon: TablerIcons.apps,
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
            '全局模式：所有应用都通过隧道。',
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
                onPressed: (_busy || _appsLoading) ? null : _openAppPicker,
                child: _appsLoading
                    ? const AppLoading(size: AppLoadingSize.small)
                    : const Text('选择应用'),
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
      icon: TablerIcons.power,
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
            icon: const Icon(TablerIcons.help_circle, size: AppTypography.iconSM),
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
      icon: TablerIcons.network,
      title: '局域网监听 (LAN)',
      children: [
        SwitchListTile(
          key: const Key('lan_enabled_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('允许局域网设备使用本机网络'),
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
            _lanStatus.warning ?? '已启用但未配置认证：同一网络下的任何设备都可使用此网络。',
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
              icon: const Icon(TablerIcons.copy, size: AppTypography.iconSM),
              tooltip: '复制地址',
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('lan_save_button'),
            onPressed: _busy ? null : _applyLanConfig,
            icon: const Icon(TablerIcons.device_floppy, size: AppTypography.iconSM),
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
      icon: TablerIcons.gauge,
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
            trailing: const Icon(TablerIcons.chevron_right),
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
                    labelText: '限速 (kbps)',
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
                  key: const Key('shaper_burst_field'),
                  controller: _shaperBurst,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '突发桶 (字节)',
                    hintText: '32768',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (_shaperLossModel != 'gilbertElliot')
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: TextField(
                    key: const Key('shaper_duplicate_field'),
                    controller: _shaperDuplicate,
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '复制 (%)',
                      hintText: '0',
                    ),
                  ),
                ),
              ],
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('shaper_loss_good_to_bad_field'),
                    controller: _shaperLossGoodToBad,
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'GE 好→坏 (%)',
                      hintText: '0',
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: TextField(
                    key: const Key('shaper_loss_bad_to_good_field'),
                    controller: _shaperLossBadToGood,
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'GE 坏→好 (%)',
                      hintText: '0',
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '抖动分布',
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: AppSegmentedButton<String>(
              key: const Key('shaper_jitter_dist_selector'),
              value: _shaperJitterDistribution,
              enabled: !_busy,
              density: AppSegmentedButton.mediumDensity,
              segments: const <AppSegment<String>>[
                AppSegment(
                  value: 'uniform',
                  label: '均匀',
                  key: Key('shaper_jitter_dist_uniform'),
                ),
                AppSegment(
                  value: 'normal',
                  label: '正态',
                  key: Key('shaper_jitter_dist_normal'),
                ),
                AppSegment(
                  value: 'pareto',
                  label: '帕累托',
                  key: Key('shaper_jitter_dist_pareto'),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _shaperJitterDistribution = value),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '丢包模型',
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: AppSegmentedButton<String>(
              key: const Key('shaper_loss_model_selector'),
              value: _shaperLossModel,
              enabled: !_busy,
              density: AppSegmentedButton.mediumDensity,
              segments: const <AppSegment<String>>[
                AppSegment(
                  value: 'none',
                  label: '无',
                  key: Key('shaper_loss_model_none'),
                ),
                AppSegment(
                  value: 'random',
                  label: '随机',
                  key: Key('shaper_loss_model_random'),
                ),
                AppSegment(
                  value: 'gilbertElliot',
                  label: 'GE',
                  key: Key('shaper_loss_model_gilbert_elliot'),
                ),
              ],
              onChanged: (value) => setState(() => _shaperLossModel = value),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '包序',
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: AppSegmentedButton<String>(
              key: const Key('shaper_order_selector'),
              value: _shaperOrder,
              enabled: !_busy,
              density: AppSegmentedButton.mediumDensity,
              segments: const <AppSegment<String>>[
                AppSegment(
                  value: 'preserve',
                  label: '保持',
                  key: Key('shaper_order_preserve'),
                ),
                AppSegment(
                  value: 'reorder',
                  label: '乱序',
                  key: Key('shaper_order_reorder'),
                ),
              ],
              onChanged: (value) => setState(() => _shaperOrder = value),
            ),
          ),
          if (_shaperOrder == 'reorder') ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('shaper_reorder_pct_field'),
                    controller: _shaperReorderPct,
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '乱序 (%)',
                      hintText: '0',
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: TextField(
                    key: const Key('shaper_reorder_gap_field'),
                    controller: _shaperReorderGap,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '乱序窗口 (帧)',
                      hintText: '0',
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          TextField(
            key: const Key('shaper_seed_field'),
            controller: _shaperSeed,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '随机种子 (seed)',
              hintText: '留空 = 按时间熵派生',
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('shaper_apply_button'),
            onPressed: _busy ? null : _applyShaper,
            icon: const Icon(TablerIcons.device_floppy, size: AppTypography.iconSM),
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
        const SizedBox(height: AppSpacing.md),
        Text(
          '运行计数',
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        _buildShaperCounters(theme, scheme),
      ],
    );
  }

  /// 进程级整形计数器（`net.shaper.get` 的 `counters`，只读展示）。
  Widget _buildShaperCounters(ThemeData theme, ColorScheme scheme) {
    final counters = _shaper.counters;
    final rows = <(String, String, int)>[
      ('up_frames', '上行整形帧', counters.upFramesShaped),
      ('down_frames', '下行整形帧', counters.downFramesShaped),
      ('up_bytes', '上行整形字节', counters.upBytesShaped),
      ('down_bytes', '下行整形字节', counters.downBytesShaped),
      ('loss_dropped', '丢包', counters.lossDropped),
      ('buffer_dropped', '队列丢弃', counters.bufferDropped),
      ('duplicated', '复制', counters.duplicated),
      ('reordered', '重排', counters.reordered),
      ('buffered_frames', '缓冲帧', counters.bufferedFrames),
      ('buffered_bytes', '缓冲字节', counters.bufferedBytes),
      ('max_buffered_frames', '缓冲帧水位', counters.maxBufferedFrames),
    ];
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: AppSpacing.onlyVerticalXS,
            child: Row(
              key: Key('shaper_counter_${row.$1}'),
              children: [
                Expanded(
                  child: Text(
                    row.$2,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  '${row.$3}',
                  key: Key('shaper_counter_${row.$1}_value'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
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
      icon: TablerIcons.file_text,
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
      icon: TablerIcons.chart_bar,
      title: '域名统计',
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('stats_reset_button'),
            onPressed: _busy ? null : _resetStats,
            icon: const Icon(TablerIcons.reload, size: AppTypography.iconSM),
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

  /// 诊断 / 日志 / 规则查看器 / config 触发入口（Todo 30）。
  Widget _buildDiagnosticsTile(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: const Key('diagnostics_entry_tile'),
        leading: const Icon(TablerIcons.activity),
        title: const Text('诊断与日志'),
        subtitle: const Text('Clash 诊断控制器、日志 / 规则查看器、配置生成'),
        trailing: const Icon(TablerIcons.chevron_right),
        onTap: _openDiagnosticsPage,
      ),
    );
  }

  /// 打开诊断页（Todo 30）；返回后无需刷新本页状态。
  void _openDiagnosticsPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProxyDiagnosticsPage()),
    );
  }

  Widget _buildEngineCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final version = _engine.version;
    final ping = _engine.ping;
    final mode = _engine.mode;
    return _SectionCard(
      icon: TablerIcons.cpu,
      title: '引擎调试信息',
      trailing: IconButton(
        key: const Key('engine_refresh'),
        tooltip: '刷新',
        icon: const Icon(TablerIcons.refresh, size: AppTypography.iconMD),
        onPressed: _refreshEngine,
      ),
      children: [
        if (_engine.isEmpty)
          Text(
            '调试模块不可用，暂无调试信息。',
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
  const _RegionHeader({super.key, required this.title});

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

// ==================== 渐进式加载骨架 ====================

/// 卡片外形的小节占位骨架（渐进式渲染期间替换尚未就绪的真实卡片）。
///
/// 全部取自主题令牌：`surfaceContainerHighest` 绘制占位条、[AppRadius] 圆角、
/// [AppSpacing] 间距/尺寸，并内嵌 [AppLoading]，浅色 / 深色下均不突兀。
/// [height] 只是占位高度（近似被替换的小节），避免数据到达后页面大幅跳动。
class _SectionSkeleton extends StatelessWidget {
  const _SectionSkeleton({super.key, required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: SizedBox(
        height: height,
        child: const Padding(
          padding: AppSpacing.allLG,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _SkeletonBar(width: AppSpacing.xl, height: AppSpacing.xl),
                  SizedBox(width: AppSpacing.sm),
                  _SkeletonBar(
                    width: AppSpacing.massive * 2,
                    height: AppSpacing.md,
                  ),
                  Spacer(),
                  AppLoading(size: AppLoadingSize.small),
                ],
              ),
              SizedBox(height: AppSpacing.lg),
              _SkeletonBar(width: double.infinity, height: AppSpacing.xxxl),
              SizedBox(height: AppSpacing.md),
              _SkeletonBar(width: double.infinity, height: AppSpacing.xxxl),
            ],
          ),
        ),
      ),
    );
  }
}

/// 骨架占位条：主题令牌着色的圆角块。
class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.allXS,
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
    final query = _query.toLowerCase();
    final List<InstalledAppOption> matches = query.isEmpty
        ? <InstalledAppOption>[...widget.apps]
        : widget.apps
            .where((app) =>
                app.name.toLowerCase().contains(query) ||
                app.packageName.toLowerCase().contains(query))
            .toList();
    // 稳定排序：已选优先 → 名称（忽略大小写）→ 包名兜底。总序确定，切换勾选时
    // 只按「已选分组」重排，组内次序稳定不抖动。
    matches.sort((a, b) {
      final aSelected = _selected.contains(a.packageName);
      final bSelected = _selected.contains(b.packageName);
      if (aSelected != bSelected) return aSelected ? -1 : 1;
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (byName != 0) return byName;
      return a.packageName.compareTo(b.packageName);
    });
    return matches;
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
      icon: const Icon(TablerIcons.apps),
      // 统一弹层左右内边距（与 AppDialogs / 档位弹层一致），搜索框与列表不再贴边。
      contentPadding: AppSpacing.onlyHorizontalXL,
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
        // 内容自适应：跟随子项高度，不抢占骨架 80% 限高的剩余空白。
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('split_app_search'),
            onChanged: (value) => setState(() => _query = value.trim()),
            decoration: const InputDecoration(
              labelText: '搜索',
              hintText: '应用名 / 包名',
              prefixIcon: Icon(TablerIcons.search),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (widget.apps.isEmpty)
            Padding(
              key: const Key('split_apps_empty'),
              padding: AppSpacing.onlyVerticalXXL,
              child: Column(
                children: [
                  Icon(TablerIcons.apps,
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
      icon: const Icon(TablerIcons.gauge),
      // 统一弹层左右内边距（与 AppDialogs 的语义化弹层一致），避免档位行贴边。
      contentPadding: AppSpacing.onlyHorizontalXL,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
      scrollable: false,
      content: Column(
        // 内容自适应：档位行数少时收紧高度，不在下方留空白。
        mainAxisSize: MainAxisSize.min,
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
        // 左右内边距由弹层骨架 contentPadding 统一提供，此处只给舒适的行高。
        padding: AppSpacing.onlyVerticalMD,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: selected ? scheme.primary : scheme.onSurface,
                  fontWeight: selected
                      ? AppTypography.weightMedium
                      : AppTypography.weightRegular,
                ),
              ),
            ),
            if (selected)
              Icon(
                TablerIcons.check,
                color: scheme.primary,
                size: AppTypography.iconLG,
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
