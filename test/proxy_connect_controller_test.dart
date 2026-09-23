import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/service/proxy_connect_controller.dart';
import 'package:gstore/page/proxy/proxy_engine_settings_store.dart';
import 'package:gstore/page/proxy/proxy_geo_manifest.dart';
import 'package:gstore/page/proxy/proxy_geo_provisioner.dart';
import 'package:gstore/page/proxy/proxy_home_facade.dart';
import 'package:gstore/page/proxy/proxy_routing_mode_store.dart';

/// 窄门面假实现：只承载连接 / 断开所需的四个方法，无需原生模块。
class _FakeConnectFacade implements ProxyConnectFacade {
  ProxyCoreStatus startResult = const ProxyCoreStatus(
    state: ProxyConnState.running,
    mode: ProxyMode.vpn,
    instanceId: 1,
    spawned: true,
    profileName: '默认配置',
  );
  Object? startError;
  Completer<ProxyCoreStatus>? startCompleter;
  CoreStartRequest? lastStart;
  int startCalls = 0;

  /// 共享调用顺序记录（用于验证 geo.kickoff 先于 core.start）。
  List<String>? order;

  CoreStopResult stopResult =
      const CoreStopResult(state: ProxyConnState.stopped);
  Object? stopError;
  int stopCalls = 0;

  RoutingModeSetResult routingResult = const RoutingModeSetResult(
    mode: ProxyRoutingMode.rule,
    applied: true,
    engineRunning: true,
  );
  Object? routingError;
  int routingSetCalls = 0;
  String? lastRoutingSet;

  String vpnConfig = '{}';
  Object? vpnConfigError;
  int vpnConfigCalls = 0;

  @override
  Future<ProxyCoreStatus> coreStart(CoreStartRequest request) {
    startCalls++;
    lastStart = request;
    order?.add('core.start');
    final error = startError;
    if (error != null) return Future<ProxyCoreStatus>.error(error);
    final completer = startCompleter;
    if (completer != null) return completer.future;
    return Future<ProxyCoreStatus>.value(startResult);
  }

  @override
  Future<CoreStopResult> coreStop() async {
    stopCalls++;
    final error = stopError;
    if (error != null) throw error;
    return stopResult;
  }

  @override
  Future<RoutingModeSetResult> routingSetMode(String mode) {
    routingSetCalls++;
    lastRoutingSet = mode;
    final error = routingError;
    if (error != null) return Future<RoutingModeSetResult>.error(error);
    return Future<RoutingModeSetResult>.value(routingResult);
  }

  @override
  Future<String> vpnConfigJson() async {
    vpnConfigCalls++;
    final error = vpnConfigError;
    if (error != null) throw error;
    return vpnConfig;
  }
}

/// 假 VPN 授权接缝：默认「同意」。
class _FakeConsent implements ProxyVpnConsent {
  _FakeConsent({this.granted = true});

  bool granted;
  int prepareCalls = 0;
  int stopCalls = 0;
  String? lastConfigJson;
  Object? prepareError;
  Object? stopError;

  /// 记录 `core.stop` 与 `stop` 的先后顺序（用于验证 try/finally 兜底）。
  final List<String> order = <String>[];

  @override
  Future<bool> prepare({String configJson = '{}'}) async {
    prepareCalls++;
    lastConfigJson = configJson;
    final error = prepareError;
    if (error != null) throw error;
    return granted;
  }

  @override
  Future<bool> stop() async {
    stopCalls++;
    order.add('consent.stop');
    final error = stopError;
    if (error != null) throw error;
    return true;
  }

  @override
  Future<bool> isRunning() async => false;
}

/// 假引擎设置存储：内存实现。
class _FakeEngineStore implements ProxyEngineSettingsStore {
  _FakeEngineStore([this.value = const ProxyEngineSettings()]);

  ProxyEngineSettings value;
  Object? readError;

  @override
  Future<ProxyEngineSettings> read() async {
    final error = readError;
    if (error != null) throw error;
    return value;
  }

  @override
  Future<void> write(ProxyEngineSettings settings) async => value = settings;
}

/// 假路由模式存储：内存实现。
class _FakeRoutingStore implements ProxyRoutingModeStore {
  _FakeRoutingStore([this.value]);

  ProxyRoutingMode? value;
  Object? readError;

  @override
  Future<ProxyRoutingMode?> read() async {
    final error = readError;
    if (error != null) throw error;
    return value;
  }

  @override
  Future<void> write(ProxyRoutingMode mode) async => value = mode;

  @override
  Future<void> clear() async => value = null;
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

/// 空操作校验和客户端。
class _NoopChecksumClient implements ProxyGeoChecksumClient {
  @override
  Future<String?> fetchSha256(String assetUrl) async => null;
}

/// 假 provisioner：覆写 kickoff 记录调用 / 顺序，可受控抛错。
class _FakeGeoProvisioner extends ProxyGeoProvisioner {
  _FakeGeoProvisioner()
      : super(
          facade: _NoopGeoFacade(),
          manifest: const ProxyGeoManifest(assets: <ProxyGeoAsset>[]),
          checksumClient: _NoopChecksumClient(),
        );

  int kickoffCalls = 0;
  String? lastProfileId;
  bool? lastForce;
  Object? kickoffError;
  bool kickoffResult = true;
  List<String>? order;

  @override
  Future<bool> kickoff({String? profileId, bool force = false}) async {
    kickoffCalls++;
    lastProfileId = profileId;
    lastForce = force;
    order?.add('geo.kickoff');
    final error = kickoffError;
    if (error != null) throw error;
    return kickoffResult;
  }
}

ProxyConnectController _controller({
  required _FakeConnectFacade facade,
  _FakeConsent? consent,
  _FakeEngineStore? engineStore,
  _FakeRoutingStore? routingStore,
  ProxyGeoProvisioner? geoProvisioner,
}) {
  return ProxyConnectController(
    facade: facade,
    vpnConsent: consent ?? _FakeConsent(),
    engineSettingsStore: engineStore ?? _FakeEngineStore(),
    routingModeStore: routingStore ?? _FakeRoutingStore(),
    geoProvisioner: geoProvisioner,
  );
}

void main() {
  group('ProxyConnectController.connect', () {
    test('happy path：prepare → core.start → 重放持久化路由模式', () async {
      final facade = _FakeConnectFacade()..vpnConfig = '{"custom":true}';
      final consent = _FakeConsent();
      final engineStore =
          _FakeEngineStore(const ProxyEngineSettings(stack: 'system', mtu: 1400));
      final routingStore = _FakeRoutingStore(ProxyRoutingMode.global);
      facade.routingResult = const RoutingModeSetResult(
        mode: ProxyRoutingMode.global,
        applied: true,
        engineRunning: true,
      );
      final controller = _controller(
        facade: facade,
        consent: consent,
        engineStore: engineStore,
        routingStore: routingStore,
      );

      final outcome = await controller.connect(
        targetMode: ProxyMode.vpn,
        profileId: 'p1',
        vpnConfigJson: '{}',
        fallbackRoutingMode: ProxyRoutingMode.rule,
      );

      // prepare：默认 '{}' → 向门面读取并透传给授权。
      expect(consent.prepareCalls, 1);
      expect(consent.lastConfigJson, '{"custom":true}');
      // core.start：模式 / 订阅 / stack / mtu 全部透传。
      expect(facade.startCalls, 1);
      expect(facade.lastStart?.mode, 'vpn');
      expect(facade.lastStart?.profileId, 'p1');
      expect(facade.lastStart?.stack, 'system');
      expect(facade.lastStart?.mtu, 1400);
      // 路由重放：使用持久化的 global（覆盖 fallback rule）。
      expect(facade.routingSetCalls, 1);
      expect(facade.lastRoutingSet, 'global');
      expect(outcome.routingMode, ProxyRoutingMode.global);
      expect(outcome.status.state, ProxyConnState.running);
    });

    test('显式非默认 vpnConfigJson：直接透传给 prepare，不读门面', () async {
      final facade = _FakeConnectFacade();
      final consent = _FakeConsent();
      final controller = _controller(facade: facade, consent: consent);

      await controller.connect(
        targetMode: ProxyMode.vpn,
        vpnConfigJson: '{"explicit":true}',
      );

      expect(facade.vpnConfigCalls, 0);
      expect(consent.lastConfigJson, '{"explicit":true}');
    });

    test('lanProxy：跳过 VPN 授权 prepare', () async {
      final facade = _FakeConnectFacade()
        ..startResult = const ProxyCoreStatus(
          state: ProxyConnState.running,
          mode: ProxyMode.lanProxy,
          instanceId: 1,
          spawned: true,
        );
      final consent = _FakeConsent();
      final controller = _controller(facade: facade, consent: consent);

      final outcome = await controller.connect(targetMode: ProxyMode.lanProxy);

      expect(consent.prepareCalls, 0);
      expect(facade.startCalls, 1);
      expect(facade.lastStart?.mode, 'lanProxy');
      expect(outcome.status.mode, ProxyMode.lanProxy);
    });

    test('prepare 被拒：抛 PROXY_VPN_CONSENT_DENIED 且不调用 core.start', () async {
      final facade = _FakeConnectFacade();
      final consent = _FakeConsent(granted: false);
      final controller = _controller(facade: facade, consent: consent);

      await expectLater(
        controller.connect(targetMode: ProxyMode.vpn),
        throwsA(
          isA<ProxyModuleException>().having(
            (e) => e.code,
            'code',
            'PROXY_VPN_CONSENT_DENIED',
          ),
        ),
      );
      expect(consent.prepareCalls, 1);
      expect(facade.startCalls, 0);
    });

    test('core.start 失败：错误冒泡且不重放路由模式', () async {
      final facade = _FakeConnectFacade()
        ..startError = const ProxyModuleException(
          code: 'PROXY_TUN_FD_INVALID',
          message: 'TUN fd 无效',
        );
      final controller = _controller(facade: facade);

      await expectLater(
        controller.connect(targetMode: ProxyMode.vpn),
        throwsA(
          isA<ProxyModuleException>().having(
            (e) => e.code,
            'code',
            'PROXY_TUN_FD_INVALID',
          ),
        ),
      );
      expect(facade.startCalls, 1);
      expect(facade.routingSetCalls, 0);
    });

    test('core.start 抛非模块异常也原样冒泡', () async {
      final facade = _FakeConnectFacade()..startError = StateError('boom');
      final controller = _controller(facade: facade);

      await expectLater(
        controller.connect(targetMode: ProxyMode.vpn),
        throwsA(isA<StateError>()),
      );
    });

    test('引擎设置读取异常：回落默认 stack/mtu，不阻断连接', () async {
      final facade = _FakeConnectFacade();
      final engineStore = _FakeEngineStore()..readError = StateError('store fail');
      final controller = _controller(facade: facade, engineStore: engineStore);

      await controller.connect(targetMode: ProxyMode.vpn);

      expect(facade.startCalls, 1);
      expect(facade.lastStart?.stack, ProxyEngineSettings().stack);
      expect(facade.lastStart?.mtu, ProxyEngineSettings().mtu);
    });

    test('vpnConfigJson 门面异常：回落默认 {} 后仍完成 prepare', () async {
      final facade = _FakeConnectFacade()..vpnConfigError = StateError('no config');
      final consent = _FakeConsent();
      final controller = _controller(facade: facade, consent: consent);

      await controller.connect(targetMode: ProxyMode.vpn, vpnConfigJson: '{}');

      expect(facade.vpnConfigCalls, 1);
      expect(consent.lastConfigJson, '{}');
    });
  });

  group('ProxyConnectController geo provisioning (rule 模式)', () {
    test('rule 模式：core.start 之前 kickoff（携带 profileId）', () async {
      final order = <String>[];
      final facade = _FakeConnectFacade()..order = order;
      final geo = _FakeGeoProvisioner()..order = order;
      final controller = _controller(
        facade: facade,
        routingStore: _FakeRoutingStore(ProxyRoutingMode.rule),
        geoProvisioner: geo,
      );

      final outcome = await controller.connect(
        targetMode: ProxyMode.vpn,
        profileId: 'p1',
      );

      expect(order, <String>['geo.kickoff', 'core.start']);
      expect(geo.kickoffCalls, 1);
      expect(geo.lastProfileId, 'p1');
      expect(facade.startCalls, 1);
      expect(outcome.status.state, ProxyConnState.running);
    });

    test('存储未命中但 fallback 为 rule：仍 kickoff', () async {
      final facade = _FakeConnectFacade();
      final geo = _FakeGeoProvisioner();
      final controller = _controller(
        facade: facade,
        routingStore: _FakeRoutingStore(), // null
        geoProvisioner: geo,
      );

      await controller.connect(
        targetMode: ProxyMode.vpn,
        fallbackRoutingMode: ProxyRoutingMode.rule,
      );

      expect(geo.kickoffCalls, 1);
      expect(facade.startCalls, 1);
    });

    test('direct 模式：不 kickoff', () async {
      final facade = _FakeConnectFacade();
      final geo = _FakeGeoProvisioner();
      final controller = _controller(
        facade: facade,
        routingStore: _FakeRoutingStore(ProxyRoutingMode.direct),
        geoProvisioner: geo,
      );

      await controller.connect(
        targetMode: ProxyMode.vpn,
        fallbackRoutingMode: ProxyRoutingMode.rule,
      );

      expect(geo.kickoffCalls, 0);
      expect(facade.startCalls, 1);
    });

    test('global 模式：不 kickoff', () async {
      final facade = _FakeConnectFacade();
      final geo = _FakeGeoProvisioner();
      final controller = _controller(
        facade: facade,
        routingStore: _FakeRoutingStore(ProxyRoutingMode.global),
        geoProvisioner: geo,
      );

      await controller.connect(targetMode: ProxyMode.vpn);

      expect(geo.kickoffCalls, 0);
      expect(facade.startCalls, 1);
    });

    test('kickoff 抛异常：不阻断连接，引擎仍启动', () async {
      final facade = _FakeConnectFacade();
      final geo = _FakeGeoProvisioner()..kickoffError = StateError('geo boom');
      final controller = _controller(
        facade: facade,
        routingStore: _FakeRoutingStore(ProxyRoutingMode.rule),
        geoProvisioner: geo,
      );

      final outcome = await controller.connect(targetMode: ProxyMode.vpn);

      expect(geo.kickoffCalls, 1);
      expect(facade.startCalls, 1);
      expect(outcome.status.state, ProxyConnState.running);
    });

    test('未注入 provisioner：连接照常（无 geo）', () async {
      final facade = _FakeConnectFacade();
      final controller = _controller(
        facade: facade,
        routingStore: _FakeRoutingStore(ProxyRoutingMode.rule),
      );

      await controller.connect(targetMode: ProxyMode.vpn);

      expect(facade.startCalls, 1);
    });
  });

  group('ProxyConnectController.replayPersistedRoutingMode', () {
    test('存储未命中：使用 fallback 模式重放', () async {
      final facade = _FakeConnectFacade()
        ..routingResult = const RoutingModeSetResult(
          mode: ProxyRoutingMode.rule,
          applied: true,
          engineRunning: true,
        );
      final controller = _controller(
        facade: facade,
        routingStore: _FakeRoutingStore(), // null
      );

      final applied = await controller.replayPersistedRoutingMode(
        fallbackRoutingMode: ProxyRoutingMode.rule,
      );

      expect(facade.routingSetCalls, 1);
      expect(facade.lastRoutingSet, 'rule');
      expect(applied, ProxyRoutingMode.rule);
    });

    test('存储为 unknown：跳过重放（不发 routing.set_mode）', () async {
      final facade = _FakeConnectFacade();
      final controller = _controller(
        facade: facade,
        routingStore: _FakeRoutingStore(ProxyRoutingMode.unknown),
      );

      final applied = await controller.replayPersistedRoutingMode(
        fallbackRoutingMode: ProxyRoutingMode.global,
      );

      expect(facade.routingSetCalls, 0);
      expect(applied, isNull);
    });

    test('fallback 为 null 且存储未设置：跳过重放', () async {
      final facade = _FakeConnectFacade();
      final controller = _controller(facade: facade);

      final applied = await controller.replayPersistedRoutingMode();

      expect(facade.routingSetCalls, 0);
      expect(applied, isNull);
    });

    test('routing.set_mode 失败：吞掉并返回 null（不抛错）', () async {
      final facade = _FakeConnectFacade()
        ..routingError = const ProxyModuleException(
          code: 'PROXY_ROUTING_FAILED',
          message: '路由切换失败',
        );
      final controller = _controller(
        facade: facade,
        routingStore: _FakeRoutingStore(ProxyRoutingMode.global),
      );

      final applied = await controller.replayPersistedRoutingMode();

      expect(facade.routingSetCalls, 1);
      expect(applied, isNull);
    });

    test('引擎回报 unknown：返回 null', () async {
      final facade = _FakeConnectFacade()
        ..routingResult = const RoutingModeSetResult(
          mode: ProxyRoutingMode.unknown,
          applied: false,
          engineRunning: false,
        );
      final controller = _controller(
        facade: facade,
        routingStore: _FakeRoutingStore(ProxyRoutingMode.global),
      );

      final applied = await controller.replayPersistedRoutingMode();

      expect(applied, isNull);
    });

    test('存储读取异常：使用 fallback 重放', () async {
      final facade = _FakeConnectFacade();
      final routingStore = _FakeRoutingStore(ProxyRoutingMode.global)
        ..readError = StateError('read fail');
      final controller = _controller(
        facade: facade,
        routingStore: routingStore,
      );

      final applied = await controller.replayPersistedRoutingMode(
        fallbackRoutingMode: ProxyRoutingMode.direct,
      );

      expect(facade.lastRoutingSet, 'direct');
      expect(applied, ProxyRoutingMode.rule); // facade 默认回报 rule
    });
  });

  group('ProxyConnectController.disconnect', () {
    test('happy path：core.stop → 停系统服务', () async {
      final facade = _FakeConnectFacade();
      final consent = _FakeConsent();
      final controller = _controller(facade: facade, consent: consent);

      final result = await controller.disconnect();

      expect(facade.stopCalls, 1);
      expect(consent.stopCalls, 1);
      expect(consent.order, <String>['consent.stop']);
      expect(result?.state, ProxyConnState.stopped);
    });

    test('core.stop 抛错：仍停系统服务且原错误冒泡（try/finally 回归锁）', () async {
      final facade = _FakeConnectFacade()
        ..stopError = const ProxyModuleException(
          code: 'PROXY_ENGINE_STOP_FAILED',
          message: '停止引擎失败',
        );
      final consent = _FakeConsent();
      final controller = _controller(facade: facade, consent: consent);

      await expectLater(
        controller.disconnect(),
        throwsA(
          isA<ProxyModuleException>().having(
            (e) => e.code,
            'code',
            'PROXY_ENGINE_STOP_FAILED',
          ),
        ),
      );
      expect(facade.stopCalls, 1);
      expect(consent.stopCalls, 1);
    });

    test('停系统服务自身抛错：吞掉，core.stop 结果正常返回', () async {
      final facade = _FakeConnectFacade();
      final consent = _FakeConsent()..stopError = StateError('stopService fail');
      final controller = _controller(facade: facade, consent: consent);

      final result = await controller.disconnect();

      expect(facade.stopCalls, 1);
      expect(consent.stopCalls, 1);
      expect(result?.state, ProxyConnState.stopped);
    });
  });
}
