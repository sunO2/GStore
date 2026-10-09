/// todo 1：认证真正生效（发送 + cURL 往返）端到端测试。
///
/// 覆盖验收：
/// - 纯函数 [applyAuth]：Basic / Bearer / APIKey(header|query)，无认证时不变；
/// - 真实 `dart:io` `HttpServer` fixture：经真实发送路径断言服务端实际收到
///   `Authorization` 头 / `?api_key=` 查询；
/// - `toCurl → parseCurl → applyAuth → send` 往返等价（各认证类型）；
/// - 无认证时 toCurl 输出与既有格式一致（characterization）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/auth_apply.dart';
import 'package:gstore/core/request_debug/curl_codec.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/page/request_debug/request_editor_page.dart';

/// 服务端实际收到的一次请求（防「假绿」）。
class _Recorded {
  _Recorded(HttpRequest request)
      : method = request.method,
        path = request.uri.path,
        query = request.uri.query,
        authorization = request.headers.value('authorization'),
        apiKeyHeader = request.headers.value('x-api-key');

  final String method;
  final String path;
  final String query;
  final String? authorization;
  final String? apiKeyHeader;
}

/// 极简 `HttpServer` fixture：记录请求后返回 200。
class _Fixture {
  _Fixture._(this._server);

  final HttpServer _server;
  final List<_Recorded> recorded = <_Recorded>[];
  late final StreamSubscription<HttpRequest> _sub;

  int get port => _server.port;
  String get origin => 'http://127.0.0.1:$port';

  static Future<_Fixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _Fixture._(server);
    fixture._sub = server.listen((request) async {
      fixture.recorded.add(_Recorded(request));
      await request.toList();
      try {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('ok');
        await request.response.close();
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

/// 真实发送路径：仅发送启用的 header / query（与 `DebugSender` 语义一致）。
Future<DebugResponse> _send(
  DebugSender sender,
  String url,
  AuthApplication applied, {
  String method = 'GET',
}) =>
    sender.send(
      method: method,
      url: url,
      headers: applied.headers,
      query: applied.query,
    );

/// `toCurl → parseCurl → applyAuth → send` 往返，返回服务端记录的请求。
Future<_Recorded> _roundTripSend(_Fixture fixture, DebugRequest req) async {
  final curl = toCurl(req);
  final parsed = parseCurl(curl);
  expect(parsed.isSuccess, isTrue, reason: parsed.error);
  final back = parsed.request!;
  final applied = applyAuth(
    auth: back.auth,
    headers: back.headers,
    query: back.query,
  );
  final sender = DebugSender();
  try {
    final response = await _send(
      sender,
      back.url,
      applied,
      method: back.method,
    );
    expect(response.error, isNull, reason: '往返发送不应失败：$curl');
  } finally {
    sender.close();
  }
  return fixture.recorded.last;
}

/// 假发送器：记录每次发送参数，返回受控响应；**不触碰网络**。
class _FakeSender implements DebugSender {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  @override
  final DebugCookieJar cookieJar = DebugCookieJar();

  @override
  Future<DebugResponse> send({
    required String method,
    required String url,
    List<DebugHeader> headers = const <DebugHeader>[],
    List<DebugQueryParam> query = const <DebugQueryParam>[],
    String body = '',
    List<int>? bodyBytes,
    bool followRedirects = true,
    Duration? timeout,
    bool useCookies = true,
    bool skipTlsVerify = false,
    DebugCancellationToken? cancelToken,
  }) async {
    calls.add(<String, Object?>{
      'method': method,
      'url': url,
      'headers': headers
          .where((h) => h.enabled && h.name.isNotEmpty)
          .map((h) => '${h.name}:${h.value}')
          .toList(),
      'query': query
          .where((q) => q.enabled && q.name.isNotEmpty)
          .map((q) => '${q.name}=${q.value}')
          .toList(),
    });
    return const DebugResponse(statusCode: 200, bodyText: 'ok', sizeBytes: 2);
  }

  @override
  void close() {}
}

class _RecordingFacade extends DefaultRequestDebugFacade {
  _RecordingFacade({required DebugSender debugSender})
      : super(
          store: RequestDebugStore(
            directoryProvider: () async => Directory.systemTemp,
          ),
          sender: debugSender,
        );

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_test 默认安装 mock HttpClient（所有请求返回 400），本文件的真实
  // `dart:io` HttpServer fixture 需要恢复真实网络栈。
  setUp(() {
    HttpOverrides.global = null;
  });

  group('applyAuth（纯函数）', () {
    test('auth 为 null：headers / query 内容不变', () {
      final out = applyAuth(
        auth: null,
        headers: const <DebugHeader>[DebugHeader(name: 'X-A', value: '1')],
        query: const <DebugQueryParam>[DebugQueryParam(name: 'a', value: '1')],
      );
      expect(out.headers.map((h) => '${h.name}:${h.value}'), <String>['X-A:1']);
      expect(out.query.map((q) => '${q.name}=${q.value}'), <String>['a=1']);
    });

    test('auth 类型为 none：不变', () {
      final out = applyAuth(
        auth: const DebugAuth(type: DebugAuthType.none),
        headers: const <DebugHeader>[DebugHeader(name: 'X-A', value: '1')],
        query: const <DebugQueryParam>[DebugQueryParam(name: 'a', value: '1')],
      );
      expect(out.headers.single.name, 'X-A');
      expect(out.query.single.name, 'a');
    });

    test('Basic：注入 Authorization: Basic <base64(user:pass)>', () {
      final out = applyAuth(
        auth: const DebugAuth(
          type: DebugAuthType.basic,
          username: 'alice',
          password: 's3cr3t',
        ),
      );
      expect(out.headers.single.name, 'Authorization');
      expect(
        out.headers.single.value,
        'Basic ${base64Encode(utf8.encode('alice:s3cr3t'))}',
      );
      expect(out.query, isEmpty);
    });

    test('Basic：覆盖已有 Authorization 头（保留位置）', () {
      final out = applyAuth(
        auth: const DebugAuth(
          type: DebugAuthType.basic,
          username: 'u',
          password: 'p',
        ),
        headers: const <DebugHeader>[
          DebugHeader(name: 'X-A', value: '1'),
          DebugHeader(name: 'authorization', value: 'Bearer stale'),
          DebugHeader(name: 'X-B', value: '2'),
        ],
      );
      expect(out.headers.length, 3);
      expect(out.headers[1].name, 'authorization');
      expect(out.headers[1].value, 'Basic ${base64Encode(utf8.encode('u:p'))}');
    });

    test('Bearer：注入 Authorization: Bearer <token>', () {
      final out = applyAuth(
        auth: const DebugAuth(type: DebugAuthType.bearer, token: 'tok-123'),
      );
      expect(out.headers.single.name, 'Authorization');
      expect(out.headers.single.value, 'Bearer tok-123');
    });

    test('APIKey header：注入命名为 apiKeyName 的头', () {
      final out = applyAuth(
        auth: const DebugAuth(
          type: DebugAuthType.apiKey,
          apiKeyName: 'X-Api-Key',
          apiKeyValue: 'v-1',
          apiKeyIn: 'header',
        ),
      );
      expect(out.headers.single.name, 'X-Api-Key');
      expect(out.headers.single.value, 'v-1');
      expect(out.query, isEmpty);
    });

    test('APIKey query：合并进 query 且同名覆盖', () {
      final out = applyAuth(
        auth: const DebugAuth(
          type: DebugAuthType.apiKey,
          apiKeyName: 'api_key',
          apiKeyValue: 'v2',
          apiKeyIn: 'query',
        ),
        query: const <DebugQueryParam>[
          DebugQueryParam(name: 'api_key', value: 'old'),
          DebugQueryParam(name: 'b', value: '1'),
        ],
      );
      expect(out.query.map((q) => '${q.name}=${q.value}'),
          <String>['api_key=v2', 'b=1']);
      expect(out.headers, isEmpty);
    });

    test('APIKey 名为空：不注入', () {
      final out = applyAuth(
        auth: const DebugAuth(
          type: DebugAuthType.apiKey,
          apiKeyName: '',
          apiKeyValue: 'v',
          apiKeyIn: 'header',
        ),
        headers: const <DebugHeader>[DebugHeader(name: 'X-A', value: '1')],
      );
      expect(out.headers.single.name, 'X-A');
    });
  });

  group('发送路径（真实 HttpServer）', () {
    test('Basic：服务端收到 Authorization: Basic', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      final applied = applyAuth(
        auth: const DebugAuth(
          type: DebugAuthType.basic,
          username: 'alice',
          password: 's3cr3t',
        ),
      );
      final response = await _send(sender, '${fixture.origin}/basic', applied);
      expect(response.error, isNull);

      final recorded = fixture.recorded.single;
      expect(
        recorded.authorization,
        'Basic ${base64Encode(utf8.encode('alice:s3cr3t'))}',
      );
    });

    test('Bearer：服务端收到 Authorization: Bearer', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      final applied = applyAuth(
        auth: const DebugAuth(type: DebugAuthType.bearer, token: 'tok-abc'),
      );
      await _send(sender, '${fixture.origin}/bearer', applied);

      expect(fixture.recorded.single.authorization, 'Bearer tok-abc');
    });

    test('APIKey(header)：服务端收到命名头', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      final applied = applyAuth(
        auth: const DebugAuth(
          type: DebugAuthType.apiKey,
          apiKeyName: 'X-Api-Key',
          apiKeyValue: 'k-9',
          apiKeyIn: 'header',
        ),
      );
      await _send(sender, '${fixture.origin}/apikey', applied);

      expect(fixture.recorded.single.apiKeyHeader, 'k-9');
      expect(fixture.recorded.single.authorization, isNull);
    });

    test('APIKey(query)：服务端收到 ?api_key=', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      final applied = applyAuth(
        auth: const DebugAuth(
          type: DebugAuthType.apiKey,
          apiKeyName: 'api_key',
          apiKeyValue: 'q-7',
          apiKeyIn: 'query',
        ),
      );
      await _send(sender, '${fixture.origin}/apikey', applied);

      final recorded = fixture.recorded.single;
      expect(recorded.query, 'api_key=q-7');
      expect(recorded.authorization, isNull);
      expect(recorded.apiKeyHeader, isNull);
    });

    test('无认证：服务端不收到任何 Authorization / api_key', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      final applied = applyAuth(auth: null);
      await _send(sender, '${fixture.origin}/none', applied);

      final recorded = fixture.recorded.single;
      expect(recorded.authorization, isNull);
      expect(recorded.apiKeyHeader, isNull);
      expect(recorded.query, isEmpty);
    });
  });

  group('cURL 往返（toCurl → parseCurl → applyAuth → send）', () {
    DebugRequest request(String url, DebugAuth auth) => DebugRequest(
          id: 'r-rt',
          name: 'rt',
          method: 'GET',
          url: url,
          auth: auth,
        );

    test('Basic', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final recorded = await _roundTripSend(
        fixture,
        request(
          '${fixture.origin}/rt-basic',
          const DebugAuth(
            type: DebugAuthType.basic,
            username: 'bob',
            password: 'pw',
          ),
        ),
      );
      expect(recorded.authorization,
          'Basic ${base64Encode(utf8.encode('bob:pw'))}');
    });

    test('Bearer', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final recorded = await _roundTripSend(
        fixture,
        request(
          '${fixture.origin}/rt-bearer',
          const DebugAuth(type: DebugAuthType.bearer, token: 'bt-1'),
        ),
      );
      expect(recorded.authorization, 'Bearer bt-1');
    });

    test('APIKey(header)', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final recorded = await _roundTripSend(
        fixture,
        request(
          '${fixture.origin}/rt-hdr',
          const DebugAuth(
            type: DebugAuthType.apiKey,
            apiKeyName: 'X-Api-Key',
            apiKeyValue: 'hk-1',
            apiKeyIn: 'header',
          ),
        ),
      );
      expect(recorded.apiKeyHeader, 'hk-1');
      expect(recorded.authorization, isNull);
    });

    test('APIKey(query)', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final recorded = await _roundTripSend(
        fixture,
        request(
          '${fixture.origin}/rt-q',
          const DebugAuth(
            type: DebugAuthType.apiKey,
            apiKeyName: 'api_key',
            apiKeyValue: 'qk-1',
            apiKeyIn: 'query',
          ),
        ),
      );
      expect(recorded.query, 'api_key=qk-1');
    });

    test('parseCurl 反向还原 -u → DebugAuth.basic', () {
      final r = parseCurl("curl 'https://x.test/' -u 'alice:s3cr3t'");
      expect(r.isSuccess, isTrue, reason: r.error);
      final auth = r.request!.auth;
      expect(auth, isNotNull);
      expect(auth!.type, DebugAuthType.basic);
      expect(auth.username, 'alice');
      expect(auth.password, 's3cr3t');
      // 不再作为普通 header 泄漏。
      expect(
        r.request!.headers.where((h) => h.name.toLowerCase() == 'authorization'),
        isEmpty,
      );
    });

    test('parseCurl 反向还原 --oauth2-bearer → DebugAuth.bearer', () {
      final r = parseCurl("curl 'https://x.test/' --oauth2-bearer 'tok-9'");
      expect(r.isSuccess, isTrue, reason: r.error);
      final auth = r.request!.auth;
      expect(auth, isNotNull);
      expect(auth!.type, DebugAuthType.bearer);
      expect(auth.token, 'tok-9');
    });

    test('parseCurl 反向还原 Authorization: Bearer 头 → DebugAuth.bearer', () {
      final r = parseCurl(
        "curl 'https://x.test/' -H 'Authorization: Bearer hdr-tok'",
      );
      expect(r.isSuccess, isTrue, reason: r.error);
      final auth = r.request!.auth;
      expect(auth, isNotNull);
      expect(auth!.type, DebugAuthType.bearer);
      expect(auth.token, 'hdr-tok');
    });

    test('parseCurl 反向还原 Authorization: Basic 头 → DebugAuth.basic', () {
      final encoded = base64Encode(utf8.encode('u:p'));
      final r = parseCurl("curl 'https://x.test/' -H 'Authorization: Basic $encoded'");
      expect(r.isSuccess, isTrue, reason: r.error);
      final auth = r.request!.auth;
      expect(auth, isNotNull);
      expect(auth!.type, DebugAuthType.basic);
      expect(auth.username, 'u');
      expect(auth.password, 'p');
    });
  });

  group('无认证特征化（characterization）', () {
    test('toCurl 无认证输出与既有格式一致', () {
      final req = DebugRequest(
        id: 'r-noauth',
        name: 'n',
        method: 'GET',
        url: 'https://x.test/p',
      );
      expect(toCurl(req), "curl -X 'GET' 'https://x.test/p'");
    });

    test('parseCurl 对无认证 curl 产出 auth=null', () {
      final r = parseCurl("curl -X 'GET' 'https://x.test/p'");
      expect(r.isSuccess, isTrue, reason: r.error);
      expect(r.request!.auth, isNull);
    });

    test('无认证往返后 send 语义不变', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final recorded = await _roundTripSend(
        fixture,
        DebugRequest(
          id: 'r-noauth-rt',
          name: 'n',
          method: 'GET',
          url: '${fixture.origin}/plain',
          headers: const <DebugHeader>[DebugHeader(name: 'X-A', value: '1')],
        ),
      );
      expect(recorded.authorization, isNull);
      expect(recorded.apiKeyHeader, isNull);
      expect(recorded.query, isEmpty);
    });
  });

  group('编辑器 _send 应用认证（widget）', () {
    testWidgets('Basic 认证随发送到达 sender', (tester) async {
      final sender = _FakeSender();
      final facade = _RecordingFacade(debugSender: sender);
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-auth-send',
          name: 'auth',
          method: 'GET',
          url: 'https://api.example/v1',
          auth: const DebugAuth(
            type: DebugAuthType.basic,
            username: 'alice',
            password: 's3cr3t',
          ),
        ),
      );

      await tester.pumpWidget(MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: RequestEditorPage(
          facade: facade,
          request: request,
          collectionId: collection.id,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pumpAndSettle();

      expect(sender.calls, hasLength(1));
      final headers = sender.calls.single['headers']! as List;
      expect(
        headers,
        contains(
          'Authorization:Basic ${base64Encode(utf8.encode('alice:s3cr3t'))}',
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('APIKey(query) 随发送到达 sender', (tester) async {
      final sender = _FakeSender();
      final facade = _RecordingFacade(debugSender: sender);
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-auth-q',
          name: 'authq',
          method: 'GET',
          url: 'https://api.example/v1',
          auth: const DebugAuth(
            type: DebugAuthType.apiKey,
            apiKeyName: 'api_key',
            apiKeyValue: 'q-1',
            apiKeyIn: 'query',
          ),
        ),
      );

      await tester.pumpWidget(MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: RequestEditorPage(
          facade: facade,
          request: request,
          collectionId: collection.id,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pumpAndSettle();

      final query = sender.calls.single['query']! as List;
      expect(query, contains('api_key=q-1'));
      expect(tester.takeException(), isNull);
    });
  });
}
