import 'package:flutter_gen_ai_chat_ui/flutter_gen_ai_chat_ui.dart'
    show ActionController, ActionParameterType;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/core/webview/webview_session_service.dart';

class _FakeWebViewService extends WebViewSessionService {
  Map<String, dynamic>? last;
  int calls = 0;

  @override
  Future<String> handle(Map<String, dynamic> params) async {
    calls++;
    last = params;
    return 'fake webView:${params['action']}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('webView 已注册且不是只读工具', () {
    final spec = AgentToolCatalog.byName('webView');
    expect(spec, isNotNull);
    expect(spec!.readOnly, false);
    expect(spec.maxResultChars, 64000);
    expect(
        spec.params.map((p) => p.name),
        containsAll([
          'action',
          'url',
          'script',
          'selector',
          'filter',
        ]));
  });

  test('int/json 参数与 function-calling schema 类型一致（不再报 must be a string）', () {
    final agent = AgentService();
    addTearDown(agent.dispose);
    final webView = agent.buildActions().firstWhere((a) => a.name == 'webView');

    for (final name in [
      'settleMs',
      'timeoutMs',
      'maxChars',
      'limit',
      'index',
      'ms'
    ]) {
      final parameter = webView.parameters.firstWhere((p) => p.name == name);
      expect(parameter.type, ActionParameterType.number, reason: name);
    }
    expect(
      webView.validateParameters({
        'action': 'requests',
        'filter': 'api',
        'limit': 50,
        'includeBodies': true,
      }),
      isEmpty,
    );
    expect(
      webView.validateParameters({
        'action': 'open',
        'url': 'https://example.com',
        'settleMs': 700,
        'timeoutMs': 20000,
      }),
      isEmpty,
    );

    final http =
        agent.buildActions().firstWhere((a) => a.name == 'httpRequest');
    expect(
      http.parameters.firstWhere((p) => p.name == 'headers').type,
      ActionParameterType.object,
    );
    expect(
      http.parameters.firstWhere((p) => p.name == 'json').type,
      ActionParameterType.object,
    );
    expect(
      http.validateParameters({
        'url': 'https://example.com/api',
        'method': 'POST',
        'headers': {'Authorization': 'Bearer x'},
        'json': {'q': 'x'},
      }),
      isEmpty,
    );
  });

  test('模型把数字/JSON 参数写成字符串时自动归一化', () {
    final agent = AgentService();
    addTearDown(agent.dispose);
    final webViewSpec = AgentToolCatalog.byName('webView')!;
    final normalized = agent.debugNormalizeParams({
      'action': 'content',
      'maxChars': '6000',
      'settleMs': '700',
      'includeBodies': 'true',
    }, webViewSpec);

    expect(normalized['maxChars'], 6000);
    expect(normalized['settleMs'], 700);
    expect(normalized['includeBodies'], true);

    final webView = agent.buildActions().firstWhere((a) => a.name == 'webView');
    expect(webView.validateParameters(normalized), isEmpty);

    final httpSpec = AgentToolCatalog.byName('httpRequest')!;
    final httpParams = agent.debugNormalizeParams({
      'url': 'https://example.com',
      'headers': '{"Authorization":"Bearer x"}',
    }, httpSpec);
    expect(httpParams['headers'], isA<Map>());
    expect((httpParams['headers'] as Map)['Authorization'], 'Bearer x');
  });

  test('content maxChars 被模型写成字符串时仍能通过 ActionController', () async {
    final fake = _FakeWebViewService();
    WebViewSessionService.debugSetInstance(fake);
    addTearDown(() => WebViewSessionService.debugSetInstance(null));

    final agent = AgentService();
    addTearDown(agent.dispose);
    final spec = AgentToolCatalog.byName('webView')!;
    final action = agent.buildActions().firstWhere((a) => a.name == 'webView');
    final normalized = agent.debugNormalizeParams({
      'action': 'content',
      'maxChars': '6000',
    }, spec);
    final controller = ActionController()..registerAction(action);

    final result = await controller.executeAction('webView', normalized);

    expect(result.success, isTrue, reason: result.error);
    expect(fake.last?['maxChars'], 6000);
  });

  test('ActionController 接受 numeric limit（回归：must be a string）', () async {
    final fake = _FakeWebViewService();
    WebViewSessionService.debugSetInstance(fake);
    addTearDown(() => WebViewSessionService.debugSetInstance(null));

    final agent = AgentService();
    addTearDown(agent.dispose);
    final action = agent.buildActions().firstWhere((a) => a.name == 'webView');
    final controller = ActionController()..registerAction(action);

    final result = await controller.executeAction('webView', {
      'action': 'requests',
      'filter': 'api',
      'limit': 50,
      'includeBodies': true,
    });

    expect(result.success, isTrue, reason: result.error);
    expect(fake.last?['limit'], 50);
  });

  test('webView 工具把参数原样交给会话服务', () async {
    final fake = _FakeWebViewService();
    WebViewSessionService.debugSetInstance(fake);
    addTearDown(() => WebViewSessionService.debugSetInstance(null));

    final agent = AgentService();
    addTearDown(agent.dispose);
    final action = agent.buildActions().firstWhere((a) => a.name == 'webView');
    final result = await action.handler({
      'action': 'requests',
      'filter': '/api/',
      'includeBodies': true,
    });

    expect(fake.calls, 1);
    expect(fake.last?['action'], 'requests');
    expect(fake.last?['filter'], '/api/');
    expect((result.data as Map)['result'], 'fake webView:requests');
  });
}
