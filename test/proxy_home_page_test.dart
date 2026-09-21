import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_home_facade.dart';
import 'package:gstore/page/proxy/proxy_home_page.dart';

/// 假门面：无需原生模块，可受控发出类型化事件、控制连接动作的完成时机。
class _FakeProxyFacade implements ProxyHomeFacade {
  _FakeProxyFacade({this.unavailable = false});

  /// 为 `true` 时 `ping` 抛「模块未安装」结构化异常。
  final bool unavailable;

  final StreamController<ProxyEvent> controller =
      StreamController<ProxyEvent>.broadcast();

  int coreStartCalls = 0;
  int coreStopCalls = 0;

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
    final error = coreStartError;
    if (error != null) return Future<ProxyCoreStatus>.error(error);
    final completer = coreStartCompleter;
    if (completer != null) return completer.future;
    return Future<ProxyCoreStatus>.value(runningStatus);
  }

  @override
  Future<CoreStopResult> coreStop() async {
    coreStopCalls++;
    return const CoreStopResult(state: ProxyConnState.stopped);
  }

  @override
  Future<TrafficSnapshot> statsTrafficGet({int? topDomains}) async =>
      trafficSnapshot;

  @override
  Future<ProfileList> profileList() async => profileListResult;

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

  @override
  Future<bool> prepare({String configJson = '{}'}) async {
    prepareCalls++;
    return granted;
  }

  @override
  Future<bool> stop() async {
    stopCalls++;
    return true;
  }

  @override
  Future<bool> isRunning() async => false;
}

Widget _wrap(Widget child) => MaterialApp(home: child);

/// 刷新若干帧（**不用** pumpAndSettle：AppLoading 为无限循环动画）。
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('disconnected：未连接态渲染状态/开关/当前配置/入口', (tester) async {
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
}
