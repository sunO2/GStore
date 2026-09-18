// Todo 12：ItToolsService 远端更新（内容哈希 + 原子替换 + 回退）测试。
//
// 全部使用进程内 loopback fake HTTP server + 注入的假下载器/假资产，
// **不访问任何外部网络**。zip fixture 在测试内用 `archive` 现场构造。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:gstore/core/rust/ModuleDownloader.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:gstore/core/rust/ModuleManifestClient.dart';
import 'package:gstore/core/service/it_tools_service.dart';

/// 测试内构造 zip 字节
Uint8List buildZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final data = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// 进程内 fake HTTP server：可逐用例替换 handler，记录命中路径/host。
class _FakeServer {
  _FakeServer(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;

  int hits = 0;
  final List<String> paths = [];
  final List<String> hosts = [];

  Future<void> Function(HttpRequest request)? handler;

  int get port => _server.port;

  Future<void> _handle(HttpRequest request) async {
    hits++;
    paths.add(request.uri.path);
    hosts.add(request.headers.host ?? '');
    try {
      final h = handler;
      if (h != null) {
        await h(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (_) {
      // 客户端提前断开时忽略写失败
    }
  }

  Future<void> close() => _server.close(force: true);
}

/// 记录是否被施加代理 / 关闭证书校验的 fake 客户端（委托真实客户端）。
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

/// 注入用假下载器：固定返回给定字节，并记录请求 URL / maxBytes。
class _FakeFetcher implements ModuleFetcher {
  _FakeFetcher(this.bytes);

  Uint8List? bytes;
  final List<String> urls = [];
  int? lastMaxBytes;
  int calls = 0;

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) async {
    calls++;
    urls.add(url);
    lastMaxBytes = maxBytes;
    return bytes;
  }
}

/// ItToolsService 的解压、清理与远端更新测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 绑定初始化会安装一个把所有 HTTP 请求变成 400 的 HttpOverrides。
  // 远端用例需要真实 loopback（仅进程内 fake server），这里恢复系统实现。
  HttpOverrides.global = null;

  group('ItToolsService.extractTo', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('it_tools_test_');
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('解压根级与嵌套文件，内容一致', () async {
      final bytes = buildZip({
        'index.html': '<html>ok</html>',
        'assets/app.js': 'console.log(1)',
        'assets/deep/nested/x.txt': 'deep',
      });

      await ItToolsService.extractTo(bytes, dir.path);

      expect(
        await File(p.join(dir.path, 'index.html')).readAsString(),
        '<html>ok</html>',
      );
      expect(
        await File(p.join(dir.path, 'assets', 'app.js')).readAsString(),
        'console.log(1)',
      );
      expect(
        await File(p.join(dir.path, 'assets', 'deep', 'nested', 'x.txt'))
            .readAsString(),
        'deep',
      );
    });

    test('拒绝跳出目标目录的条目（zip-slip）', () async {
      final bytes = buildZip({
        'ok.txt': 'ok',
        '../escaped.txt': 'pwn',
        'assets/../../escaped2.txt': 'pwn',
        '/tmp/absolute_escape.txt': 'pwn',
      });

      await ItToolsService.extractTo(bytes, dir.path);

      expect(await File(p.join(dir.path, 'ok.txt')).exists(), isTrue);
      expect(await File(p.join(dir.parent.path, 'escaped.txt')).exists(), isFalse);
      expect(
          await File(p.join(dir.parent.path, 'escaped2.txt')).exists(), isFalse);
      expect(await File('/tmp/absolute_escape.txt').exists(), isFalse);
    });

    test('覆盖同名文件时内容为新值', () async {
      await File(p.join(dir.path, 'index.html')).writeAsString('old');

      await ItToolsService.extractTo(buildZip({'index.html': 'new'}), dir.path);

      expect(await File(p.join(dir.path, 'index.html')).readAsString(), 'new');
    });
  });

  group('ItToolsService 清理（「缓存管理」入口）', () {
    late Directory docs;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('it_tools_docs_');
      ItToolsService.debugDocsDir = docs;
      ItToolsService.debugDisableAutoUpdate = true;
    });

    tearDown(() async {
      ItToolsService.debugReset();
      if (await docs.exists()) {
        await docs.delete(recursive: true);
      }
    });

    test('extractedDir 指向文档目录下的 it_tools', () async {
      final dir = await ItToolsService.extractedDir();
      expect(dir.path, p.join(docs.path, 'it_tools'));
    });

    test('目录不存在时清理返回 false', () async {
      expect(await ItToolsService.clearExtracted(), isFalse);
    });

    test('clearExtracted 连带清理 .prev 与 .new', () async {
      for (final name in [
        'it_tools',
        ItToolsService.previousDirName,
        ItToolsService.stagingDirName,
      ]) {
        final d = Directory(p.join(docs.path, name))..createSync(recursive: true);
        File(p.join(d.path, 'x')).writeAsStringSync('x');
      }

      expect(await ItToolsService.clearExtracted(), isTrue);
      for (final name in [
        'it_tools',
        ItToolsService.previousDirName,
        ItToolsService.stagingDirName,
      ]) {
        expect(await Directory(p.join(docs.path, name)).exists(), isFalse);
      }
    });

    test(
      '清理会连标记一起删除 → 下次 ensureExtracted 必然重新解压',
      () async {
        // 离线包现在是 CI 用「上游 + 补丁」重建的产物、不入库。
        // 本地没跑 scripts/it_tools/build_bundle.sh 时资产不存在——跳过而不是报错。
        try {
          await rootBundle.load(ItToolsService.assetZipPath);
        } catch (_) {
          markTestSkipped('离线包不存在（先跑 scripts/it_tools/build_bundle.sh 生成）');
          return;
        }
        // 首次：目录为空，应当解压真实资产并落地内容标记
        final dir = await ItToolsService.ensureExtracted();
        expect(await File(p.join(dir.path, 'index.html')).exists(), isTrue);
        final marker = await ItToolsService.readCurrentMarker();
        expect(marker, isNotNull, reason: '解压后必须落标记，否则无法判断内容是否变更');
        expect(marker!.source, ItToolsService.sourceAsset);

        // 已解压且内容一致 → 不重复解压（埋一个哨兵文件，重解会被清掉）
        final sentinel = File(p.join(dir.path, 'sentinel.txt'));
        await sentinel.writeAsString('keep');
        await ItToolsService.ensureExtracted();
        expect(await sentinel.exists(), isTrue, reason: '有可用目录时不应重新解压');

        // 清理后 → 标记没了 → 必然重新解压（哨兵文件随之消失）
        expect(await ItToolsService.clearExtracted(), isTrue);
        expect(await dir.exists(), isFalse);

        await ItToolsService.ensureExtracted();
        expect(await File(p.join(dir.path, 'index.html')).exists(), isTrue);
        expect(await sentinel.exists(), isFalse, reason: '清理后应重新解压出新目录');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('ItToolsService 远端更新（内容哈希 + 原子替换 + 回退）', () {
    late Directory docs;
    late Directory support;
    late _FakeServer server;
    late List<_RecordingHttpClient> created;

    String origin() => 'http://127.0.0.1:${server.port}';

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('it_tools_docs_');
      support = await Directory.systemTemp.createTemp('it_tools_support_');
      ItToolsService.debugDocsDir = docs;
      ItToolsService.debugDisableAutoUpdate = true;
      server = _FakeServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
      created = [];
    });

    tearDown(() async {
      await server.close();
      ItToolsService.debugReset();
      if (await docs.exists()) {
        await docs.delete(recursive: true);
      }
      if (await support.exists()) {
        await support.delete(recursive: true);
      }
    });

    Directory currentDir() => Directory(p.join(docs.path, 'it_tools'));
    Directory prevDir() =>
        Directory(p.join(docs.path, ItToolsService.previousDirName));
    Directory stagingDir() =>
        Directory(p.join(docs.path, ItToolsService.stagingDirName));

    ModuleManifestClient buildRecordedClient() => ModuleManifestClient(
          releasesUrl: Uri.parse('${origin()}/releases/latest'),
          supportDirProvider: () async => support,
          abiProvider: () async => 'arm64-v8a',
          clientFactory: () {
            final recording = _RecordingHttpClient(HttpClient());
            created.add(recording);
            return recording;
          },
          timeout: const Duration(seconds: 5),
        );

    /// 同一 Release 提供 `it_tools.json` + `it-tools.zip`（zip 可选，供真实下载器用）。
    void serveRemote({
      required String hash,
      required int size,
      Uint8List? zip,
      String asset = 'it-tools.zip',
    }) {
      server.handler = (request) async {
        final path = request.uri.path;
        if (path == '/releases/latest') {
          request.response.statusCode = HttpStatus.ok;
          request.response.write(jsonEncode({
            'tag_name': 'v1.0.0',
            'prerelease': false,
            'assets': [
              {
                'name': 'it_tools.json',
                'browser_download_url': '${origin()}/it_tools.json',
                'size': 64,
              },
              {
                'name': asset,
                'browser_download_url': '${origin()}/$asset',
                'size': size,
              },
            ],
          }));
        } else if (path == '/it_tools.json') {
          request.response.statusCode = HttpStatus.ok;
          request.response.write(jsonEncode({
            'contentHash': hash,
            'asset': asset,
            'size': size,
          }));
        } else if (path == '/$asset' && zip != null) {
          request.response.statusCode = HttpStatus.ok;
          request.response.add(zip);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      };
    }

    void serveOffline() {
      server.handler = (request) async {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      };
    }

    Future<void> seedCurrent(String html, String hash) async {
      final dir = currentDir()..createSync(recursive: true);
      File(p.join(dir.path, 'index.html')).writeAsStringSync(html);
      File(p.join(dir.path, ItToolsService.markerFileName)).writeAsStringSync(
        jsonEncode({'contentHash': hash, 'source': ItToolsService.sourceRemote}),
      );
    }

    Future<Map<String, dynamic>> readMarkerAt(Directory dir) async {
      final raw =
          await File(p.join(dir.path, ItToolsService.markerFileName)).readAsString();
      return jsonDecode(raw) as Map<String, dynamic>;
    }

    // 1. 远端成功：原子换名后入口存在，标记 source=remote / contentHash 正确；
    //    清单通道未代理、未关证书校验。
    test('远端成功：原子换名 + source=remote + contentHash 正确（无代理通道）',
        () async {
      final zip = buildZip({
        'index.html': '<html>remote-v1</html>',
        'assets/app.js': 'x',
      });
      final hash = sha256Hex(zip);
      serveRemote(hash: hash, size: zip.length, zip: zip);

      final fetcher = _FakeFetcher(zip);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      final result = await ItToolsService.updateFromRemote(forceRefresh: true);

      expect(result.updated, isTrue);
      expect(result.source, ItToolsService.sourceRemote);
      expect(result.contentHash, hash);

      final dir = await ItToolsService.extractedDir();
      expect(
        await File(p.join(dir.path, 'index.html')).readAsString(),
        '<html>remote-v1</html>',
      );
      final marker = await ItToolsService.readCurrentMarker();
      expect(marker, isNotNull);
      expect(marker!.source, ItToolsService.sourceRemote);
      expect(marker.contentHash, hash);

      // 确实从 Release 资产 URL 下载，且带上清单 size 作为上限
      expect(fetcher.urls.single, '${origin()}/it-tools.zip');
      expect(fetcher.lastMaxBytes, zip.length);

      // 清单信任锚：无代理、默认证书校验
      expect(created, isNotEmpty);
      for (final c in created) {
        expect(c.findProxySet, isFalse, reason: '不得施加任何代理（默认 DIRECT）');
        expect(c.badCertificateCallbackSet, isFalse,
            reason: '不得关闭证书校验');
      }
      expect(server.hosts, everyElement(startsWith('127.0.0.1')));

      // 首次安装无旧目录 → 不产生 .prev；.new 已被消费
      expect(await stagingDir().exists(), isFalse);
      expect(await prevDir().exists(), isFalse);
    });

    // 2. 第二次成功更新：旧当前目录保留为 .prev（含旧标记），.new 被消费。
    test('第二次更新保留上一份为 it_tools.prev，标记各自正确', () async {
      final zip1 = buildZip({'index.html': 'v1'});
      final zip2 = buildZip({'index.html': 'v2'});
      final hash1 = sha256Hex(zip1);
      final hash2 = sha256Hex(zip2);

      final fetcher = _FakeFetcher(zip1);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      serveRemote(hash: hash1, size: zip1.length, zip: zip1);
      expect(
        (await ItToolsService.updateFromRemote(forceRefresh: true)).updated,
        isTrue,
      );

      serveRemote(hash: hash2, size: zip2.length, zip: zip2);
      fetcher.bytes = zip2;
      expect(
        (await ItToolsService.updateFromRemote(forceRefresh: true)).updated,
        isTrue,
      );

      final dir = await ItToolsService.extractedDir();
      expect(await File(p.join(dir.path, 'index.html')).readAsString(), 'v2');
      expect((await ItToolsService.readCurrentMarker())!.contentHash, hash2);

      expect(await prevDir().exists(), isTrue);
      expect(
        await File(p.join(prevDir().path, 'index.html')).readAsString(),
        'v1',
      );
      expect((await readMarkerAt(prevDir()))['contentHash'], hash1);
      expect(await stagingDir().exists(), isFalse);
    });

    // 3. contentHash 不符：旧目录与旧标记原样保留，.new 清理。
    test('contentHash 不符：保留旧目录与旧标记，.new 清理', () async {
      final zip = buildZip({'index.html': 'new-remote'});
      final oldHash = 'b' * 64;
      await seedCurrent('old-local', oldHash);

      final fetcher = _FakeFetcher(zip);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      // size 正确，hash 是合法的 64 hex 但不匹配
      serveRemote(hash: 'c' * 64, size: zip.length, zip: zip);

      final result = await ItToolsService.updateFromRemote(forceRefresh: true);

      expect(result.updated, isFalse);
      expect(result.reason, 'hash-mismatch');
      expect(
        await File(p.join(currentDir().path, 'index.html')).readAsString(),
        'old-local',
      );
      expect((await ItToolsService.readCurrentMarker())!.contentHash, oldHash);
      expect(await stagingDir().exists(), isFalse);
      expect(await prevDir().exists(), isFalse, reason: '失败不得动 .prev');
    });

    // 4. size 不符：同样 fail-closed。
    test('size 不符：保留旧目录与旧标记', () async {
      final zip = buildZip({'index.html': 'new-remote'});
      final oldHash = 'd' * 64;
      await seedCurrent('old-local', oldHash);

      final fetcher = _FakeFetcher(zip);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      serveRemote(hash: sha256Hex(zip), size: zip.length + 7, zip: zip);

      final result = await ItToolsService.updateFromRemote(forceRefresh: true);

      expect(result.updated, isFalse);
      expect(result.reason, 'size-mismatch');
      expect(
        await File(p.join(currentDir().path, 'index.html')).readAsString(),
        'old-local',
      );
      expect((await ItToolsService.readCurrentMarker())!.contentHash, oldHash);
      expect(await stagingDir().exists(), isFalse);
    });

    // 5. 畸形输入：hash/size 都匹配但 zip 损坏 → 解压失败，不破坏旧目录。
    test('zip 损坏：解压失败且不破坏旧目录/旧标记', () async {
      final bad = Uint8List.fromList(utf8.encode('this is not a zip'));
      final oldHash = 'e' * 64;
      await seedCurrent('old-local', oldHash);

      final fetcher = _FakeFetcher(bad);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      serveRemote(hash: sha256Hex(bad), size: bad.length, zip: bad);

      final result = await ItToolsService.updateFromRemote(forceRefresh: true);

      expect(result.updated, isFalse);
      expect(result.reason, 'error');
      expect(
        await File(p.join(currentDir().path, 'index.html')).readAsString(),
        'old-local',
      );
      expect((await ItToolsService.readCurrentMarker())!.contentHash, oldHash);
      expect(await stagingDir().exists(), isFalse);
    });

    // 6. 更新失败不得删除既有 .prev（回滚来源保留）。
    test('更新失败不删除既有 it_tools.prev', () async {
      final zip1 = buildZip({'index.html': 'v1'});
      final zip2 = buildZip({'index.html': 'v2'});
      await seedCurrent('seed', 'a' * 64);

      final fetcher = _FakeFetcher(zip1);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      // 第一次成功：seed → .prev，v1 → 当前
      serveRemote(hash: sha256Hex(zip1), size: zip1.length, zip: zip1);
      expect(
        (await ItToolsService.updateFromRemote(forceRefresh: true)).updated,
        isTrue,
      );
      expect(
        await File(p.join(prevDir().path, 'index.html')).readAsString(),
        'seed',
      );

      // 第二次失败（hash 不符）：.prev 与当前都必须保留
      serveRemote(hash: 'f' * 64, size: zip2.length, zip: zip2);
      fetcher.bytes = zip2;
      final failed = await ItToolsService.updateFromRemote(forceRefresh: true);
      expect(failed.reason, 'hash-mismatch');

      expect(
        await File(p.join(prevDir().path, 'index.html')).readAsString(),
        'seed',
        reason: '失败时既有 .prev 不得被删除',
      );
      expect(
        await File(p.join(currentDir().path, 'index.html')).readAsString(),
        'v1',
      );
      expect(await stagingDir().exists(), isFalse);
    });

    // 7. 内容一致 → up-to-date，不再下载。
    test('contentHash 一致时 up-to-date，不重复下载', () async {
      final zip = buildZip({'index.html': 'same'});
      final hash = sha256Hex(zip);
      serveRemote(hash: hash, size: zip.length, zip: zip);

      final fetcher = _FakeFetcher(zip);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      final first = await ItToolsService.updateFromRemote(forceRefresh: true);
      expect(first.updated, isTrue);
      expect(fetcher.calls, 1);

      final second = await ItToolsService.updateFromRemote();
      expect(second.updated, isFalse);
      expect(second.reason, 'up-to-date');
      expect(fetcher.calls, 1, reason: '同 contentHash 不得重复下载');
    });

    // 8. 真实内部下载器（Todo 3）从 loopback 取 zip，无代理、校验后落地。
    test('真实内部下载器从 loopback 下载并通过 size/contentHash 校验', () async {
      final zip = buildZip({'index.html': '<html>real-dl</html>'});
      final hash = sha256Hex(zip);
      serveRemote(hash: hash, size: zip.length, zip: zip);

      ItToolsService.debugFetcher = ModuleDownloader(
        proxyProvider: () => '',
        // loopback 仅测试用；生产白名单不含回环地址
        allowedHosts: {...ModuleDownloader.defaultAssetHosts, '127.0.0.1'},
      );
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      final result = await ItToolsService.updateFromRemote(forceRefresh: true);

      expect(result.updated, isTrue);
      expect(result.contentHash, hash);
      final dir = await ItToolsService.extractedDir();
      expect(
        await File(p.join(dir.path, 'index.html')).readAsString(),
        '<html>real-dl</html>',
      );
      for (final c in created) {
        expect(c.findProxySet, isFalse);
        expect(c.badCertificateCallbackSet, isFalse);
      }
    });

    // 9. 离线：回退随包资产并标记 source=asset。
    test('离线：回退随包资产并标记 source=asset', () async {
      serveOffline();
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      final assetZip = buildZip({'index.html': '<html>asset</html>'});
      ItToolsService.debugAssetLoader = () async => assetZip;

      final dir = await ItToolsService.ensureExtracted();

      expect(
        await File(p.join(dir.path, 'index.html')).readAsString(),
        '<html>asset</html>',
      );
      final marker = await ItToolsService.readCurrentMarker();
      expect(marker, isNotNull);
      expect(marker!.source, ItToolsService.sourceAsset);
      expect(marker.contentHash, sha256Hex(assetZip));
      expect(await stagingDir().exists(), isFalse);
      expect(await prevDir().exists(), isFalse);
    });

    // 10. 回滚链：当前缺失时用上一份可用远端，不触发随包资产。
    test('当前缺失：回滚上一份可用远端，不触发随包资产', () async {
      final prev = prevDir()..createSync(recursive: true);
      File(p.join(prev.path, 'index.html')).writeAsStringSync('prev-remote');
      File(p.join(prev.path, ItToolsService.markerFileName)).writeAsStringSync(
        jsonEncode(
          {'contentHash': '9' * 64, 'source': ItToolsService.sourceRemote},
        ),
      );
      var assetUsed = false;
      ItToolsService.debugAssetLoader = () async {
        assetUsed = true;
        return buildZip({'index.html': 'asset'});
      };
      serveOffline();
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      final dir = await ItToolsService.ensureExtracted();

      expect(
        await File(p.join(dir.path, 'index.html')).readAsString(),
        'prev-remote',
      );
      expect(assetUsed, isFalse, reason: '有可用上一份时不应动用随包资产');
      final marker = await ItToolsService.readCurrentMarker();
      expect(marker!.source, ItToolsService.sourceRemote);
      expect(marker.contentHash, '9' * 64);
      expect(await prevDir().exists(), isFalse);
      expect(await stagingDir().exists(), isFalse);
    });

    // 11. 无可用目录且无网络 → 随包资产（兜底不丢失）。
    test('当前与上一份均不可用：随包资产兜底', () async {
      serveOffline();
      ItToolsService.debugManifestClientFactory = buildRecordedClient;
      final assetZip = buildZip({'index.html': 'asset-fallback'});
      ItToolsService.debugAssetLoader = () async => assetZip;

      final dir = await ItToolsService.ensureExtracted();

      expect(
        await File(p.join(dir.path, 'index.html')).readAsString(),
        'asset-fallback',
      );
      expect(
        (await ItToolsService.readCurrentMarker())!.source,
        ItToolsService.sourceAsset,
      );
    });

    // 12. 首次安装但盘上已有陈旧 .prev：`_swap` 必须先丢弃，不得把陈旧回滚源留下。
    test('首次安装丢弃陈旧 it_tools.prev（无旧当前）', () async {
      final stale = prevDir()..createSync(recursive: true);
      File(p.join(stale.path, 'index.html')).writeAsStringSync('stale-prev');
      File(p.join(stale.path, ItToolsService.markerFileName)).writeAsStringSync(
        jsonEncode(
          {'contentHash': '1' * 64, 'source': ItToolsService.sourceRemote},
        ),
      );

      final zip = buildZip({'index.html': '<html>fresh</html>'});
      final hash = sha256Hex(zip);
      serveRemote(hash: hash, size: zip.length, zip: zip);
      final fetcher = _FakeFetcher(zip);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      final result = await ItToolsService.updateFromRemote(forceRefresh: true);
      expect(result.updated, isTrue);

      expect(
        await File(p.join(currentDir().path, 'index.html')).readAsString(),
        '<html>fresh</html>',
      );
      expect(
        await prevDir().exists(),
        isFalse,
        reason: '无旧当前时不得留下会误导回滚的陈旧 .prev',
      );
      expect(await stagingDir().exists(), isFalse);
    });

    // 13. 回滚链：当前目录存在但损坏（缺 index.html）→ 用 .prev 提升，损坏目录被丢弃。
    test('当前损坏但 .prev 可用：回滚 .prev 并清掉损坏目录', () async {
      final broken = currentDir()..createSync(recursive: true);
      File(p.join(broken.path, 'junk.txt')).writeAsStringSync('broken');

      final prev = prevDir()..createSync(recursive: true);
      File(p.join(prev.path, 'index.html')).writeAsStringSync('prev-good');
      File(p.join(prev.path, ItToolsService.markerFileName)).writeAsStringSync(
        jsonEncode(
          {'contentHash': '2' * 64, 'source': ItToolsService.sourceRemote},
        ),
      );

      var assetUsed = false;
      ItToolsService.debugAssetLoader = () async {
        assetUsed = true;
        return buildZip({'index.html': 'asset'});
      };
      serveOffline();
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      final dir = await ItToolsService.ensureExtracted();

      expect(
        await File(p.join(dir.path, 'index.html')).readAsString(),
        'prev-good',
      );
      expect(
        await File(p.join(dir.path, 'junk.txt')).exists(),
        isFalse,
        reason: '损坏的当前目录不得残留进提升后的当前目录',
      );
      expect(assetUsed, isFalse, reason: '.prev 可用时不应动用随包资产');
      final marker = await ItToolsService.readCurrentMarker();
      expect(marker!.source, ItToolsService.sourceRemote);
      expect(marker.contentHash, '2' * 64);
      expect(await prevDir().exists(), isFalse);
      expect(await stagingDir().exists(), isFalse);
    });

    // 14. 回退链末段：当前与 .prev 都损坏 → 随包资产；损坏当前被换名进 .prev（可审计）。
    test('当前与 .prev 均损坏：随包资产兜底且损坏当前移入 .prev', () async {
      final broken = currentDir()..createSync(recursive: true);
      File(p.join(broken.path, 'junk.txt')).writeAsStringSync('broken-current');

      final brokenPrev = prevDir()..createSync(recursive: true);
      File(p.join(brokenPrev.path, 'junk2.txt'))
          .writeAsStringSync('broken-prev');

      final assetZip = buildZip({'index.html': 'asset-fallback'});
      ItToolsService.debugAssetLoader = () async => assetZip;
      serveOffline();
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      final dir = await ItToolsService.ensureExtracted();

      expect(
        await File(p.join(dir.path, 'index.html')).readAsString(),
        'asset-fallback',
      );
      expect(
        (await ItToolsService.readCurrentMarker())!.source,
        ItToolsService.sourceAsset,
      );
      expect(
        (await ItToolsService.readCurrentMarker())!.contentHash,
        sha256Hex(assetZip),
      );
      // 原子换名的审计痕迹：损坏的当前目录被换名到 .prev，而不是被静默丢弃
      expect(await prevDir().exists(), isTrue);
      expect(await File(p.join(prevDir().path, 'junk.txt')).exists(), isTrue);
      expect(await stagingDir().exists(), isFalse);
    });

    // 15. 连续三次成功更新：.prev 只保留紧邻前一份，标记链正确，无 .new / .tmp 残留。
    test('连续更新：.prev 只保留紧邻前一份且标记链正确', () async {
      final zips = [
        buildZip({'index.html': 'v1'}),
        buildZip({'index.html': 'v2'}),
        buildZip({'index.html': 'v3'}),
      ];
      final hashes = zips.map(sha256Hex).toList();

      final fetcher = _FakeFetcher(zips[0]);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      for (var i = 0; i < zips.length; i++) {
        serveRemote(hash: hashes[i], size: zips[i].length, zip: zips[i]);
        fetcher.bytes = zips[i];
        final r = await ItToolsService.updateFromRemote(forceRefresh: true);
        expect(r.updated, isTrue, reason: '第 ${i + 1} 次更新应成功');
        expect(r.contentHash, hashes[i]);
      }

      final current = currentDir();
      expect(
        await File(p.join(current.path, 'index.html')).readAsString(),
        'v3',
      );
      expect((await ItToolsService.readCurrentMarker())!.contentHash, hashes[2]);

      final prev = prevDir();
      expect(await File(p.join(prev.path, 'index.html')).readAsString(), 'v2');
      expect((await readMarkerAt(prev))['contentHash'], hashes[1]);
      expect((await readMarkerAt(prev))['source'], ItToolsService.sourceRemote);

      expect(await stagingDir().exists(), isFalse);
      expect(
        await File(
          p.join(current.path, '${ItToolsService.markerFileName}.tmp'),
        ).exists(),
        isFalse,
        reason: '标记写必须原子（先 .tmp 后 rename），不得残留半写标记',
      );
    });

    // 16. 畸形清单：contentHash 非 64-hex → 视为远端不可用，零下载且状态不变。
    test('非法 contentHash：远端不可用且不发起下载', () async {
      final zip = buildZip({'index.html': 'never-downloaded'});
      final oldHash = '3' * 64;
      await seedCurrent('old-local', oldHash);

      final fetcher = _FakeFetcher(zip);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      serveRemote(hash: 'NOT-A-SHA256', size: zip.length, zip: zip);

      final result = await ItToolsService.updateFromRemote(forceRefresh: true);

      expect(result.updated, isFalse);
      expect(result.reason, 'remote-unavailable');
      expect(fetcher.calls, 0, reason: '清单都没校验通过，绝不应下载载荷');
      expect(
        await File(p.join(currentDir().path, 'index.html')).readAsString(),
        'old-local',
      );
      expect((await ItToolsService.readCurrentMarker())!.contentHash, oldHash);
    });

    // 17. 畸形清单：size 为 0 → 视为远端不可用（拒绝空资产）。
    test('非法 size（0）：远端不可用且状态不变', () async {
      final zip = buildZip({'index.html': 'x'});
      final oldHash = '4' * 64;
      await seedCurrent('old-local', oldHash);

      final fetcher = _FakeFetcher(zip);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      serveRemote(hash: sha256Hex(zip), size: 0, zip: zip);

      final result = await ItToolsService.updateFromRemote(forceRefresh: true);

      expect(result.updated, isFalse);
      expect(result.reason, 'remote-unavailable');
      expect(fetcher.calls, 0);
      expect(
        await File(p.join(currentDir().path, 'index.html')).readAsString(),
        'old-local',
      );
    });

    // 18. 合法 hash/size 但 zip 缺 index.html → 'missing-entry'，旧目录/标记不变。
    test('zip 缺入口文件：missing-entry 且旧目录/标记不变', () async {
      final noEntry = buildZip({'assets/app.js': 'x'});
      final oldHash = '5' * 64;
      await seedCurrent('old-local', oldHash);

      final fetcher = _FakeFetcher(noEntry);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      serveRemote(hash: sha256Hex(noEntry), size: noEntry.length, zip: noEntry);

      final result = await ItToolsService.updateFromRemote(forceRefresh: true);

      expect(result.updated, isFalse);
      expect(result.reason, 'missing-entry');
      expect(
        await File(p.join(currentDir().path, 'index.html')).readAsString(),
        'old-local',
      );
      expect((await ItToolsService.readCurrentMarker())!.contentHash, oldHash);
      expect(await stagingDir().exists(), isFalse);
      expect(await prevDir().exists(), isFalse);
    });

    // 19. 反复中断：一次失败后再次成功；失败不留 .new，首次成功无 .prev。
    test('失败后重试成功：失败不留 .new，首次成功无 .prev', () async {
      final zip = buildZip({'index.html': 'recovered'});
      final hash = sha256Hex(zip);
      final fetcher = _FakeFetcher(zip);
      ItToolsService.debugFetcher = fetcher;
      ItToolsService.debugManifestClientFactory = buildRecordedClient;

      // 第一次：合法但与载荷不符的 hash → hash-mismatch
      serveRemote(hash: '6' * 64, size: zip.length, zip: zip);
      final failed = await ItToolsService.updateFromRemote(forceRefresh: true);
      expect(failed.reason, 'hash-mismatch');
      expect(await currentDir().exists(), isFalse);
      expect(await stagingDir().exists(), isFalse);

      // 第二次：修正后的清单 → 成功安装
      serveRemote(hash: hash, size: zip.length, zip: zip);
      final ok = await ItToolsService.updateFromRemote(forceRefresh: true);
      expect(ok.updated, isTrue);
      expect(
        await File(p.join(currentDir().path, 'index.html')).readAsString(),
        'recovered',
      );
      expect(await prevDir().exists(), isFalse);
      expect(await stagingDir().exists(), isFalse);
    });
  });

  group('ItToolsMarker 语义（contentHash / source）', () {
    test('合法 remote/asset 标记可往返序列化', () {
      for (final source in [
        ItToolsService.sourceRemote,
        ItToolsService.sourceAsset,
      ]) {
        final marker = ItToolsMarker(contentHash: 'a' * 64, source: source);
        final decoded = ItToolsMarker.tryFromJson(marker.toJson());
        expect(decoded, isNotNull);
        expect(decoded!.contentHash, 'a' * 64);
        expect(decoded.source, source);
      }
      expect(ItToolsService.sourceRemote, isNot(ItToolsService.sourceAsset));
    });

    test('畸形标记一律返回 null（缺字段/类型错/未知来源绝不崩溃）', () {
      expect(ItToolsMarker.tryFromJson(null), isNull);
      expect(ItToolsMarker.tryFromJson('not-a-map'), isNull);
      expect(ItToolsMarker.tryFromJson(<String, Object?>{}), isNull);
      expect(
        ItToolsMarker.tryFromJson({'source': ItToolsService.sourceRemote}),
        isNull,
        reason: '缺 contentHash',
      );
      expect(
        ItToolsMarker.tryFromJson(
          {'contentHash': '', 'source': ItToolsService.sourceRemote},
        ),
        isNull,
        reason: '空 contentHash',
      );
      expect(
        ItToolsMarker.tryFromJson({'contentHash': 123, 'source': 'asset'}),
        isNull,
        reason: 'contentHash 类型错误',
      );
      expect(
        ItToolsMarker.tryFromJson({'contentHash': 'a' * 64, 'source': 'evil'}),
        isNull,
        reason: '未知 source 不得被当作合法来源',
      );
    });

    test('readCurrentMarker：损坏/未知来源标记 → null（fail-closed）', () async {
      final docs = await Directory.systemTemp.createTemp('it_tools_marker_');
      ItToolsService.debugDocsDir = docs;
      ItToolsService.debugDisableAutoUpdate = true;
      addTearDown(() async {
        ItToolsService.debugReset();
        if (await docs.exists()) await docs.delete(recursive: true);
      });

      final dir = Directory(p.join(docs.path, 'it_tools'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'index.html')).writeAsString('<html/>');

      final markerFile = File(p.join(dir.path, ItToolsService.markerFileName));
      await markerFile.writeAsString('{"contentHash":"abc","source":"evil"}');
      expect(await ItToolsService.readCurrentMarker(), isNull);

      await markerFile.writeAsString('not-json');
      expect(await ItToolsService.readCurrentMarker(), isNull);
    });
  });

  group('ItToolsService 存活保护（服务级 beginUse/endUse/isInUse）', () {
    late Directory docs;
    late Directory currentDir;
    late Directory prevDir;
    late Directory stagingDir;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('it_tools_liveness_');
      ItToolsService.debugDocsDir = docs;
      ItToolsService.debugDisableAutoUpdate = true;
      currentDir = Directory(p.join(docs.path, 'it_tools'));
      prevDir = Directory(p.join(docs.path, ItToolsService.previousDirName));
      stagingDir = Directory(p.join(docs.path, ItToolsService.stagingDirName));
    });

    tearDown(() async {
      ItToolsService.debugReset();
      if (await docs.exists()) await docs.delete(recursive: true);
    });

    void seedDir(Directory dir, String html) {
      dir.createSync(recursive: true);
      File(p.join(dir.path, 'index.html')).writeAsStringSync(html);
      File(p.join(dir.path, ItToolsService.markerFileName)).writeAsStringSync(
        jsonEncode(
          {'contentHash': '7' * 64, 'source': ItToolsService.sourceRemote},
        ),
      );
    }

    test('isInUse 可重入：全部释放前保持存活，归零后空闲，零计数释放是 no-op',
        () async {
      expect(ItToolsService.isInUse, isFalse);

      ItToolsService.beginUse();
      ItToolsService.beginUse();
      expect(ItToolsService.isInUse, isTrue);

      await ItToolsService.endUse();
      expect(ItToolsService.isInUse, isTrue, reason: '仍有使用者，不得视为空闲');

      await ItToolsService.endUse();
      expect(ItToolsService.isInUse, isFalse);

      // 计数为 0 时再次释放是安全 no-op
      await ItToolsService.endUse();
      expect(ItToolsService.isInUse, isFalse);
    });

    test('使用中清理被延迟且如实返回，释放后连同 .prev/.new 一起清理', () async {
      seedDir(currentDir, 'current');
      seedDir(prevDir, 'prev');
      seedDir(stagingDir, 'staging');

      ItToolsService.beginUse();
      expect(
        await ItToolsService.clearManagedDirs(),
        ItToolsClearOutcome.deferred,
      );
      expect(ItToolsService.isInUse, isTrue);
      for (final dir in [currentDir, prevDir, stagingDir]) {
        expect(await dir.exists(), isTrue, reason: '存活期不得删除 ${dir.path}');
      }
      // 同一存活状态下再清理仍如实返回 false（不得误报成功）
      expect(await ItToolsService.clearExtracted(), isFalse);
      expect(await currentDir.exists(), isTrue);

      await ItToolsService.endUse();
      expect(ItToolsService.isInUse, isFalse);
      for (final dir in [currentDir, prevDir, stagingDir]) {
        expect(await dir.exists(), isFalse, reason: '释放后延迟清理应兑现');
      }
    });

    test('清理窗口内新使用者进入：重新延迟，绝不删除活动目录', () async {
      seedDir(currentDir, 'current');
      seedDir(prevDir, 'prev');
      seedDir(stagingDir, 'staging');

      ItToolsService.beginUse();
      expect(
        await ItToolsService.clearManagedDirs(),
        ItToolsClearOutcome.deferred,
      );

      // 在 endUse#1 的「目录解析后、最终校验前」窗口注入新使用者
      ItToolsService.debugBeforeClearDelete = () {
        ItToolsService.debugBeforeClearDelete = null; // 只触发一次
        ItToolsService.beginUse();
      };

      await ItToolsService.endUse(); // #1：窗口内新使用者进入
      expect(ItToolsService.isInUse, isTrue, reason: '新使用者已进入');
      for (final dir in [currentDir, prevDir, stagingDir]) {
        expect(
          await dir.exists(),
          isTrue,
          reason: '窗口内新进入者使用的目录绝不能被删除',
        );
      }
      expect(await ItToolsService.readCurrentMarker(), isNotNull);

      // 新使用者退出 → 延迟清理才兑现
      await ItToolsService.endUse(); // #2
      expect(ItToolsService.isInUse, isFalse);
      for (final dir in [currentDir, prevDir, stagingDir]) {
        expect(await dir.exists(), isFalse);
      }
    });
  });
}
