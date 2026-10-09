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

/// 自签名 HTTPS fixture（用于 TLS 校验开关）。证书 SAN=IP:127.0.0.1。
class _TlsFixture {
  _TlsFixture._(this._server);

  final HttpServer _server;
  final List<_Recorded> recorded = <_Recorded>[];
  late final StreamSubscription<HttpRequest> _sub;

  int get port => _server.port;
  String get origin => 'https://127.0.0.1:$port';

  static Future<_TlsFixture> start() async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_selfSignedCertPem))
      ..usePrivateKeyBytes(utf8.encode(_selfSignedKeyPem));
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final fixture = _TlsFixture._(server);
    fixture._sub = server.listen((request) async {
      final recorded = _Recorded(request);
      final chunks = await request.toList();
      recorded.body = <int>[for (final c in chunks) ...c];
      fixture.recorded.add(recorded);
      try {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('secure-ok');
        await request.response.close();
      } catch (_) {
        // 严格校验握手失败时服务端写入可能抛错，属预期。
      }
    });
    return fixture;
  }

  Future<void> close() async {
    await _sub.cancel();
    await _server.close(force: true);
  }
}

/// 测试专用自签名证书（仅用于本地 fixture，非生产信任链）。
const String _selfSignedCertPem = '''
-----BEGIN CERTIFICATE-----
MIIDGjCCAgKgAwIBAgIUYHBgIEXjLd47c20qrdKjOb4LQeIwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MTAwODIzNDYxNVoXDTM2MTAw
NTIzNDYxNVowFDESMBAGA1UEAwwJMTI3LjAuMC4xMIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEA1mmLIFMyyHZ0bFrmfML0/FxQSOagRaW2KY0AiC5xp4pN
ifqSMM8C2zlRDdGX0W2PExIs1XH86yrxvvgw/b6EkRnmmhAS8nd9lwRcxOay9qUy
dI1etIlKyiMlUZTJqdeBikCkw4bKFruqIpQ++EOTCd4s4UK26LnFbOCvl3MdE0Rb
ZNYLa+Qz8L38Odl/sa9bpXV7FhE0DMOC/iaToZodtE4BGe+ZbFtvYcFNdpVmD0kW
YFkKmzFZ+tL3E5oUpp4xPlv6td2REzn3s26tbW2NAVUsDxFJYwe7bqSPp8x7SVn/
s8w7YyOD+ptg7nQNtoCu1+NwWBZXD9ZlkjbsUCT+yQIDAQABo2QwYjAdBgNVHQ4E
FgQUkybS5qV0Zhq8uwetPAVPPjv39x4wHwYDVR0jBBgwFoAUkybS5qV0Zhq8uwet
PAVPPjv39x4wDwYDVR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwR/AAABMA0GCSqG
SIb3DQEBCwUAA4IBAQCvjYMlSxK+eHjT6JwMgCQssF0M2ZYm8kQPz5muUq9P0cFI
H44WHRhs65HhygdNvE2O/NY+f0h9zVRTLJ4v8p3ICUURH+fTn6mzySyys0vytt9O
XcD9Rk2MPWDOcMUhKxyWdFkT9FpyYbNA13eP5LD0fuhVkJdJYtbEkr9nYQn01s+0
d7w2mWJLD1Vu04clyjixPhDMkqFxLwVqMradIrhKmpBEFKwDvYF7ry0BG6ZGo5Vd
9olbAd+Sgi9HBu/HCYv3lmqoFJZFGTXcu0mpV4cECbbhffAtNyqbsDAK4cfxRyZj
5s43NsoWdKfZU3ls8neSzsHM/JC/wi7x05WPqx+d
-----END CERTIFICATE-----
''';

const String _selfSignedKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDWaYsgUzLIdnRs
WuZ8wvT8XFBI5qBFpbYpjQCILnGnik2J+pIwzwLbOVEN0ZfRbY8TEizVcfzrKvG+
+DD9voSRGeaaEBLyd32XBFzE5rL2pTJ0jV60iUrKIyVRlMmp14GKQKTDhsoWu6oi
lD74Q5MJ3izhQrboucVs4K+Xcx0TRFtk1gtr5DPwvfw52X+xr1uldXsWETQMw4L+
JpOhmh20TgEZ75lsW29hwU12lWYPSRZgWQqbMVn60vcTmhSmnjE+W/q13ZETOfez
bq1tbY0BVSwPEUljB7tupI+nzHtJWf+zzDtjI4P6m2DudA22gK7X43BYFlcP1mWS
NuxQJP7JAgMBAAECggEAD4E4BYE5XGQDJ5dr2xzGq33KHnjIS+Zfpbc5ER/5VF9n
cQa0zfZs+J5h8p5enKSQDUB/YSX/ifVOivvr9bAdFQMVo7wYKql3uap1QkCD3jB0
VWz9qroniuDUwNwCDe1JbvkdZmLtDTd1O6U9vSU3JlEHLM5EEiXmQBPVZB3NE0ij
GHMXadh7cqXCV60/hmaY2yAUavOBF+8vH6InlUSx607lavfI+y1Uu/lDblJ4qcLC
MD5673UyKYJnmnR4GVMFBBJLP0yYvPOdspnesQPjyb6HG2MEeNHOjsrFdrZIsq1T
USbvxsSuTOzHLFu1135YDH4sRadA5+by3r7jvHL8awKBgQDiWZdZQbKWHzaP8b2N
KWFcateJ/Zi1r3ThbZCajpGwkKHUENUMieITLsfZp6p1Z6Ac1m3mSotrxtjSLFB8
O3Xwu15KM/Duql8WYFuhjugZ+eiGlpAA/MfR2KBcgNzXeY9r6P4P3czGD40QI5lA
dzTuaWNhoB22E35L13NztFjbjwKBgQDyf6Jro4hhZHSiYAZ0kpRZuVi02tvCFpnG
o9QE09Eg+56GMMTYOUXlFQWH0TpPqz9avCDKPAYztDrn02Vd39IQ5iIW4B8/SLji
xXHZnJsjn9iQccFK7dZuWQV5Mj1N9ha5lDcs/HyYgUsnCcYcb38zlGZbjz2EOxNp
NycgTpW0JwKBgQC7j4WsfpYfc6ngyW5KpLl6vUXxoGSEWOm/Su0CRZVP++k9Mt13
0GG3h5IvN5I2SzIP81eJ9sdk/Zb5QaNH7nWij4BoeHXzLtYwUpRbYXHO5JjbvbOC
PfTOXHU1ccqN+rrvrleoiiB/Fq/LadQ56Q3BaS7i3K0CDVEgQ131yMHA3QKBgEft
gdCplfdFY68SCngjTit65Yvnas2cBIq951JzPZGp8LBe4NQ90LSNUrGhZslgww73
xEYYHcLST7KZqnR4wgdPK4dbfQk5WdWxuP5SDFY5wHO/uhSujS736r6zHynzt3Pe
Oat3TMGzgAYZSREAJVu4RdAcoaOKHkzUFh/oD1F7AoGANgzX8jfjCHWqNym6e6dm
1W9dVz2WZDlvTulc5i6s99PYWZGbYZC/eNSqmt9tYq+ivjtsD4g8QcJmrFRexDXc
uNQqOUT3FcA9aUaldmJY70QxXNiNollzl3hqZQrfjgSmkd2qHNxiJhaPJHjh8R7Y
ffs2whjmSITQ/U3mPC8bdic=
-----END PRIVATE KEY-----
''';

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

  // plan todo 4：每请求网络选项（useCookies / skipTlsVerify）。
  group('DebugSender per-request network options', () {
    test('useCookies:false sends no jar cookie and does not record Set-Cookie',
        () async {
      final fixture = await _Fixture.start((request, recorded) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.add('Set-Cookie', 'server=1; Path=/');
        request.response.write('ok');
        await request.response.close();
      });
      addTearDown(fixture.close);

      final jar = DebugCookieJar()..store('127.0.0.1', <String, List<String>>{
            'set-cookie': <String>['jar=present; Path=/'],
          });
      final sender = DebugSender(cookieJar: jar);
      addTearDown(sender.close);

      final response = await sender.send(
        method: 'GET',
        url: '${fixture.origin}/x',
        useCookies: false,
      );

      expect(response.error, isNull);
      expect(fixture.recorded.single.cookie, isNull,
          reason: 'useCookies=false 时绝不带 jar cookie');
      expect(jar.cookieHeaderFor('127.0.0.1'), contains('jar=present'),
          reason: 'useCookies=false 不得清空既有 jar');
      expect(
        jar.cookiesFor('127.0.0.1').map((c) => c.name),
        isNot(contains('server')),
        reason: 'useCookies=false 时响应 Set-Cookie 不写入 jar',
      );
    });

    test('default strict certificate rejects a self-signed HTTPS server',
        () async {
      final fixture = await _TlsFixture.start();
      addTearDown(fixture.close);

      final sender = DebugSender();
      addTearDown(sender.close);

      final response = await sender.send(
        method: 'GET',
        url: '${fixture.origin}/secure',
        timeout: const Duration(seconds: 5),
      );

      expect(response.statusCode, 0);
      expect(response.error, isNotNull, reason: '默认严格证书必须拒绝自签名');
    });

    test(
        'skipTlsVerify:true accepts a self-signed HTTPS server, only for that request',
        () async {
      final fixture = await _TlsFixture.start();
      addTearDown(fixture.close);

      final sender = DebugSender();
      addTearDown(sender.close);

      final ok = await sender.send(
        method: 'GET',
        url: '${fixture.origin}/secure',
        timeout: const Duration(seconds: 5),
        skipTlsVerify: true,
      );
      expect(ok.error, isNull);
      expect(ok.statusCode, 200);
      expect(ok.bodyText, 'secure-ok');

      // 紧接一个严格请求必须再次失败：跳过校验只作用于那一个请求。
      final strict = await sender.send(
        method: 'GET',
        url: '${fixture.origin}/secure',
        timeout: const Duration(seconds: 5),
      );
      expect(strict.error, isNotNull,
          reason: '跳过校验不得泄漏到后续请求（禁止全局证书绕过）');
    });
  });

  // plan todo 4：模型容错持久化（可选字段 / 缺失即默认）。
  group('DebugRequest network options round-trip', () {
    test('round-trips optional options and tolerates missing keys', () {
      final request = DebugRequest(
        id: 'r-net',
        name: 'net',
        timeoutMs: 5000,
        followRedirects: false,
        useCookieJar: false,
        skipTlsVerify: true,
      );

      final decoded = DebugRequest.fromJson(
        jsonDecode(jsonEncode(request.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.timeoutMs, 5000);
      expect(decoded.followRedirects, isFalse);
      expect(decoded.useCookieJar, isFalse);
      expect(decoded.skipTlsVerify, isTrue);

      // 旧数据缺少这些键 → 全部为 null（调用方按默认 30s/跟随/用 jar/严格）。
      final legacy = DebugRequest.fromJson(
        <String, dynamic>{'id': 'r-legacy', 'name': 'old'},
      );
      expect(legacy.timeoutMs, isNull);
      expect(legacy.followRedirects, isNull);
      expect(legacy.useCookieJar, isNull);
      expect(legacy.skipTlsVerify, isNull);
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

  // plan todo 5：请求取消 + 结构化「已取消」结果 + 幂等。
  group('DebugSender cancellation', () {
    test('aborts an in-flight request with a structured cancelled result',
        () async {
      final fixture = await _Fixture.start((request, recorded) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        try {
          request.response.statusCode = HttpStatus.ok;
          request.response.write('late');
          await request.response.close();
        } catch (_) {
          // 客户端取消后写入抛错，属预期（最佳努力）。
        }
      });
      addTearDown(fixture.close);

      final sender = DebugSender();
      addTearDown(sender.close);

      final token = DebugCancellationToken();
      final stopwatch = Stopwatch()..start();
      final pending = sender.send(
        method: 'GET',
        url: '${fixture.origin}/slow',
        timeout: const Duration(seconds: 10),
        cancelToken: token,
      );
      // 等请求真正上路后再取消。
      await Future<void>.delayed(const Duration(milliseconds: 150));
      token.cancel();

      final response = await pending;
      stopwatch.stop();

      expect(response.cancelled, isTrue,
          reason: '取消必须返回结构化 cancelled 结果');
      expect(response.error, isNull,
          reason: '取消不是错误，不得伪造成 error');
      expect(response.statusCode, 0);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)),
          reason: '取消必须尽快返回，绝不挂起');
    });

    test('cancel() is idempotent (no crash, single effect)', () {
      final token = DebugCancellationToken();
      var effects = 0;
      token.onCancel(() => effects++);

      token.cancel();
      token.cancel();
      token.cancel();

      expect(token.isCancelled, isTrue);
      expect(effects, 1, reason: '重复取消不得重复触发副作用');
    });

    test('an already-cancelled token short-circuits before any network I/O',
        () async {
      final fixture = await _Fixture.start((request, recorded) async {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      addTearDown(fixture.close);

      final sender = DebugSender();
      addTearDown(sender.close);

      final token = DebugCancellationToken()..cancel();
      final response = await sender.send(
        method: 'GET',
        url: '${fixture.origin}/never',
        cancelToken: token,
      );

      expect(response.cancelled, isTrue);
      expect(fixture.recorded, isEmpty,
          reason: '已取消的 token 必须在建立连接前短路');
    });

    test('a null token keeps the existing success shape unchanged', () async {
      final fixture = await _Fixture.start((request, recorded) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('ok');
        await request.response.close();
      });
      addTearDown(fixture.close);

      final sender = DebugSender();
      addTearDown(sender.close);

      final response = await sender.send(
        method: 'GET',
        url: '${fixture.origin}/ok',
      );

      expect(response.cancelled, isFalse);
      expect(response.error, isNull);
      expect(response.statusCode, 200);
      expect(response.bodyText, 'ok');
    });
  });
}
