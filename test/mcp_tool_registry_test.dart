import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/core/agent/mcp/mcp_models.dart';
import 'package:gstore/core/agent/mcp/mcp_tool_registry.dart';

void main() {
  test('工具名稳定且符合 function-calling 规则', () {
    final name = McpToolRegistry.specName('Server Id!', 'Get.Weather');
    expect(name, 'mcp__server_id__get_weather');
    expect(name.length, lessThanOrEqualTo(64));
    expect(RegExp(r'^[a-z0-9_]+$').hasMatch(name), isTrue);
  });

  test('McpToolInfo → AgentToolSpec 保留原始 schema 与服务器绑定', () {
    final server = McpServerConfig(
      id: 'weather',
      name: 'Weather',
      url: 'https://mcp.example/mcp',
    );
    final tool = McpToolInfo(
      name: 'get_weather',
      description: 'Get weather by city',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'city': {'type': 'string', 'description': '城市'},
        },
        'required': ['city'],
      },
      readOnly: true,
    );
    final spec = McpToolRegistry.toSpec(server: server, tool: tool);
    expect(spec.mcp, isTrue);
    expect(spec.mcpServerId, 'weather');
    expect(spec.mcpToolName, 'get_weather');
    expect(spec.alwaysSensitive, isTrue);
    expect(spec.group, AgentToolGroup.mcp);
    final schema = spec.inputJsonSchema;
    expect(schema['type'], 'object');
    expect((schema['properties'] as Map)['city'], isNotNull);
  });

  test('运行时注册/注销 MCP 工具', () {
    final server = McpServerConfig(
      id: 's',
      name: 'S',
      url: 'https://mcp.example/mcp',
    );
    final spec = McpToolRegistry.toSpec(
      server: server,
      tool: const McpToolInfo(
        name: 't',
        description: 'd',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
    );
    AgentToolCatalog.register(spec);
    expect(AgentToolCatalog.byName(spec.name), isNotNull);
    AgentToolCatalog.unregister(spec.name);
    expect(AgentToolCatalog.byName(spec.name), isNull);
  });
}
