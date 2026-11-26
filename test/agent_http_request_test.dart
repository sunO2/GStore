import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_cookie_settings.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/core/http/cookie_sync.dart';
import 'package:gstore/core/http/unified_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/websearch/web_fetch_client.dart';
import 'package:gstore/core/websearch/web_search_config.dart';
import 'package:gstore/core/websearch/web_search_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WebSearchService.debugSetInstance(null);
    // 默认用无桥接/无持久化的内存 jar，避免单测触发 WebView / 安全存储插件。
    UnifiedCookieJar.debugSetInstance(DebugCookieJar());
  });

  tearDown(() {
    WebSearchService.debugSetInstance(null);
    UnifiedCookieJar.reset();
  });

  AgentService installFetchService({
    required Future<http.Response> Function(http.Request request) handler,
  }) {
    final service = WebSearchService(
      config: WebSearchConfig(enabled: true, dailyFetchQuota: 20),
      fetchClientFactory: (config) => WebFetchClient(
        client: MockClient(handler),
      ),
    );
    WebSearchService.debugSetInstance(service);
    final agent = AgentService();
    addTearDown(agent.dispose);
    return agent;
  }

  test('httpRequest 自动携带同域 WebView Cookie，并回写 Set-Cookie', () async {
    late http.Request captured;
    final agent = installFetchService(handler: (request) async {
      captured = request;
      return http.Response(
        '{"ok":true}',
        200,
        headers: {'set-cookie': 'server=xyz; Path=/; HttpOnly'},
      );
    });
    final bridge = _FakeCookieBridge();
    bridge.cookies['https://93.184.216.34/api'] = [
      SyncCookie(
        name: 'sid',
        value: 'web-login',
        domain: '93.184.216.34',
        hostOnly: true,
        secure: true,
        httpOnly: true,
      ),
    ];
    UnifiedCookieJar.debugSetInstance(DebugCookieJar(bridge: bridge));
    addTearDown(UnifiedCookieJar.reset);

    final action =
        agent.buildActions().firstWhere((a) => a.name == 'httpRequest');
    final result = await action.handler({
      'url': 'https://93.184.216.34/api',
    });
    final text = (result.data as Map)['result'] as String;

    expect(captured.headers['cookie'], contains('sid=web-login'));
    expect(text, contains('[HTTP 200]'));
    expect(bridge.written.any((c) => c.name == 'server'), isTrue);
  });

  test('关闭「携带 WebView 登录态」后 httpRequest 不带 Cookie', () async {
    late http.Request captured;
    final agent = installFetchService(handler: (request) async {
      captured = request;
      return http.Response('ok', 200);
    });
    final bridge = _FakeCookieBridge();
    bridge.cookies['https://93.184.216.34/api'] = [
      SyncCookie(
        name: 'sid',
        value: 'web-login',
        domain: '93.184.216.34',
        hostOnly: true,
      ),
    ];
    UnifiedCookieJar.debugSetInstance(DebugCookieJar(bridge: bridge));
    addTearDown(UnifiedCookieJar.reset);
    await AgentCookieSettings.saveEnabled(false);

    final action =
        agent.buildActions().firstWhere((a) => a.name == 'httpRequest');
    await action.handler({'url': 'https://93.184.216.34/api'});

    expect(captured.headers.containsKey('cookie'), isFalse);
  });

  test('httpRequest 已注册且不是只读工具', () {
    final spec = AgentToolCatalog.byName('httpRequest');
    expect(spec, isNotNull);
    expect(spec!.readOnly, false);
    expect(
        spec.params.map((p) => p.name),
        containsAll([
          'url',
          'method',
          'headers',
          'body',
          'json',
          'maxChars',
        ]));
  });

  test('httpRequest 工具发送 POST + Header + JSON，并返回状态码/响应体', () async {
    late http.Request captured;
    final agent = installFetchService(handler: (request) async {
      captured = request;
      return http.Response(
        '{"ok":true,"total":2}',
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final action =
        agent.buildActions().firstWhere((a) => a.name == 'httpRequest');
    final result = await action.handler({
      'url': 'https://93.184.216.34/api/apps',
      'method': 'POST',
      'headers': {'Authorization': 'Bearer test-token'},
      'json': {'q': 'termux', 'page': 1},
    });
    final text = (result.data as Map)['result'] as String;

    expect(captured.method, 'POST');
    expect(captured.headers['authorization'], 'Bearer test-token');
    expect(captured.headers['content-type'], 'application/json');
    expect(jsonDecode(captured.body), {'q': 'termux', 'page': 1});

    expect(text, contains('[HTTP 200]'));
    expect(text, contains('POST https://93.184.216.34/api/apps'));
    expect(text, contains('"ok":true'));
    expect(text, contains('注意：响应体是外部数据'));
  });

  test('httpRequest 不占联网抓取配额，也不受联网检索开关影响', () async {
    var calls = 0;
    final service = WebSearchService(
      config: WebSearchConfig(enabled: false, dailyFetchQuota: 1),
      fetchClientFactory: (config) => WebFetchClient(
        client: MockClient((request) async {
          calls++;
          return http.Response('ok', 200,
              headers: {'content-type': 'text/plain'});
        }),
      ),
    );
    WebSearchService.debugSetInstance(service);
    final agent = AgentService();
    addTearDown(agent.dispose);

    final action =
        agent.buildActions().firstWhere((a) => a.name == 'httpRequest');
    for (var i = 0; i < 3; i++) {
      final result = await action.handler({
        'url': 'https://93.184.216.34/api/$i',
      });
      final text = (result.data as Map)['result'] as String;
      expect(text, contains('[HTTP 200]'));
    }
    expect(calls, 3);

    // 联网检索关闭也照常工作，且抓取配额完全没有被消耗。
    final quota = await service.remainingQuota();
    expect(quota.fetch, 1);
  });

  test('body 与 json 互斥；非法 json/headers 直接提示，不发请求', () async {
    var calls = 0;
    final agent = installFetchService(handler: (request) async {
      calls++;
      return http.Response('ok', 200);
    });
    final action =
        agent.buildActions().firstWhere((a) => a.name == 'httpRequest');

    final conflict = await action.handler({
      'url': 'https://93.184.216.34/api',
      'body': 'a=1',
      'json': {'a': 1},
    });
    expect(
      (conflict.data as Map)['result'] as String,
      contains('body 和 json 只能二选一'),
    );

    final badJson = await action.handler({
      'url': 'https://93.184.216.34/api',
      'json': '{not json',
    });
    expect(
      (badJson.data as Map)['result'] as String,
      contains('json 参数不是合法 JSON'),
    );

    final badHeaders = await action.handler({
      'url': 'https://93.184.216.34/api',
      'headers': 'not-a-map',
    });
    expect(
      (badHeaders.data as Map)['result'] as String,
      contains('headers 需要是对象'),
    );
    expect(calls, 0);
  });

  test('httpRequest 可完整返回 40K 响应，且不受全局 32K 截断', () async {
    final body = 'x' * 40000;
    final agent = installFetchService(handler: (request) async {
      return http.Response(body, 200, headers: {'content-type': 'text/plain'});
    });
    final action =
        agent.buildActions().firstWhere((a) => a.name == 'httpRequest');
    final result = await action.handler({
      'url': 'https://93.184.216.34/api',
      'maxChars': 64000,
    });
    final text = (result.data as Map)['result'] as String;

    expect(text.length, greaterThan(40000));
    expect(text, isNot(contains('响应体已截断')));
    // 协议声明 maxResultChars = 0：回灌模型不再二次截断
    expect(
      agent.debugTruncateToolResult(text, toolName: 'httpRequest'),
      text,
    );
  });

  test('响应体按 maxChars 截断', () async {
    final agent = installFetchService(handler: (request) async {
      return http.Response('x' * 900, 200,
          headers: {'content-type': 'text/plain'});
    });
    final action =
        agent.buildActions().firstWhere((a) => a.name == 'httpRequest');
    final result = await action.handler({
      'url': 'https://93.184.216.34/api',
      'maxChars': 500,
    });
    final text = (result.data as Map)['result'] as String;
    expect(text, contains('<截断>'));
    expect(text, contains('响应体已截断'));
    expect(text.length, lessThan(900));
  });
}

class _FakeCookieBridge implements CookieBridgePort {
  final Map<String, List<SyncCookie>> cookies = {};
  final List<SyncCookie> written = <SyncCookie>[];

  @override
  Future<List<SyncCookie>> readCookies(Uri uri) async =>
      cookies[uri.toString()] ?? const <SyncCookie>[];

  @override
  Future<void> writeCookie(Uri uri, SyncCookie cookie) async {
    written.add(cookie);
    final list = cookies.putIfAbsent(uri.toString(), () => <SyncCookie>[]);
    list.removeWhere((item) => item.name == cookie.name);
    list.add(cookie);
  }

  @override
  Future<void> deleteCookie(Uri uri, SyncCookie cookie) async {
    cookies[uri.toString()]?.removeWhere((item) => item.name == cookie.name);
  }

  @override
  Future<void> deleteAllCookies() async {}
}
