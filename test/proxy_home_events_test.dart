// T31：首页消费 proxy.subscription.* / proxy.config.applied 事件并给出 UI 反馈，
// 且页面销毁时取消 geo waitReady 轮询。全部密闭式（注入假门面 / 假 geo）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_geo_manifest.dart';
import 'package:gstore/page/proxy/proxy_geo_provisioner.dart';
import 'package:gstore/page/proxy/proxy_home_facade.dart';
import 'package:gstore/page/proxy/proxy_home_page.dart';

/// 最小假门面：只读返回默认值，事件流受控。
class _FakeHomeFacade implements ProxyHomeFacade {
  final StreamController<ProxyEvent> controller =
      StreamController<ProxyEvent>.broadcast();

  ProfileList profileListResult = const ProfileList();

  @override
  Stream<ProxyEvent> get events => controller.stream;

  @override
  Future<ProxyPingResult> ping() async => const ProxyPingResult(
        pong: true,
        module: 'proxy',
        moduleVersion: '0.1.0',
        apiVersion: 1,
        minHostAbi: 3,
        hostAbi: 3,
        state: ProxyConnState.stopped,
        mode: ProxyMode.off,
      );

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
  Future<ProxyCoreStatus> coreStart(CoreStartRequest request) async =>
      const ProxyCoreStatus(
        state: ProxyConnState.running,
        mode: ProxyMode.vpn,
        instanceId: 1,
        spawned: true,
      );

  @override
  Future<CoreStopResult> coreStop() async =>
      const CoreStopResult(state: ProxyConnState.stopped);

  @override
  Future<CoreModeResult> coreGetMode() async => const CoreModeResult(
        mode: ProxyMode.off,
        state: ProxyConnState.stopped,
        sinceMs: 0,
      );

  @override
  Future<CoreSetModeResult> coreSetMode(String mode) async => CoreSetModeResult(
        ok: true,
        mode: ProxyMode.fromWire(mode),
        previous: ProxyMode.vpn,
      );

  @override
  Future<RoutingModeResult> routingGetMode() async =>
      const RoutingModeResult(mode: ProxyRoutingMode.rule, engineRunning: false);

  @override
  Future<RoutingModeSetResult> routingSetMode(String mode) async =>
      RoutingModeSetResult(
        mode: ProxyRoutingMode.fromWire(mode),
        applied: true,
        engineRunning: false,
      );

  @override
  Future<ProxyLanStatus> lanStatus() async =>
      const ProxyLanStatus(bound: false, config: ProxyLanConfig(enabled: false));

  @override
  Future<TrafficSnapshot> statsTrafficGet({int? topDomains}) async =>
      const TrafficSnapshot();

  @override
  Future<ProfileList> profileList() async => profileListResult;

  @override
  Future<NodeListResult> nodeList() async => const NodeListResult();

  @override
  Future<ProxyShaperSnapshot> loadShaperConfig() async =>
      const ProxyShaperSnapshot();

  @override
  Future<CaptureConfig> captureConfigGet() async => const CaptureConfig();

  @override
  Future<CaptureConfig> captureConfigSet(CaptureConfig config) async => config;

  @override
  Future<CaptureCaInfo> captureCaGet() async => const CaptureCaInfo();

  @override
  Future<String> vpnConfigJson() async => '{}';

  void emit(ProxyEvent event) => controller.add(event);
}

/// 假 VPN 授权：默认「同意」。
class _FakeVpnConsent implements ProxyVpnConsent {
  @override
  Future<bool> prepare({String configJson = '{}'}) async => true;

  @override
  Future<bool> stop() async => true;

  @override
  Future<bool> isRunning() async => false;
}

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

/// 假 provisioner：`waitReady` 永挂起（模拟后台轮询中），记录取消次数。
class _FakeGeoProvisioner extends ProxyGeoProvisioner {
  _FakeGeoProvisioner()
      : super(
          facade: _NoopGeoFacade(),
          manifest: const ProxyGeoManifest(assets: <ProxyGeoAsset>[]),
          checksumClient: _NoopChecksumClient(),
        );

  final Completer<bool> waitGate = Completer<bool>();
  int cancelCalls = 0;

  @override
  Future<bool> kickoff({String? profileId, bool force = false}) async => true;

  @override
  Future<bool> waitReady({Duration? timeout}) => waitGate.future;

  @override
  void cancelWaitReady() {
    cancelCalls++;
    if (!waitGate.isCompleted) waitGate.complete(false);
  }
}

class _FakeGeoProvisionerFactory extends ProxyGeoProvisionerFactory {
  _FakeGeoProvisionerFactory(this.provisioner);

  final ProxyGeoProvisioner provisioner;

  @override
  Future<ProxyGeoProvisioner?> create() async => provisioner;
}

Widget _wrap(Widget child) => MaterialApp(home: child);

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('订阅更新事件触发 UI 反馈（节点数）', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeHomeFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    facade.emit(const ProxySubscriptionUpdatedEvent(
      profileId: 'p1',
      nodeCount: 12,
      traffic: ProxyTraffic(),
      expireAtMs: 0,
    ));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-subscription-notice')), findsOneWidget);
    expect(find.textContaining('12'), findsWidgets);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('订阅失败事件触发错误反馈', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeHomeFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    facade.emit(const ProxySubscriptionFailedEvent(
      profileId: 'p1',
      attempts: 2,
      consecutiveFailures: 2,
      lastAttemptMs: 0,
      nextRefreshAtMs: 0,
      error: ProxyStateError(code: 'FETCH_FAILED', message: '网络不可达'),
    ));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-subscription-notice')), findsOneWidget);
    expect(find.textContaining('网络不可达'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('订阅新增事件触发 UI 反馈', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeHomeFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    facade.emit(const ProxySubscriptionAddedEvent(
      profileId: 'p2',
      name: '测试订阅',
    ));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-subscription-notice')), findsOneWidget);
    expect(find.textContaining('测试订阅'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('配置已应用事件触发 UI 反馈', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeHomeFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    facade.emit(const ProxyConfigAppliedEvent(
      profileId: 'p1',
      hash: 'abc',
      template: 'clash',
    ));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-config-applied-notice')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('页面销毁取消 geo waitReady 轮询', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeHomeFacade();
    final geo = _FakeGeoProvisioner();
    await tester.pumpWidget(_wrap(ProxyHomePage(
      facade: facade,
      vpnConsent: _FakeVpnConsent(),
      geoProvisionerFactory: _FakeGeoProvisionerFactory(geo),
    )));
    await _flush(tester);
    // 触发若干层微任务，确保 provisioner 已创建并进入 waitReady。
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    // 销毁页面（切到空 widget）。
    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    await _flush(tester);

    expect(geo.cancelCalls, 1, reason: '销毁后必须取消 geo 轮询');
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });
}
