import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/core/agent/mcp/mcp_client.dart';
import 'package:gstore/core/agent/mcp/mcp_server_store.dart';
import 'package:gstore/core/agent/mcp/mcp_tool_registry.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Client _mockMcp() {
  return MockClient((request) async {
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
              'serverInfo': {'name': 'Mock', 'version': '1'},
            },
          }),
          200,
          headers: {
            'content-type': 'application/json',
            'mcp-session-id': 's1',
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
                      'text': {'type': 'string'},
                    },
                    'required': ['text'],
                  },
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      case 'tools/call':
        final params = body['params'] as Map;
        return http.Response(
          'data: ${jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'content': [
                {'type': 'text', 'text': 'echo:${params['arguments']['text']}'},
              ],
            },
          })}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      default:
        return http.Response('', 404);
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MCP 服务器发现工具 → 注册到 catalog → 调用', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await McpServerStore.load();
    final server = await store.add(
      name: 'Mock',
      url: 'https://mcp.example/mcp',
    );

    final agent = AgentService()
      ..debugMcpClientFactory =
          (config) => McpClient(url: config.url, httpClient: _mockMcp());

    try {
      await agent.debugSyncMcpTools(store);

      final specName = McpToolRegistry.specName(server.id, 'echo');
      final spec = AgentToolCatalog.byName(specName);
      expect(spec, isNotNull);
      expect(spec!.mcp, isTrue);
      expect(spec.mcpServerId, server.id);
      expect(spec.mcpToolName, 'echo');
      expect(spec.inputJsonSchema['type'], 'object');

      final output = await agent.debugCallMcpTool(spec, {'text': 'hi'});
      expect(output, 'echo:hi');
    } finally {
      AgentToolCatalog.unregister(McpToolRegistry.specName(server.id, 'echo'));
      agent.dispose();
    }
  });
}
