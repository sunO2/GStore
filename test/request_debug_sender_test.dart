/// todo 26：`DebugSender` 端到端测试（本地 `dart:io` `HttpServer` fixture）。
///
/// 断言：方法 / 头 / 查询 / 体实际到达服务端（服务端侧读取，防「假绿」）；
/// `Set-Cookie` 入 jar 并可回发（含多 cookie + 带逗号的 Expires）；超时 /
/// 连接失败返回结构化 `error` 且不抛、不挂起；重定向策略生效。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';

/// 服务端实际收到的一次请求（用于防「假绿」的服务端断言）。
class _Recorded {
  _Recorded(HttpRequest request)
      : method = request.method,
        path = request.uri.path,
        query = request.uri.query,
        cookie = request.headers.value('cookie'),
        xTest = request.headers.value('x-test'),
        xOff = request.headers.value('x-off'),
        contentType = request.headers.value('content-type');

  final String method;
  final String path;
  final String query;
  final String? cookie;
  final String? xTest;
  final String? xOff;
  final String? contentType;
  List<int> body = const <int>[];

  String get bodyText => utf8.decode(body, allowMalformed: true);
}

/// 极简 `HttpServer` fixture：记录请求后交给 handler 决定响应。
class _Fixture {
  _Fixture._(this._server);

  final HttpServer _server;
  final List<_Recorded> recorded = <_Recorded>[];
  late final StreamSubscription<HttpRequest> _sub;

  int get port => _server.port;
  String get origin => 'http://127.0.0.1:$port';

  static Future<_Fixture> start(
    Future<void> Function(HttpRequest request, _Recorded recorded) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _Fixture._(server);
    fixture._sub = server.listen((request) async {
      final recorded = _Recorded(request);
      final chunks = await request.toList();
      recorded.body = <int>[for (final c in chunks) ...c];
      fixture.recorded.add(recorded);
      try {
        await handler(request, recorded);
      } catch (_) {
        // 客户端超时断连后写入抛错，属预期（最佳努力）。
      }
    });
    return fixture;
  }

  Future<void> close() async {
    await _sub.cancel();
    await _server.close(force: true);
  }
}

void main() {
  group('DebugSender', () {
    test('sends method / enabled headers / query / body to the server', () async {
      final fixture = await _Fixture.start((request, recorded) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('ok');
        await request.response.close();
      });
      addTearDown(fixture.close);

      final sender = DebugSender();
      addTearDown(sender.close);

      final response = await sender.send(
        method: 'post',
        url: '${fixture.origin}/echo',
        headers: const <DebugHeader>[
          DebugHeader(name: 'Content-Type', value: 'application/json'),
          DebugHeader(name: 'X-Test', value: 'abc'),
          DebugHeader(name: 'X-Off', value: 'should-not-send', enabled: false),
        ],
        query: const <DebugQueryParam>[
          DebugQueryParam(name: 'q', value: '1'),
          DebugQueryParam(name: 'skip', value: 'x', enabled: false),
        ],
        body: '{"a":1}',
      );

      expect(response.error, isNull);
      expect(response.statusCode, 200);
      expect(response.bodyText, 'ok');
      expect(response.sizeBytes, 2);
      expect(response.bodyBytes, utf8.encode('ok'));
      expect(response.durationMs, greaterThanOrEqualTo(0));

      // 服务端侧断言（防假绿）。
      final recorded = fixture.recorded.single;
      expect(recorded.method, 'POST');
      expect(recorded.path, '/echo');
      expect(recorded.query, 'q=1');
      expect(recorded.xTest, 'abc');
      expect(recorded.xOff, isNull, reason: 'enabled=false 的头绝不发送');
      expect(recorded.contentType, 'application/json');
      expect(recorded.bodyText, '{"a":1}');
    });

    test('stores Set-Cookie in the jar and re-sends it on the next request',
        () async {
      final fixture = await _Fixture.start((request, recorded) async {
        request.response.statusCode = HttpStatus.ok;
        if (recorded.path == '/login') {
          request.response.headers
              .add('Set-Cookie', 'sid=abc123; Path=/; HttpOnly');
        }
        request.response.write('ok');
        await request.response.close();
      });
      addTearDown(fixture.close);

      final sender = DebugSender();
      addTearDown(sender.close);

      await sender.send(method: 'GET', url: '${fixture.origin}/login');
      expect(
        sender.cookieJar.cookieHeaderFor('127.0.0.1'),
        contains('sid=abc123'),
        reason: 'Set-Cookie 必须进入 jar',
      );

      await sender.send(method: 'GET', url: '${fixture.origin}/home');
      final second = fixture.recorded.last;
      expect(second.cookie, contains('sid=abc123'),
          reason: '已存 cookie 必须在后续请求回发');
    });

    test('stores multiple Set-Cookie headers (Expires with comma intact)',
        () async {
      final fixture = await _Fixture.start((request, recorded) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.add('Set-Cookie', 'a=1; Path=/');
        request.response.headers.add(
          'Set-Cookie',
          'b=2; Path=/; Expires=Wed, 21 Oct 2099 07:28:00 GMT',
        );
        request.response.write('ok');
        await request.response.close();
      });
      addTearDown(fixture.close);

      final sender = DebugSender();
      addTearDown(sender.close);

      final response =
          await sender.send(method: 'GET', url: '${fixture.origin}/multi');

      final stored = sender.cookieJar.cookiesFor('127.0.0.1');
      expect(stored.map((c) => c.name).toSet(), <String>{'a', 'b'},
          reason: '多个 Set-Cookie 必须全部解析，Expires 中的逗号不得误切');

      final header = sender.cookieJar.cookieHeaderFor('127.0.0.1');
      expect(header, contains('a=1'));
      expect(header, contains('b=2'));

      // 响应也带上 cookie 视图。
      expect(response.cookies.map((c) => c.name).toSet(), <String>{'a', 'b'});
    });

    test('timeout returns a structured error and does not hang', () async {
      final fixture = await _Fixture.start((request, recorded) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      addTearDown(fixture.close);

      final sender = DebugSender();
      addTearDown(sender.close);

      final stopwatch = Stopwatch()..start();
      final response = await sender.send(
        method: 'GET',
        url: '${fixture.origin}/slow',
        timeout: const Duration(milliseconds: 200),
      );
      stopwatch.stop();

      expect(response.error, isNotNull, reason: '超时必须返回结构化 error');
      expect(response.statusCode, 0);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)),
          reason: '超时必须在期限内结束，绝不挂起');
    });

    test('connection failure returns a structured error, never throws',
        () async {
      // 取一个刚释放的端口 → 连接必然被拒绝。
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      final sender = DebugSender();
      addTearDown(sender.close);

      final response = await sender.send(
        method: 'GET',
        url: 'http://127.0.0.1:$deadPort/never',
        timeout: const Duration(seconds: 2),
      );

      expect(response.error, isNotNull, reason: '连接失败必须结构化返回');
      expect(response.statusCode, 0);
      expect(response.bodyBytes, isEmpty);
    });

    test('redirect policy is honoured', () async {
      final fixture = await _Fixture.start((request, recorded) async {
        if (recorded.path == '/redirect') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set('Location', '/final');
        } else {
          request.response.statusCode = HttpStatus.ok;
          request.response.write('done');
        }
        await request.response.close();
      });
      addTearDown(fixture.close);

      final sender = DebugSender();
      addTearDown(sender.close);

      final followed = await sender.send(
        method: 'GET',
        url: '${fixture.origin}/redirect',
      );
      expect(followed.statusCode, 200);
      expect(followed.bodyText, 'done');

      final notFollowed = await sender.send(
        method: 'GET',
        url: '${fixture.origin}/redirect',
        followRedirects: false,
      );
      expect(notFollowed.statusCode, 302,
          reason: 'followRedirects=false 时必须原样返回 3xx');
    });

    test('cookie jar can be shared explicitly across senders', () async {
      final jar = DebugCookieJar()..store('127.0.0.1', <String, List<String>>{
            'set-cookie': <String>['shared=yes; Path=/'],
          });

      final fixture = await _Fixture.start((request, recorded) async {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      addTearDown(fixture.close);

      final sender = DebugSender(cookieJar: jar);
      addTearDown(sender.close);

      await sender.send(method: 'GET', url: '${fixture.origin}/x');
      expect(fixture.recorded.single.cookie, contains('shared=yes'));
    });
  });
}
