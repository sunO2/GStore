import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_active_node_store.dart';
import 'package:gstore/page/proxy/proxy_active_profile_store.dart';
import 'package:gstore/page/proxy/proxy_home_facade.dart';
import 'package:gstore/page/proxy/proxy_home_page.dart';
import 'package:gstore/page/proxy/proxy_logs_page.dart';
import 'package:gstore/page/proxy/proxy_nodes_facade.dart';
import 'package:gstore/page/proxy/proxy_nodes_page.dart';
import 'package:gstore/page/proxy/proxy_profiles_page.dart';
import 'package:gstore/page/proxy/proxy_routing_mode_store.dart';
import 'package:gstore/page/proxy/proxy_run_mode_store.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';
import 'package:gstore/page/proxy/proxy_stats_page.dart';

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

  @override
  Future<String> vpnConfigJson() async => '{}';

  void emit(ProxyEvent event) => controller.add(event);
}

/// 假 VPN 授权触发：默认「同意」。
class _FakeVpnConsent implements ProxyVpnConsent {
  _FakeVpnConsent({this.granted = true});

  final bool granted;
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
  Future<bool> isRunning() async => false;
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

Widget _wrap(Widget child) => MaterialApp(home: child);

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
    expect(find.text('当前节点'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('运行日志'), findsOneWidget);
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
      topDomains: <DomainStat>[
        DomainStat(domain: 'example.com', outbound: 'HK-01'),
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
    var logs = 0;
    var stats = 0;
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        onOpenLogs: () => logs++,
        onOpenStats: () => stats++,
      )),
    );
    await _flush(tester);

    await tester.ensureVisible(find.text('运行日志'));
    await tester.pump();
    await tester.tap(find.text('运行日志'));
    await tester.pump();
    await tester.ensureVisible(find.text('流量统计'));
    await tester.pump();
    await tester.tap(find.text('流量统计'));
    await tester.pump();

    expect(logs, 1);
    expect(stats, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('模块不可用：显示结构化错误态与重试按钮', (tester) async {
    final facade = _FakeProxyFacade(unavailable: true);
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.text('代理模块不可用'), findsOneWidget);
    expect(find.text('代理模块未安装'), findsOneWidget);
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
    expect(find.text('局域网代理（仅共享给其它设备）'), findsOneWidget);
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
    expect(find.text('订阅'), findsOneWidget);
    expect(find.text('节点选择'), findsOneWidget);
    expect(find.text('代理模式'), findsOneWidget);
    expect(find.text('代理设置'), findsOneWidget);

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
    expect(find.text('订阅与配置'), findsOneWidget);
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
    expect(find.text('代理设置'), findsOneWidget);

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
    expect(find.text('暂无节点'), findsOneWidget);
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
    expect(find.text('订阅一（5 节点）'), findsOneWidget);
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

  testWidgets('快捷入口：无回调时运行日志进入日志页（不再提示后续版本）', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    await tester.ensureVisible(find.text('运行日志'));
    await tester.pump();
    await tester.tap(find.text('运行日志'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ProxyLogsPage), findsOneWidget);
    expect(find.text('日志查看器将在后续版本开放'), findsNothing);
    expect(tester.takeException(), isNull);

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

    expect(find.text('未选择订阅'), findsOneWidget);
    expect(find.text('未选择节点'), findsOneWidget);
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

    // 断开按钮保持主题默认（未引入 error 配色）。
    final List<OutlinedButton> outlined = tester
        .widgetList<OutlinedButton>(
          find.byWidgetPredicate((Widget w) => w is OutlinedButton),
        )
        .toList();
    expect(outlined, isNotEmpty);
    for (final OutlinedButton button in outlined) {
      expect(button.style?.foregroundColor, isNull);
    }
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
    expect(find.text('局域网代理（仅共享给其它设备）'), findsOneWidget);

    // 离开再进入代理页（重建 State）：从持久化恢复用户选择。
    await tester.pumpWidget(_wrap(const SizedBox()));
    await tester.pump();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, runModeStore: store)),
    );
    await _flush(tester);

    expect(find.text('局域网代理（仅共享给其它设备）'), findsOneWidget);
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
    expect(find.text('局域网代理（仅共享给其它设备）'), findsOneWidget);

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
    expect(find.text('局域网代理（仅共享给其它设备）'), findsOneWidget);
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
    expect(find.text('局域网代理（仅共享给其它设备）'), findsOneWidget);

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

    expect(find.text('局域网代理（仅共享给其它设备）'), findsOneWidget);
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
}
