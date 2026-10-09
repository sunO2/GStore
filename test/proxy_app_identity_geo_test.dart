// T31：app-identity 性能（按需/批量图标）+ geo 校验安全 + waitReady 可取消。
//
// 全部密闭式：注入假 loader / iconSaver / cleaner / facade，不触碰原生通道。

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/http/rhttp_adapter.dart';
import 'package:gstore/page/proxy/proxy_app_identity.dart';
import 'package:gstore/page/proxy/proxy_geo_manifest.dart';
import 'package:gstore/page/proxy/proxy_geo_provisioner.dart';
import 'package:installed_apps/app_info.dart';

AppInfo _app(String packageName, String name, {Uint8List? icon}) => AppInfo(
      name: name,
      icon: icon,
      packageName: packageName,
      versionName: '1.0.0',
      versionCode: 1,
      builtWith: BuiltWith.native_or_others,
      installedTimestamp: 0,
    );

Uint8List _bytes(int n) => Uint8List.fromList(List<int>.generate(n, (i) => i));

/// 假 geo 门面：可控 rulesGet / configGenerate / rulesReload，记录调用。
class _FakeGeoFacade implements ProxyGeoFacade {
  RulesSnapshot rulesGetResult = const RulesSnapshot();
  Object? rulesGetError;
  int rulesGetCalls = 0;
  int reloadCalls = 0;
  RulesReloadRequest? lastReload;

  @override
  Future<RulesSnapshot> rulesGet() async {
    rulesGetCalls++;
    final error = rulesGetError;
    if (error != null) throw error;
    return rulesGetResult;
  }

  @override
  Future<GeneratedConfig> configGenerate(GenerateRequest request) async =>
      const GeneratedConfig(config: 'generated-yaml');

  @override
  Future<RulesSnapshot> rulesReload(RulesReloadRequest request) async {
    reloadCalls++;
    lastReload = request;
    return const RulesSnapshot();
  }
}

/// 假校验和客户端：按 URL 返回预设 sha（含 null = 不可用）。
class _FakeChecksumClient implements ProxyGeoChecksumClient {
  _FakeChecksumClient(this.shas);

  final Map<String, String?> shas;

  @override
  Future<String?> fetchSha256(String assetUrl) async => shas[assetUrl];
}

ProxyGeoManifest _manifest() => const ProxyGeoManifest(
      assets: <ProxyGeoAsset>[
        ProxyGeoAsset(
          file: 'country.mmdb',
          url: 'https://github.com/MetaCubeX/country.mmdb',
        ),
        ProxyGeoAsset(
          file: 'geosite.dat',
          url: 'https://github.com/MetaCubeX/geosite.dat',
        ),
      ],
    );

void main() {
  group('ProxyAppIdentityResolver 性能', () {
    test('ensureLoaded(resolveIcons:false) 不写盘；resolveIcons 按需解析', () async {
      var saveCalls = 0;
      final resolver = ProxyAppIdentityResolver(
        isAndroid: true,
        loader: () async => <AppInfo>[
          _app('a', 'A', icon: _bytes(3)),
          _app('b', 'B', icon: _bytes(3)),
          _app('c', 'C', icon: _bytes(3)),
        ],
        iconSaver: (packageName, bytes) async {
          saveCalls++;
          return '/tmp/$packageName.png';
        },
      );

      await resolver.ensureLoaded(resolveIcons: false);
      // 元数据加载阶段绝不逐个写盘。
      expect(saveCalls, 0, reason: '元数据加载不应写图标');
      expect(resolver.lookup('a')?.label, 'A');
      expect(resolver.lookup('a')?.iconPath, isNull);

      // 按需解析：只写被请求的包。
      await resolver.resolveIcons(<String>['a', 'b']);
      expect(saveCalls, 2);
      expect(resolver.lookup('a')?.iconPath, '/tmp/a.png');
      expect(resolver.lookup('b')?.iconPath, '/tmp/b.png');
      expect(resolver.lookup('c')?.iconPath, isNull, reason: '未请求的包不写盘');

      // 幂等：重复解析不重复写盘。
      await resolver.resolveIcons(<String>['a']);
      expect(saveCalls, 2);
    });

    test('ensureLoaded 默认批量并发解析（非逐个同步写盘）', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final resolver = ProxyAppIdentityResolver(
        isAndroid: true,
        loader: () async =>
            List<AppInfo>.generate(24, (i) => _app('p$i', 'P$i', icon: _bytes(3))),
        iconSaver: (packageName, bytes) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(Duration.zero);
          inFlight--;
          return '/tmp/$packageName.png';
        },
      );

      await resolver.ensureLoaded();

      expect(maxInFlight, greaterThan(1), reason: '批量并发，不是逐个同步写盘');
      expect(resolver.lookup('p0')?.iconPath, '/tmp/p0.png');
      expect(resolver.lookup('p23')?.iconPath, '/tmp/p23.png');
    });

    test('rescan 重新扫描并清理临时缓存（保留当前包集合）', () async {
      var loadCalls = 0;
      Set<String>? cleanedKeep;
      final resolver = ProxyAppIdentityResolver(
        isAndroid: true,
        loader: () async {
          loadCalls++;
          return <AppInfo>[_app('a', 'A', icon: _bytes(3))];
        },
        iconSaver: (packageName, bytes) async => '/tmp/$packageName.png',
        iconCacheCleaner: (keep) async {
          cleanedKeep = keep;
        },
      );

      await resolver.ensureLoaded();
      expect(loadCalls, 1);

      await resolver.rescan();

      expect(loadCalls, 2, reason: '重扫重新查询已安装应用');
      expect(cleanedKeep, contains('a'), reason: '清理时保留当前包集合');
      expect(resolver.lookup('a')?.iconPath, '/tmp/a.png');
    });

    test('cleanupIconCache 可显式清理（不重扫）', () async {
      var cleanerCalls = 0;
      Set<String>? cleanedKeep;
      final resolver = ProxyAppIdentityResolver(
        isAndroid: true,
        loader: () async => <AppInfo>[_app('a', 'A', icon: _bytes(3))],
        iconSaver: (packageName, bytes) async => '/tmp/$packageName.png',
        iconCacheCleaner: (keep) async {
          cleanerCalls++;
          cleanedKeep = keep;
        },
      );

      await resolver.ensureLoaded();
      await resolver.cleanupIconCache();

      expect(cleanerCalls, 1);
      expect(cleanedKeep, contains('a'));
    });
  });

  group('geo 校验安全', () {
    test('DioProxyGeoChecksumClient 默认 Dio 启用证书校验（不允许坏证书）', () {
      final Dio dio = DioProxyGeoChecksumClient.buildDefaultDio();
      final adapter = dio.httpClientAdapter;
      expect(adapter, isA<RhttpAdapter>());
      expect(
        (adapter as RhttpAdapter).allowBadCertificate,
        isFalse,
        reason: 'geo 校验和客户端必须做证书校验',
      );
    });

    test('校验和全部不可用 → kickoff 显式失败，不 reload', () async {
      final facade = _FakeGeoFacade();
      final provisioner = ProxyGeoProvisioner(
        facade: facade,
        manifest: _manifest(),
        checksumClient: _FakeChecksumClient(<String, String?>{
          _manifest().assets[0].url: null,
          _manifest().assets[1].url: null,
        }),
        proxyPrefix: () => '',
      );

      expect(await provisioner.kickoff(), isFalse);
      expect(facade.reloadCalls, 0);
    });
  });

  group('waitReady 取消', () {
    test('取消后停止轮询（不再调用 rulesGet）', () async {
      final facade = _FakeGeoFacade()
        ..rulesGetResult = const RulesSnapshot(
          geo: GeoStatus(status: 'downloading'),
        );
      final provisioner = ProxyGeoProvisioner(
        facade: facade,
        manifest: _manifest(),
        checksumClient: _FakeChecksumClient(const <String, String?>{}),
        proxyPrefix: () => '',
        pollInterval: const Duration(milliseconds: 2),
        timeout: const Duration(seconds: 30),
      );

      final Future<bool> pending = provisioner.waitReady();
      // 让若干次轮询发生，再取消。
      await Future<void>.delayed(const Duration(milliseconds: 15));
      provisioner.cancelWaitReady();

      expect(await pending, isFalse);
      final callsAtCancel = facade.rulesGetCalls;
      expect(callsAtCancel, greaterThanOrEqualTo(1));

      // 取消后不再产生新的轮询。
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(facade.rulesGetCalls, callsAtCancel, reason: '取消后不再轮询');
    });
  });
}
