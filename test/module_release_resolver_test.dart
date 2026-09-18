// Todo 8：清单信任锚 + Release 解析器测试。
// 进程内 fake HTTP server（loopback）+ 可注入 ABI/时钟/客户端，不访问真实网络。
// `file_names` 与 lib/core/rust 既有约定一致。
// ignore_for_file: file_names

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleManifestClient.dart';

final String _sha256 = 'a' * 64;
final String _itHash = 'b' * 64;

/// 进程内 fake HTTP server：统计命中次数/路径/host/If-None-Match。
class _FakeServer {
  _FakeServer(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;

  int hits = 0;
  final List<String> paths = [];
  final List<String> hosts = [];
  final List<String?> ifNoneMatch = [];

  FutureOr<void> Function(HttpRequest request)? handler;

  int get port => _server.port;

  Future<void> _handle(HttpRequest request) async {
    hits++;
    paths.add(request.uri.path);
    hosts.add(request.headers.host ?? '');
    ifNoneMatch.add(request.headers.value(HttpHeaders.ifNoneMatchHeader));
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

/// 记录是否被施加了代理 / 关闭了证书校验的 fake 客户端（委托真实客户端）。
class _RecordingHttpClient implements HttpClient {
  _RecordingHttpClient(this.inner);

  final HttpClient inner;
  bool findProxySet = false;
  bool badCertificateCallbackSet = false;

  @override
  set findProxy(String Function(Uri uri)? f) {
    findProxySet = true;
    inner.findProxy = f;
  }

  @override
  set badCertificateCallback(
      bool Function(X509Certificate cert, String host, int port)? callback) {
    badCertificateCallbackSet = true;
    inner.badCertificateCallback = callback;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => inner.getUrl(url);

  @override
  void close({bool force = false}) => inner.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

String _releaseJson({
  required String origin,
  bool prerelease = false,
  bool includeModules = true,
  bool includeItTools = true,
  String modulesPath = '/downloads/modules.json',
  String itToolsPath = '/downloads/it_tools.json',
  List<Map<String, Object?>> extraAssets = const [],
}) {
  final assets = <Map<String, Object?>>[
    if (includeModules)
      <String, Object?>{
        'name': 'modules.json',
        'browser_download_url': '$origin$modulesPath',
        'size': 128,
      },
    if (includeItTools)
      <String, Object?>{
        'name': 'it_tools.json',
        'browser_download_url': '$origin$itToolsPath',
        'size': 64,
      },
    ...extraAssets,
  ];
  return jsonEncode({
    'tag_name': 'v1.0.0',
    'prerelease': prerelease,
    'assets': assets,
  });
}

String _modulesJson({
  String version = '1.2.3',
  Map<String, String> abiAssets = const {
    'arm64-v8a': 'libgstore_mod_qr_1.2.3-arm64-v8a.so',
  },
  int size = 2048,
}) {
  final abi = <String, Object?>{};
  abiAssets.forEach((name, asset) {
    abi[name] = {'asset': asset, 'sha256': _sha256, 'size': size};
  });
  return jsonEncode({
    'version': 2,
    'modules': {
      'qr': {'version': version, 'abi': abi},
    },
  });
}

void main() {
  late _FakeServer server;
  late Directory tmpRoot;
  late Uri releasesUrl;

  String origin() => 'http://127.0.0.1:${server.port}';

  setUp(() async {
    server = _FakeServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tmpRoot = await Directory.systemTemp.createTemp('gstore_manifest_test_');
    releasesUrl = Uri.parse('${origin()}/releases/latest');
  });

  tearDown(() async {
    await server.close();
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  ModuleManifestClient buildClient({
    DateTime Function()? clock,
    String abi = 'arm64-v8a',
    HttpClient Function()? clientFactory,
  }) {
    return ModuleManifestClient(
      releasesUrl: releasesUrl,
      supportDirProvider: () async => tmpRoot,
      abiProvider: () async => abi,
      clock: clock,
      clientFactory: clientFactory,
      timeout: const Duration(seconds: 5),
    );
  }

  // 1. fixture 200 → 从 Release assets 取当前 ABI 的 browser_download_url。
  test('200 fixture resolves the module browser_download_url for the ABI',
      () async {
    const soAsset = 'libgstore_mod_qr_1.2.3-arm64-v8a.so';
    final soUrl = '${origin()}/releases/download/v1.0.0/$soAsset';

    server.handler = (request) async {
      switch (request.uri.path) {
        case '/releases/latest':
          request.response.statusCode = HttpStatus.ok;
          request.response.write(_releaseJson(
            origin: origin(),
            extraAssets: [
              {
                'name': soAsset,
                'browser_download_url': soUrl,
                'size': 2048,
              },
            ],
          ));
          await request.response.close();
        case '/downloads/modules.json':
          request.response.statusCode = HttpStatus.ok;
          request.response.write(_modulesJson());
          await request.response.close();
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    };

    final location = await buildClient().locateModuleAsset('qr');
    expect(location, isNotNull);
    expect(location!.url, soUrl,
        reason: '必须用 Release 的 browser_download_url，而非拼接 base/abi/file');
    expect(location.url, isNot(contains('/arm64-v8a/')));
    expect(location.asset, soAsset);
    expect(location.sha256, _sha256);
    expect(location.size, 2048);
    expect(location.version, '1.2.3');
    expect(location.abi, 'arm64-v8a');
    expect(
      server.paths,
      isNot(contains('/releases/download/v1.0.0/$soAsset')),
      reason: '解析器只提供 URL，不得自行下载 .so',
    );
  });

  // 1b. 不同 ABI 命中各自的 Release 资产 URL（真实设备 ABI 解析）。
  test('resolves the asset matching the injected ABI', () async {
    const arm64 = 'libgstore_mod_qr_1.2.3-arm64-v8a.so';
    const v7a = 'libgstore_mod_qr_1.2.3-armeabi-v7a.so';
    final arm64Url = '${origin()}/dl/$arm64';
    final v7aUrl = '${origin()}/dl/$v7a';

    server.handler = (request) async {
      if (request.uri.path == '/releases/latest') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_releaseJson(
          origin: origin(),
          extraAssets: [
            {'name': arm64, 'browser_download_url': arm64Url, 'size': 1},
            {'name': v7a, 'browser_download_url': v7aUrl, 'size': 1},
          ],
        ));
      } else if (request.uri.path == '/downloads/modules.json') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_modulesJson(abiAssets: {
          'arm64-v8a': arm64,
          'armeabi-v7a': v7a,
        }));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    };

    final v7aLocation = await buildClient(abi: 'armeabi-v7a')
        .locateModuleAsset('qr');
    expect(v7aLocation, isNotNull);
    expect(v7aLocation!.url, v7aUrl);
    expect(v7aLocation.abi, 'armeabi-v7a');
  });

  // 2. 304 → 复用缓存清单，不再下载 body。
  test('304 reuses the cached manifest without re-downloading the body',
      () async {
    const etag = 'W/"fixture-v1"';
    var bodiesServed = 0;

    server.handler = (request) async {
      switch (request.uri.path) {
        case '/releases/latest':
          request.response.statusCode = HttpStatus.ok;
          request.response.write(_releaseJson(origin: origin()));
          await request.response.close();
        case '/downloads/modules.json':
          if (request.headers.value(HttpHeaders.ifNoneMatchHeader) == etag) {
            request.response.statusCode = HttpStatus.notModified;
            await request.response.close();
          } else {
            bodiesServed++;
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.set(HttpHeaders.etagHeader, etag);
            request.response.write(_modulesJson());
            await request.response.close();
          }
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    };

    final client = buildClient();
    final first = await client.load();
    expect(first, isNotNull);
    expect(bodiesServed, 1);

    final second = await client.load(forceRefresh: true);
    expect(second, isNotNull);
    expect(second!.entry('qr')!.version, '1.2.3');
    expect(bodiesServed, 1, reason: '304 不得重新下载 body');
    expect(server.countPath('/downloads/modules.json'), 2);
    expect(server.ifNoneMatch.where((v) => v == etag).length, 1);
  });

  // 3. 403 无缓存 → null，不抛异常。
  test('403 with no cache returns null and never throws', () async {
    server.handler = (request) async {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
    };

    final client = buildClient();
    expect(await client.load(), isNull);
    expect(await client.loadItToolsManifest(), isNull);
    expect(await client.moduleAssetUrl('qr'), isNull);
  });

  // 3b. 403 有缓存 → 回退已校验缓存。
  test('403 after a valid fetch falls back to the cached manifest', () async {
    var forbidden = false;
    var now = DateTime(2026, 1, 1, 8);
    server.handler = (request) async {
      if (forbidden) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      if (request.uri.path == '/releases/latest') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_releaseJson(origin: origin()));
      } else if (request.uri.path == '/downloads/modules.json') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_modulesJson());
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    };

    final client = buildClient(clock: () => now);
    expect(await client.load(), isNotNull);

    forbidden = true;
    now = now.add(const Duration(hours: 48));
    final cached = await client.load();
    expect(cached, isNotNull);
    expect(cached!.entry('qr')!.version, '1.2.3');
  });

  // 4. 清单请求无代理、默认证书校验：断言注入客户端从未被设置代理/证书回调。
  test('manifest request is unproxied and uses default cert validation',
      () async {
    server.handler = (request) async {
      if (request.uri.path == '/releases/latest') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_releaseJson(origin: origin()));
      } else if (request.uri.path == '/downloads/modules.json') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_modulesJson());
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    };

    final created = <_RecordingHttpClient>[];
    final client = buildClient(clientFactory: () {
      final recording = _RecordingHttpClient(HttpClient());
      created.add(recording);
      return recording;
    });

    final manifest = await client.load();
    expect(manifest, isNotNull);
    expect(created, isNotEmpty);

    for (final c in created) {
      expect(c.findProxySet, isFalse, reason: '不得施加任何代理（默认 DIRECT）');
      expect(c.badCertificateCallbackSet, isFalse,
          reason: '不得关闭证书校验（默认校验，回调保持 null）');
    }
    expect(server.hosts, everyElement(startsWith('127.0.0.1')),
        reason: '直连已解析的原始 host，未经代理');
  });

  // 5. 清单资产 404 → 失效并恰好重解析一次。
  test('404 manifest asset invalidates and re-resolves exactly once', () async {
    var releasesHits = 0;
    server.handler = (request) async {
      switch (request.uri.path) {
        case '/releases/latest':
          releasesHits++;
          request.response.statusCode = HttpStatus.ok;
          request.response.write(_releaseJson(
            origin: origin(),
            modulesPath:
                releasesHits == 1 ? '/v1/modules.json' : '/v2/modules.json',
          ));
          await request.response.close();
        case '/v1/modules.json':
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        case '/v2/modules.json':
          request.response.statusCode = HttpStatus.ok;
          request.response.write(_modulesJson());
          await request.response.close();
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    };

    final manifest = await buildClient().load();
    expect(manifest, isNotNull);
    expect(releasesHits, 2, reason: '恰好重解析一次');
    expect(server.countPath('/v1/modules.json'), 1);
    expect(server.countPath('/v2/modules.json'), 1);
  });

  // 5b. 重解析后仍 404 → null，且不再无限重试。
  test('re-resolved asset also 404 returns null without further retries',
      () async {
    var releasesHits = 0;
    server.handler = (request) async {
      if (request.uri.path == '/releases/latest') {
        releasesHits++;
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_releaseJson(
          origin: origin(),
          modulesPath:
              releasesHits == 1 ? '/v1/modules.json' : '/v2/modules.json',
        ));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    };

    expect(await buildClient().load(), isNull);
    expect(releasesHits, 2, reason: '只允许一次重解析');
  });

  // 6. TTL：24h 内零网络；过期后重新校验。
  test('TTL expires triggers refetch while fresh cache stays offline', () async {
    var now = DateTime(2026, 1, 1, 8);
    server.handler = (request) async {
      if (request.uri.path == '/releases/latest') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_releaseJson(origin: origin()));
      } else if (request.uri.path == '/downloads/modules.json') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_modulesJson());
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    };

    final client = buildClient(clock: () => now);
    expect(await client.load(), isNotNull);
    expect(server.countPath('/releases/latest'), 1);

    now = now.add(const Duration(hours: 1));
    expect(await client.load(), isNotNull);
    expect(server.countPath('/releases/latest'), 1, reason: 'TTL 内零网络');

    now = now.add(const Duration(hours: 24)); // 累计 25h
    expect(await client.load(), isNotNull);
    expect(server.countPath('/releases/latest'), 2, reason: '超过 24h 重新校验');
  });

  // 7. it_tools.json 解析为 {contentHash, asset, size}。
  test('it_tools.json parses into contentHash/asset/size', () async {
    server.handler = (request) async {
      switch (request.uri.path) {
        case '/releases/latest':
          request.response.statusCode = HttpStatus.ok;
          request.response.write(_releaseJson(origin: origin()));
          await request.response.close();
        case '/downloads/it_tools.json':
          request.response.statusCode = HttpStatus.ok;
          request.response.write(jsonEncode({
            'contentHash': _itHash,
            'asset': 'it-tools.zip',
            'size': 98765,
          }));
          await request.response.close();
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    };

    final it = await buildClient().loadItToolsManifest();
    expect(it, isNotNull);
    expect(it!.contentHash, _itHash);
    expect(it.asset, 'it-tools.zip');
    expect(it.size, 98765);
  });

  // 7b. it_tools.json 畸形 → null，不崩溃。
  test('malformed it_tools.json returns null without crashing', () async {
    server.handler = (request) async {
      if (request.uri.path == '/releases/latest') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_releaseJson(origin: origin()));
      } else if (request.uri.path == '/downloads/it_tools.json') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('{"contentHash": 123, "asset": "", "size": "x"}');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    };

    expect(await buildClient().loadItToolsManifest(), isNull);
  });

  // 8. 畸形/缺字段输入：返回 null，绝不崩溃。
  test('malformed release and manifest inputs return null safely', () async {
    // 8a. Release 缺少 modules.json 资产。
    server.handler = (request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.write(_releaseJson(origin: origin(), includeModules: false));
      await request.response.close();
    };
    expect(await buildClient().load(), isNull,
        reason: '缺 modules.json 资产 → null');

    // 8b. prerelease → 忽略。
    server.handler = (request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.write(_releaseJson(origin: origin(), prerelease: true));
      await request.response.close();
    };
    expect(await buildClient().load(), isNull, reason: 'prerelease 必须忽略');

    // 8c. modules.json 非法 JSON。
    server.handler = (request) async {
      if (request.uri.path == '/releases/latest') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_releaseJson(origin: origin()));
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('{not valid json');
      }
      await request.response.close();
    };
    expect(await buildClient().load(), isNull, reason: '非法 JSON → null');

    // 8d. 旧 schema（file_name）显式拒绝 → null（不崩溃）。
    server.handler = (request) async {
      if (request.uri.path == '/releases/latest') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_releaseJson(origin: origin()));
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(jsonEncode({'version': 1, 'file_name': 'x.so'}));
      }
      await request.response.close();
    };
    expect(await buildClient().load(), isNull, reason: '旧 schema → 降级 null');

    // 8e. 清单中该 ABI 缺失 → 无 URL。
    server.handler = (request) async {
      if (request.uri.path == '/releases/latest') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_releaseJson(origin: origin()));
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(_modulesJson(abiAssets: {
          'x86_64': 'libgstore_mod_qr_1.2.3-x86_64.so',
        }));
      }
      await request.response.close();
    };
    expect(await buildClient(abi: 'armeabi-v7a').locateModuleAsset('qr'),
        isNull, reason: '缺 ABI → null');
  });

  // 9. 结构性守卫：信任锚源码不得出现代理/关闭证书校验的入口。
  test('trust anchor source has no proxy or cert-bypass references', () {
    final source =
        File('lib/core/rust/ModuleManifestClient.dart').readAsStringSync();
    const forbidden = [
      'getProxy',
      'badCertificateCallback',
      'findProxy',
      'GithubRestClient',
      'DioClient',
      'allowBadCertificate',
    ];
    for (final token in forbidden) {
      expect(source.contains(token), isFalse,
          reason: '清单信任锚不得引用 $token');
    }
  });
}
