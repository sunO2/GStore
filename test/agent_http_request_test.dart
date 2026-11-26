import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
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
  });

  tearDown(() {
    WebSearchService.debugSetInstance(null);
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
