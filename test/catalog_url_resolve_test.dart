/// `CatalogUrlSetting.resolveDownloadUrl()` 的单元测试。
///
/// 验证：
/// 1. `catalog_url` 默认值 = GitHub 仓库地址（配置注册表 + 未配置时的 read）；
/// 2. GitHub 仓库地址 → 解析 releases `[0]` 的 `assets[0].browser_download_url`
///    （注入 releasesOverride 替身，不发真实 HTTP）；
/// 3. 直接 `.db` 地址原样透传（不触及 releases）；
/// 4. 配置了代理时按全局代理安全前缀（幂等，不二次拼接）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/core.dart' show resetProxyForTest, updateProxy;
import 'package:gstore/page/home/tab/discovery/gstore_catalog_update.dart';

const String _repoUrl = 'https://github.com/sunO2/GStore-Repositorys';
const String _assetUrl =
    'https://github.com/sunO2/GStore-Repositorys/releases/download/v1.2.3/apps.db';

Future<void> _configureUrl(String url) async {
  final result = await ConfigService.instance.set(ConfigKeys.catalogUrl, url);
  expect(result.success, isTrue, reason: 'catalog_url must be writable');
}

String _releasesJson({String assetUrl = _assetUrl}) => jsonEncode([
      {
        'name': '1.2.3',
        'assets': [
          {
            'name': 'apps.db',
            'browser_download_url': assetUrl,
            'size': 1024,
          },
        ],
      },
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(
      storages: <ConfigStorage>[MemoryConfigStorage(), MemoryConfigStorage()],
    );
    ConfigRegistry.registerAll(ConfigService.instance);
    resetProxyForTest();
    // 测试默认禁用代理（否则 getProxy() 回退到 defaultProxy，URL 会被加前缀）。
    await updateProxy('');
  });

  tearDown(() {
    CatalogUrlSetting.releasesOverride = null;
    resetProxyForTest();
  });

  test('catalog_url defaults to the GStore-Repositorys GitHub repo', () async {
    final entry = ConfigService.instance.entry(ConfigKeys.catalogUrl);
    expect(entry?.defaultValue, _repoUrl,
        reason: 'the registry default must point at the catalog repo');
    expect(await CatalogUrlSetting.read(), _repoUrl,
        reason: 'an unset catalog_url must read back as the default repo URL');
  });

  test('a GitHub repo URL resolves to assets[0].browser_download_url', () async {
    await _configureUrl(_repoUrl);
    var calls = 0;
    String? seenOwner;
    String? seenRepo;
    CatalogUrlSetting.releasesOverride = (owner, repo) async {
      calls++;
      seenOwner = owner;
      seenRepo = repo;
      return _releasesJson();
    };

    final resolved = await CatalogUrlSetting.resolveDownloadUrl();

    expect(calls, 1, reason: 'the releases seam must be used exactly once');
    expect(seenOwner, 'sunO2');
    expect(seenRepo, 'GStore-Repositorys');
    expect(resolved, _assetUrl,
        reason: 'the first asset browser_download_url must be returned');
  });

  test('a repo URL with a trailing slash and .git is still parsed', () async {
    await _configureUrl('https://github.com/sunO2/GStore-Repositorys.git/');
    CatalogUrlSetting.releasesOverride =
        (owner, repo) async => _releasesJson();

    expect(await CatalogUrlSetting.resolveDownloadUrl(), _assetUrl);
  });

  test('a direct .db URL passes through unchanged', () async {
    await _configureUrl('https://example.com/catalog.db');
    CatalogUrlSetting.releasesOverride = (owner, repo) async =>
        throw StateError('releases must not be called for a direct URL');

    expect(await CatalogUrlSetting.resolveDownloadUrl(),
        'https://example.com/catalog.db');
  });

  test('a configured proxy is prefixed safely (no double prefix)', () async {
    await _configureUrl(_repoUrl);
    await updateProxy('https://gh-proxy.org/');
    CatalogUrlSetting.releasesOverride =
        (owner, repo) async => _releasesJson();

    final resolved = await CatalogUrlSetting.resolveDownloadUrl();

    expect(resolved, 'https://gh-proxy.org/$_assetUrl');
  });

  test('an unresolvable release returns null instead of throwing', () async {
    await _configureUrl(_repoUrl);
    CatalogUrlSetting.releasesOverride =
        (owner, repo) async => jsonEncode([
              {'name': '1.2.3', 'assets': <dynamic>[]},
            ]);

    expect(await CatalogUrlSetting.resolveDownloadUrl(), isNull);
  });
}
