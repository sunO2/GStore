// 随包 v2 清单兜底 / 哈希固定 / ABI 下限 / 代理作用域测试。
//
// 全程进程内 loopback `HttpServer` + 注入 seam（clock/supportDirProvider/
// abiProvider/bundledManifestLoader/proxyProvider）；无真实网络、无 Flutter
// asset bundle（随包清单始终以闭包注入 JSON 字符串）。
// `file_names` 与 lib/core/rust 既有约定一致。
// ignore_for_file: file_names

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleManifestClient.dart';
import 'package:path/path.dart' as p;

/// 进程内 fake HTTP server：统计命中次数 / 完整请求 URI / 路径。
class _FakeServer {
  _FakeServer(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;

  int hits = 0;
  final List<Uri> uris = [];
  final List<String> paths = [];

  FutureOr<void> Function(HttpRequest request)? handler;

  int get port => _server.port;

  Future<void> _handle(HttpRequest request) async {
    hits++;
    uris.add(request.uri);
    paths.add(request.uri.path);
    try {
      final h = handler;
      if (h != null) {
        await h(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (_) {
      // 客户端提前断开时忽略写失败。
    }
  }

  int countPath(String path) => paths.where((x) => x == path).length;

  Future<void> close() => _server.close(force: true);
}

/// 记录 `getUrl` 目标、仅放行 loopback 的客户端（非 loopback 立即抛
/// [SocketException]，避免测试触碰真实网络）。
class _LoopbackOnlyClient implements HttpClient {
  _LoopbackOnlyClient(this.inner, this.requested);

  final HttpClient inner;
  final List<Uri> requested;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requested.add(url);
    if (url.host == '127.0.0.1' || url.host == 'localhost') {
      return inner.getUrl(url);
    }
    throw const SocketException('blocked non-loopback in hermetic test');
  }

  @override
  void close({bool force = false}) => inner.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 构造单模块 `qr` / 单 ABI `arm64-v8a` 的 v2 清单 JSON。
String _v2Manifest({
  required String version,
  required String asset,
  required String sha256,
  required int size,
  String? minHostAbi,
}) {
  return jsonEncode({
    'version': 2,
    'modules': {
      'qr': {
        'version': version,
        if (minHostAbi != null) 'min_host_abi': minHostAbi,
        'abi': {
          'arm64-v8a': {'asset': asset, 'sha256': sha256, 'size': size},
        },
      },
    },
  });
}

/// 构造 `releases/latest` 元数据；`modulesUrl` 为清单资产的完整
/// `browser_download_url`（便于注入非本机 host）。
String _releaseJson({
  required String modulesUrl,
  List<Map<String, Object?>> extraAssets = const [],
}) {
  return jsonEncode({
    'tag_name': 'v1.0.0',
    'prerelease': false,
    'assets': <Map<String, Object?>>[
      <String, Object?>{
        'name': 'modules.json',
        'browser_download_url': modulesUrl,
        'size': 128,
      },
      ...extraAssets,
    ],
  });
}

/// 捕获 `debugPrint` 输出，测试结束自动还原。
List<String> _captureDebugPrint() {
  final logs = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) logs.add(message);
  };
  addTearDown(() => debugPrint = original);
  return logs;
}

void main() {
  late _FakeServer server;
  late Directory tmpRoot;
  late List<Directory> extraDirs;
  late Uri releasesUrl;

  String origin() => 'http://127.0.0.1:${server.port}';

  Future<Directory> newTempDir() async {
    final dir = await Directory.systemTemp.createTemp('gstore_bundled_test_');
    extraDirs.add(dir);
    return dir;
  }

  setUp(() async {
    server = _FakeServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tmpRoot = await Directory.systemTemp.createTemp('gstore_bundled_root_');
    extraDirs = [];
    releasesUrl = Uri.parse('${origin()}/releases/latest');
  });

  tearDown(() async {
    await server.close();
    for (final dir in [tmpRoot, ...extraDirs]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  ModuleManifestClient buildClient({
    Directory? supportDir,
    Uri? releasesUrlOverride,
    String? downloadsBaseUrl,
    String abi = 'arm64-v8a',
    BundledManifestLoader? bundledManifestLoader,
    String Function()? proxyProvider,
    HttpClient Function()? clientFactory,
    DateTime Function()? clock,
  }) {
    return ModuleManifestClient(
      releasesUrl: releasesUrlOverride ?? releasesUrl,
      downloadsBaseUrl: downloadsBaseUrl,
      supportDirProvider: () async => supportDir ?? tmpRoot,
      abiProvider: () async => abi,
      clock: clock,
      clientFactory: clientFactory,
      bundledManifestLoader: bundledManifestLoader,
      proxyProvider: proxyProvider,
      timeout: const Duration(seconds: 5),
    );
  }

  /// 离线（端口 1 连接必被拒绝）+ 无缓存的 releases 入口。
  Uri offlineReleases() => Uri.parse('http://127.0.0.1:1/releases/latest');

  File cacheManifestFile(Directory dir) =>
      File(p.join(dir.path, 'gstore_modules', '_cache', 'modules.json'));

  // ---------------------------------------------------------------------------
  // (a)–(e) 解析链：网络 → 已校验缓存 → 随包 v2 → null
  // ---------------------------------------------------------------------------

  group('随包 v2 清单兜底（解析链）', () {
    const asset = 'libgstore_mod_qr_0.1.0-arm64-v8a.so';
    final sha = 'c1' * 32; // 64 位十六进制

    // (a) 网络不可用 + 无缓存 + 注入随包 loader → 用随包清单。
    test('网络不可用且无缓存：随包 v2 清单兜底生效且不写磁盘缓存', () async {
      final logs = _captureDebugPrint();
      final client = buildClient(
        releasesUrlOverride: offlineReleases(),
        bundledManifestLoader: (_) async => _v2Manifest(
          version: '0.1.0',
          asset: asset,
          sha256: sha,
          size: 42,
        ),
      );

      final loaded = await client.load();
      expect(loaded, isNotNull);
      expect(loaded!.entry('qr'), isNotNull);
      expect(loaded.entry('qr')!.version, '0.1.0');
      expect(loaded.entry('qr')!.forAbi('arm64-v8a')!.asset, asset);
      expect(loaded.entry('qr')!.forAbi('arm64-v8a')!.sha256, sha);
      expect(
        logs.any((l) => l.contains('随包 v2 清单兜底')),
        isTrue,
        reason: '兜底应有可观测日志',
      );
      expect(
        cacheManifestFile(tmpRoot).existsSync(),
        isFalse,
        reason: '随包清单不是网络结果，绝不写入磁盘缓存',
      );
    });

    // (b) 未注入随包 loader → 兜底关闭。
    test('未注入随包 loader：兜底关闭，load() 返回 null', () async {
      final client = buildClient(
        releasesUrlOverride: offlineReleases(),
        bundledManifestLoader: null,
      );

      expect(await client.load(), isNull);
      expect(cacheManifestFile(tmpRoot).existsSync(), isFalse);
    });

    // (c) 网络可用 → 网络清单胜出，随包清单不被采用。
    test('网络可用：网络清单胜出，随包清单未被采用', () async {
      const networkAsset = 'libgstore_mod_qr_1.2.3-arm64-v8a.so';
      final networkSha = 'a' * 64;
      var bundledCalls = 0;

      server.handler = (request) async {
        switch (request.uri.path) {
          case '/releases/latest':
            request.response.statusCode = HttpStatus.ok;
            request.response.write(_releaseJson(
              modulesUrl: '${origin()}/downloads/modules.json',
              extraAssets: [
                {
                  'name': networkAsset,
                  'browser_download_url': '${origin()}/dl/$networkAsset',
                  'size': 111,
                },
              ],
            ));
            await request.response.close();
          case '/downloads/modules.json':
            request.response.statusCode = HttpStatus.ok;
            request.response.write(_v2Manifest(
              version: '1.2.3',
              asset: networkAsset,
              sha256: networkSha,
              size: 111,
            ));
            await request.response.close();
          default:
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
        }
      };

      final client = buildClient(
        bundledManifestLoader: (_) async {
          bundledCalls++;
          return _v2Manifest(
            version: '9.9.9',
            asset: 'libgstore_mod_qr_9.9.9-arm64-v8a.so',
            sha256: 'b' * 64,
            size: 999,
          );
        },
      );

      final loaded = await client.load();
      expect(loaded, isNotNull);
      expect(loaded!.entry('qr')!.version, '1.2.3');
      expect(loaded.entry('qr')!.version, isNot('9.9.9'),
          reason: '网络清单必须胜出');
      expect(bundledCalls, 0, reason: '网络成功时无需读取随包清单');
    });

    // (d) 随包为 legacy v1 / 非法 JSON → 吞掉 ModuleManifestFormatException → null。
    test('随包 loader 返回 legacy v1 / 非法 JSON：吞掉格式异常返回 null',
        () async {
      final client = buildClient(
        releasesUrlOverride: offlineReleases(),
        bundledManifestLoader: (_) async => jsonEncode({
          'version': 2,
          'modules': {
            'qr': {
              'version': '1.0.0',
              'file_name': 'libgstore_mod_qr.so',
              'abi': {
                'arm64-v8a': {'asset': asset, 'sha256': sha, 'size': 1},
              },
            },
          },
        }),
      );
      expect(await client.load(), isNull, reason: 'legacy file_name → 吞掉 → null');

      final malformed = buildClient(
        supportDir: await newTempDir(),
        releasesUrlOverride: offlineReleases(),
        bundledManifestLoader: (_) async => '{not valid json',
      );
      expect(await malformed.load(), isNull, reason: '非法 JSON → 吞掉 → null');
    });

    // (e) 随包 loader 抛任意异常 → 吞掉 → null。
    test('随包 loader 抛异常：吞掉返回 null', () async {
      final client = buildClient(
        releasesUrlOverride: offlineReleases(),
        bundledManifestLoader: (_) async => throw StateError('bundled boom'),
      );

      expect(await client.load(), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // (f)–(h) 哈希固定 / ABI 下限
  // ---------------------------------------------------------------------------

  group('随包清单哈希固定与 ABI 下限', () {
    final netSha = 'a' * 64;
    final bundleSha = 'b' * 64;

    /// 让 releases/清单体都命中本机 server 的公共 handler。
    void serveNetwork({
      required String networkManifest,
      required String abiAsset,
    }) {
      server.handler = (request) async {
        switch (request.uri.path) {
          case '/releases/latest':
            request.response.statusCode = HttpStatus.ok;
            request.response.write(_releaseJson(
              modulesUrl: '${origin()}/downloads/modules.json',
              extraAssets: [
                {
                  'name': abiAsset,
                  'browser_download_url': '${origin()}/dl/$abiAsset',
                  'size': 1,
                },
              ],
            ));
            await request.response.close();
          case '/downloads/modules.json':
            request.response.statusCode = HttpStatus.ok;
            request.response.write(networkManifest);
            await request.response.close();
          default:
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
        }
      };
    }

    // (f) 同名资产 ⇒ 采用随包 sha256/size。
    test('同名 ABI 资产：sha256/size 采用随包固定', () async {
      const shared = 'libgstore_mod_qr_0.1.0-arm64-v8a.so';
      serveNetwork(
        networkManifest: _v2Manifest(
          version: '0.1.0',
          asset: shared,
          sha256: netSha,
          size: 100,
        ),
        abiAsset: shared,
      );

      final client = buildClient(
        bundledManifestLoader: (_) async => _v2Manifest(
          version: '0.1.0',
          asset: shared,
          sha256: bundleSha,
          size: 200,
        ),
      );

      final loc = await client.locateModuleAsset('qr');
      expect(loc, isNotNull);
      expect(loc!.asset, shared);
      expect(loc.sha256, bundleSha, reason: '同名资产 → 随包哈希固定');
      expect(loc.size, 200, reason: '同名资产 → 随包 size');
      expect(loc.version, '0.1.0');
    });

    // (g) 资产名不同（版本内嵌） ⇒ 不固定，沿用所选清单哈希。
    test('资产名因版本不同：不固定，采用所选清单哈希', () async {
      const netAsset = 'libgstore_mod_qr_0.1.1-arm64-v8a.so';
      const bundledAsset = 'libgstore_mod_qr_0.1.0-arm64-v8a.so';
      serveNetwork(
        networkManifest: _v2Manifest(
          version: '0.1.1',
          asset: netAsset,
          sha256: netSha,
          size: 100,
        ),
        abiAsset: netAsset,
      );

      final client = buildClient(
        bundledManifestLoader: (_) async => _v2Manifest(
          version: '0.1.0',
          asset: bundledAsset,
          sha256: bundleSha,
          size: 200,
        ),
      );

      final loc = await client.locateModuleAsset('qr');
      expect(loc, isNotNull);
      expect(loc!.asset, netAsset, reason: '资产名不同 ⇒ 不固定');
      expect(loc.sha256, netSha);
      expect(loc.size, 100);
      expect(loc.version, '0.1.1');
    });

    // (h) 候选 min_host_abi 高于随包下限 ⇒ null。
    test('min_host_abi 高于随包下限：locateModuleAsset 返回 null', () async {
      const shared = 'libgstore_mod_qr_0.1.0-arm64-v8a.so';
      serveNetwork(
        networkManifest: _v2Manifest(
          version: '0.1.0',
          asset: shared,
          sha256: netSha,
          size: 100,
          minHostAbi: '3',
        ),
        abiAsset: shared,
      );

      final client = buildClient(
        bundledManifestLoader: (_) async => _v2Manifest(
          version: '0.1.0',
          asset: shared,
          sha256: bundleSha,
          size: 200,
          minHostAbi: '2',
        ),
      );

      expect(await client.locateModuleAsset('qr'), isNull);
    });

    // (h) 等于/低于下限或缺失 ⇒ 允许。
    test('min_host_abi 等于/低于随包下限或缺失：允许', () async {
      const shared = 'libgstore_mod_qr_0.1.0-arm64-v8a.so';

      Future<ModuleAssetLocation?> locateWith(String? networkMin) async {
        serveNetwork(
          networkManifest: _v2Manifest(
            version: '0.1.0',
            asset: shared,
            sha256: netSha,
            size: 100,
            minHostAbi: networkMin,
          ),
          abiAsset: shared,
        );
        final client = buildClient(
          supportDir: await newTempDir(),
          bundledManifestLoader: (_) async => _v2Manifest(
            version: '0.1.0',
            asset: shared,
            sha256: bundleSha,
            size: 200,
            minHostAbi: '2',
          ),
        );
        return client.locateModuleAsset('qr');
      }

      expect(await locateWith('2'), isNotNull, reason: '等于下限 ⇒ 允许');
      expect(await locateWith('1'), isNotNull, reason: '低于下限 ⇒ 允许');
      expect(await locateWith(null), isNotNull, reason: '缺失 ⇒ 不设下限');
    });
  });

  // ---------------------------------------------------------------------------
  // (i) 代理作用域
  // ---------------------------------------------------------------------------

  group('代理仅作用于清单正文 GET', () {
    const soAsset = 'libgstore_mod_qr_1.2.3-arm64-v8a.so';
    const githubModulesUrl =
        'https://github.com/sunO2/GStore/releases/latest/download/modules.json';
    const githubSoUrl =
        'https://github.com/sunO2/GStore/releases/download/v1.0.0/$soAsset';

    // (i)(1)(2) 注入代理 ⇒ 正文经代理取回，返回 URL 保持原始 github host。
    test('注入 proxyProvider：正文经代理，返回 URL 仍是原始 github URL', () async {
      final proxyPrefix = '${origin()}/gh/';

      server.handler = (request) async {
        final target = request.uri.path;
        if (target == '/releases/latest') {
          request.response.statusCode = HttpStatus.ok;
          request.response.write(_releaseJson(
            modulesUrl: githubModulesUrl,
            extraAssets: [
              {
                'name': soAsset,
                'browser_download_url': githubSoUrl,
                'size': 2048,
              },
            ],
          ));
        } else if (target.contains('https://github.com/') &&
            target.endsWith('modules.json')) {
          request.response.statusCode = HttpStatus.ok;
          request.response.write(_v2Manifest(
            version: '1.2.3',
            asset: soAsset,
            sha256: 'a' * 64,
            size: 2048,
          ));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      };

      final client = buildClient(proxyProvider: () => proxyPrefix);

      final loc = await client.locateModuleAsset('qr');

      expect(
        server.uris.any((u) =>
            u.path.contains('https://github.com/') &&
            u.path.endsWith('modules.json')),
        isTrue,
        reason: '清单正文必须以代理形态（前缀 + 原始 github URL）请求',
      );
      expect(
        server.countPath('/releases/latest'),
        1,
        reason: 'Release 元数据始终直连，不经代理',
      );
      expect(
        server.uris.any((u) => u.path.contains('/gh/releases/latest')),
        isFalse,
        reason: 'api 入口绝不经代理',
      );

      expect(loc, isNotNull);
      expect(loc!.url, githubSoUrl,
          reason: '返回 URL 必须是代理前的原始 github URL');
      expect(loc.url.startsWith(proxyPrefix), isFalse);
      expect(loc.url, isNot(contains(proxyPrefix)));
    });

    // (i)(3) 未注入 proxyProvider ⇒ 直连原始 URL（无前缀）。
    test('未注入 proxyProvider：正文直连原始 github URL', () async {
      final requested = <Uri>[];
      server.handler = (request) async {
        if (request.uri.path == '/releases/latest') {
          request.response.statusCode = HttpStatus.ok;
          request.response.write(_releaseJson(modulesUrl: githubModulesUrl));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      };

      final client = buildClient(
        clientFactory: () => _LoopbackOnlyClient(HttpClient(), requested),
      );

      // 正文 GET 指向非 loopback（github.com）→ 被测试客户端拦截并抛
      // SocketException；无随包 loader ⇒ 回退 null（不抛异常）。
      expect(await client.load(), isNull);
      expect(
        requested.any((u) => u.toString() == githubModulesUrl),
        isTrue,
        reason: '未注入代理时应直连原始 github URL',
      );
      expect(requested.any((u) => u.host != '127.0.0.1'), isTrue);
      expect(
        requested.any((u) => u.path.contains('/gh/')),
        isFalse,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // (j) 任何注入失败都不抛异常
  // ---------------------------------------------------------------------------

  test('load/locateModuleAsset 在任何注入失败下都不抛异常', () async {
    final client = ModuleManifestClient(
      releasesUrl: offlineReleases(),
      supportDirProvider: () async => throw StateError('no support dir'),
      abiProvider: () async => throw StateError('no abi'),
      bundledManifestLoader: (_) async => throw StateError('bundled boom'),
      timeout: const Duration(seconds: 2),
    );

    expect(await client.load(), isNull);
    expect(await client.locateModuleAsset('qr'), isNull);
    expect(await client.moduleAssetUrl('qr'), isNull);
  });
}
