import 'package:flutter/material.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

import 'proxy_active_node_store.dart';
import 'proxy_active_profile_store.dart';
import 'proxy_home_facade.dart';
import 'proxy_logs_page.dart';
import 'proxy_nodes_facade.dart';
import 'proxy_nodes_page.dart';
import 'proxy_profiles_page.dart';
import 'proxy_routing_mode_store.dart';
import 'proxy_run_mode_store.dart';
import 'proxy_settings_facade.dart';
import 'proxy_settings_page.dart';
import 'proxy_stats_page.dart';

/// 代理首页（VPN 状态 / 连接开关 / 实时流量 / 当前配置 / 日志·统计入口）。
///
/// **纯展示层**：状态、模式、流量、配置名全部来自 [ProxyHomeFacade] 的响应与
/// 类型化事件；连接动作只做「调门面 + 调授权触发」[ProxyVpnConsent]，不含任何
/// 解析 / 网络 / 路由 / 统计逻辑（全部在 Rust 的 `gstore_mod_proxy`）。
///
/// * 连接：`ProxyVpnConsent.prepare`（拉起系统 VPN 授权，已授权直接起服务）→
///   门面 `core.start`；
/// * 断开：门面 `core.stop` → `ProxyVpnConsent.stop`；
/// * 流量：`proxy.stats` 事件（节流 >= 1s），初始值由 `stats.traffic.get` 播种；
/// * 错误：结构化横幅 + 「重试」，模块不可用则整页错误态（绝不崩溃）。
///
/// 依赖全部可注入，组件测试无需原生模块。
class ProxyHomePage extends StatefulWidget {
  const ProxyHomePage({
    super.key,
    this.facade,
    this.vpnConsent,
    this.profileStore,
    this.nodeStore,
    this.runModeStore,
    this.routingModeStore,
    this.nodesFacade,
    this.onOpenLogs,
    this.onOpenStats,
    this.onOpenLanSettings,
    this.vpnConfigJson = '{}',
  });

  /// 门面（测试可注入假实现；为空时用 [ProxyModuleHomeFacade] 生产单例）。
  final ProxyHomeFacade? facade;

  /// VPN 授权 / 前台服务触发（测试可注入假实现；为空时走平台通道）。
  final ProxyVpnConsent? vpnConsent;

  /// 选中订阅 id 的持久化接缝（测试注入内存实现；为空时用 [ConfigStore]）。
  final ProxyActiveProfileStore? profileStore;

  /// 选中节点的持久化接缝（测试注入内存实现；为空时用 [ConfigStore]）。
  /// 节点页写入、首页读取，用于入口卡显示与节点页高亮回显。
  final ProxyActiveNodeStore? nodeStore;

  /// 用户选择的运行模式的持久化接缝（测试注入内存实现；为空时用 [ConfigStore]）。
  /// 与引擎上报的「当前运行模式」分离：断开/重连/重入页面后恢复用户选择。
  final ProxyRunModeStore? runModeStore;

  /// 用户选择的路由模式（直连/规则/全局）的持久化接缝（测试注入内存实现；
  /// 为空时用 [ConfigStore]）。与运行模式分离：新隧道默认 `rule`，连接后重放。
  final ProxyRoutingModeStore? routingModeStore;

  /// 节点页门面（测试注入假实现；为空时节点页用生产单例适配器）。
  final ProxyNodesFacade? nodesFacade;

  /// 「运行日志」快捷入口；为空时打开 [ProxyLogsPage]。
  final VoidCallback? onOpenLogs;

  /// 「流量统计」快捷入口；为空时打开 [ProxyStatsPage]。
  final VoidCallback? onOpenStats;

  /// 「局域网设置」快捷入口（模式选择为 `lanProxy` 但 LAN 未启用时的跳转）。
  /// 为空时直接打开 [ProxySettingsPage]。
  final VoidCallback? onOpenLanSettings;

  /// 传给 Kotlin `ProxyVpnService` 的配置 JSON（默认 `{}` = 全量路由）。
  /// Dart 侧**不生成**该配置，仅透传。
  final String vpnConfigJson;

  @override
  State<ProxyHomePage> createState() => _ProxyHomePageState();
}

class _ProxyHomePageState extends State<ProxyHomePage> {
  late final ProxyHomeFacade _facade;
  late final ProxyVpnConsent _vpnConsent;
  late final ProxyActiveProfileStore _profileStore;
  late final ProxyActiveNodeStore _nodeStore;
  late final ProxyRunModeStore _runModeStore;
  late final ProxyRoutingModeStore _routingStore;
  StreamSubscription<ProxyEvent>? _eventSub;

  bool _loading = true;
  String? _loadError;
  bool _busy = false;
  ProxyVersionInfo? _version;
  ProxyConnState _connState = ProxyConnState.stopped;
  ProxyMode _mode = ProxyMode.unknown;

  /// 用户选择的运行模式（持久化；未运行时用于「连接」动作）。引擎上报的当前模式
  /// 存于 [_mode]，两者分离，引擎事件不覆盖本字段。
  ProxyMode _targetMode = ProxyMode.vpn;

  /// 用户选择的路由模式（持久化）；连接成功后重放到引擎，未运行时隐藏开关。
  ProxyRoutingMode _routingMode = ProxyRoutingMode.rule;
  ProxyLanStatus? _lanStatus;
  ProxyStateError? _actionError;
  String? _stateReason;
  ProxyStatsEvent? _stats;
  ProxyNodeDelayEvent? _nodeDelay;
  List<ProxyConfigWarning> _configWarnings = const <ProxyConfigWarning>[];

  String? _profileName;
  int? _profileNodeCount;

  /// 当前选中的订阅 id（持久化；连接时经 `CoreStartRequest.profileId` 传入）。
  String? _selectedProfileId;
  String? _currentOutbound;

  /// 各代理组的实时选中（`node.list`）；引擎运行时优先用于「当前节点」展示。
  NodeListResult? _nodeList;

  /// 当前选中的节点（持久化；节点页写入，首页展示 + 节点页高亮回显）。
  ProxyActiveNode? _activeNode;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleHomeFacade();
    _vpnConsent = widget.vpnConsent ?? const PlatformProxyVpnConsent();
    _profileStore =
        widget.profileStore ?? const ConfigStoreProxyActiveProfileStore();
    _nodeStore = widget.nodeStore ?? const ConfigStoreProxyActiveNodeStore();
    _runModeStore =
        widget.runModeStore ?? const ConfigStoreProxyRunModeStore();
    _routingStore =
        widget.routingModeStore ?? const ConfigStoreProxyRoutingModeStore();
    _eventSub = _facade.events.listen(_onEvent, onError: _onEventError);
    _load();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  // ==================== 加载 / 事件 ====================

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final ping = await _facade.ping();
      final version = await _facade.version();
      // 只读展示数据，失败不影响主状态（best-effort）。
      final profiles = await _safe(() => _facade.profileList());
      final traffic = await _safe(() => _facade.statsTrafficGet(topDomains: 1));
      final lan = await _safe(() => _facade.lanStatus());
      final nodeList = await _safe(() => _facade.nodeList());

      // 解析「当前订阅」：优先沿用持久化 id；失效时若只剩 1 个订阅则自动选中并
      // 持久化，否则清除。选中 id 连接时经 `core.start.profileId` 生效。
      final ProfileSummary? selected = await _resolveSelectedProfile(
        profiles?.profiles ?? const <ProfileSummary>[],
      );
      final ProxyActiveNode? activeNode =
          await _safe<ProxyActiveNode?>(() => _nodeStore.read());
      // 用户选择的运行模式（与引擎上报的当前模式分离）。
      final ProxyMode? storedRunMode =
          await _safe<ProxyMode?>(() => _runModeStore.read());
      // 用户选择的路由模式（新隧道默认 rule，连接后重放）。
      final ProxyRoutingMode? storedRouting =
          await _safe<ProxyRoutingMode?>(() => _routingStore.read());

      if (!mounted) return;
      setState(() {
        _connState = ping.state ?? ProxyConnState.stopped;
        _mode = ping.mode ?? ProxyMode.unknown;
        _targetMode = _persistedTarget(storedRunMode) ?? _selectableMode(_mode);
        if (storedRouting != null &&
            storedRouting != ProxyRoutingMode.unknown) {
          _routingMode = storedRouting;
        }
        _lanStatus = lan;
        _version = version;
        _selectedProfileId = selected?.id;
        _profileName = selected?.name;
        _profileNodeCount = selected?.nodeCount;
        _activeNode = activeNode;
        if (traffic != null) _applyTopDomains(traffic.topDomains);
        if (nodeList != null) _nodeList = nodeList;
        _loading = false;
      });
      if (_isRunning) await _syncRoutingMode();
      await _recoverEngineIfServiceRunning();
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = '代理模块加载失败：$error';
        _loading = false;
      });
    }
  }

  /// best-effort 只读调用：模块错误降级为 `null`，不影响主状态。
  Future<T?> _safe<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (_) {
      return null;
    }
  }

  /// 解析「当前订阅」：优先沿用持久化 id；失效时若只剩 1 个订阅则自动选中并
  /// 持久化，否则清除。返回 null 表示「未选择」。
  Future<ProfileSummary?> _resolveSelectedProfile(
    List<ProfileSummary> profiles,
  ) async {
    final String? persistedId =
        await _safe<String?>(() => _profileStore.read());
    final Set<String> ids = <String>{for (final p in profiles) p.id};
    if (persistedId != null && ids.contains(persistedId)) {
      for (final profile in profiles) {
        if (profile.id == persistedId) return profile;
      }
    } else if (profiles.length == 1) {
      final ProfileSummary only = profiles.first;
      await _safe(() => _profileStore.write(only.id));
      return only;
    } else if (persistedId != null) {
      await _safe(() => _profileStore.clear());
    }
    return null;
  }

  /// 从订阅页返回后重新解析选中订阅（用户可能改选 / 增删）。
  Future<void> _reloadSelectedProfile() async {
    final profiles = await _safe(() => _facade.profileList());
    final ProfileSummary? selected = await _resolveSelectedProfile(
      profiles?.profiles ?? const <ProfileSummary>[],
    );
    if (!mounted) return;
    setState(() {
      _selectedProfileId = selected?.id;
      _profileName = selected?.name;
      _profileNodeCount = selected?.nodeCount;
    });
  }

  /// 从节点页返回后重新读取选中节点（用户可能改选）；best-effort，失败降级为
  /// 保持旧值（绝不崩溃）。
  Future<void> _reloadActiveNode() async {
    final ProxyActiveNode? activeNode =
        await _safe<ProxyActiveNode?>(() => _nodeStore.read());
    if (!mounted) return;
    setState(() => _activeNode = activeNode);
  }

  /// always-on / 进程死亡恢复：前台服务在跑但 Rust 引擎已停（进程被系统重启后
  /// 引擎状态丢失）时，重新 `core.start` 把数据面拉起来。失败走错误横幅，不崩溃。
  Future<void> _recoverEngineIfServiceRunning() async {
    try {
      if (!await _vpnConsent.isRunning()) return;
      final status = await _facade.coreStart(
        CoreStartRequest(profileId: _selectedProfileId),
      );
      if (!mounted) return;
      setState(() {
        _connState = status.state;
        _mode = status.mode;
      });
      await _applyPersistedRoutingMode();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = ProxyStateError(
          code: 'PROXY_ENGINE_RECOVER_FAILED',
          message: '$error',
        );
      });
    }
  }

  // ==================== 路由模式（直连 / 规则 / 全局） ====================

  /// 运行中时以引擎实际路由模式为准（best-effort，失败保持持久化值）。
  Future<void> _syncRoutingMode() async {
    if (!_isRunning) return;
    final result = await _safe(() => _facade.routingGetMode());
    if (!mounted || result == null) return;
    if (result.mode == ProxyRoutingMode.unknown) return;
    setState(() => _routingMode = result.mode);
  }

  /// 新隧道默认 `rule`：连接成功后把持久化的路由模式重放给引擎，并反映结果。
  Future<void> _applyPersistedRoutingMode() async {
    final stored = await _safe<ProxyRoutingMode?>(() => _routingStore.read());
    final target = stored ?? _routingMode;
    if (target == ProxyRoutingMode.unknown) return;
    final result = await _safe(() => _facade.routingSetMode(target.wire));
    if (!mounted || result == null) return;
    if (result.mode == ProxyRoutingMode.unknown) return;
    setState(() => _routingMode = result.mode);
  }

  /// 用户点选分段：请求切换、用响应的 `mode` 反映状态并持久化意图
  /// （引擎未运行时 `applied:false` 也持久化）。失败展示错误并保留旧值。
  Future<void> _selectRoutingMode(ProxyRoutingMode mode) async {
    if (_busy || mode == ProxyRoutingMode.unknown) return;
    setState(() => _busy = true);
    try {
      final result = await _facade.routingSetMode(mode.wire);
      await _safe(() => _routingStore.write(mode));
      if (!mounted) return;
      setState(() {
        if (result.mode != ProxyRoutingMode.unknown) _routingMode = result.mode;
      });
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError =
            ProxyStateError(code: error.code, message: error.message);
      });
      AppDialogs.showError(error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = ProxyStateError(
          code: 'PROXY_ACTION_FAILED',
          message: '$error',
        );
      });
      AppDialogs.showError('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 路由模式药丸分段控件（仅在已连接时渲染；引擎运行时才可切换）。
  ///
  /// 复用设计系统 [AppSegmentedButton]/[AppSegment]，不手写胶囊；颜色/字号全部
  /// 取自主题令牌与组件自身。
  Widget _buildRoutingModeSwitch(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '路由模式',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppSegmentedButton<ProxyRoutingMode>(
          key: const Key('proxy-routing-mode-switch'),
          value: _routingMode,
          enabled: !_busy,
          segments: const <AppSegment<ProxyRoutingMode>>[
            AppSegment(
              value: ProxyRoutingMode.direct,
              label: '直连',
              key: Key('proxy-routing-mode-direct'),
            ),
            AppSegment(
              value: ProxyRoutingMode.rule,
              label: '规则',
              key: Key('proxy-routing-mode-rule'),
            ),
            AppSegment(
              value: ProxyRoutingMode.global,
              label: '全局',
              key: Key('proxy-routing-mode-global'),
            ),
          ],
          onChanged: _selectRoutingMode,
        ),
      ],
    );
  }

  /// 从 Rust 已排序的 topDomains 取首个 outbound 作为「当前节点」展示。
  ///
  /// 只是渲染 Rust 给出的值（[TrafficSnapshot.topDomains] 由 Rust 排序），
  /// Dart 不做任何聚合 / 排序。
  void _applyTopDomains(List<DomainStat> topDomains) {
    if (topDomains.isEmpty) return;
    final outbound = topDomains.first.outbound;
    if (outbound.isNotEmpty) _currentOutbound = outbound;
  }

  void _onEvent(ProxyEvent event) {
    if (!mounted) return;
    var refreshNodes = false;
    setState(() {
      switch (event) {
        case ProxyStateEvent():
          _connState = event.state;
          _mode = event.mode;
          if (event.state == ProxyConnState.running) {
            refreshNodes = true;
          } else if (event.state == ProxyConnState.stopped) {
            _nodeList = null;
          }
          _actionError = event.error;
          _stateReason = event.reason;
        case ProxyModeEvent():
          // 引擎上报的当前模式不覆盖用户的持久化选择（_targetMode 不变）。
          _mode = event.mode;
        case ProxyStatsEvent():
          _stats = event;
          _applyTopDomains(event.topDomains);
          if (_isRunning) refreshNodes = true;
        case ProxyConfigAppliedEvent():
          break;
        case ProxyNodeDelayEvent():
          _nodeDelay = event;
        case ProxySubscriptionUpdatedEvent():
        case ProxySubscriptionProgressEvent():
        case ProxySubscriptionFailedEvent():
        case ProxySubscriptionAddedEvent():
        case ProxySubscriptionRemovedEvent():
        case ProxyConnEvent():
        case ProxyDnsEvent():
        case ProxyTunReleasedEvent():
          break;
      }
    });
    if (refreshNodes) _refreshNodeList();
  }

  /// 与 stats 同节奏刷新实时选中节点：best-effort，失败保持旧值（不崩溃）。
  Future<void> _refreshNodeList() async {
    final live = await _safe(() => _facade.nodeList());
    if (!mounted || live == null) return;
    setState(() => _nodeList = live);
  }

  void _onEventError(Object error) {
    if (!mounted) return;
    setState(
      () => _actionError = ProxyStateError(
        code: 'PROXY_EVENT_STREAM',
        message: '$error',
      ),
    );
  }

  // ==================== 连接 / 断开 ====================

  Future<void> _toggleConnection() async {
    if (_busy) return;
    final connecting = !_isRunning;
    setState(() {
      _busy = true;
      _actionError = null;
      _stateReason = null;
      _connState =
          connecting ? ProxyConnState.starting : ProxyConnState.stopping;
    });
    try {
      if (connecting) {
        final target = _targetMode;
        if (target == ProxyMode.vpn) {
          // 连接必须带上持久化的分流配置（Todo 23 → Todo 24 交接），仅在显式传入
          // 非默认配置时才直接用 widget 参数。
          var configJson = widget.vpnConfigJson;
          if (configJson == '{}') {
            configJson =
                await _safe(() => _facade.vpnConfigJson()) ?? configJson;
          }
          final prepared = await _vpnConsent.prepare(configJson: configJson);
          if (!prepared) {
            throw const ProxyModuleException(
              code: 'PROXY_VPN_CONSENT_DENIED',
              message: 'VPN 授权未通过，无法建立连接',
            );
          }
        }
        final status = await _facade.coreStart(
          CoreStartRequest(mode: target.wire, profileId: _selectedProfileId),
        );
        if (!mounted) return;
        setState(() {
          _connState = status.state;
          _mode = status.mode;
          _targetMode = _selectableMode(status.mode);
          final name = status.profileName;
          if (name != null && name.isNotEmpty) _profileName = name;
          _configWarnings = status.warnings;
        });
        // 新隧道默认 rule：连接成功后重放持久化的路由模式。
        await _applyPersistedRoutingMode();
      } else {
        // 断开必须「先停引擎、再停系统服务」，且停服务用 try/finally 兜底：
        // core.stop 抛错（引擎异常 / 模块不可用 / 超时）时，若直接走 catch，
        // 系统 VpnService 会残留持有 TUN、VPN 图标不消失。停服务是尽力而为，
        // 其自身异常不得覆盖 core.stop 的原始错误（_safe 吞掉并返回 null）。
        CoreStopResult? stopped;
        try {
          stopped = await _facade.coreStop();
        } finally {
          await _safe(() => _vpnConsent.stop());
        }
        if (!mounted) return;
        setState(() {
          _connState = stopped?.state ?? ProxyConnState.stopped;
          _stats = null;
          _currentOutbound = null;
          _nodeList = null;
          _configWarnings = const <ProxyConfigWarning>[];
        });
      }
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError =
            ProxyStateError(code: error.code, message: error.message);
        if (connecting) _connState = ProxyConnState.stopped;
      });
      AppDialogs.showError(error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = ProxyStateError(
          code: 'PROXY_ACTION_FAILED',
          message: '$error',
        );
        if (connecting) _connState = ProxyConnState.stopped;
      });
      AppDialogs.showError('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 错误横幅的「重试」：连接失败重试连接，运行中错误重载快照。
  Future<void> _retry() async {
    if (_isRunning) {
      await _load();
    } else {
      await _toggleConnection();
    }
  }

  // ==================== 运行模式（VPN / 局域网代理） ====================

  Future<void> _openModePicker() async {
    if (_busy) return;
    final result = await AppSheet.show<ProxyMode>(
      context: context,
      title: '运行模式',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _modeOption(
            mode: ProxyMode.vpn,
            key: const Key('proxy-mode-option-vpn'),
            icon: Icons.shield_outlined,
            title: 'VPN 模式（全设备）',
            subtitle: '手机全部流量经由代理，并共享给其它设备（当 LAN 已启用）',
          ),
          _modeOption(
            mode: ProxyMode.lanProxy,
            key: const Key('proxy-mode-option-lanProxy'),
            icon: Icons.lan_outlined,
            title: '局域网代理（仅共享给其它设备）',
            subtitle: '手机自身流量不经过代理，仅向局域网提供入站',
          ),
        ],
      ),
    );
    if (result == null) return;
    // 用户的模式选择立即持久化：断开 / 重连 / 重入页面后恢复该选择。
    await _safe(() => _runModeStore.write(result));
    await _requestMode(result);
  }

  Widget _modeOption({
    required ProxyMode mode,
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = _targetMode == mode;
    return InkWell(
      key: key,
      onTap: () => Navigator.of(context).pop(mode),
      child: Padding(
        padding: AppSpacing.onlyVerticalSM,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: AppTypography.iconMD,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check,
                  size: AppTypography.iconMD, color: scheme.primary),
          ],
        ),
      ),
    );
  }

  /// 用户选择了一个模式：未运行时只记录目标（由「连接」启动）；运行中则实时切换。
  Future<void> _requestMode(ProxyMode target) async {
    if (target == _targetMode && (!_isRunning || target == _mode)) return;
    if (!_isRunning) {
      setState(() => _targetMode = target);
      return;
    }
    if (target == _mode) {
      setState(() => _targetMode = target);
      return;
    }
    await _switchMode(target);
  }

  /// 实时切换模式。模式状态机在 Rust：这里只负责平台前置/后置动作
  /// （VPN 需先 `establish`；离开 VPN 后停掉前台服务）与结构化错误展示。
  Future<void> _switchMode(ProxyMode target) async {
    setState(() {
      _busy = true;
      _actionError = null;
      _stateReason = null;
      _connState = ProxyConnState.starting;
    });
    try {
      if (target == ProxyMode.vpn) {
        var configJson = widget.vpnConfigJson;
        if (configJson == '{}') {
          configJson = await _safe(() => _facade.vpnConfigJson()) ?? configJson;
        }
        final prepared = await _vpnConsent.prepare(configJson: configJson);
        if (!prepared) {
          throw const ProxyModuleException(
            code: 'PROXY_VPN_CONSENT_DENIED',
            message: 'VPN 授权未通过，无法切换模式',
          );
        }
      }
      final result = await _facade.coreSetMode(target.wire);
      if (target == ProxyMode.lanProxy) {
        // lanProxy 不持有 VpnService：停掉前台服务，避免残留 VPN。
        await _vpnConsent.stop();
      }
      if (!mounted) return;
      setState(() {
        _connState = ProxyConnState.running;
        _mode = result.mode;
        _targetMode = _selectableMode(result.mode);
      });
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError =
            ProxyStateError(code: error.code, message: error.message);
        _connState = ProxyConnState.running;
        _targetMode = _selectableMode(_mode);
      });
      AppDialogs.showError(error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = ProxyStateError(
          code: 'PROXY_ACTION_FAILED',
          message: '$error',
        );
        _connState = ProxyConnState.running;
        _targetMode = _selectableMode(_mode);
      });
      AppDialogs.showError('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openLanSettings() {
    final callback = widget.onOpenLanSettings;
    if (callback != null) {
      callback();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProxySettingsPage()),
    );
  }

  /// 「订阅」入口：打开订阅 / 配置管理页。
  ///
  /// 返回后重新解析选中订阅——用户可能改选 / 增删；首页据此刷新「当前配置」。
  Future<void> _openProfiles() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProxyProfilesPage(profileStore: _profileStore),
      ),
    );
    if (!mounted) return;
    await _reloadSelectedProfile();
  }

  /// 「节点选择」入口：打开节点 / 代理组页。
  ///
  /// 首页只持有**选中的 profile id**；节点与分组清单由节点页经门面
  /// `profile.get` 自行加载（本页不做任何解析）。无选中订阅时节点页渲染其
  /// 设计好的空态。返回后重新读取选中节点——用户可能改选，首页入口卡据此刷新。
  Future<void> _openNodes() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProxyNodesPage(
          profileId: _selectedProfileId,
          facade: widget.nodesFacade,
          nodeStore: _nodeStore,
          initialActiveByGroup: _activeNodeMap(),
        ),
      ),
    );
    if (!mounted) return;
    await _reloadActiveNode();
  }

  /// 节点页高亮回显的初始映射：`{group: node}`（无持久化选择时为空）。
  Map<String, String> _activeNodeMap() {
    final selection = _activeNode;
    if (selection == null ||
        selection.group.isEmpty ||
        selection.node.isEmpty) {
      return const <String, String>{};
    }
    return <String, String>{selection.group: selection.node};
  }

  // ==================== 展示辅助 ====================

  bool get _isRunning => _connState == ProxyConnState.running;

  /// 可选模式归一化：只有 vpn / lanProxy 是可选择的目标（`off` 由断开按钮表达）。
  ProxyMode _selectableMode(ProxyMode mode) =>
      mode == ProxyMode.lanProxy ? ProxyMode.lanProxy : ProxyMode.vpn;

  /// 持久化模式归一化：`null` / `unknown` / `off` 视为「未存储」，返回 `null`。
  ProxyMode? _persistedTarget(ProxyMode? mode) {
    if (mode == null || mode == ProxyMode.unknown || mode == ProxyMode.off) {
      return null;
    }
    return _selectableMode(mode);
  }

  bool get _lanEnabled => _lanStatus?.config?.enabled ?? false;

  bool get _lanProxyNeedsWarning =>
      _targetMode == ProxyMode.lanProxy && !_lanEnabled;

  bool get _isTransitioning =>
      _connState == ProxyConnState.starting ||
      _connState == ProxyConnState.stopping;

  String get _statusText => switch (_connState) {
        ProxyConnState.stopped => '未连接',
        ProxyConnState.starting => '正在连接…',
        ProxyConnState.running => '已连接',
        ProxyConnState.stopping => '正在断开…',
        ProxyConnState.unknown => '状态未知',
      };

  String get _toggleLabel {
    if (_connState == ProxyConnState.starting) return '连接中…';
    if (_connState == ProxyConnState.stopping) return '断开中…';
    if (_isRunning) return '断开';
    return '连接';
  }

  String get _modeText => switch (_mode) {
        ProxyMode.off => '关闭',
        ProxyMode.vpn => 'VPN',
        ProxyMode.lanProxy => '局域网代理',
        ProxyMode.unknown => '未知',
      };

  String get _profileText {
    final name = _profileName;
    if (name == null || name.isEmpty) return '未选择';
    final count = _profileNodeCount;
    return count == null ? name : '$name（$count 节点）';
  }

  String get _nodeText {
    final live = _nodeList;
    if (_isRunning && live != null && live.engineRunning) {
      final current = live.current;
      if (current != null) {
        final leaf = current.node;
        if (leaf != null && leaf.isNotEmpty) return leaf;
        final now = current.now;
        if (now != null && now.isNotEmpty) return now;
      }
    }
    final active = _activeNode;
    if (active != null && active.node.isNotEmpty) return active.node;
    final outbound = _currentOutbound;
    return (outbound == null || outbound.isEmpty) ? '自动' : outbound;
  }

  /// 入口卡「订阅」副标题：当前选中订阅名（无选中降级为中性文案）。
  String get _subscriptionCardSubtitle {
    final name = _profileName;
    return (name == null || name.isEmpty) ? '未选择订阅' : name;
  }

  /// 入口卡「节点选择」副标题：优先持久化的选中节点（`ProxyActiveNodeStore`），
  /// 否则中性文案。（运行时 outbound 仍由状态卡的「当前节点」行表达，避免重复。）
  String get _nodesCardSubtitle {
    final active = _activeNode;
    if (active != null && active.node.isNotEmpty) {
      return active.group.isEmpty
          ? active.node
          : '${active.group} · ${active.node}';
    }
    return '未选择节点';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('代理')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final loadError = _loadError;
    if (loadError != null) {
      return _buildUnavailable(context, loadError);
    }
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        _buildStatusCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildEntryCards(
          context,
          subscriptionSubtitle: _subscriptionCardSubtitle,
          nodesSubtitle: _nodesCardSubtitle,
        ),
        const SizedBox(height: AppSpacing.lg),
        _buildTrafficCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildQuickEntries(context),
        if (_nodeDelay != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _buildDelayCard(context, _nodeDelay!),
        ],
        if (_version != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _buildVersionCard(context, _version!),
        ],
      ],
    );
  }

  /// 模块未安装 / 不可用：结构化错误态（非崩溃）。
  Widget _buildUnavailable(BuildContext context, String message) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: AppSpacing.allXL,
            child: Column(
              children: [
                Icon(
                  Icons.extension_off_outlined,
                  size: AppTypography.iconXXXL,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: AppSpacing.md),
                Text('代理模块不可用', style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ==================== 运行模式 / 入口卡 ====================

  String get _modeOptionLabel =>
      _targetMode == ProxyMode.lanProxy ? '局域网代理（仅共享给其它设备）' : 'VPN 模式（全设备）';

  /// 入口区：**两行 × 每行两张独立 [Card]**。
  ///
  /// 第 1 行 订阅 / 节点选择；第 2 行 代理模式 / 代理设置。代理设置**始终**
  /// 渲染（不依赖运行模式）；LAN 未启用警告渲染在两行之下。
  ///
  /// [subscriptionSubtitle] / [nodesSubtitle] 由调用方传入（当前选中订阅名 /
  /// 当前选中节点），避免入口卡再自行解析状态。
  Widget _buildEntryCards(
    BuildContext context, {
    required String subscriptionSubtitle,
    required String nodesSubtitle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildEntryCard(
                  context,
                  key: const Key('proxy-subscribe-tile'),
                  icon: Icons.rss_feed_outlined,
                  title: '订阅',
                  subtitle: subscriptionSubtitle,
                  onTap: _openProfiles,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _buildEntryCard(
                  context,
                  key: const Key('proxy-nodes-tile'),
                  icon: Icons.account_tree_outlined,
                  title: '节点选择',
                  subtitle: nodesSubtitle,
                  onTap: _openNodes,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildEntryCard(
                  context,
                  key: const Key('proxy-mode-tile'),
                  icon: Icons.tune,
                  title: '代理模式',
                  subtitle: _modeOptionLabel,
                  onTap: _busy ? null : _openModePicker,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _buildEntryCard(
                  context,
                  key: const Key('proxy-settings-tile'),
                  icon: Icons.lan_outlined,
                  title: '代理设置',
                  subtitle: '局域网监听与入站端口',
                  onTap: _openLanSettings,
                ),
              ),
            ],
          ),
        ),
        if (_lanProxyNeedsWarning) ...[
          const SizedBox(height: AppSpacing.sm),
          _buildLanWarning(context),
        ],
      ],
    );
  }

  /// LAN 未启用但目标模式为局域网代理时的结构化警告 + 快捷入口。
  Widget _buildLanWarning(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const Key('proxy-lan-disabled-warning'),
      width: double.infinity,
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: AppRadius.allMD,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.warning_amber_outlined,
                size: AppTypography.iconMD,
                color: scheme.onTertiaryContainer,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  '局域网代理需要先启用局域网监听',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onTertiaryContainer,
                    fontWeight: AppTypography.weightMedium,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '当前「局域网监听 (LAN)」处于关闭状态，切换到局域网代理会返回 '
            'PROXY_NO_INBOUND。请先在设置中开启它。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onTertiaryContainer,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('proxy-open-lan-settings'),
              onPressed: _openLanSettings,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onTertiaryContainer,
              ),
              child: const Text('去开启局域网监听'),
            ),
          ),
        ],
      ),
    );
  }

  /// 单张入口 [Card]：图标 + 标题 + 说明，卡内 [InkWell] 水波纹与主题令牌
  /// （圆角 / 间距 / 字号全部走设计系统）。每张卡彼此独立（2×2 布局）。
  Widget _buildEntryCard(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: AppRadius.allLG,
        child: Padding(
          padding: AppSpacing.allMD,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: AppTypography.iconMD, color: scheme.primary),
              const SizedBox(height: AppSpacing.sm),
              Text(title, style: theme.textTheme.bodyLarge),
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== 状态卡 ====================

  Widget _buildStatusCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasError = _actionError != null;
    // 连接状态色**只反映连接状态**（运行 → primary / 过渡 → tertiary /
    // 停止 → onSurfaceVariant）。错误仅由下方错误横幅（errorContainer）表达，
    // 绝不把状态图标 / 文案染成 error 红（否则「连接成功但引擎报错」会被误读为
    // 「断开按钮变红」）。
    final statusColor = _isRunning
        ? scheme.primary
        : _isTransitioning
            ? scheme.tertiary
            : scheme.onSurfaceVariant;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _isRunning
                      ? Icons.shield_outlined
                      : Icons.shield_moon_outlined,
                  size: AppTypography.iconXL,
                  color: statusColor,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    _statusText,
                    key: const Key('proxy-status-text'),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _infoRow(theme, '模式', _modeText),
            _infoRow(theme, '当前配置', _profileText),
            _infoRow(theme, '当前节点', _nodeText),
            if (_isRunning) ...[
              const SizedBox(height: AppSpacing.md),
              _buildRoutingModeSwitch(context),
            ],
            if (_stateReason != null && _stateReason!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(_stateReason!, style: theme.textTheme.bodySmall),
            ],
            if (hasError) ...[
              const SizedBox(height: AppSpacing.md),
              _buildErrorBanner(context, _actionError!),
            ],
            if (_configWarnings.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              _buildWarnings(context, _configWarnings),
            ],
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: double.infinity,
              child: _isRunning
                  ? OutlinedButton.icon(
                      onPressed: _busy ? null : _toggleConnection,
                      icon: _buttonIcon(),
                      label: Text(_toggleLabel),
                    )
                  : FilledButton.icon(
                      onPressed: _busy ? null : _toggleConnection,
                      icon: _buttonIcon(),
                      label: Text(_toggleLabel),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buttonIcon() {
    if (_busy) {
      return const SizedBox(
        width: AppTypography.iconMD,
        height: AppTypography.iconMD,
        child: AppLoading(size: AppLoadingSize.small),
      );
    }
    return Icon(_isRunning ? Icons.power_settings_new : Icons.shield_outlined);
  }

  Widget _buildErrorBanner(BuildContext context, ProxyStateError error) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const Key('proxy-error-banner'),
      width: double.infinity,
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: AppRadius.allMD,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: AppTypography.iconMD,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  error.code.isEmpty ? '代理引擎错误' : error.code,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: AppTypography.weightMedium,
                  ),
                ),
              ),
            ],
          ),
          if (error.message.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              error.message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : _retry,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onErrorContainer,
              ),
              child: const Text('重试'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarnings(
    BuildContext context,
    List<ProxyConfigWarning> warnings,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: AppRadius.allMD,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '配置警告（${warnings.length}）',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onTertiaryContainer,
              fontWeight: AppTypography.weightMedium,
            ),
          ),
          for (final warning in warnings)
            Padding(
              padding: AppSpacing.onlyTopXS,
              child: Text(
                warning.message.isEmpty ? warning.code : warning.message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onTertiaryContainer,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ==================== 流量卡 ====================

  Widget _buildTrafficCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stats = _stats;
    final uploadBytes = stats?.uploadBytes ?? 0;
    final downloadBytes = stats?.downloadBytes ?? 0;
    final upBps = stats?.upBps ?? 0;
    final downBps = stats?.downBps ?? 0;
    final activeConns = stats?.activeConns ?? 0;
    final maxBps = upBps > downBps ? upBps : downBps;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.swap_vert_outlined,
                  size: AppTypography.iconMD,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text('实时流量', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            _infoRow(
              theme,
              '上传',
              '${byteSize(uploadBytes)} · ${byteSize(upBps)}/s',
              valueKey: const Key('proxy-upload-total'),
            ),
            _infoRow(
              theme,
              '下载',
              '${byteSize(downloadBytes)} · ${byteSize(downBps)}/s',
              valueKey: const Key('proxy-download-total'),
            ),
            _infoRow(
              theme,
              '活动连接',
              '$activeConns',
              valueKey: const Key('proxy-active-conns'),
            ),
            if ((stats?.domainCount ?? 0) > 0)
              _infoRow(theme, '已统计域名', '${stats!.domainCount}'),
            const SizedBox(height: AppSpacing.sm),
            _ThroughputBar(
              icon: Icons.arrow_upward,
              bps: upBps,
              maxBps: maxBps,
              color: scheme.tertiary,
            ),
            const SizedBox(height: AppSpacing.xs),
            _ThroughputBar(
              icon: Icons.arrow_downward,
              bps: downBps,
              maxBps: maxBps,
              color: scheme.primary,
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 快捷入口 ====================

  Widget _buildQuickEntries(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('运行日志'),
            subtitle: const Text('连接、DNS 与模块日志'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openLogs,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.bar_chart_outlined),
            title: const Text('流量统计'),
            subtitle: const Text('按域名的连接数与流量'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openStats,
          ),
        ],
      ),
    );
  }

  void _openLogs() {
    final callback = widget.onOpenLogs;
    if (callback != null) {
      callback();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProxyLogsPage()),
    );
  }

  void _openStats() {
    final callback = widget.onOpenStats;
    if (callback != null) {
      callback();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProxyStatsPage()),
    );
  }

  // ==================== 延迟 / 版本 ====================

  Widget _buildDelayCard(BuildContext context, ProxyNodeDelayEvent delay) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.speed_outlined),
        title: Text(delay.node.isEmpty ? delay.group : delay.node),
        subtitle: Text(delay.group),
        trailing: Text(
          delay.error == null ? '${delay.delayMs} ms' : '失败',
          style: theme.textTheme.labelLarge?.copyWith(
            color: delay.error == null
                ? theme.colorScheme.primary
                : theme.colorScheme.error,
          ),
        ),
      ),
    );
  }

  Widget _buildVersionCard(BuildContext context, ProxyVersionInfo version) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('模块信息', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            _infoRow(theme, '版本', version.moduleVersion),
            _infoRow(theme, 'API', '${version.apiVersion}'),
            _infoRow(
              theme,
              'Host ABI',
              '${version.hostAbi}（最低 ${version.minHostAbi}）',
            ),
            if (version.targetArch.isNotEmpty)
              _infoRow(theme, '架构', version.targetArch),
          ],
        ),
      ),
    );
  }

  // ==================== 通用行 ====================

  Widget _infoRow(
    ThemeData theme,
    String label,
    String value, {
    Key? valueKey,
  }) {
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Text(
              value,
              key: valueKey,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: AppTypography.weightMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单行吞吐量条：按当前方向速率的相对大小填充，仅用于展示。
///
/// 颜色全部取自 [ColorScheme]，不硬编码。
class _ThroughputBar extends StatelessWidget {
  const _ThroughputBar({
    required this.icon,
    required this.bps,
    required this.maxBps,
    required this.color,
  });

  final IconData icon;
  final int bps;
  final int maxBps;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final value = maxBps <= 0 ? 0.0 : (bps / maxBps).clamp(0.0, 1.0);

    return Row(
      children: [
        Icon(icon, size: AppTypography.iconXS, color: color),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: ClipRRect(
            borderRadius: AppRadius.allXS,
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          '${byteSize(bps)}/s',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
