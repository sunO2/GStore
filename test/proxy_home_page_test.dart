import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_active_node_store.dart';
import 'package:gstore/page/proxy/proxy_active_profile_store.dart';
import 'package:gstore/page/proxy/proxy_engine_settings_store.dart';
import 'package:gstore/page/proxy/proxy_geo_manifest.dart';
import 'package:gstore/page/proxy/proxy_geo_provisioner.dart';
import 'package:gstore/page/proxy/proxy_capture_settings_page.dart';
import 'package:gstore/page/proxy/proxy_home_facade.dart';
import 'package:gstore/page/proxy/proxy_home_page.dart';
import 'package:gstore/page/proxy/proxy_requests_page.dart';
import 'package:gstore/page/proxy/proxy_nodes_facade.dart';
import 'package:gstore/page/proxy/proxy_nodes_page.dart';
import 'package:gstore/page/proxy/proxy_profiles_page.dart';
import 'package:gstore/page/proxy/proxy_routing_mode_store.dart';
import 'package:gstore/page/proxy/proxy_run_mode_store.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';
import 'package:gstore/page/proxy/proxy_settings_page.dart';
import 'package:gstore/page/proxy/proxy_shaper_presets.dart';
import 'package:gstore/page/proxy/proxy_stats_page.dart';
import 'package:gstore/page/proxy/proxy_traffic_chart.dart';

/// 假门面：无需原生模块，可受控发出类型化事件、控制连接动作的完成时机。
class _FakeProxyFacade implements ProxyHomeFacade {
  _FakeProxyFacade({this.unavailable = false});

  /// 为 `true` 时 `ping` 抛「模块未安装」结构化异常。
  final bool unavailable;

  final StreamController<ProxyEvent> controller =
      StreamController<ProxyEvent>.broadcast();

  int coreStartCalls = 0;
  int coreStopCalls = 0;
  int coreSetModeCalls = 0;
  String? lastSetMode;

  int routingGetModeCalls = 0;
  int routingSetModeCalls = 0;
  String? lastSetRoutingMode;

  /// 非空时 `routingSetMode` 以该错误失败（用于路由切换失败 QA）。
  Object? routingSetModeError;

  /// `routingGetMode` 返回值；默认规则模式 + 引擎运行。
  RoutingModeResult routingGetModeResult = const RoutingModeResult(
    mode: ProxyRoutingMode.rule,
    engineRunning: true,
  );

  /// 最近一次 `core.start` 请求（用于断言 `profileId` 透传）。
  CoreStartRequest? lastCoreStart;

  /// LAN listener state returned by [lanStatus]; drives the lanProxy warning.
  bool lanEnabled = false;

  /// 非空时 `coreSetMode` 以该错误失败（用于 lanProxy 未启用 LAN 的失败 QA）。
  Object? coreSetModeError;

  /// 非空时 `coreStart` 返回该 future（用于断言「连接中」过渡态）。
  Completer<ProxyCoreStatus>? coreStartCompleter;

  /// 非空时 `coreStart` 以该错误失败（用于失败 QA）。
  Object? coreStartError;

  ProxyPingResult pingResult = const ProxyPingResult(
    pong: true,
    module: 'proxy',
    moduleVersion: '0.1.0',
    apiVersion: 1,
    minHostAbi: 3,
    hostAbi: 3,
    state: ProxyConnState.stopped,
    mode: ProxyMode.off,
  );

  TrafficSnapshot trafficSnapshot = const TrafficSnapshot();
  ProfileList profileListResult = const ProfileList();

  static const ProxyCoreStatus runningStatus = ProxyCoreStatus(
    state: ProxyConnState.running,
    mode: ProxyMode.vpn,
    instanceId: 1,
    spawned: true,
    profileName: '默认配置',
  );

  @override
  Future<ProxyPingResult> ping() async {
    if (unavailable) throw ProxyModuleUnavailableException();
    return pingResult;
  }

  @override
  Future<ProxyVersionInfo> version() async => const ProxyVersionInfo(
        module: 'proxy',
        moduleVersion: '0.1.0',
        apiVersion: 1,
        minHostAbi: 3,
        hostAbi: 3,
        meowRev: '',
        targetArch: 'aarch64',
      );

  @override
  Stream<ProxyEvent> get events => controller.stream;

  @override
  Future<ProxyCoreStatus> coreStart(CoreStartRequest request) {
    coreStartCalls++;
    lastCoreStart = request;
    final error = coreStartError;
    if (error != null) return Future<ProxyCoreStatus>.error(error);
    final completer = coreStartCompleter;
    if (completer != null) return completer.future;
    return Future<ProxyCoreStatus>.value(runningStatus);
  }

  /// 非空时 `coreStop` 以该错误失败（用于断开失败回归）。
  Object? coreStopError;

  @override
  Future<CoreStopResult> coreStop() async {
    coreStopCalls++;
    final error = coreStopError;
    if (error != null) throw error;
    return const CoreStopResult(state: ProxyConnState.stopped);
  }

  @override
  Future<CoreModeResult> coreGetMode() async => const CoreModeResult(
        mode: ProxyMode.off,
        state: ProxyConnState.stopped,
        sinceMs: 0,
      );

  @override
  Future<CoreSetModeResult> coreSetMode(String mode) {
    coreSetModeCalls++;
    lastSetMode = mode;
    final error = coreSetModeError;
    if (error != null) return Future<CoreSetModeResult>.error(error);
    return Future<CoreSetModeResult>.value(
      CoreSetModeResult(
        ok: true,
        mode: ProxyMode.fromWire(mode),
        previous: ProxyMode.vpn,
      ),
    );
  }

  @override
  Future<RoutingModeResult> routingGetMode() async {
    routingGetModeCalls++;
    return routingGetModeResult;
  }

  @override
  Future<RoutingModeSetResult> routingSetMode(String mode) {
    routingSetModeCalls++;
    lastSetRoutingMode = mode;
    final error = routingSetModeError;
    if (error != null) return Future<RoutingModeSetResult>.error(error);
    return Future<RoutingModeSetResult>.value(
      RoutingModeSetResult(
        mode: ProxyRoutingMode.fromWire(mode),
        applied: true,
        engineRunning: true,
      ),
    );
  }

  @override
  Future<ProxyLanStatus> lanStatus() async => ProxyLanStatus(
        bound: lanEnabled,
        config: ProxyLanConfig(enabled: lanEnabled),
      );

  @override
  Future<TrafficSnapshot> statsTrafficGet({int? topDomains}) async =>
      trafficSnapshot;

  @override
  Future<ProfileList> profileList() async => profileListResult;

  /// `node.list` 返回值；默认引擎未运行（无 current），用于回退路径。
  NodeListResult nodeListResult = const NodeListResult();

  @override
  Future<NodeListResult> nodeList() async => nodeListResult;

  /// `net.shaper.get` 返回值；默认关闭（无徽标）。测试可注入启用快照。
  ProxyShaperSnapshot shaperSnapshot = const ProxyShaperSnapshot();

  @override
  Future<ProxyShaperSnapshot> loadShaperConfig() async => shaperSnapshot;

  // ---- capture.* ----

  /// `capture.config.get` 返回值；默认关闭。为 `null` 时抛模块不可用
  /// （用于「抓包能力不可用 → 区块禁用 + 提示」回归）。
  CaptureConfig? captureConfig = const CaptureConfig();

  /// `capture.ca.get` 返回值；默认「未生成」（无 CA）。
  CaptureCaInfo captureCa = const CaptureCaInfo();

  int captureConfigSetCalls = 0;
  CaptureConfig? lastCaptureConfigSet;

  /// 非空时 `captureConfigSet` 以该错误失败（用于下发失败回归）。
  Object? captureConfigSetError;

  @override
  Future<CaptureConfig> captureConfigGet() async {
    final config = captureConfig;
    if (config == null) throw ProxyModuleUnavailableException();
    return config;
  }

  @override
  Future<CaptureConfig> captureConfigSet(CaptureConfig config) async {
    captureConfigSetCalls++;
    lastCaptureConfigSet = config;
    final error = captureConfigSetError;
    if (error != null) throw error;
    captureConfig = config;
    return config;
  }

  @override
  Future<CaptureCaInfo> captureCaGet() async => captureCa;

  @override
  Future<String> vpnConfigJson() async => '{}';

  void emit(ProxyEvent event) => controller.add(event);
}

/// 假 VPN 授权触发：默认「同意」。
class _FakeVpnConsent implements ProxyVpnConsent {
  _FakeVpnConsent({this.granted = true, this.running = false});

  final bool granted;

  /// [isRunning] 返回值；为 `true` 时首页加载会走引擎恢复路径。
  final bool running;
  int prepareCalls = 0;
  int stopCalls = 0;

  /// 非空时 `stop` 以该错误失败（用于停服务失败不崩溃回归）。
  Object? stopError;

  @override
  Future<bool> prepare({String configJson = '{}'}) async {
    prepareCalls++;
    return granted;
  }

  @override
  Future<bool> stop() async {
    stopCalls++;
    final error = stopError;
    if (error != null) throw error;
    return true;
  }

  @override
  Future<bool> isRunning() async => running;
}

/// 假节点门面：首页仅用于把 profileId 透传给节点页，节点页自身数据在此为空。
class _FakeNodesFacade implements ProxyNodesFacade {
  final StreamController<ProxyEvent> controller =
      StreamController<ProxyEvent>.broadcast(sync: true);

  String? lastProfileId;

  @override
  Stream<ProxyEvent> get events => controller.stream;

  @override
  Future<StoredProfile> profileGet(String id) async {
    lastProfileId = id;
    return StoredProfile(
      id: id,
      profile: const ImportedProfile(name: '订阅', format: 'clash'),
    );
  }

  @override
  Future<NodeSelectResult> nodeSelect(String group, String node) async =>
      NodeSelectResult(ok: true, group: group, node: node, active: node);

  @override
  Future<DelayTestResult> nodeDelayTest(NodeDelayTestRequest request) async =>
      const DelayTestResult();

  /// `node.list` 返回值（默认空：页面回退到类型推断 + 持久化选择）。
  NodeListResult nodeListResult = const NodeListResult();

  @override
  Future<NodeListResult> nodeList() async => nodeListResult;

  @override
  Future<void> reconcileEngine(String profileId) async {}
}

/// 假「当前订阅」持久化存储：内存实现。
class _FakeProfileStore implements ProxyActiveProfileStore {
  _FakeProfileStore([this.value]);

  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String id) async => value = id;

  @override
  Future<void> clear() async => value = null;
}

/// 假「当前选中节点」持久化存储：内存实现。
class _FakeActiveNodeStore implements ProxyActiveNodeStore {
  _FakeActiveNodeStore([this.value]);

  ProxyActiveNode? value;

  @override
  Future<ProxyActiveNode?> read() async => value;

  @override
  Future<void> write(ProxyActiveNode selection) async => value = selection;

  @override
  Future<void> clear() async => value = null;
}

/// 假「用户选择的运行模式」持久化存储：内存实现。
class _FakeRunModeStore implements ProxyRunModeStore {
  _FakeRunModeStore([this.value]);

  ProxyMode? value;

  @override
  Future<ProxyMode?> read() async => value;

  @override
  Future<void> write(ProxyMode mode) async => value = mode;

  @override
  Future<void> clear() async => value = null;
}

/// 假「用户选择的路由模式」持久化存储：内存实现。
class _FakeRoutingModeStore implements ProxyRoutingModeStore {
  _FakeRoutingModeStore([this.value]);

  ProxyRoutingMode? value;

  @override
  Future<ProxyRoutingMode?> read() async => value;

  @override
  Future<void> write(ProxyRoutingMode mode) async => value = mode;

  @override
  Future<void> clear() async => value = null;
}

/// 假「引擎侧设置（stack / MTU）」持久化存储：内存实现。
class _FakeEngineSettingsStore implements ProxyEngineSettingsStore {
  _FakeEngineSettingsStore([this.value = const ProxyEngineSettings()]);

  ProxyEngineSettings value;

  @override
  Future<ProxyEngineSettings> read() async => value;

  @override
  Future<void> write(ProxyEngineSettings settings) async => value = settings;
}

/// 空操作 geo 门面（仅满足 [ProxyGeoProvisioner] 构造，不会真正被调用）。
class _NoopGeoFacade implements ProxyGeoFacade {
  @override
  Future<RulesSnapshot> rulesGet() async => const RulesSnapshot();

  @override
  Future<GeneratedConfig> configGenerate(GenerateRequest request) async =>
      const GeneratedConfig(config: '');

  @override
  Future<RulesSnapshot> rulesReload(RulesReloadRequest request) async =>
      const RulesSnapshot();
}

class _NoopChecksumClient implements ProxyGeoChecksumClient {
  @override
  Future<String?> fetchSha256(String assetUrl) async => null;
}

/// 假 provisioner：覆写 kickoff / waitReady，可受控门控等待时机。
class _FakeGeoProvisioner extends ProxyGeoProvisioner {
  _FakeGeoProvisioner()
      : super(
          facade: _NoopGeoFacade(),
          manifest: const ProxyGeoManifest(assets: <ProxyGeoAsset>[]),
          checksumClient: _NoopChecksumClient(),
        );

  int kickoffCalls = 0;
  bool kickoffResult = true;
  Object? kickoffError;
  int waitReadyCalls = 0;
  Completer<bool>? waitReadyGate;
  bool waitReadyResult = true;

  /// `lastFailureReason` 返回值（模拟 Rust 上报的 geo 资产失败原因）。
  String? failureReason;

  /// `lastFailureReason` 调用次数。
  int lastFailureReasonCalls = 0;

  @override
  Future<bool> kickoff({String? profileId, bool force = false}) async {
    kickoffCalls++;
    final error = kickoffError;
    if (error != null) throw error;
    return kickoffResult;
  }

  @override
  Future<bool> waitReady({Duration? timeout}) async {
    waitReadyCalls++;
    final gate = waitReadyGate;
    if (gate != null) return gate.future;
    return waitReadyResult;
  }

  @override
  Future<String?> lastFailureReason() async {
    lastFailureReasonCalls++;
    return failureReason;
  }
}

/// 假 geo 工厂：始终返回注入的 provisioner。
class _FakeGeoProvisionerFactory extends ProxyGeoProvisionerFactory {
  _FakeGeoProvisionerFactory(this.provisioner);

  final ProxyGeoProvisioner provisioner;

  @override
  Future<ProxyGeoProvisioner?> create() async => provisioner;
}

Widget _wrap(Widget child) => MaterialApp(home: child);

/// 注入全局导航 key：`AppDialogs.showConfirmSheet` 等统一弹层经
/// [appNavigatorKey] 呈现，测试需挂载同一 key 才能渲染。
Widget _wrapNav(Widget child) =>
    MaterialApp(navigatorKey: appNavigatorKey, home: child);

/// 放大测试视口：首页在状态/模式/流量三张卡之后还有快捷入口，默认 800x600
/// 会因 `ListView` 懒构建而找不到屏外条目。测试改用高视口。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 刷新若干帧（**不用** pumpAndSettle：AppLoading 为无限循环动画）。
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// 读取路由模式药丸当前选中值。
ProxyRoutingMode _routingSwitchValue(WidgetTester tester) =>
    tester
        .widget<AppSegmentedButton<ProxyRoutingMode>>(
          find.byKey(const Key('proxy-routing-mode-switch')),
        )
        .value;

void main() {
  testWidgets('disconnected：未连接态渲染状态/开关/当前配置/入口', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('当前配置'), findsOneWidget);
    expect(find.text('未选择'), findsOneWidget);
    expect(find.text('网络端子'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('请求域名 / IP'), findsOneWidget);
    expect(find.text('流量统计'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('connecting：点击连接 -> 过渡态 -> running（happy QA）', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent();
    final completer = Completer<ProxyCoreStatus>();
    facade.coreStartCompleter = completer;

    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);
    expect(find.text('未连接'), findsOneWidget);

    await tester.tap(find.text('连接'));
    await tester.pump();

    // 过渡态：状态与按钮都显示进行中，且授权流程已触发。
    expect(find.text('正在连接…'), findsOneWidget);
    expect(find.text('连接中…'), findsOneWidget);
    expect(consent.prepareCalls, 1);
    expect(facade.coreStartCalls, 1);

    completer.complete(_FakeProxyFacade.runningStatus);
    await _flush(tester);

    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('断开'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('connected：proxy.stats 事件驱动流量/活动连接渲染', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    facade.emit(const ProxyStatsEvent(
      uploadBytes: 1024,
      downloadBytes: 2097152,
      activeConns: 7,
      upBps: 2048,
      downBps: 4096,
      domainCount: 12,
      flowCount: 3,
      topDomains: <DomainStat>[
        DomainStat(
          domain: 'example.com',
          outbound: 'HK-01',
          uploadBytes: 1024,
          downloadBytes: 1024,
        ),
      ],
    ));
    await _flush(tester);

    expect(find.text('已连接'), findsOneWidget);
    expect(
      (tester.widget<Text>(find.byKey(const Key('proxy-active-conns')))).data,
      '7',
    );
    expect(find.textContaining('1.00 KB'), findsWidgets);
    expect(find.textContaining('2.00 MB'), findsWidgets);
    expect(find.text('HK-01'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    // 新增流量明细：跟踪连接数 + 最活跃域名（域名 · 总字节）。
    expect(
      (tester.widget<Text>(find.byKey(const Key('proxy-flow-count')))).data,
      '3',
    );
    expect(
      (tester.widget<Text>(find.byKey(const Key('proxy-top-domain')))).data,
      'example.com · 2.00 KB',
    );
    // 60 秒折线图取代了旧的相对进度条。
    expect(find.byKey(const Key('proxy-traffic-chart')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    // 实时速率与累计分离：速率带 /s（number 强调），累计不带 /s。
    expect(
      (tester.widget<Text>(find.byKey(const Key('proxy-upload-speed')))).data,
      '↑ 2.00 KB/s',
    );
    expect(
      (tester.widget<Text>(find.byKey(const Key('proxy-download-speed')))).data,
      '↓ 4.00 KB/s',
    );
    expect(
      (tester.widget<Text>(find.byKey(const Key('proxy-upload-total')))).data,
      '↑ 1.00 KB',
    );
    expect(
      (tester.widget<Text>(find.byKey(const Key('proxy-download-total')))).data,
      '↓ 2.00 MB',
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('traffic：field 缺省/为 0 时省略明细行', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    // 无 stats（全 0）：跟踪连接 / 最活跃域名行不渲染。
    expect(find.byKey(const Key('proxy-flow-count')), findsNothing);
    expect(find.byKey(const Key('proxy-top-domain')), findsNothing);

    // domainCount 为 0、flowCount 为 0、topDomains 为空：仍省略。
    facade.emit(const ProxyStatsEvent(
      uploadBytes: 0,
      downloadBytes: 0,
      activeConns: 0,
      upBps: 0,
      downBps: 0,
      domainCount: 0,
      flowCount: 0,
    ));
    await _flush(tester);
    expect(find.byKey(const Key('proxy-flow-count')), findsNothing);
    expect(find.byKey(const Key('proxy-top-domain')), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('disconnect：运行中点击断开 -> core.stop + 触发停服务', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);
    expect(find.text('断开'), findsOneWidget);

    await tester.tap(find.text('断开'));
    await _flush(tester);

    expect(facade.coreStopCalls, 1);
    expect(consent.stopCalls, 1);
    expect(find.text('未连接'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('disconnect 失败：core.stop 抛错时仍触发停服务（try/finally 回归锁）',
      (tester) async {
    final facade = _FakeProxyFacade()
      ..coreStopError = const ProxyModuleException(
        code: 'PROXY_ENGINE_STOP_FAILED',
        message: '停止引擎失败',
      );
    final consent = _FakeVpnConsent();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);
    expect(find.text('断开'), findsOneWidget);

    await tester.tap(find.text('断开'));
    await _flush(tester);

    // 核心回归：core.stop 抛错绝不能阻止停服务调用，否则系统 VpnService 残留。
    expect(facade.coreStopCalls, 1);
    expect(
      consent.stopCalls,
      1,
      reason: 'core.stop 抛错时仍必须触发停服务（try/finally）',
    );
    expect(find.byKey(const Key('proxy-error-banner')), findsOneWidget);
    expect(find.text('PROXY_ENGINE_STOP_FAILED'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('disconnect 失败：停服务自身抛错不崩溃、不产生未捕获异常', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent()..stopError = StateError('stopService 失败');
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);
    expect(find.text('断开'), findsOneWidget);

    await tester.tap(find.text('断开'));
    await _flush(tester);

    // core.stop 成功、停服务失败：错误被 _safe 吞掉，UI 正常回到未连接，绝不崩溃。
    expect(facade.coreStopCalls, 1);
    expect(consent.stopCalls, 1);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.byKey(const Key('proxy-error-banner')), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('failure：proxy.state 错误 -> 错误横幅代码/消息 + 重试', (tester) async {
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.stopped,
      mode: ProxyMode.off,
      error: ProxyStateError(
        code: 'PROXY_ENGINE_START_FAILED',
        message: '引擎启动失败',
      ),
    ));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-error-banner')), findsOneWidget);
    expect(find.text('PROXY_ENGINE_START_FAILED'), findsOneWidget);
    expect(find.text('引擎启动失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('failure QA：core.start 抛错 -> 横幅 + 重试成功', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent();
    facade.coreStartError = const ProxyModuleException(
      code: 'PROXY_TUN_FD_INVALID',
      message: 'TUN fd 无效',
      status: 422,
    );

    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);

    await tester.tap(find.text('连接'));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-error-banner')), findsOneWidget);
    expect(find.text('PROXY_TUN_FD_INVALID'), findsOneWidget);
    expect(find.text('TUN fd 无效'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 重试：清除错误后再次 core.start 成功 -> 已连接。
    facade.coreStartError = null;
    await tester.tap(find.text('重试'));
    await _flush(tester);

    expect(find.text('已连接'), findsOneWidget);
    expect(facade.coreStartCalls, 2);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('failure QA：用户拒绝授权 -> 结构化拒绝错误', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent(granted: false);
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);

    await tester.tap(find.text('连接'));
    await _flush(tester);

    expect(find.text('PROXY_VPN_CONSENT_DENIED'), findsOneWidget);
    expect(facade.coreStartCalls, 0);
    expect(consent.prepareCalls, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('quick entry：回调优先，缺省时给出提示（不崩溃）', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    var requests = 0;
    var stats = 0;
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        onOpenRequests: () => requests++,
        onOpenStats: () => stats++,
      )),
    );
    await _flush(tester);

    await tester.ensureVisible(find.text('请求域名 / IP'));
    await tester.pump();
    await tester.tap(find.text('请求域名 / IP'));
    await tester.pump();
    await tester.ensureVisible(find.text('流量统计'));
    await tester.pump();
    await tester.tap(find.text('流量统计'));
    await tester.pump();

    expect(requests, 1);
    expect(stats, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('模块不可用：显示结构化错误态与重试按钮', (tester) async {
    final facade = _FakeProxyFacade(unavailable: true);
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

  expect(find.text('调试模块不可用'), findsOneWidget);
  expect(find.text('调试模块未安装'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('mode picker：选择局域网代理但 LAN 未启用 -> 警告 + 设置快捷入口', (tester) async {
    // 入口卡现有三行（订阅 / 节点选择 / 代理模式），LAN 警告按钮会落到默认
    // 800x600 视口之外；用高视口保证警告区的快捷入口可点击。
    _useTallViewport(tester);
    final facade = _FakeProxyFacade(); // lanEnabled = false
    var openedLanSettings = 0;
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        onOpenLanSettings: () => openedLanSettings++,
      )),
    );
    await _flush(tester);

    expect(find.byKey(const Key('proxy-mode-tile')), findsOneWidget);
    expect(find.text('VPN 模式（全设备）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-mode-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('proxy-mode-option-lanProxy')), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-mode-option-lanProxy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 未运行：仅记录目标，不触发 core.set_mode；显示结构化警告 + 快捷入口。
    expect(facade.coreSetModeCalls, 0);
    expect(find.byKey(const Key('proxy-lan-disabled-warning')), findsOneWidget);
    expect(find.textContaining('PROXY_NO_INBOUND'), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-open-lan-settings')));
    await tester.pump();
    expect(openedLanSettings, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('mode picker：运行模式行遵守统一左右内边距（20px）', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-mode-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final Rect row =
        tester.getRect(find.byKey(const Key('proxy-mode-option-vpn')));
    final Rect sheet = tester.getRect(find.byType(AppSheetScaffold));
    // 相对弹层左边缘：运行模式行必须内缩统一的 20px（onlyHorizontalXL）。
    expect(row.left - sheet.left,
        closeTo(AppSpacing.onlyHorizontalXL.left, 1.0),
        reason: '运行模式行必须遵守统一弹层的 20px 左右内边距');
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('live switch：运行中从 VPN 切到局域网代理 -> core.set_mode + 停服务',
      (tester) async {
    final facade = _FakeProxyFacade()..lanEnabled = true;
    final consent = _FakeVpnConsent();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);
    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);
    expect(find.text('已连接'), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-mode-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('proxy-mode-option-lanProxy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(facade.coreSetModeCalls, 1);
    expect(facade.lastSetMode, 'lanProxy');
    expect(consent.stopCalls, 1, reason: 'lanProxy must stop the VpnService');
    expect(find.text('局域网共享（仅共享给其它设备）'), findsOneWidget);
    expect(find.byKey(const Key('proxy-lan-disabled-warning')), findsNothing);

    // 切换到当前模式是 no-op（不再次请求）。
    facade.coreSetModeCalls = 0;
    await tester.tap(find.byKey(const Key('proxy-mode-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('proxy-mode-option-lanProxy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(facade.coreSetModeCalls, 0);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('failure QA：lanProxy 结构化 PROXY_NO_INBOUND -> 错误横幅',
      (tester) async {
    final facade = _FakeProxyFacade()
      ..coreSetModeError = const ProxyModuleException(
        code: 'PROXY_NO_INBOUND',
        message: 'lanProxy requires an enabled LAN listener',
        status: 422,
      );
    final consent = _FakeVpnConsent();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);
    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-mode-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('proxy-mode-option-lanProxy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(facade.coreSetModeCalls, 1);
    expect(find.byKey(const Key('proxy-error-banner')), findsOneWidget);
    expect(find.text('PROXY_NO_INBOUND'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('入口卡：两行 × 每行两张独立卡片，代理设置常显', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    // 四张卡片均在。
    expect(find.byKey(const Key('proxy-subscribe-tile')), findsOneWidget);
    expect(find.byKey(const Key('proxy-nodes-tile')), findsOneWidget);
    expect(find.byKey(const Key('proxy-mode-tile')), findsOneWidget);
    expect(find.byKey(const Key('proxy-settings-tile')), findsOneWidget);
    expect(find.text('网络组'), findsOneWidget);
    expect(find.text('网络选择'), findsOneWidget);
    expect(find.text('网络模式'), findsOneWidget);
    expect(find.text('调试设置'), findsOneWidget);

    final double subscribeY =
        tester.getTopLeft(find.byKey(const Key('proxy-subscribe-tile'))).dy;
    final double nodesY =
        tester.getTopLeft(find.byKey(const Key('proxy-nodes-tile'))).dy;
    final double modeY =
        tester.getTopLeft(find.byKey(const Key('proxy-mode-tile'))).dy;
    final double settingsY =
        tester.getTopLeft(find.byKey(const Key('proxy-settings-tile'))).dy;

    // 第 1 行：订阅 / 节点选择同排；第 2 行：代理模式 / 代理设置同排。
    expect(subscribeY, closeTo(nodesY, 1.0));
    expect(modeY, closeTo(settingsY, 1.0));
    // 第 1 行在第 2 行之上。
    expect(subscribeY, lessThan(modeY));
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('入口卡：点击订阅进入订阅与配置页', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-subscribe-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ProxyProfilesPage), findsOneWidget);
    expect(find.text('网络组与配置'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('入口卡：代理设置始终渲染（VPN 模式也显示）且可跳转设置', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    var openedSettings = 0;
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        onOpenLanSettings: () => openedSettings++,
      )),
    );
    await _flush(tester);

    // VPN 模式（默认目标）下代理设置也必须出现。
    expect(find.byKey(const Key('proxy-settings-tile')), findsOneWidget);
    expect(find.text('调试设置'), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-settings-tile')));
    await tester.pump();
    expect(openedSettings, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('入口卡：点击节点选择进入节点页', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-nodes-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ProxyNodesPage), findsOneWidget);
    // 无选中订阅：节点页渲染其设计好的空态，而不是崩溃。
    expect(find.text('暂无端子'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('入口卡：节点入口把选中订阅 profileId 传给节点页', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..profileListResult = const ProfileList(
        count: 1,
        profiles: <ProfileSummary>[
          ProfileSummary(id: 'p1', name: '订阅一', nodeCount: 5),
        ],
      );
    final store = _FakeProfileStore('p1');
    final nodesFacade = _FakeNodesFacade();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        profileStore: store,
        nodesFacade: nodesFacade,
      )),
    );
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-nodes-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final page = tester.widget<ProxyNodesPage>(find.byType(ProxyNodesPage));
    expect(page.profileId, 'p1');
    expect(nodesFacade.lastProfileId, 'p1');
    expect(tester.takeException(), isNull);

    await facade.controller.close();
    await nodesFacade.controller.close();
  });

  testWidgets('当前配置：选中订阅显示 名称（N 节点），无选中显示 未选择', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..profileListResult = const ProfileList(
        count: 1,
        profiles: <ProfileSummary>[
          ProfileSummary(id: 'p1', name: '订阅一', nodeCount: 5),
        ],
      );
    final store = _FakeProfileStore();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, profileStore: store)),
    );
    await _flush(tester);

    // 只有 1 个订阅：自动选中并持久化。
    expect(store.value, 'p1');
    expect(find.text('订阅一（5 个端子）'), findsOneWidget);
    expect(find.text('未选择'), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('连接：core.start 透传选中订阅 profileId', (tester) async {
    final facade = _FakeProxyFacade()
      ..profileListResult = const ProfileList(
        count: 1,
        profiles: <ProfileSummary>[
          ProfileSummary(id: 'p1', name: '订阅一', nodeCount: 5),
        ],
      );
    final store = _FakeProfileStore('p1');
    final consent = _FakeVpnConsent();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        vpnConsent: consent,
        profileStore: store,
      )),
    );
    await _flush(tester);

    await tester.tap(find.text('连接'));
    await _flush(tester);

    expect(facade.coreStartCalls, 1);
    expect(facade.lastCoreStart?.profileId, 'p1');
    expect(find.text('已连接'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('连接：core.start 透传持久化 stack/mtu', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent();
    final engineStore =
        _FakeEngineSettingsStore(const ProxyEngineSettings(stack: 'system', mtu: 1400));
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        vpnConsent: consent,
        engineSettingsStore: engineStore,
      )),
    );
    await _flush(tester);

    await tester.tap(find.text('连接'));
    await _flush(tester);

    expect(facade.coreStartCalls, 1);
    expect(facade.lastCoreStart?.stack, 'system');
    expect(facade.lastCoreStart?.mtu, 1400);
    expect(find.text('已连接'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('引擎恢复：core.start 透传持久化 stack/mtu', (tester) async {
    final facade = _FakeProxyFacade();
    // 前台服务在跑（isRunning 为 true）→ 加载即走引擎恢复路径。
    final consent = _FakeVpnConsent(running: true);
    final engineStore =
        _FakeEngineSettingsStore(const ProxyEngineSettings(stack: 'system', mtu: 1400));
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        vpnConsent: consent,
        engineSettingsStore: engineStore,
      )),
    );
    await _flush(tester);

    expect(facade.coreStartCalls, 1);
    expect(facade.lastCoreStart?.stack, 'system');
    expect(facade.lastCoreStart?.mtu, 1400);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('快捷入口：无回调时请求域名 / IP 进入请求收集页（不再提示后续版本）', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    await tester.ensureVisible(find.text('请求域名 / IP'));
    await tester.pump();
    await tester.tap(find.text('请求域名 / IP'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ProxyRequestsPage), findsOneWidget);
    expect(find.text('日志查看器将在后续版本开放'), findsNothing);
    expect(tester.takeException(), isNull);

    // 卸载页面以释放请求收集页的 2s 兜底 Timer。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    await facade.controller.close();
  });

  testWidgets('快捷入口：无回调时流量统计进入统计页（不再提示后续版本）', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    await tester.ensureVisible(find.text('流量统计'));
    await tester.pump();
    await tester.tap(find.text('流量统计'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ProxyStatsPage), findsOneWidget);
    expect(find.text('流量统计将在后续版本开放'), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('入口卡副标题：显示选中订阅名与选中节点，未选择时中性文案',
      (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..profileListResult = const ProfileList(
        count: 1,
        profiles: <ProfileSummary>[
          ProfileSummary(id: 'p1', name: '订阅一', nodeCount: 5),
        ],
      );
    final profileStore = _FakeProfileStore();
    final nodeStore = _FakeActiveNodeStore(
      const ProxyActiveNode(group: 'PROXY', node: '香港 01'),
    );
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        profileStore: profileStore,
        nodeStore: nodeStore,
      )),
    );
    await _flush(tester);

    // 订阅卡副标题 = 选中订阅名（非「导入/更新节点订阅」）。
    expect(find.text('订阅一'), findsOneWidget);
    // 节点卡副标题 = 分组 · 选中节点。
    expect(find.text('PROXY · 香港 01'), findsOneWidget);
    expect(find.text('导入/更新节点订阅'), findsNothing);
    expect(find.text('选择节点 / 测速'), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('入口卡副标题：无选中时显示中性文案', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, nodeStore: _FakeActiveNodeStore())),
    );
    await _flush(tester);

  expect(find.text('未选择网络组'), findsOneWidget);
  expect(find.text('未选择端子'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('status：运行中收到引擎错误时状态色不转 error，错误仍走横幅',
      (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);

    // 连接成功后再来一条带 error 的 state 事件：状态色必须仍为 primary。
    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
      error: ProxyStateError(code: 'PROXY_X', message: '引擎报错'),
    ));
    await _flush(tester);

    final BuildContext ctx =
        tester.element(find.byKey(const Key('proxy-status-text')));
    final ColorScheme scheme = Theme.of(ctx).colorScheme;
    final Text status =
        tester.widget<Text>(find.byKey(const Key('proxy-status-text')));
    expect(status.data, '已连接');
    expect(status.style?.color, scheme.primary);
    expect(status.style?.color, isNot(scheme.error));

    // 错误反馈仍在横幅（errorContainer）+ 重试按钮。
    expect(find.byKey(const Key('proxy-error-banner')), findsOneWidget);
    expect(find.text('PROXY_X'), findsOneWidget);
    expect(find.text('引擎报错'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 断开按钮为破坏性样式：主题 error 底 + onError 前景（状态图标/文案仍非 error）。
    final FilledButton disconnect = tester.widget<FilledButton>(
      find.byKey(const Key('proxy-disconnect-button')),
    );
    expect(
      disconnect.style?.backgroundColor?.resolve(<WidgetState>{}),
      scheme.error,
    );
    expect(
      disconnect.style?.foregroundColor?.resolve(<WidgetState>{}),
      scheme.onError,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('节点入口：透传 store + 初始高亮，返回后刷新副标题', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..profileListResult = const ProfileList(
        count: 1,
        profiles: <ProfileSummary>[
          ProfileSummary(id: 'p1', name: '订阅一', nodeCount: 5),
        ],
      );
    final profileStore = _FakeProfileStore('p1');
    final nodeStore = _FakeActiveNodeStore(
      const ProxyActiveNode(group: 'PROXY', node: '香港 01'),
    );
    final nodesFacade = _FakeNodesFacade();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        profileStore: profileStore,
        nodeStore: nodeStore,
        nodesFacade: nodesFacade,
      )),
    );
    await _flush(tester);
    expect(find.text('PROXY · 香港 01'), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-nodes-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final page = tester.widget<ProxyNodesPage>(find.byType(ProxyNodesPage));
    expect(page.nodeStore, same(nodeStore));
    expect(page.initialActiveByGroup, <String, String>{'PROXY': '香港 01'});

    // 在「节点页」期间选择发生变化：返回首页应刷新入口卡副标题。
    nodeStore.value = const ProxyActiveNode(group: 'AUTO', node: '美国 03');
    await tester.pageBack();
    await _flush(tester);

    expect(find.text('AUTO · 美国 03'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
    await nodesFacade.controller.close();
  });

  testWidgets('当前节点：运行中展示 node.list 的实时 current.now（覆盖持久化标签）',
      (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..nodeListResult = const NodeListResult(
        engineRunning: true,
        current: NodeCurrent(group: 'PROXY', now: '香港 01'),
      );
    final nodeStore = _FakeActiveNodeStore(
      const ProxyActiveNode(group: 'PROXY', node: '持久化旧节点'),
    );
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, nodeStore: nodeStore)),
    );
    await _flush(tester);

    // 引擎未运行：不采用实时值，回退持久化标签。
    expect(find.text('持久化旧节点'), findsOneWidget);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);

    // 运行中：实时 current.now 覆盖持久化标签。
    expect(find.text('香港 01'), findsWidgets);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('当前节点：current.now 为嵌套分组时展示 current.node 叶子',
      (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..pingResult = const ProxyPingResult(
        pong: true,
        module: 'proxy',
        moduleVersion: '0.1.0',
        apiVersion: 1,
        minHostAbi: 3,
        hostAbi: 3,
        state: ProxyConnState.running,
        mode: ProxyMode.vpn,
      )
      ..nodeListResult = const NodeListResult(
        engineRunning: true,
        current: NodeCurrent(group: 'PROXY', now: 'AUTO', node: '日本 02'),
      );
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.text('日本 02'), findsOneWidget);
    expect(find.text('自动'), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('当前节点：引擎停止时回退到持久化节点标签', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..nodeListResult = const NodeListResult(engineRunning: false);
    final nodeStore = _FakeActiveNodeStore(
      const ProxyActiveNode(group: 'PROXY', node: '持久化节点'),
    );
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, nodeStore: nodeStore)),
    );
    await _flush(tester);

    expect(find.text('持久化节点'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('运行模式：选择局域网代理后持久化，重建页面恢复', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    final store = _FakeRunModeStore();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, runModeStore: store)),
    );
    await _flush(tester);
    expect(find.text('VPN 模式（全设备）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-mode-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('proxy-mode-option-lanProxy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(store.value, ProxyMode.lanProxy);
    expect(find.text('局域网共享（仅共享给其它设备）'), findsOneWidget);

    // 离开再进入代理页（重建 State）：从持久化恢复用户选择。
    await tester.pumpWidget(_wrap(const SizedBox()));
    await tester.pump();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, runModeStore: store)),
    );
    await _flush(tester);

    expect(find.text('局域网共享（仅共享给其它设备）'), findsOneWidget);
    expect(find.text('VPN 模式（全设备）'), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('运行模式：断开不清空已持久化的模式选择', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent();
    final store = _FakeRunModeStore(ProxyMode.lanProxy);
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        vpnConsent: consent,
        runModeStore: store,
      )),
    );
    await _flush(tester);
    expect(find.text('局域网共享（仅共享给其它设备）'), findsOneWidget);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.lanProxy,
    ));
    await _flush(tester);
    expect(find.text('断开'), findsOneWidget);

    await tester.tap(find.text('断开'));
    await _flush(tester);

    expect(find.text('未连接'), findsOneWidget);
    expect(store.value, ProxyMode.lanProxy);
    expect(find.text('局域网共享（仅共享给其它设备）'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('运行模式：引擎上报的运行模式不覆盖用户持久化选择', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    final store = _FakeRunModeStore(ProxyMode.lanProxy);
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, runModeStore: store)),
    );
    await _flush(tester);
    expect(find.text('局域网共享（仅共享给其它设备）'), findsOneWidget);

    // 引擎事件上报 vpn：用户的 lanProxy 选择不被覆盖。
    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    facade.emit(const ProxyModeEvent(
      mode: ProxyMode.vpn,
      previous: ProxyMode.off,
    ));
    await _flush(tester);

    expect(find.text('局域网共享（仅共享给其它设备）'), findsOneWidget);
    expect(store.value, ProxyMode.lanProxy);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('运行模式：存储值无效时安全回退 VPN', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    final store = _FakeRunModeStore(ProxyMode.unknown);
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, runModeStore: store)),
    );
    await _flush(tester);

    expect(find.text('VPN 模式（全设备）'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('运行模式：未存储时默认 VPN', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    final store = _FakeRunModeStore();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, runModeStore: store)),
    );
    await _flush(tester);

    expect(find.text('VPN 模式（全设备）'), findsOneWidget);
    expect(store.value, isNull);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('路由模式：未连接隐藏药丸，连接后显示 直连/规则/全局', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-routing-mode-switch')), findsNothing);
    expect(find.text('直连'), findsNothing);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-routing-mode-switch')), findsOneWidget);
    expect(find.byKey(const Key('proxy-routing-mode-direct')), findsOneWidget);
    expect(find.byKey(const Key('proxy-routing-mode-rule')), findsOneWidget);
    expect(find.byKey(const Key('proxy-routing-mode-global')), findsOneWidget);
    expect(find.text('直连'), findsOneWidget);
    expect(find.text('规则'), findsOneWidget);
    expect(find.text('全局'), findsOneWidget);
    expect(_routingSwitchValue(tester), ProxyRoutingMode.rule);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('路由模式：点击全局 -> routing.set_mode(global) 且持久化', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    final store = _FakeRoutingModeStore();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, routingModeStore: store)),
    );
    await _flush(tester);
    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-routing-mode-global')));
    await _flush(tester);

    expect(facade.routingSetModeCalls, 1);
    expect(facade.lastSetRoutingMode, 'global');
    expect(store.value, ProxyRoutingMode.global);
    expect(_routingSwitchValue(tester), ProxyRoutingMode.global);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('路由模式：连接成功后重放持久化选择', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent();
    final store = _FakeRoutingModeStore(ProxyRoutingMode.global);
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        vpnConsent: consent,
        routingModeStore: store,
      )),
    );
    await _flush(tester);

    await tester.tap(find.text('连接'));
    await _flush(tester);
    await tester.pump();

    expect(facade.coreStartCalls, 1);
    expect(facade.routingSetModeCalls, 1);
    expect(facade.lastSetRoutingMode, 'global');
    expect(store.value, ProxyRoutingMode.global);
    expect(find.text('已连接'), findsOneWidget);
    expect(_routingSwitchValue(tester), ProxyRoutingMode.global);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('路由模式：切换失败 -> 错误提示 + 保留旧值', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..routingSetModeError = const ProxyModuleException(
        code: 'PROXY_ROUTING_FAILED',
        message: '路由切换失败',
      );
    final store = _FakeRoutingModeStore();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, routingModeStore: store)),
    );
    await _flush(tester);
    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);
    expect(_routingSwitchValue(tester), ProxyRoutingMode.rule);

    await tester.tap(find.byKey(const Key('proxy-routing-mode-global')));
    await _flush(tester);
    await tester.pump();

    expect(facade.routingSetModeCalls, 1);
    expect(find.byKey(const Key('proxy-error-banner')), findsOneWidget);
    expect(find.text('PROXY_ROUTING_FAILED'), findsOneWidget);
    expect(_routingSwitchValue(tester), ProxyRoutingMode.rule);
    expect(store.value, isNull);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('路由模式：加载时反映 routing.get_mode 结果', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..pingResult = const ProxyPingResult(
        pong: true,
        module: 'proxy',
        moduleVersion: '0.1.0',
        apiVersion: 1,
        minHostAbi: 3,
        hostAbi: 3,
        state: ProxyConnState.running,
        mode: ProxyMode.vpn,
      )
      ..routingGetModeResult = const RoutingModeResult(
        mode: ProxyRoutingMode.direct,
        engineRunning: true,
      );
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(facade.routingGetModeCalls, 1);
    expect(find.byKey(const Key('proxy-routing-mode-switch')), findsOneWidget);
    expect(_routingSwitchValue(tester), ProxyRoutingMode.direct);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('路由模式：标签与药丸各占一行（药丸换行）', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);
    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);

    final Finder label = find.text('路由模式');
    final Finder pill = find.byKey(const Key('proxy-routing-mode-switch'));
    // 药丸必须换行到标签下方：药丸顶部在标签底部之下。
    expect(
      tester.getTopLeft(pill).dy,
      greaterThan(tester.getBottomLeft(label).dy),
      reason: '标题与药丸必须各占一行，药丸换行到标签下方',
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('窄屏 320：路由模式行不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);
    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);

    expect(find.text('路由模式'), findsOneWidget);
    expect(find.byKey(const Key('proxy-routing-mode-switch')), findsOneWidget);
    // takeException 捕获 RenderFlex overflow（若有会在此抛出）。
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('geo：规则模式初始化 kickoff，准备中提示，失败可重试', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    final geo = _FakeGeoProvisioner();
    final gate = Completer<bool>();
    geo.waitReadyGate = gate;
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        vpnConsent: _FakeVpnConsent(),
        geoProvisionerFactory: _FakeGeoProvisionerFactory(geo),
      )),
    );
    await _flush(tester);
    // geo 创建 / kickoff 是若干层微任务链，多泵几帧确保已触发。
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    // 默认（未存储）路由模式为 rule → 初始化即 kickoff；等待就绪期间显示非阻塞提示。
    expect(geo.kickoffCalls, 1);
    expect(find.byKey(const Key('proxy-geo-status-banner')), findsOneWidget);
    expect(find.textContaining('正在准备 CN 直连规则数据'), findsOneWidget);

    // waitReady 失败 → 失败态 + 重试入口。
    gate.complete(false);
    await _flush(tester);
    await tester.pump();
    expect(find.text('CN 直连规则数据准备失败'), findsOneWidget);
    expect(find.byKey(const Key('proxy-geo-retry')), findsOneWidget);

    // 重试：重新 kickoff（force），成功后提示消失。
    final gate2 = Completer<bool>();
    geo.waitReadyGate = gate2;
    await tester.tap(find.byKey(const Key('proxy-geo-retry')));
    await _flush(tester);
    expect(geo.kickoffCalls, 2);

    gate2.complete(true);
    await _flush(tester);
    await tester.pump();
    expect(find.byKey(const Key('proxy-geo-status-banner')), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('geo：失败时横幅显示 Rust 上报的具体原因', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    final geo = _FakeGeoProvisioner()
      ..failureReason = 'checksum mismatch: country.mmdb';
    final gate = Completer<bool>();
    geo.waitReadyGate = gate;
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        vpnConsent: _FakeVpnConsent(),
        geoProvisionerFactory: _FakeGeoProvisionerFactory(geo),
      )),
    );
    await _flush(tester);
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    // waitReady 失败 → 横幅泛化标题 + best-effort 取到的具体原因。
    gate.complete(false);
    await _flush(tester);
    await tester.pump();

    expect(find.text('CN 直连规则数据准备失败'), findsOneWidget);
    expect(find.byKey(const Key('proxy-geo-error')), findsOneWidget);
    expect(
      find.textContaining('checksum mismatch: country.mmdb'),
      findsOneWidget,
    );
    expect(geo.lastFailureReasonCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('geo：失败但取不到原因时回落泛化文案', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    final geo = _FakeGeoProvisioner(); // failureReason 为空 → 泛化文案
    final gate = Completer<bool>();
    geo.waitReadyGate = gate;
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        vpnConsent: _FakeVpnConsent(),
        geoProvisionerFactory: _FakeGeoProvisionerFactory(geo),
      )),
    );
    await _flush(tester);
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    gate.complete(false);
    await _flush(tester);
    await tester.pump();

    expect(find.byKey(const Key('proxy-geo-error')), findsNothing);
    expect(find.text('规则模式依赖的 geo 数据下载失败，可重试。'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('geo：非规则模式（direct）不 kickoff', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    final geo = _FakeGeoProvisioner();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        vpnConsent: _FakeVpnConsent(),
        routingModeStore: _FakeRoutingModeStore(ProxyRoutingMode.direct),
        geoProvisionerFactory: _FakeGeoProvisionerFactory(geo),
      )),
    );
    await _flush(tester);
    await tester.pump();

    expect(geo.kickoffCalls, 0);
    expect(find.byKey(const Key('proxy-geo-status-banner')), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('geo：运行中切换到规则模式触发 kickoff', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    final geo = _FakeGeoProvisioner();
    final store = _FakeRoutingModeStore(ProxyRoutingMode.direct);
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        routingModeStore: store,
        geoProvisionerFactory: _FakeGeoProvisionerFactory(geo),
      )),
    );
    await _flush(tester);
    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);
    expect(geo.kickoffCalls, 0);

    await tester.tap(find.byKey(const Key('proxy-routing-mode-rule')));
    await _flush(tester);

    expect(geo.kickoffCalls, 1);
    expect(store.value, ProxyRoutingMode.rule);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('traffic：快照播种淘汰计数 + Top-3 域名行（超出不渲染）',
      (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..trafficSnapshot = const TrafficSnapshot(
        uploadBytes: 2048,
        downloadBytes: 4096,
        activeConns: 2,
        upBps: 1024,
        downBps: 1024,
        domainCount: 5,
        flowCount: 2,
        capacity: 2048,
        evicted: 7,
        topDomains: <DomainStat>[
          DomainStat(domain: 'a.com', uploadBytes: 100, downloadBytes: 100),
          DomainStat(domain: 'b.com', uploadBytes: 50, downloadBytes: 50),
          DomainStat(domain: 'c.com', uploadBytes: 25, downloadBytes: 25),
          DomainStat(domain: 'd.com', uploadBytes: 10, downloadBytes: 10),
        ],
      );
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    // 容量/淘汰仅由 `stats.traffic.get` 快照携带：有淘汰就显示。
    expect(
      (tester.widget<Text>(find.byKey(const Key('proxy-capacity-evicted'))))
          .data,
      '2048 / 7',
    );
    // Top-3：首行保留稳定 key，最多三行；第 4 个域名不渲染。
    expect(
      (tester.widget<Text>(find.byKey(const Key('proxy-top-domain')))).data,
      'a.com · 200 B',
    );
    expect(find.text('b.com · 100 B'), findsOneWidget);
    expect(find.text('c.com · 50 B'), findsOneWidget);
    expect(find.text('d.com · 20 B'), findsNothing);
    expect(find.byKey(const Key('proxy-traffic-chart')), findsOneWidget);
    // 快照播种后 `_stats` 不再空白：活动连接显示快照值。
    expect(
      (tester.widget<Text>(find.byKey(const Key('proxy-active-conns')))).data,
      '2',
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('traffic：断开（stopped）清空折线缓冲', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    ProxyTrafficChartPainter painter() {
      final chart = find.byKey(const Key('proxy-traffic-chart'));
      return tester
          .widget<CustomPaint>(
            find.descendant(of: chart, matching: find.byType(CustomPaint)),
          )
          .painter! as ProxyTrafficChartPainter;
    }

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    facade.emit(const ProxyStatsEvent(
      uploadBytes: 1024,
      downloadBytes: 2048,
      activeConns: 1,
      upBps: 4096,
      downBps: 8192,
    ));
    await _flush(tester);
    expect(painter().up, isNotEmpty);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.stopped,
      mode: ProxyMode.off,
    ));
    await _flush(tester);
    expect(painter().up, isEmpty);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('弱网模拟徽标：启用时状态卡右侧显示「弱网模拟 · 档位」', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..shaperSnapshot = ProxyShaperSnapshot(
        config: presetById(ProxyShaperPresetIds.g3)!.config,
      );
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-shaper-badge')), findsOneWidget);
    expect(find.text('弱网模拟 · 3G'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('弱网模拟徽标：未知配置回落「自定义」', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..shaperSnapshot = const ProxyShaperSnapshot(
        config: ProxyShaperConfig(enabled: true),
      );
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.text('弱网模拟 · 自定义'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('弱网模拟徽标：关闭时不显示', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-shaper-badge')), findsNothing);
    expect(find.textContaining('弱网模拟'), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('弱网模拟徽标：点击进入设置页（并请求滚动到弱网小节）', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..shaperSnapshot = ProxyShaperSnapshot(
        config: presetById(ProxyShaperPresetIds.g3)!.config,
      );
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.byType(ProxySettingsPage), findsNothing);
    await tester.tap(find.byKey(const Key('proxy-shaper-badge-tap')));
    await tester.pump();
    // 路由过渡（300ms）+ 设置页初始 load 的若干微任务。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump();

    expect(find.byType(ProxySettingsPage), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('卡片顺序：网站连通性在流量统计之下、模块信息之上', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    final double trafficY = tester.getTopLeft(find.text('流量统计')).dy;
    final double probeY =
        tester.getTopLeft(find.byKey(const Key('proxy-site-probe-card'))).dy;
    final double versionY = tester.getTopLeft(find.text('模块信息')).dy;

    expect(
      probeY,
      greaterThan(trafficY),
      reason: '网站连通性应在流量统计卡片之下',
    );
    expect(
      probeY,
      lessThan(versionY),
      reason: '网站连通性应在模块信息卡片之上',
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  // ==================== 抓包区块（Todo 20） ====================

  testWidgets('抓包区块：默认渲染「已关闭」+ 总开关关闭 + 设置入口', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade(); // captureConfig 默认 enabled:false
    var openedSettings = 0;
    await tester.pumpWidget(_wrap(ProxyHomePage(
      facade: facade,
      onOpenCaptureSettings: () => openedSettings++,
    )));
    await _flush(tester);

    expect(find.text('抓包'), findsOneWidget);
    expect(find.text('已关闭'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('proxy-capture-toggle')),
    );
    expect(toggle.value, isFalse);
    expect(toggle.onChanged, isNotNull);
    expect(
      find.byKey(const Key('proxy-capture-settings-entry')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('proxy-capture-settings-entry')));
    await tester.pump();
    expect(openedSettings, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('抓包设置：生产路由下不经注入回调也进入真实设置页（回归：不再提示尚未接入）',
      (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    // 关键：**不注入** onOpenCaptureSettings，模拟生产 app_router 的
    // `const ProxyHomePage()`（宿主从不注入该接缝）。断言真实入口仍打开真实
    // 设置页，且「尚未接入」提示永不再现。
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    await tester.ensureVisible(
      find.byKey(const Key('proxy-capture-settings-entry')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('proxy-capture-settings-entry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ProxyCaptureSettingsPage), findsOneWidget);
    expect(find.text('抓包设置页尚未接入，请稍后再试。'), findsNothing);
    expect(tester.takeException(), isNull);

    // 卸载被推入的设置页，释放其异步加载。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    await facade.controller.close();
  });

  testWidgets('抓包区块：已开启且 CA 已生成 → 摘要 HTTP+HTTPS', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..captureConfig = const CaptureConfig(enabled: true)
      ..captureCa = const CaptureCaInfo(generated: true);
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.text('HTTP+HTTPS'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('proxy-capture-toggle')),
    );
    expect(toggle.value, isTrue);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('抓包区块：已开启但 CA 未生成 → 摘要仅 HTTP', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..captureConfig = const CaptureConfig(enabled: true)
      ..captureCa = const CaptureCaInfo(); // generated:false
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.text('仅 HTTP'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('抓包开关：有 CA 时开启 → 调用 capture.config.set(enabled:true)', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..captureCa = const CaptureCaInfo(generated: true);
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-capture-toggle')));
    await _flush(tester);

    expect(facade.captureConfigSetCalls, 1);
    expect(facade.lastCaptureConfigSet?.enabled, isTrue);
    // 既有字段必须保留（只改 enabled，不得清空白名单 / 端口）。
    expect(facade.lastCaptureConfigSet?.tlsPorts, const <int>[443, 8443]);
    expect(find.text('HTTP+HTTPS'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('抓包开关：关闭 → 调用 capture.config.set(enabled:false)', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..captureConfig = const CaptureConfig(enabled: true)
      ..captureCa = const CaptureCaInfo(generated: true);
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-capture-toggle')));
    await _flush(tester);

    expect(facade.captureConfigSetCalls, 1);
    expect(facade.lastCaptureConfigSet?.enabled, isFalse);
    expect(find.text('已关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('抓包开关：无 CA 开启被拦截并提示（绝不默默开启）', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade(); // captureCa 默认未生成
    var openedSettings = 0;
    await tester.pumpWidget(_wrapNav(ProxyHomePage(
      facade: facade,
      onOpenCaptureSettings: () => openedSettings++,
    )));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-capture-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 拦截：未下发任何 set，开关保持关闭，弹出引导。
    expect(facade.captureConfigSetCalls, 0);
    expect(find.text('需要先生成根证书'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('proxy-capture-toggle')),
    );
    expect(toggle.value, isFalse);

    // 引导确认 → 打开抓包设置入口。
    await tester.tap(find.text('去设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(openedSettings, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('抓包开关：下发失败 → 开关不乐观翻转 + showError', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()
      ..captureCa = const CaptureCaInfo(generated: true)
      ..captureConfigSetError = const ProxyModuleException(
        code: 'PROXY_CAPTURE_CONFIG_INVALID',
        message: 'invalid',
      );
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-capture-toggle')));
    await _flush(tester);

    expect(facade.captureConfigSetCalls, 1);
    expect(find.text('已关闭'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('proxy-capture-toggle')),
    );
    expect(toggle.value, isFalse);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('抓包区块：模块不可用 → 区块禁用 + 提示', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade()..captureConfig = null;
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('proxy-capture-toggle')),
    );
    expect(toggle.onChanged, isNull);
    expect(
      find.byKey(const Key('proxy-capture-unavailable')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });
}
