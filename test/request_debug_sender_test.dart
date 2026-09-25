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
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';

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

    test('rejects a response Set-Cookie whose Domain is an unrelated host',
        () async {
      final fixture = await _Fixture.start((request, recorded) async {
        request.response.statusCode = HttpStatus.ok;
        // 同一响应：一个合法 host-only，一个试图注入无关 host。
        request.response.headers.add('Set-Cookie', 'ok=1; Path=/');
        request.response.headers
            .add('Set-Cookie', 'leak=1; Domain=example.com; Path=/');
        request.response.write('ok');
        await request.response.close();
      });
      addTearDown(fixture.close);

      final sender = DebugSender();
      addTearDown(sender.close);

      await sender.send(method: 'GET', url: '${fixture.origin}/set');

      final own = sender.cookieJar.cookieHeaderFor('127.0.0.1');
      expect(own, contains('ok=1'), reason: '匹配 host 的 cookie 必须接受');
      expect(own, isNot(contains('leak=1')));
      expect(sender.cookieJar.cookieHeaderFor('example.com'), isEmpty,
          reason: '无关 host 不得被响应注入 cookie');
    });
  });

  // plan todo 2：URL 查询与参数行按名合并（覆盖而非追加）。
  group('DebugSender query merge (override)', () {
    Future<_Fixture> startFixture() =>
        _Fixture.start((request, recorded) async {
          request.response.statusCode = HttpStatus.ok;
          request.response.write('ok');
          await request.response.close();
        });

    test('overrides a duplicate query key from the URL', () async {
      final fixture = await startFixture();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      final response = await sender.send(
        method: 'GET',
        url: '${fixture.origin}/echo?a=1',
        query: const <DebugQueryParam>[DebugQueryParam(name: 'a', value: '2')],
      );

      expect(response.error, isNull);
      expect(fixture.recorded.single.query, 'a=2',
          reason: '同名查询键必须覆盖而非追加（绝不能是 a=1&a=2）');
    });

    test('an override may expand to multiple values for the same key',
        () async {
      final fixture = await startFixture();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      await sender.send(
        method: 'GET',
        url: '${fixture.origin}/echo?a=1',
        query: const <DebugQueryParam>[
          DebugQueryParam(name: 'a', value: '2'),
          DebugQueryParam(name: 'a', value: '3'),
        ],
      );

      expect(fixture.recorded.single.query, 'a=2&a=3');
    });

    test('keeps URL-only query keys when there is no override', () async {
      final fixture = await startFixture();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      await sender.send(method: 'GET', url: '${fixture.origin}/echo?a=1');

      expect(fixture.recorded.single.query, 'a=1');
    });

    test('preserves a valueless query key', () async {
      final fixture = await startFixture();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      await sender.send(method: 'GET', url: '${fixture.origin}/echo?flag');

      expect(fixture.recorded.single.query, 'flag');
    });

    test('placeholder URL with no active env returns a response, never throws',
        () async {
      final sender = DebugSender();
      addTearDown(sender.close);

      final response = await sender.send(
        method: 'GET',
        url: '{{host}}/p?a=1',
        timeout: const Duration(seconds: 2),
      );

      expect(response, isA<DebugResponse>());
      expect(response.error, isNotNull,
          reason: '未解析占位符不是合法绝对 URL，必须结构化失败而非抛');
    });
  });

  // plan todo 2：门面端到端（单个请求合并后的查询到达服务端）。
  group('DefaultRequestDebugFacade end-to-end query merge', () {
    test('records the merged query on the server (no duplicate)', () async {
      final fixture = await _Fixture.start((request, recorded) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('ok');
        await request.response.close();
      });
      addTearDown(fixture.close);

      final facade = DefaultRequestDebugFacade(
        store: RequestDebugStore(),
        sender: DebugSender(),
      );
      addTearDown(facade.sender.close);

      final request = DebugRequest(
        id: 'r-e2e',
        name: 'e2e',
        method: 'GET',
        url: '${fixture.origin}/p',
        query: const <DebugQueryParam>[DebugQueryParam(name: 'a', value: '2')],
      );

      final response = await facade.send(
        method: request.method,
        url: request.url,
        query: request.query,
      );

      expect(response.error, isNull);
      expect(fixture.recorded.single.query, 'a=2');
    });
  });
}
