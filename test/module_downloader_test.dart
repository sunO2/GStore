// 下载器测试：进程内 fake HTTP server（loopback），不访问真实网络。
// `file_names` 与 lib/core/rust 既有约定一致。
// ignore_for_file: file_names

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleDownloader.dart';

/// 进程内 fake HTTP server：统计命中次数/路径/host，便于断言"恰好一次"。
class _FakeServer {
  _FakeServer(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;

  /// 收到的请求数（用于"无网络请求"/"有界重试"/"并发去重"断言）。
  int hits = 0;

  /// 每个请求的 path（用于断言代理前缀/直连路径）。
  final List<String> paths = [];

  /// 每个请求的 Host 头。
  final List<String> hosts = [];

  /// 每个请求的响应处理函数。
  FutureOr<void> Function(HttpRequest request)? handler;

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
      // 客户端提前断开（超时/超限 abort）时忽略写失败。
    }
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late _FakeServer server;
  late Directory tmpRoot;

  setUp(() async {
    server = _FakeServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tmpRoot = await Directory.systemTemp.createTemp('gstore_dl_test_');
  });

  tearDown(() async {
    await server.close();
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String origin() => 'http://127.0.0.1:${server.port}';

  // 1. 恶意原始 host 被拒，且不产生任何网络请求。
  test('rejects malicious original hosts without any network request', () async {
    var clients = 0;
    final downloader = ModuleDownloader(
      proxyProvider: () => '',
      clientFactory: () {
        clients++;
        return HttpClient();
      },
      tmpRoot: tmpRoot,
    );

    expect(await downloader.fetch('https://evil.com/plugin.so'), isNull);
    expect(await downloader.fetch('https://github.com.evil.com/x.so'), isNull);
    expect(await downloader.fetch('https://evilgithub.com/x.so'), isNull);
    expect(await downloader.fetch('http://github.com/x.so'), isNull); // http 非环回
    expect(await downloader.fetch('ftp://github.com/x.so'), isNull);

    expect(clients, 0, reason: '校验失败必须在建连前返回');
    expect(server.hits, 0);
  });

  // 2. 逐跳校验：非白名单重定向被拒；白名单重定向被跟随。
  test('validates each redirect hop against the allowlist', () async {
    server.handler = (request) async {
      switch (request.uri.path) {
        case '/start-evil':
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader,
              'https://evil.com/plugin.so');
          await request.response.close();
        case '/start-ok':
          request.response.statusCode = HttpStatus.found;
          request.response.headers
              .set(HttpHeaders.locationHeader, '/final.so');
          await request.response.close();
        case '/final.so':
          request.response.statusCode = HttpStatus.ok;
          request.response.add(utf8.encode('PAYLOAD'));
          await request.response.close();
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    };

    final downloader = ModuleDownloader(
      allowedHosts: {'127.0.0.1'},
      proxyProvider: () => '',
      tmpRoot: tmpRoot,
    );

    expect(await downloader.fetch('${origin()}/start-evil'), isNull);
    expect(server.paths, ['/start-evil']);

    final ok = await downloader.fetch('${origin()}/start-ok');
    expect(ok, isNotNull);
    expect(utf8.decode(ok!), 'PAYLOAD');
    expect(server.paths, contains('/final.so'));
  });

  // 3. 空代理 → 直连已校验的原始 URL（断言 host/path）。
  test('empty proxy requests the validated original URL directly', () async {
    server.handler = (request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.add(utf8.encode('DIRECT'));
      await request.response.close();
    };

    final downloader = ModuleDownloader(
      allowedHosts: {'127.0.0.1'},
      proxyProvider: () => '',
      tmpRoot: tmpRoot,
    );

    final bytes = await downloader.fetch('${origin()}/asset.so');
    expect(utf8.decode(bytes!), 'DIRECT');
    expect(server.paths, ['/asset.so']);
    expect(server.hosts.single, '127.0.0.1');
    expect(server.hits, 1);
    expect(tmpRoot.listSync(), isEmpty,
        reason: '内部临时文件必须清理（原子 rename 交给调用方）');
  });

  // 3b. 代理仅在原始 host 通过校验后作为固定前缀施加；恶意原始 host 不能借代理绕过。
  test('applies proxy prefix only after original host validation', () async {
    server.handler = (request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.add(utf8.encode('PROXIED'));
      await request.response.close();
    };

    var clients = 0;
    final downloader = ModuleDownloader(
      allowedHosts: {'127.0.0.1', 'github.com'},
      proxyProvider: () => 'http://127.0.0.1:${server.port}/p',
      clientFactory: () {
        clients++;
        return HttpClient();
      },
      tmpRoot: tmpRoot,
    );

    final bytes = await downloader.fetch(
        'https://github.com/sunO2/GStore/releases/download/v1/a.so');
    expect(utf8.decode(bytes!), 'PROXIED');
    expect(server.paths.single, startsWith('/p/'));
    expect(server.paths.single, contains('github.com/sunO2/GStore'));

    clients = 0;
    server.paths.clear();
    server.hits = 0;
    expect(await downloader.fetch('https://evil.com/a.so'), isNull);
    expect(clients, 0, reason: '代理不得让未通过校验的原始 host 发请求');
    expect(server.hits, 0);
  });

  // 4. 403 有界重试后失败（不是无限重试）。
  test('retries transient 403 a bounded number of times then fails', () async {
    server.handler = (request) async {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
    };

    final backoffs = <Duration>[];
    final downloader = ModuleDownloader(
      allowedHosts: {'127.0.0.1'},
      proxyProvider: () => '',
      maxAttempts: 3,
      initialBackoff: const Duration(milliseconds: 10),
      sleep: (duration) async => backoffs.add(duration),
      tmpRoot: tmpRoot,
    );

    expect(await downloader.fetch('${origin()}/x.so'), isNull);
    expect(server.hits, 3, reason: '恰好 maxAttempts 次');
    expect(backoffs.length, 2, reason: '仅在尝试之间退避');
  });

  // 4b. 超时有界失败。
  test('times out and fails after a bounded number of attempts', () async {
    server.handler = (request) async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      request.response.statusCode = HttpStatus.ok;
      request.response.add(utf8.encode('LATE'));
      await request.response.close();
    };

    final downloader = ModuleDownloader(
      allowedHosts: {'127.0.0.1'},
      proxyProvider: () => '',
      timeout: const Duration(milliseconds: 100),
      maxAttempts: 2,
      initialBackoff: const Duration(milliseconds: 1),
      sleep: (_) async {},
      tmpRoot: tmpRoot,
    );

    expect(await downloader.fetch('${origin()}/slow.so'), isNull);
    expect(server.hits, 2, reason: '超时有界，不得无限重试');
  });

  // 5. 并发去重：同一 URL 并发两次 → 恰好一次网络请求。
  test('deduplicates concurrent fetches of the same URL', () async {
    server.handler = (request) async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      request.response.statusCode = HttpStatus.ok;
      request.response.add(utf8.encode('DEDUP'));
      await request.response.close();
    };

    final downloader = ModuleDownloader(
      allowedHosts: {'127.0.0.1'},
      proxyProvider: () => '',
      tmpRoot: tmpRoot,
    );

    final url = '${origin()}/same.so';
    final results = await Future.wait([
      downloader.fetch(url),
      downloader.fetch(url),
    ]);

    expect(utf8.decode(results[0]!), 'DEDUP');
    expect(utf8.decode(results[1]!), 'DEDUP');
    expect(server.hits, 1, reason: '并发调用必须共享同一 Future');
  });

  // 6. 大小上限：超过 maxBytes 的响应被拒绝，且不重试。
  test('rejects a response exceeding maxBytes', () async {
    final big = Uint8List(4096)..fillRange(0, 4096, 7);
    server.handler = (request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.add(big);
      await request.response.close();
    };

    final downloader = ModuleDownloader(
      allowedHosts: {'127.0.0.1'},
      proxyProvider: () => '',
      tmpRoot: tmpRoot,
    );

    expect(
      await downloader.fetch('${origin()}/big.so', maxBytes: 1024),
      isNull,
    );
    expect(server.hits, 1, reason: '超限为致命错误，不重试');
  });

  // 6b. downloadToFile：成功写调用方 `.tmp`，失败删除该 `.tmp`（调用方负责 rename）。
  test('downloadToFile writes caller tmp and cleans up on failure', () async {
    server.handler = (request) async {
      if (request.uri.path == '/ok.so') {
        request.response.statusCode = HttpStatus.ok;
        request.response.add(utf8.encode('ATOMIC'));
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    };

    final downloader = ModuleDownloader(
      allowedHosts: {'127.0.0.1'},
      proxyProvider: () => '',
      tmpRoot: tmpRoot,
    );

    final target = File('${tmpRoot.path}/target.so.tmp');
    expect(await downloader.downloadToFile('${origin()}/ok.so', target),
        isTrue);
    expect(utf8.decode(await target.readAsBytes()), 'ATOMIC');
    expect(target.existsSync(), isTrue, reason: 'rename 由调用方负责');

    final failed = File('${tmpRoot.path}/missing.so.tmp');
    expect(await downloader.downloadToFile('${origin()}/missing.so', failed),
        isFalse);
    expect(failed.existsSync(), isFalse, reason: '失败必须删除半写 .tmp');
  });

  // 7. 结构断言：自举下载器不得引用 Rust 下载内核。
  test('source does not reference the rust download kernel', () {
    final source =
        File('lib/core/rust/ModuleDownloader.dart').readAsStringSync();
    final forbidden = 'gstore' + '_mod_download';
    expect(source.contains(forbidden), isFalse,
        reason: '自举下载必须走 dart:io HttpClient，不得调用 Rust 下载内核');
  });
}
