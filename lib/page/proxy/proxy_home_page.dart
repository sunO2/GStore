import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/service/proxy_ca_service.dart';
import 'package:gstore/core/service/proxy_connect_controller.dart';

import 'proxy_active_node_store.dart';
import 'proxy_active_profile_store.dart';
import 'proxy_capture_ca_gate.dart';
import 'proxy_capture_settings_page.dart';
import 'proxy_connections_page.dart';
import 'proxy_engine_settings_store.dart';
import 'proxy_geo_provisioner.dart';
import 'proxy_home_facade.dart';
import 'proxy_requests_page.dart';
import 'proxy_nodes_facade.dart';
import 'proxy_nodes_page.dart';
import 'proxy_profiles_page.dart';
import 'proxy_routing_mode_store.dart';
import 'proxy_run_mode_store.dart';
import 'proxy_settings_facade.dart';
import 'proxy_settings_page.dart';
import 'proxy_shaper_presets.dart';
import 'proxy_site_probe.dart';
import 'proxy_site_probe_card.dart';
import 'proxy_stats_page.dart';
import 'proxy_traffic_chart.dart';

/// 代理首页（VPN 状态 / 连接开关 / 实时流量 / 当前配置 / 域名·IP·统计入口）。
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
    this.engineSettingsStore,
    this.nodesFacade,
    this.geoProvisionerFactory,
    this.siteProbe,
    this.onOpenRequests,
    this.onOpenStats,
    this.onOpenConnections,
    this.onOpenLanSettings,
    this.onOpenCaptureSettings,
    this.splitTunnelFacade,
    this.caService,
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

  /// 引擎侧设置（stack / MTU）的持久化接缝（测试注入内存实现；为空时用
  /// [ConfigStore]）。连接 / 引擎恢复时读取并随 `core.start` 的请求下发。
  final ProxyEngineSettingsStore? engineSettingsStore;

  /// 用户选择的路由模式（直连/规则/全局）的持久化接缝（测试注入内存实现；
  /// 为空时用 [ConfigStore]）。与运行模式分离：新隧道默认 `rule`，连接后重放。
  final ProxyRoutingModeStore? routingModeStore;

  /// 节点页门面（测试注入假实现；为空时节点页用生产单例适配器）。
  final ProxyNodesFacade? nodesFacade;

  /// geo provisioning 组装工厂（测试注入假工厂；为空时用生产单例
  /// [ProxyGeoProvisionerFactory.instance]）。规则模式下页面据此 kickoff +
  /// 后台 `waitReady` 反映状态。
  final ProxyGeoProvisionerFactory? geoProvisionerFactory;

  /// 网站连通性探测接缝（测试注入假实现；为空时卡片用生产 [SiteProbe]）。
  /// 探测遵循当前代理与规则；仅用户手动触发，不在页面加载时自动执行。
  final SiteProbe? siteProbe;

  /// 「请求域名 / IP」快捷入口；为空时打开 [ProxyRequestsPage]。
  final VoidCallback? onOpenRequests;

  /// 「流量统计」快捷入口；为空时打开 [ProxyStatsPage]。
  final VoidCallback? onOpenStats;

  /// 「活动连接」快捷入口（显示当前活动连接数）；为空时打开
  /// [ProxyConnectionsPage]。
  final VoidCallback? onOpenConnections;

  /// 「局域网设置」快捷入口（模式选择为 `lanProxy` 但 LAN 未启用时的跳转）。
  /// 为空时直接打开 [ProxySettingsPage]。
  final VoidCallback? onOpenLanSettings;

  /// 「抓包设置 ›」入口注入缝（测试可注入计数回调断言跳转）。
  ///
  /// 为空时**生产兜底**打开 [ProxyCaptureSettingsPage]（与 [onOpenRequests] /
  /// [onOpenStats] / [onOpenLanSettings] 同构）。宿主 `app_router.dart` 用
  /// `const ProxyHomePage()` 从不注入本字段，因此生产路径必须自带 fallback，
  /// 否则会错误落到「尚未接入」提示。
  final VoidCallback? onOpenCaptureSettings;

  /// 分流门面（启动对账：`routing` 应用范围抓包依赖按应用分流）。
  ///
  /// 为空时用生产 [ProxyModuleSettingsFacade]；测试注入内存假实现即可密闭。
  final ProxySplitTunnelFacade? splitTunnelFacade;

  /// CA 安装 / 信任探测能力（测试可注入假实现；为空时走平台通道）。
  ///
  /// 仅用于把 `HTTP+HTTPS` 摘要从「已生成」细化到「是否已安装」；探测失败 /
  /// 平台不支持时**保持未知**，绝不谎报为「未安装」。
  final ProxyCaService? caService;

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
  late final ProxyEngineSettingsStore _engineStore;
  late final ProxyGeoProvisionerFactory _geoFactory;
  late final ProxyCaService _caService;

  /// 懒创建并缓存的生产 provisioner（清单异步加载，创建完成后回填给协调器）。
  ProxyGeoProvisioner? _geoProvisioner;
  Future<ProxyGeoProvisioner?>? _geoFuture;

  /// 规则模式 CN 直连 geo 数据的准备状态（驱动非阻塞提示 / 重试）。
  _GeoStatus _geoStatus = _GeoStatus.idle;

  /// geo 下载失败时 Rust 上报的首个资产错误原因（`geo.assets[].error`）。
  /// 用于在失败横幅里显示「为什么失败」，而不只是泛化文案。
  String? _geoError;

  /// 连接 / 断开编排器（UI 无关，注入首页各接缝；供快捷磁贴复用同一流程）。
  late final ProxyConnectController _controller;
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

  /// 实时流量折线图的 60 秒环形缓冲（上行 / 下行），每收到一条 `proxy.stats`
  /// 事件追加一个样本；断开 / 清空时重置。
  final ProxyTrafficBuffer _traffic = ProxyTrafficBuffer();

  /// 域名聚合的已淘汰计数（仅 `stats.traffic.get` 快照携带，事件不携带）。
  int _statsEvicted = 0;

  ProxyNodeDelayEvent? _nodeDelay;
  List<ProxyConfigWarning> _configWarnings = const <ProxyConfigWarning>[];

  String? _profileName;
  int? _profileNodeCount;

  /// 当前选中的订阅 id（持久化；连接时经 `CoreStartRequest.profileId` 传入）。
  String? _selectedProfileId;
  String? _currentOutbound;

  /// 各代理组的实时选中（`node.list`）；引擎运行时优先用于「当前节点」展示。
  NodeListResult? _nodeList;

  /// 弱网模拟快照（`net.shaper.get`，best-effort）；`config.enabled` 为真时在状态
  /// 卡标题右侧展示「弱网模拟 · <档位>」徽标。
  ProxyShaperSnapshot? _shaper;

  /// 抓包 / MITM 门控配置（`capture.config.get`，best-effort）。
  ///
  /// `null` = 模块未提供 `capture.*`（区块禁用并提示），与「已加载但 `enabled:false`」
  /// 严格区分，避免把「不可用」误报成「已关闭」。
  CaptureConfig? _captureConfig;

  /// CA 是否已生成（`capture.ca.get`，best-effort）。仅用于状态摘要区分
  /// `仅 HTTP` / `HTTP+HTTPS`；开启动作前仍会实时复核（绝不凭缓存放行）。
  bool _captureCaGenerated = false;

  /// 最近一次 `capture.ca.get` 的完整信息（best-effort；供安装状态探测使用）。
  CaptureCaInfo? _captureCaInfo;

  /// 系统证书是否已安装（`systemCaInstalled`，best-effort）。
  ///
  /// `null` = 未知 / 探测失败 / 平台不支持；`false` 时摘要如实降级为
  /// `HTTP+HTTPS（CA 未安装）`。绝不谎报。
  bool? _captureCaInstalled;

  /// 抓包总开关下发中（防抖；期间开关禁用）。
  bool _captureBusy = false;

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
    _engineStore =
        widget.engineSettingsStore ?? const ConfigStoreProxyEngineSettingsStore();
    _geoFactory =
        widget.geoProvisionerFactory ?? ProxyGeoProvisionerFactory.instance;
    _caService = widget.caService ?? MethodChannelProxyCaService();
    _controller = ProxyConnectController(
      facade: _facade,
      vpnConsent: _vpnConsent,
      engineSettingsStore: _engineStore,
      routingModeStore: _routingStore,
      captureScopeGate: HomeFacadeCaptureScopeGate(_facade),
      splitTunnelFacade: widget.splitTunnelFacade ?? ProxyModuleSettingsFacade(),
    );
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
      final traffic = await _safe(() => _facade.statsTrafficGet(topDomains: 3));
      final lan = await _safe(() => _facade.lanStatus());
      final nodeList = await _safe(() => _facade.nodeList());
      final shaper = await _safe(() => _facade.loadShaperConfig());
      // 抓包门控配置（best-effort）：`null` = 模块未提供 `capture.*` → 区块禁用。
      final capture = await _safe(() => _facade.captureConfigGet());
      // 启动对账：`routing` 应用范围抓包与 VPN 分流不一致（漂移）→ 自动关闭抓包。
      // 非 null 即发生了自动关闭，需把展示配置同步为关闭并提示用户。
      final captureDrift = await _controller.reconcileCaptureAppScope();
      final captureCa =
          capture == null ? null : await _safe(() => _facade.captureCaGet());

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
        _shaper = shaper;
        _captureConfig = captureDrift == null
            ? capture
            : capture?.copyWith(enabled: false);
        _captureCaGenerated = captureCa?.generated ?? false;
        _captureCaInfo = captureCa;
        _selectedProfileId = selected?.id;
        _profileName = selected?.name;
        _profileNodeCount = selected?.nodeCount;
        _activeNode = activeNode;
        if (traffic != null) {
          // 用快照播种实时流量：既填充 `_stats`（首条事件到达前不空白），
          // 也把最新一点补进折线缓冲，避免从零突变。
          _stats = ProxyStatsEvent(
            uploadBytes: traffic.uploadBytes,
            downloadBytes: traffic.downloadBytes,
            activeConns: traffic.activeConns,
            upBps: traffic.upBps,
            downBps: traffic.downBps,
            domainCount: traffic.domainCount,
            flowCount: traffic.flowCount,
            capacity: traffic.capacity,
            topDomains: traffic.topDomains,
          );
          _statsEvicted = traffic.evicted;
          _traffic.clear();
          _traffic.add(upBps: traffic.upBps, downBps: traffic.downBps);
          _applyTopDomains(traffic.topDomains);
        }
        if (nodeList != null) _nodeList = nodeList;
        _loading = false;
      });
      // 安装状态探测（best-effort，不阻塞主状态）：把摘要从「已生成」细化到
      // 「是否已安装」；失败 / 平台不支持时保持未知，绝不谎报为未安装。
      unawaited(_probeCaptureCaInstalled());
      if (captureDrift != null) {
        AppDialogs.showWarning(captureDrift);
      }
      if (_isRunning) await _syncRoutingMode();
      await _recoverEngineIfServiceRunning();
      // 规则模式：页面初始化即 best-effort 触发 geo provisioning（后台下载）。
      unawaited(_prepareGeoIfRule());
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = '调试模块加载失败：$error';
        _loading = false;
      });
    }
  }

  /// 探测系统证书存储是否已安装当前根 CA（best-effort）。
  ///
  /// 仅在 CA 已生成时探测；通道不可用（平台不支持）或探测失败时保持
  /// `null`（未知），标签回退到 `HTTP+HTTPS`，**不**谎报为「未安装」。
  Future<void> _probeCaptureCaInstalled() async {
    final info = _captureCaInfo;
    if (info == null || !info.generated) return;
    try {
      final installed = await _caService.systemCaInstalled(
        pem: info.pem.isEmpty ? null : info.pem,
      );
      if (!mounted) return;
      setState(() => _captureCaInstalled = installed);
    } on ProxyCaException {
      // 平台不支持检测 / 探测失败：保持未知。
    } catch (_) {
      // best-effort：探测失败不影响主流程。
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

  /// 读取持久化的引擎侧设置（stack / MTU）；存储异常时回落默认值。
  ///
  /// best-effort：绝不抛错，避免持久化失败阻断连接 / 引擎恢复。
  Future<ProxyEngineSettings> _readEngineSettings() async {
    try {
      return await _engineStore.read();
    } catch (_) {
      // 存储异常 → 默认引擎参数（gvisor / 1500）。
      return const ProxyEngineSettings();
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
      final settings = await _readEngineSettings();
      final status = await _facade.coreStart(
        CoreStartRequest(
          profileId: _selectedProfileId,
          stack: settings.stack,
          mtu: settings.mtu,
        ),
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
  ///
  /// 编排（读取存储 / `routing.set_mode` / 失败吞掉）在 [ProxyConnectController]，
  /// 本页只把回报的模式反映到界面状态。
  Future<void> _applyPersistedRoutingMode() async {
    final applied = await _controller.replayPersistedRoutingMode(
      fallbackRoutingMode: _routingMode,
    );
    if (!mounted || applied == null) return;
    setState(() => _routingMode = applied);
  }

  // ==================== geo provisioning（规则模式 CN 直连） ====================

  /// 懒创建并缓存 provisioner；创建完成后回填给 [ProxyConnectController]。
  ///
  /// 并发调用复用同一 Future；清单加载失败返回 `null`（页面 best-effort 跳过）。
  Future<ProxyGeoProvisioner?> _ensureGeoProvisioner() {
    final existing = _geoProvisioner;
    if (existing != null) return Future<ProxyGeoProvisioner?>.value(existing);
    final pending = _geoFuture;
    if (pending != null) return pending;
    final created = _geoFactory.create().then((provisioner) {
      if (provisioner != null) {
        _geoProvisioner = provisioner;
        _controller.geoProvisioner = provisioner;
      }
      return provisioner;
    });
    _geoFuture = created;
    return created;
  }

  /// 目标路由模式为 `rule` 时触发 geo provisioning，并后台等待就绪反映状态。
  ///
  /// best-effort：非 `rule` / provisioner 不可用不处理；kickoff 失败 → 失败态
  /// （展示重试）；`waitReady` 在后台进行，不阻塞页面。成功保持静默（仅清除提示）。
  Future<void> _prepareGeoIfRule({bool force = false}) async {
    if (_routingMode != ProxyRoutingMode.rule) return;
    final provisioner = await _ensureGeoProvisioner();
    if (!mounted || provisioner == null) return;
    if (_geoStatus == _GeoStatus.preparing) return;
    setState(() {
      _geoStatus = _GeoStatus.preparing;
      _geoError = null;
    });
    final kickedOff = await provisioner.kickoff(
      profileId: _selectedProfileId,
      force: force,
    );
    if (!mounted) return;
    if (!kickedOff) {
      await _markGeoFailed(provisioner);
      return;
    }
    // 后台等待下载完成（引擎会自动重编译规则，无需二次 reload）。
    final ready = await provisioner.waitReady();
    if (!mounted) return;
    if (ready) {
      setState(() {
        _geoStatus = _GeoStatus.ready;
        _geoError = null;
      });
      return;
    }
    await _markGeoFailed(provisioner);
  }

  /// 进入失败态并尽力取出 Rust 上报的失败原因（`geo.assets[].error`）。
  ///
  /// best-effort：原因取不到（`null`）时保留泛化失败文案，绝不因取原因而崩溃。
  Future<void> _markGeoFailed(ProxyGeoProvisioner provisioner) async {
    final reason = await provisioner.lastFailureReason();
    if (!mounted) return;
    setState(() {
      _geoStatus = _GeoStatus.failed;
      _geoError = (reason != null && reason.isNotEmpty) ? reason : null;
    });
  }

  /// 失败后的重试：`force` 绕过 provisioner 的 60s 失败节流后重新 kickoff。
  Future<void> _retryGeo() async {
    if (_geoStatus == _GeoStatus.preparing) return;
    setState(() {
      _geoStatus = _GeoStatus.idle;
      _geoError = null;
    });
    await _prepareGeoIfRule(force: true);
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
      // 切到规则模式：best-effort 触发 CN 直连 geo provisioning。
      if (mode == ProxyRoutingMode.rule) {
        unawaited(_prepareGeoIfRule());
      }
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
    // 标签与药丸各占一行：标题在上，药丸换行左对齐到下一行。
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
          density: AppSegmentedButton.mediumDensity,
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
            _traffic.clear();
            _statsEvicted = 0;
          }
          _actionError = event.error;
          _stateReason = event.reason;
        case ProxyModeEvent():
          // 引擎上报的当前模式不覆盖用户的持久化选择（_targetMode 不变）。
          _mode = event.mode;
        case ProxyStatsEvent():
          _stats = event;
          _traffic.add(upBps: event.upBps, downBps: event.downBps);
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
        case ProxyRequestEvent():
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
        // 规则模式连接前确保 provisioner 已回填给协调器（kickoff 在 core.start
        // 之前 best-effort 执行；清单已缓存时此处零开销）。
        if (_routingMode == ProxyRoutingMode.rule) {
          await _ensureGeoProvisioner();
        }
        // 连接编排（可选授权 prepare → core.start → 重放路由模式）全部由
        // [ProxyConnectController] 负责；本页只消费回报的契约模型更新界面状态，
        // 错误原样冒泡到下方统一错误处理（行为与重构前一致）。
        final outcome = await _controller.connect(
          targetMode: _targetMode,
          profileId: _selectedProfileId,
          vpnConfigJson: widget.vpnConfigJson,
          fallbackRoutingMode: _routingMode,
        );
        if (!mounted) return;
        setState(() {
          final status = outcome.status;
          _connState = status.state;
          _mode = status.mode;
          _targetMode = _selectableMode(status.mode);
          final name = status.profileName;
          if (name != null && name.isNotEmpty) _profileName = name;
          _configWarnings = status.warnings;
          final routing = outcome.routingMode;
          if (routing != null) _routingMode = routing;
        });
      } else {
        // 断开的「先停引擎、再停系统服务（try/finally 兜底）」编排在
        // [ProxyConnectController.disconnect]；本页只反映停止后的状态。
        final stopped = await _controller.disconnect();
        if (!mounted) return;
        setState(() {
          _connState = stopped?.state ?? ProxyConnState.stopped;
          _stats = null;
          _statsEvicted = 0;
          _traffic.clear();
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
      // 统一弹层左右内边距（与 AppDialogs 的语义化弹层一致），避免行贴边。
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _modeOption(
            mode: ProxyMode.vpn,
            key: const Key('proxy-mode-option-vpn'),
            icon: TablerIcons.shield,
            title: 'VPN 模式（全设备）',
            subtitle: '手机全部流量经由隧道，并共享给其它设备（当 LAN 已启用）',
          ),
          _modeOption(
            mode: ProxyMode.lanProxy,
            key: const Key('proxy-mode-option-lanProxy'),
            icon: TablerIcons.network,
            title: '局域网共享（仅共享给其它设备）',
            subtitle: '手机自身流量不经过隧道，仅向局域网提供入站',
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
              Icon(TablerIcons.check,
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
    unawaited(_openSettingsAndReload());
  }

  /// 打开 [ProxySettingsPage]，返回后重新 [_load]——用户可能在其中切换弱网模拟 /
  /// 引擎设置，首页据此刷新（best-effort，失败不阻断）。
  ///
  /// [scrollToShaper] 为真时把「滚动到弱网模拟小节」意图透传给设置页（由状态卡
  /// 徽标点击触发）；设置页自身在该页初始 load 完成后执行滚动。
  Future<void> _openSettingsAndReload({bool scrollToShaper = false}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProxySettingsPage(scrollToShaper: scrollToShaper),
      ),
    );
    if (!mounted) return;
    await _load();
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
        ProxyMode.lanProxy => '局域网共享',
        ProxyMode.unknown => '未知',
      };

  String get _profileText {
    final name = _profileName;
    if (name == null || name.isEmpty) return '未选择';
    final count = _profileNodeCount;
    return count == null ? name : '$name（$count 个端子）';
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
    return (name == null || name.isEmpty) ? '未选择网络组' : name;
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
    return '未选择端子';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网络调试')),
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
        _buildCaptureCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildTrafficCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildQuickEntries(context),
        if (_geoStatus == _GeoStatus.preparing ||
            _geoStatus == _GeoStatus.failed) ...[
          const SizedBox(height: AppSpacing.lg),
          _buildGeoStatusBanner(context),
        ],
        if (_nodeDelay != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _buildDelayCard(context, _nodeDelay!),
        ],
        const SizedBox(height: AppSpacing.lg),
        ProxySiteProbeCard(probe: widget.siteProbe),
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
                  TablerIcons.puzzle_off,
                  size: AppTypography.iconXXXL,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: AppSpacing.md),
                Text('调试模块不可用', style: theme.textTheme.titleMedium),
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
      _targetMode == ProxyMode.lanProxy ? '局域网共享（仅共享给其它设备）' : 'VPN 模式（全设备）';

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
                  icon: TablerIcons.rss,
                  title: '网络组',
                  subtitle: subscriptionSubtitle,
                  onTap: _openProfiles,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _buildEntryCard(
                  context,
                  key: const Key('proxy-nodes-tile'),
                  icon: TablerIcons.sitemap,
                  title: '网络选择',
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
                  icon: TablerIcons.adjustments,
                  title: '网络模式',
                  subtitle: _modeOptionLabel,
                  onTap: _busy ? null : _openModePicker,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _buildEntryCard(
                  context,
                  key: const Key('proxy-settings-tile'),
                  icon: TablerIcons.network,
                  title: '调试设置',
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
                TablerIcons.alert_triangle,
                size: AppTypography.iconMD,
                color: scheme.onTertiaryContainer,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  '局域网共享需要先启用局域网监听',
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
            '当前「局域网监听 (LAN)」处于关闭状态，切换到局域网共享会返回 '
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

  /// 状态卡标题右侧的弱网模拟徽标：`弱网模拟 · <档位>`。
  ///
  /// 档位经纯函数 [presetForConfig] 从已加载配置反查（未知 → 自定义）。配色用
  /// `secondaryContainer`（M3「已选中 / 强调但非主色」语义）：与状态卡自身的连接
  /// 状态色（primary / tertiary / onSurfaceVariant）都不冲突，也不与错误色混淆。
  ///
  /// 点击进入 [ProxySettingsPage] 并自动滚动到「弱网模拟」小节；外观保持不变，仅
  /// 在最外层套一层透明 [Material] + [InkWell] 提供主题水波纹与可访问按钮语义。
  Widget _buildShaperBadge(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = presetForConfig(_shaper!.config).label;
    return Semantics(
      button: true,
      label: '弱网模拟 · $label，点击进入设置',
      child: Material(
        type: MaterialType.transparency,
        borderRadius: AppRadius.allSM,
        child: InkWell(
          key: const Key('proxy-shaper-badge-tap'),
          onTap: () => unawaited(_openSettingsAndReload(scrollToShaper: true)),
          borderRadius: AppRadius.allSM,
          // 透明内边距扩大点击热区，彩色药丸本身尺寸 / 外观不变。
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xs),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 140),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: AppRadius.allSM,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    TablerIcons.gauge,
                    size: AppTypography.iconSM,
                    color: scheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(
                    child: Text(
                      '弱网模拟 · $label',
                      key: const Key('proxy-shaper-badge'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

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
                      ? TablerIcons.shield
                      : TablerIcons.shield_off,
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
                if (_shaper?.config.enabled == true) ...[
                  const SizedBox(width: AppSpacing.sm),
                  _buildShaperBadge(context),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _infoRow(theme, '模式', _modeText),
            _infoRow(theme, '当前配置', _profileText),
            _infoRow(theme, '网络端子', _nodeText),
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
              // 断开是破坏性动作：主题 error 底 + onError 前景；连接保持默认 primary/filled。
              // （状态图标 / 文案不得染 error，见卡片顶部注释；本处只改动作按钮。）
              child: _isRunning
                  ? FilledButton.icon(
                      key: const Key('proxy-disconnect-button'),
                      onPressed: _busy ? null : _toggleConnection,
                      icon: _buttonIcon(),
                      label: Text(_toggleLabel),
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.error,
                        foregroundColor: scheme.onError,
                      ),
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
    return Icon(_isRunning ? TablerIcons.power : TablerIcons.shield);
  }

  /// 规则模式 geo 数据的非阻塞状态条：准备中（spinner + 文案）/ 失败（重试）。
  ///
  /// 颜色全部取自主题令牌（`tertiaryContainer` 准备中 / `errorContainer` 失败），
  /// 不阻塞连接、不用弹框。
  Widget _buildGeoStatusBanner(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = _geoStatus == _GeoStatus.failed;
    final containerColor =
        failed ? scheme.errorContainer : scheme.tertiaryContainer;
    final contentColor =
        failed ? scheme.onErrorContainer : scheme.onTertiaryContainer;
    return Container(
      key: const Key('proxy-geo-status-banner'),
      width: double.infinity,
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: AppRadius.allMD,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (failed)
                Icon(
                  TablerIcons.alert_circle,
                  size: AppTypography.iconMD,
                  color: contentColor,
                )
              else
                const SizedBox(
                  width: AppTypography.iconMD,
                  height: AppTypography.iconMD,
                  child: AppLoading(size: AppLoadingSize.small),
                ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  failed ? 'CN 直连规则数据准备失败' : '正在准备 CN 直连规则数据…',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: contentColor,
                    fontWeight: AppTypography.weightMedium,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            failed
                ? ((_geoError != null && _geoError!.isNotEmpty)
                    ? '原因：$_geoError'
                    : '规则模式依赖的 geo 数据下载失败，可重试。')
                : '后台下载中，不影响当前连接；完成后 CN 直连规则自动生效。',
            key: failed && _geoError != null && _geoError!.isNotEmpty
                ? const Key('proxy-geo-error')
                : null,
            style: theme.textTheme.bodySmall?.copyWith(color: contentColor),
          ),
          if (failed)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('proxy-geo-retry'),
                onPressed: _busy ? null : _retryGeo,
                style: TextButton.styleFrom(foregroundColor: contentColor),
                child: const Text('重新准备'),
              ),
            ),
        ],
      ),
    );
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
                TablerIcons.alert_circle,
                size: AppTypography.iconMD,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  error.code.isEmpty ? '调试引擎错误' : error.code,
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
    final capacity = stats?.capacity ?? 0;
    final evicted = _statsEvicted;
    final domainCount = stats?.domainCount ?? 0;
    final flowCount = stats?.flowCount ?? 0;
    final topDomains = stats?.topDomains ?? const <DomainStat>[];

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
                  TablerIcons.arrows_up_down,
                  size: AppTypography.iconMD,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text('实时流量', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text(
                  '最近 60 秒',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            // 60 秒双序列平滑折线（下 = primary，上 = tertiary）。
            ProxyTrafficChart(buffer: _traffic),
            const SizedBox(height: AppSpacing.sm),
            _trafficMetricRow(
              theme,
              '实时速率',
              <Widget>[
                _speedValue(
                  '↑ ${byteSize(upBps)}/s',
                  color: scheme.tertiary,
                  key: const Key('proxy-upload-speed'),
                ),
                _speedValue(
                  '↓ ${byteSize(downBps)}/s',
                  color: scheme.primary,
                  key: const Key('proxy-download-speed'),
                ),
              ],
            ),
            _trafficMetricRow(
              theme,
              '累计',
              <Widget>[
                _totalValue(
                  theme,
                  '↑ ${byteSize(uploadBytes)}',
                  key: const Key('proxy-upload-total'),
                ),
                _totalValue(
                  theme,
                  '↓ ${byteSize(downloadBytes)}',
                  key: const Key('proxy-download-total'),
                ),
              ],
            ),
            _infoRow(
              theme,
              '活动连接',
              '$activeConns',
              valueKey: const Key('proxy-active-conns'),
            ),
            // 已淘汰计数仅由 `stats.traffic.get` 快照携带（事件不含），有值才显示。
            if (evicted > 0)
              _infoRow(
                theme,
                '容量/淘汰',
                '$capacity / $evicted',
                valueKey: const Key('proxy-capacity-evicted'),
                subtle: true,
              ),
            if (domainCount > 0) _infoRow(theme, '已统计域名', '$domainCount'),
            if (flowCount > 0)
              _infoRow(
                theme,
                '跟踪连接',
                '$flowCount',
                valueKey: const Key('proxy-flow-count'),
              ),
            if (topDomains.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Top 3 域名',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              for (var i = 0; i < topDomains.length && i < 3; i++)
                _infoRow(
                  theme,
                  '${i + 1}',
                  '${topDomains[i].domain} · '
                      '${byteSize(topDomains[i].uploadBytes + topDomains[i].downloadBytes)}',
                  valueKey: i == 0 ? const Key('proxy-top-domain') : null,
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 流量指标行：左侧标签 + 右侧右对齐的一组数值（窄屏由各数值自身省略）。
  Widget _trafficMetricRow(
    ThemeData theme,
    String label,
    List<Widget> values,
  ) {
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var i = 0; i < values.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.md),
                  Flexible(child: values[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 实时速率数值：`AppTypography.number` 强调，颜色取主题令牌。
  Widget _speedValue(
    String text, {
    required Color color,
    required Key key,
  }) {
    return Text(
      text,
      key: key,
      textAlign: TextAlign.right,
      overflow: TextOverflow.ellipsis,
      style: AppTypography.number.copyWith(color: color),
    );
  }

  /// 累计流量数值：常规 body 强调（**无** `/s`）。
  Widget _totalValue(
    ThemeData theme,
    String text, {
    required Key key,
  }) {
    return Text(
      text,
      key: key,
      textAlign: TextAlign.right,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: AppTypography.weightMedium,
      ),
    );
  }


  // ==================== 抓包区块 ====================

  /// 抓包状态摘要：模块不可用 / 已关闭 / 仅 HTTP / HTTP+HTTPS。
  ///
  /// 「仅 HTTP vs HTTP+HTTPS」由 **CA 是否已生成** 决定（`capture.config` 无
  /// HTTPS 字段）：无 CA 时 HTTPS 无法 MITM 终止，如实显示「仅 HTTP」。
  /// CA 已生成但**已确认未安装**到系统证书存储时，进一步如实标注
  /// 「（CA 未安装）」；未知 / 平台不支持检测时保持 `HTTP+HTTPS`（不谎报）。
  String get _captureStatusLabel {
    final config = _captureConfig;
    if (config == null) return '抓包能力不可用';
    if (!config.enabled) return '已关闭';
    if (!_captureCaGenerated) return '仅 HTTP';
    if (_captureCaInstalled == false) return 'HTTP+HTTPS（CA 未安装）';
    return 'HTTP+HTTPS';
  }

  Widget _buildCaptureCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final config = _captureConfig;
    final unavailable = config == null;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          SwitchListTile(
            key: const Key('proxy-capture-toggle'),
            secondary: const Icon(TablerIcons.shield_lock),
            title: const Text('抓包'),
            subtitle: Text(
              _captureStatusLabel,
              key: const Key('proxy-capture-status'),
            ),
            value: config?.enabled ?? false,
            onChanged: (unavailable || _captureBusy)
                ? null
                : _onToggleCapture,
          ),
          if (unavailable)
            Padding(
              padding: AppSpacing.onlyHorizontalLG.copyWith(
                bottom: AppSpacing.md,
              ),
              child: Row(
                key: const Key('proxy-capture-unavailable'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    TablerIcons.alert_triangle,
                    size: AppTypography.iconSM,
                    color: scheme.error,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '当前调试模块未提供抓包能力（capture.*），请更新模块后再试。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (config != null && config.enabled)
            Padding(
              padding: AppSpacing.onlyHorizontalLG.copyWith(
                bottom: AppSpacing.md,
              ),
              child: Row(
                children: [
                  Icon(
                    TablerIcons.apps,
                    size: AppTypography.iconSM,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      config.appScope == ProxyCaptureAppScope.routing
                          ? '应用范围：VPN 分流'
                          : '应用范围：UID 归因',
                      key: const Key('proxy-capture-scope'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          ListTile(
            key: const Key('proxy-capture-settings-entry'),
            leading: const Icon(TablerIcons.adjustments),
            title: const Text('抓包设置'),
            subtitle: const Text('白名单 / 抓取内容 / 存储'),
            trailing: const Icon(TablerIcons.chevron_right),
            onTap: _openCaptureSettings,
          ),
        ],
      ),
    );
  }

  /// 总开关：关闭即时下发；开启前**先复核 CA**，无 CA 则拦截并引导（绝不默默开启）。
  Future<void> _onToggleCapture(bool value) async {
    final config = _captureConfig;
    if (config == null || _captureBusy) return;
    if (!value) {
      await _applyCaptureEnabled(false);
      return;
    }
    // 首次开启前实时复核（不信任加载期缓存，避免 CA 被重置后仍放行）。
    // 门控逻辑与文案集中在校验通过的 [ensureCaptureCaGate]，供首页 / 设置页 /
    // 列表页复用（无 CA 则拦截并引导，绝不默默开启）。
    final ok = await ensureCaptureCaGate(
      captureCaGet: () => _facade.captureCaGet(),
      onOpenCaptureSettings: _openCaptureSettings,
    );
    if (!mounted || !ok) return;
    _captureCaGenerated = true;
    await _applyCaptureEnabled(true);
  }

  /// 下发 `capture.config.set`（仅改 `enabled`，其余字段原样保留）。
  ///
  /// 失败**不乐观翻转**：状态只在成功响应后更新；异常走统一 `showError`。
  Future<void> _applyCaptureEnabled(bool enabled) async {
    final config = _captureConfig;
    if (config == null) return;
    setState(() => _captureBusy = true);
    try {
      final next =
          await _facade.captureConfigSet(config.copyWith(enabled: enabled));
      if (!mounted) return;
      setState(() {
        _captureConfig = next;
        _captureBusy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _captureBusy = false);
      AppDialogs.showError('抓包开关下发失败：$error');
    }
  }

  /// 「抓包设置 ›」：优先经注入缝跳转（测试可注入计数回调）；否则生产兜底打开
  /// [ProxyCaptureSettingsPage]（与 [_openRequests] / [_openStats] 同构）。
  ///
  /// 「尚未接入」提示已删除：宿主从不注入接缝，该提示在生产必然误报。
  void _openCaptureSettings() {
    final callback = widget.onOpenCaptureSettings;
    if (callback != null) {
      callback();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ProxyCaptureSettingsPage(),
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
            leading: const Icon(TablerIcons.world_search),
            title: const Text('请求域名 / IP'),
            subtitle: const Text('实时收集请求的域名与目标 IP'),
            trailing: const Icon(TablerIcons.chevron_right),
            onTap: _openRequests,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(TablerIcons.chart_bar),
            title: const Text('流量统计'),
            subtitle: const Text('按域名的连接数与流量'),
            trailing: const Icon(TablerIcons.chevron_right),
            onTap: _openStats,
          ),
          const Divider(height: 1),
          ListTile(
            key: const Key('proxy-connections-tile'),
            leading: const Icon(TablerIcons.plug_connected),
            title: const Text('活动连接'),
            subtitle: Text('${_stats?.activeConns ?? 0} 个活动连接'),
            trailing: const Icon(TablerIcons.chevron_right),
            onTap: _openConnections,
          ),
        ],
      ),
    );
  }

  void _openRequests() {
    final callback = widget.onOpenRequests;
    if (callback != null) {
      callback();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProxyRequestsPage()),
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

  void _openConnections() {
    final callback = widget.onOpenConnections;
    if (callback != null) {
      callback();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProxyConnectionsPage()),
    );
  }

  // ==================== 延迟 / 版本 ====================

  Widget _buildDelayCard(BuildContext context, ProxyNodeDelayEvent delay) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(TablerIcons.gauge),
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
    bool subtle = false,
  }) {
    final Color variantColor = theme.colorScheme.onSurfaceVariant;
    final TextStyle? labelStyle = subtle
        ? theme.textTheme.bodySmall?.copyWith(color: variantColor)
        : theme.textTheme.bodyMedium?.copyWith(color: variantColor);
    final TextStyle? valueStyle = subtle
        ? theme.textTheme.bodySmall?.copyWith(color: variantColor)
        : theme.textTheme.bodyMedium?.copyWith(
            fontWeight: AppTypography.weightMedium,
          );
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: labelStyle),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Text(
              value,
              key: valueKey,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: valueStyle,
            ),
          ),
        ],
      ),
    );
  }
}

/// 规则模式 CN 直连 geo 数据的准备状态。
enum _GeoStatus {
  /// 未开始 / 不适用（非规则模式）。
  idle,

  /// 正在探测 / 触发下载（页面显示非阻塞提示）。
  preparing,

  /// 已就绪（静默）。
  ready,

  /// 触发或下载失败（页面显示重试）。
  failed,
}
