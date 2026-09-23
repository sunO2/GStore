import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_geo_manifest.dart';
import 'package:gstore/page/proxy/proxy_geo_provisioner.dart';

const String _shaCountry =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _shaGeosite = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const String _proxyPrefix = 'https://gh-proxy.org/';

/// 假 geo 门面：可控 rulesGet / configGenerate / rulesReload，记录调用顺序。
class _FakeGeoFacade implements ProxyGeoFacade {
  final List<String> calls = <String>[];

  RulesSnapshot rulesGetResult = const RulesSnapshot();
  Object? rulesGetError;
  int rulesGetCalls = 0;

  GeneratedConfig generateResult =
      const GeneratedConfig(config: 'generated-yaml');
  Object? generateError;
  Completer<void>? generateGate;
  int generateCalls = 0;
  GenerateRequest? lastGenerate;

  RulesSnapshot reloadResult = const RulesSnapshot();
  int reloadCalls = 0;
  RulesReloadRequest? lastReload;

  @override
  Future<RulesSnapshot> rulesGet() async {
    calls.add('rulesGet');
    rulesGetCalls++;
    final error = rulesGetError;
    if (error != null) throw error;
    return rulesGetResult;
  }

  @override
  Future<GeneratedConfig> configGenerate(GenerateRequest request) async {
    calls.add('configGenerate');
    generateCalls++;
    lastGenerate = request;
    final gate = generateGate;
    if (gate != null) await gate.future;
    final error = generateError;
    if (error != null) throw error;
    return generateResult;
  }

  @override
  Future<RulesSnapshot> rulesReload(RulesReloadRequest request) async {
    calls.add('rulesReload');
    reloadCalls++;
    lastReload = request;
    return reloadResult;
  }
}

/// 假校验和客户端：按 URL 返回预设 sha。
class _FakeChecksumClient implements ProxyGeoChecksumClient {
  _FakeChecksumClient(this.shas);

  final Map<String, String?> shas;
  final List<String> requested = <String>[];

  @override
  Future<String?> fetchSha256(String assetUrl) async {
    requested.add(assetUrl);
    return shas[assetUrl];
  }
}

/// 可控时钟：[now] 返回当前值并按 [step] 前进。
class _MutableClock {
  _MutableClock(this.current);

  DateTime current;
  Duration step = Duration.zero;

  DateTime now() {
    final value = current;
    current = current.add(step);
    return value;
  }
}

ProxyGeoManifest _manifest() => const ProxyGeoManifest(
      assets: <ProxyGeoAsset>[
        ProxyGeoAsset(
          file: 'country.mmdb',
          url:
              'https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb',
        ),
        ProxyGeoAsset(
          file: 'geosite.dat',
          url:
              'https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat',
        ),
      ],
    );

_FakeChecksumClient _checksumBoth() => _FakeChecksumClient(<String, String?>{
      _manifest().assets[0].url: _shaCountry,
      _manifest().assets[1].url: _shaGeosite,
    });

ProxyGeoProvisioner _provisioner({
  required _FakeGeoFacade facade,
  ProxyGeoChecksumClient? checksum,
  DateTime Function()? clock,
  Duration timeout = const Duration(seconds: 90),
  Duration pollInterval = Duration.zero,
}) =>
    ProxyGeoProvisioner(
      facade: facade,
      manifest: _manifest(),
      checksumClient: checksum ?? _checksumBoth(),
      proxyPrefix: () => _proxyPrefix,
      clock: clock,
      pollInterval: pollInterval,
      timeout: timeout,
    );

void main() {
  group('kickoff', () {
    test('geo 未就绪 → configGenerate → rulesReload（download:true，两资产带前缀+sha）',
        () async {
      final facade = _FakeGeoFacade();
      final provisioner = _provisioner(facade: facade);

      final ok = await provisioner.kickoff(profileId: 'p1');

      expect(ok, isTrue);
      expect(facade.calls, <String>['rulesGet', 'configGenerate', 'rulesReload']);
      expect(facade.generateCalls, 1);
      expect(facade.lastGenerate?.profileId, 'p1');
      expect(facade.reloadCalls, 1);

      final reload = facade.lastReload!;
      expect(reload.config, 'generated-yaml');
      final geo = reload.geo!;
      expect(geo['download'], isTrue);
      final assets = (geo['assets'] as Map).cast<String, dynamic>();
      expect(assets.keys.toSet(), <String>{'country.mmdb', 'geosite.dat'});

      final country = (assets['country.mmdb'] as Map).cast<String, String>();
      expect(country['sha256'], _shaCountry);
      expect(country['url'], '$_proxyPrefix${_manifest().assets[0].url}');

      final geosite = (assets['geosite.dat'] as Map).cast<String, String>();
      expect(geosite['sha256'], _shaGeosite);
      expect(geosite['url'], '$_proxyPrefix${_manifest().assets[1].url}');
    });

    test('geo 已 ready → 不调用 configGenerate/rulesReload', () async {
      final facade = _FakeGeoFacade()
        ..rulesGetResult = const RulesSnapshot(
          geo: GeoStatus(status: ProxyGeoProvisioner.readyStatus),
        );
      final provisioner = _provisioner(facade: facade);

      final ok = await provisioner.kickoff();

      expect(ok, isTrue);
      expect(facade.calls, <String>['rulesGet']);
      expect(facade.generateCalls, 0);
      expect(facade.reloadCalls, 0);
    });

    test('某资产 sha 为 null → 跳过该资产，仅提交另一个', () async {
      final facade = _FakeGeoFacade();
      final checksum = _FakeChecksumClient(<String, String?>{
        _manifest().assets[0].url: null,
        _manifest().assets[1].url: _shaGeosite,
      });
      final provisioner = _provisioner(facade: facade, checksum: checksum);

      final ok = await provisioner.kickoff();

      expect(ok, isTrue);
      expect(facade.reloadCalls, 1);
      final assets = (facade.lastReload!.geo!['assets'] as Map).cast<String, dynamic>();
      expect(assets.keys.toList(), <String>['geosite.dat']);
      expect((assets['geosite.dat'] as Map)['sha256'], _shaGeosite);
    });

    test('全部资产 sha 不可用 → 返回 false 且不 reload', () async {
      final facade = _FakeGeoFacade();
      final checksum = _FakeChecksumClient(<String, String?>{
        _manifest().assets[0].url: null,
        _manifest().assets[1].url: null,
      });
      final provisioner = _provisioner(facade: facade, checksum: checksum);

      final ok = await provisioner.kickoff();

      expect(ok, isFalse);
      expect(facade.reloadCalls, 0);
    });

    test('并发 kickoff 去重：同一 in-flight Future，仅一次 configGenerate/reload',
        () async {
      final facade = _FakeGeoFacade();
      final gate = Completer<void>();
      facade.generateGate = gate;
      final provisioner = _provisioner(facade: facade);

      final first = provisioner.kickoff(profileId: 'p1');
      final second = provisioner.kickoff(profileId: 'p1');
      gate.complete();
      final results = await Future.wait(<Future<bool>>[first, second]);

      expect(results, <bool>[true, true]);
      expect(facade.generateCalls, 1);
      expect(facade.reloadCalls, 1);
    });

    test('configGenerate 抛异常（无 profile）→ 返回 false，绝不抛', () async {
      final facade = _FakeGeoFacade()..generateError = StateError('no profile');
      final provisioner = _provisioner(facade: facade);

      final ok = await provisioner.kickoff();

      expect(ok, isFalse);
      expect(facade.reloadCalls, 0);
    });

    test('rulesGet 抛异常 → 返回 false，绝不抛', () async {
      final facade = _FakeGeoFacade()..rulesGetError = StateError('engine down');
      final provisioner = _provisioner(facade: facade);

      final ok = await provisioner.kickoff();

      expect(ok, isFalse);
    });

    test('失败后 60s 内重复 kickoff 被节流，超过后恢复', () async {
      final clock = _MutableClock(DateTime(2026, 1, 1));
      final facade = _FakeGeoFacade()..generateError = StateError('no profile');
      final provisioner = _provisioner(facade: facade, clock: clock.now);

      expect(await provisioner.kickoff(), isFalse);
      expect(facade.generateCalls, 1);

      // 清掉错误，但仍在 60s 节流窗口内 → 直接 false，不再尝试生成。
      facade.generateError = null;
      expect(await provisioner.kickoff(), isFalse);
      expect(facade.generateCalls, 1);

      clock.current = clock.current.add(const Duration(seconds: 61));
      expect(await provisioner.kickoff(), isTrue);
      expect(facade.generateCalls, 2);
    });
  });

  group('waitReady', () {
    test('ready → true', () async {
      final facade = _FakeGeoFacade()
        ..rulesGetResult = const RulesSnapshot(
          geo: GeoStatus(status: ProxyGeoProvisioner.readyStatus),
        );
      final provisioner = _provisioner(facade: facade);

      expect(await provisioner.waitReady(), isTrue);
    });

    test('failed → false', () async {
      final facade = _FakeGeoFacade()
        ..rulesGetResult = const RulesSnapshot(
          geo: GeoStatus(status: ProxyGeoProvisioner.failedStatus),
        );
      final provisioner = _provisioner(facade: facade);

      expect(await provisioner.waitReady(), isFalse);
    });

    test('超时 → false', () async {
      final clock = _MutableClock(DateTime(2026, 1, 1));
      clock.step = const Duration(seconds: 100);
      final facade = _FakeGeoFacade()
        ..rulesGetResult = const RulesSnapshot(
          geo: GeoStatus(status: 'downloading'),
        );
      final provisioner = _provisioner(
        facade: facade,
        clock: clock.now,
        timeout: const Duration(seconds: 90),
      );

      expect(await provisioner.waitReady(), isFalse);
      expect(facade.rulesGetCalls, 1);
    });

    test('rulesGet 持续异常 → 超时后 false（绝不抛）', () async {
      final clock = _MutableClock(DateTime(2026, 1, 1));
      clock.step = const Duration(seconds: 100);
      final facade = _FakeGeoFacade()..rulesGetError = StateError('boom');
      final provisioner = _provisioner(
        facade: facade,
        clock: clock.now,
        timeout: const Duration(seconds: 90),
      );

      expect(await provisioner.waitReady(), isFalse);
    });
  });
}
