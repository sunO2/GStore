import 'package:flutter/material.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

import 'proxy_home_facade.dart';
import 'proxy_profiles_page.dart';
import 'proxy_settings_facade.dart';
import 'proxy_settings_page.dart';

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
    this.onOpenLogs,
    this.onOpenStats,
    this.onOpenLanSettings,
    this.vpnConfigJson = '{}',
  });

  /// 门面（测试可注入假实现；为空时用 [ProxyModuleHomeFacade] 生产单例）。
  final ProxyHomeFacade? facade;

  /// VPN 授权 / 前台服务触发（测试可注入假实现；为空时走平台通道）。
  final ProxyVpnConsent? vpnConsent;

  /// 「运行日志」快捷入口；为空时给出「后续版本开放」提示。
  final VoidCallback? onOpenLogs;

  /// 「流量统计」快捷入口；为空时给出「后续版本开放」提示。
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
  StreamSubscription<ProxyEvent>? _eventSub;

  bool _loading = true;
  String? _loadError;
  bool _busy = false;
  ProxyVersionInfo? _version;
  ProxyConnState _connState = ProxyConnState.stopped;
  ProxyMode _mode = ProxyMode.unknown;
  /// 目标模式（未运行时用于「连接」动作；运行时即当前模式）。
  ProxyMode _targetMode = ProxyMode.vpn;
  ProxyLanStatus? _lanStatus;
  ProxyStateError? _actionError;
  String? _stateReason;
  ProxyStatsEvent? _stats;
  ProxyNodeDelayEvent? _nodeDelay;
  List<ProxyConfigWarning> _configWarnings = const <ProxyConfigWarning>[];

  String? _profileName;
  int? _profileNodeCount;
  String? _currentOutbound;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleHomeFacade();
    _vpnConsent = widget.vpnConsent ?? const PlatformProxyVpnConsent();
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
      if (!mounted) return;
      setState(() {
        _connState = ping.state ?? ProxyConnState.stopped;
        _mode = ping.mode ?? ProxyMode.unknown;
        _targetMode = _selectableMode(_mode);
        _lanStatus = lan;
        _version = version;
        if (profiles != null && profiles.profiles.isNotEmpty) {
          final profile = profiles.profiles.first;
          _profileName = profile.name;
          _profileNodeCount = profile.nodeCount;
        }
        if (traffic != null) _applyTopDomains(traffic.topDomains);
        _loading = false;
      });
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

  /// always-on / 进程死亡恢复：前台服务在跑但 Rust 引擎已停（进程被系统重启后
  /// 引擎状态丢失）时，重新 `core.start` 把数据面拉起来。失败走错误横幅，不崩溃。
  Future<void> _recoverEngineIfServiceRunning() async {
    try {
      if (!await _vpnConsent.isRunning()) return;
      final status = await _facade.coreStart(const CoreStartRequest());
      if (!mounted) return;
      setState(() {
        _connState = status.state;
        _mode = status.mode;
      });
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
    setState(() {
      switch (event) {
        case ProxyStateEvent():
          _connState = event.state;
          _mode = event.mode;
          if (event.state == ProxyConnState.running) {
            _targetMode = _selectableMode(event.mode);
          }
          _actionError = event.error;
          _stateReason = event.reason;
        case ProxyModeEvent():
          _mode = event.mode;
          _targetMode = _selectableMode(event.mode);
        case ProxyStatsEvent():
          _stats = event;
          _applyTopDomains(event.topDomains);
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
            configJson = await _safe(() => _facade.vpnConfigJson()) ?? configJson;
          }
          final prepared =
              await _vpnConsent.prepare(configJson: configJson);
          if (!prepared) {
            throw const ProxyModuleException(
              code: 'PROXY_VPN_CONSENT_DENIED',
              message: 'VPN 授权未通过，无法建立连接',
            );
          }
        }
        final status = await _facade.coreStart(CoreStartRequest(mode: target.wire));
        if (!mounted) return;
        setState(() {
          _connState = status.state;
          _mode = status.mode;
          _targetMode = _selectableMode(status.mode);
          final name = status.profileName;
          if (name != null && name.isNotEmpty) _profileName = name;
          _configWarnings = status.warnings;
        });
      } else {
        final stopped = await _facade.coreStop();
        await _vpnConsent.stop();
        if (!mounted) return;
        setState(() {
          _connState = stopped.state;
          _stats = null;
          _currentOutbound = null;
          _configWarnings = const <ProxyConfigWarning>[];
        });
      }
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = ProxyStateError(code: error.code, message: error.message);
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
              Icon(Icons.check, size: AppTypography.iconMD, color: scheme.primary),
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
        _actionError = ProxyStateError(code: error.code, message: error.message);
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
  void _openProfiles() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProxyProfilesPage()),
    );
  }

  // ==================== 展示辅助 ====================

  bool get _isRunning => _connState == ProxyConnState.running;

  /// 可选模式归一化：只有 vpn / lanProxy 是可选择的目标（`off` 由断开按钮表达）。
  ProxyMode _selectableMode(ProxyMode mode) =>
      mode == ProxyMode.lanProxy ? ProxyMode.lanProxy : ProxyMode.vpn;

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
    final outbound = _currentOutbound;
    return (outbound == null || outbound.isEmpty) ? '自动' : outbound;
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
        _buildModeCard(context),
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

  String get _modeOptionLabel => _targetMode == ProxyMode.lanProxy
      ? '局域网代理（仅共享给其它设备）'
      : 'VPN 模式（全设备）';

  Widget _buildModeCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 「代理设置」只在当前 / 目标模式为局域网代理时出现；VPN 模式不渲染。
    final showSettings =
        _mode == ProxyMode.lanProxy || _targetMode == ProxyMode.lanProxy;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          // Row A：订阅（订阅 / 配置管理入口，整行）。
          ListTile(
            key: const Key('proxy-subscribe-tile'),
            leading: Icon(Icons.rss_feed_outlined, color: scheme.primary),
            title: const Text('订阅'),
            subtitle: const Text('导入/更新节点订阅'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openProfiles,
          ),
          // Row B：代理模式 + 代理设置（并排；设置仅 lanProxy 模式渲染）。
          Padding(
            padding: AppSpacing.onlyHorizontalMD,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _buildModeEntryTile(
                      context,
                      key: const Key('proxy-mode-tile'),
                      icon: Icons.tune,
                      title: '代理模式',
                      subtitle: _modeOptionLabel,
                      onTap: _busy ? null : _openModePicker,
                    ),
                  ),
                  if (showSettings) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: _buildModeEntryTile(
                        context,
                        key: const Key('proxy-settings-tile'),
                        icon: Icons.lan_outlined,
                        title: '代理设置',
                        subtitle: '局域网监听与入站端口',
                        onTap: _openLanSettings,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_lanProxyNeedsWarning)
            Padding(
              padding: AppSpacing.onlyHorizontalLG,
              child: Container(
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
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }

  /// Row B 的紧凑入口：图标 + 标题 + 说明，沿用卡内 [InkWell] 水波纹与
  /// 主题令牌（圆角 / 间距 / 字号全部走设计系统）。
  Widget _buildModeEntryTile(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: AppRadius.allMD,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: AppTypography.iconMD, color: scheme.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
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
          ],
        ),
      ),
    );
  }

  // ==================== 状态卡 ====================

  Widget _buildStatusCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasError = _actionError != null;
    final statusColor = hasError
        ? scheme.error
        : _isRunning
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
    AppDialogs.showInfo('日志查看器将在后续版本开放');
  }

  void _openStats() {
    final callback = widget.onOpenStats;
    if (callback != null) {
      callback();
      return;
    }
    AppDialogs.showInfo('流量统计将在后续版本开放');
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
