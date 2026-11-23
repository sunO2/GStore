/// MCP（Model Context Protocol）客户端数据模型
library;

/// 一台远程 MCP 服务器配置
class McpServerConfig {
  McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    Map<String, String>? headers,
    this.enabled = true,
    this.timeoutSeconds = 15,
  }) : headers = headers ?? <String, String>{};

  final String id;
  String name;
  String url;

  /// 额外请求头（如 Authorization: Bearer ...）
  Map<String, String> headers;

  bool enabled;

  /// 单次请求超时（秒）
  int timeoutSeconds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'headers': headers,
        'enabled': enabled,
        'timeoutSeconds': timeoutSeconds,
      };

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    final rawHeaders = json['headers'];
    return McpServerConfig(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'MCP',
      url: json['url']?.toString() ?? '',
      headers: rawHeaders is Map
          ? rawHeaders.map((k, v) => MapEntry(k.toString(), v.toString()))
          : const <String, String>{},
      enabled: json['enabled'] as bool? ?? true,
      timeoutSeconds: (json['timeoutSeconds'] as num?)?.toInt() ?? 15,
    );
  }
}

/// MCP 服务器初始化结果
class McpServerInfo {
  const McpServerInfo({
    required this.protocolVersion,
    required this.serverName,
    required this.serverVersion,
    this.sessionId,
  });

  final String protocolVersion;
  final String serverName;
  final String serverVersion;
  final String? sessionId;
}

/// MCP 工具描述（tools/list）
class McpToolInfo {
  const McpToolInfo({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.readOnly = false,
  });

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;

  /// 服务器 annotations.readOnlyHint（不可全信；仅用于展示/排序）
  final bool readOnly;

  factory McpToolInfo.fromJson(Map<String, dynamic> json) {
    final schema = json['inputSchema'];
    final annotations = json['annotations'];
    return McpToolInfo(
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      inputSchema: schema is Map
          ? schema.map((k, v) => MapEntry(k.toString(), v))
          : const <String, Object?>{},
      readOnly: annotations is Map && annotations['readOnlyHint'] == true,
    );
  }
}

/// MCP tools/call 结果
class McpCallResult {
  const McpCallResult({
    required this.text,
    required this.isError,
    required this.rawContent,
  });

  final String text;
  final bool isError;
  final List<dynamic> rawContent;
}

/// MCP 协议/传输错误
class McpException implements Exception {
  McpException(this.message, {this.code, this.data});

  final String message;
  final int? code;
  final Object? data;

  @override
  String toString() =>
      'McpException${code == null ? '' : '($code)'}: $message';
}
