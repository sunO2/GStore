/// MCP 工具 → AgentToolSpec 的映射（P2-2）
library;

import 'dart:convert';

import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';

import 'mcp_models.dart';

class McpToolRegistry {
  McpToolRegistry._();

  static const String namePrefix = 'mcp__';

  /// 稳定、符合 function-calling 命名规则的名称（≤64，[a-z0-9_-]）
  static String specName(String serverId, String toolName) {
    final raw =
        '$namePrefix${_slug(serverId, 22)}__${_slug(toolName, 36)}';
    if (raw.length <= 64) return raw;
    return raw.substring(0, 64);
  }

  static AgentToolSpec toSpec({
    required McpServerConfig server,
    required McpToolInfo tool,
  }) {
    final name = specName(server.id, tool.name);
    final description = tool.description.trim().isEmpty
        ? tool.name
        : tool.description.trim();
    return AgentToolSpec(
      name: name,
      group: AgentToolGroup.mcp,
      label: '${server.name}: ${tool.name}',
      brief: '[${server.name}] ${_brief(description)}',
      protocol: '''
MCP 工具（服务器：${server.name}）
工具名：${tool.name}
说明：$description
服务器地址：${server.url}
输入参数（JSON Schema）：
${const JsonEncoder.withIndent('  ').convert(tool.inputSchema)}
''',
      params: const <AgentToolParam>[],
      rawInputJsonSchema: tool.inputSchema,
      mcp: true,
      mcpServerId: server.id,
      mcpToolName: tool.name,
      // 外部工具默认按敏感处理：模型必须先 confirmAction，且页面需在前台
      alwaysSensitive: true,
      enabled: server.enabled,
    );
  }

  /// 由 JSON Schema 反推 UI/AiAction 的参数（MCP 执行不依赖它，仅用于展示/兼容）
  static List<AgentToolParam> paramsFromSchema(Map<String, Object?>? schema) {
    if (schema == null) return const <AgentToolParam>[];
    final properties = schema['properties'];
    if (properties is! Map) return const <AgentToolParam>[];
    final required = <String>{
      if (schema['required'] is List)
        for (final item in schema['required'] as List) item.toString(),
    };
    final params = <AgentToolParam>[];
    properties.forEach((key, value) {
      final name = key.toString();
      final map = value is Map
          ? value.map((k, v) => MapEntry(k.toString(), v))
          : const <String, dynamic>{};
      final type = _paramType(map['type'], map.containsKey('properties'));
      params.add(AgentToolParam(
        name: name,
        description: map['description']?.toString() ?? '',
        required: required.contains(name),
        type: type,
      ));
    });
    return params;
  }

  static String _paramType(Object? raw, bool hasProperties) {
    switch (raw?.toString()) {
      case 'integer':
        return 'int';
      case 'number':
        return 'int';
      case 'boolean':
        return 'bool';
      case 'object':
        return 'json';
      case 'array':
        return 'json';
      default:
        return hasProperties ? 'json' : 'string';
    }
  }

  static String _slug(String input, int max) {
    var value = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    value = value.replaceAll(RegExp(r'^_+|_+$'), '');
    if (value.isEmpty) value = 'x';
    if (value.length > max) value = value.substring(0, max);
    return value;
  }

  static String _brief(String text) {
    final value = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return value.length > 120 ? '${value.substring(0, 120)}…' : value;
  }
}
