import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/mcp/mcp_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('MCP initialize/list/call（JSON + SSE + session 头）', () async {
    final requests = <http.Request>[];
    final mock = MockClient((request) async {
      requests.add(request);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final method = body['method']?.toString();
      final id = body['id'];
      switch (method) {
        case 'initialize':
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'protocolVersion': '2025-06-18',
                'capabilities': {'tools': {}},
                'serverInfo': {'name': 'Mock MCP', 'version': '1.0'},
              },
            }),
            200,
            headers: {
              'content-type': 'application/json',
              'mcp-session-id': 'sess-1',
            },
          );
        case 'notifications/initialized':
          return http.Response('', 202);
        case 'tools/list':
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'tools': [
                  {
                    'name': 'echo',
                    'description': 'Echo text',
                    'inputSchema': {
                      'type': 'object',
                      'properties': {
                        'text': {'type': 'string', 'description': 'text'},
                      },
                      'required': ['text'],
                    },
                    'annotations': {'readOnlyHint': true},
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        case 'tools/call':
          final params = body['params'] as Map;
          final sse = 'event: message\n'
              'data: ${jsonEncode({
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'content': [
                    {'type': 'text', 'text': 'echo:${params['arguments']['text']}'},
                  ],
                  'isError': false,
                },
              })}\n\n';
          return http.Response(
            sse,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        default:
          return http.Response('not found', 404);
      }
    });

    final client = McpClient(
      url: 'https://mcp.example/mcp',
      headers: const {'Authorization': 'Bearer token'},
      httpClient: mock,
    );

    final info = await client.connect();
    expect(info.serverName, 'Mock MCP');
    expect(client.sessionId, 'sess-1');

    final tools = await client.listTools();
    expect(tools, hasLength(1));
    expect(tools.single.name, 'echo');
    expect(tools.single.readOnly, isTrue);

    final result = await client.callTool('echo', {'text': 'hi'});
    expect(result.isError, isFalse);
    expect(result.text, 'echo:hi');

    // 后续请求带 session 与自定义头
    final listRequest =
        requests.firstWhere((r) => r.body.contains('tools/list'));
    expect(listRequest.headers['Mcp-Session-Id'], 'sess-1');
    expect(listRequest.headers['Authorization'], 'Bearer token');

    await client.close();
  });

  test('JSON-RPC error 抛 McpException', () async {
    final mock = MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      if (body['method'] == 'initialize') {
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': body['id'],
            'error': {'code': -32601, 'message': 'no tools'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('', 202);
    });
    final client = McpClient(
      url: 'https://mcp.example/mcp',
      httpClient: mock,
    );
    await expectLater(
      client.connect(),
      throwsA(isA<Exception>().having(
        (e) => e.toString(),
        'message',
        contains('no tools'),
      )),
    );
  });
}
