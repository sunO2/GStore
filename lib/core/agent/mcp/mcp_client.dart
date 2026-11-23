/// MCP Streamable HTTP 客户端（P2-2）
///
/// 只实现工具链路所需的最小协议：
/// - initialize / notifications/initialized
/// - tools/list（含 nextCursor 分页）
/// - tools/call
///
/// 传输：HTTP POST + JSON-RPC 2.0；响应支持 `application/json` 与
/// `text/event-stream`（SSE）。会话通过 `Mcp-Session-Id` 头保持。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mcp_models.dart';

class McpClient {
  McpClient({
    required this.url,
    Map<String, String> headers = const {},
    int timeoutSeconds = 15,
    http.Client? httpClient,
  })  : headers = Map<String, String>.from(headers),
        timeout = Duration(seconds: timeoutSeconds),
        _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  final String url;
  final Map<String, String> headers;
  final Duration timeout;
  final http.Client _http;
  final bool _ownsClient;

  String? _sessionId;
  String? _protocolVersion;
  McpServerInfo? _info;
  bool _initialized = false;
  Future<McpServerInfo>? _connecting;
  int _nextId = 1;

  bool get isConnected => _initialized;
  String? get sessionId => _sessionId;
  McpServerInfo? get info => _info;

  /// 建立连接（幂等；并发调用复用同一个 future）
  Future<McpServerInfo> connect() {
    if (_initialized && _info != null) return Future.value(_info);
    final pending = _connecting;
    if (pending != null) return pending;
    final future = _doConnect();
    _connecting = future;
    return future.whenComplete(() => _connecting = null);
  }

  Future<McpServerInfo> _doConnect() async {
    Map<String, dynamic> result;
    try {
      result = await _request('initialize', {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'GStore', 'version': '1.0'},
      });
    } on McpException catch (error) {
      // 部分旧服务器只接受 2024-11-05
      if (error.code != -32602) rethrow;
      result = await _request('initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'GStore', 'version': '1.0'},
      });
    }

    _protocolVersion = result['protocolVersion']?.toString() ?? '2025-06-18';
    final serverInfo = result['serverInfo'];
    final serverName = serverInfo is Map
        ? serverInfo['name']?.toString() ?? 'MCP'
        : 'MCP';
    final serverVersion = serverInfo is Map
        ? serverInfo['version']?.toString() ?? ''
        : '';
    _info = McpServerInfo(
      protocolVersion: _protocolVersion!,
      serverName: serverName,
      serverVersion: serverVersion,
      sessionId: _sessionId,
    );
    _initialized = true;

    // 通知不需要响应；部分服务器返回 202/204 空 body
    await _notify('notifications/initialized', const <String, dynamic>{});
    return _info!;
  }

  /// 拉取全部工具（自动翻页）
  Future<List<McpToolInfo>> listTools() async {
    await connect();
    final tools = <String, McpToolInfo>{};
    String? cursor;
    for (var page = 0; page < 10; page++) {
      final result = await _request('tools/list', {
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      });
      final raw = result['tools'];
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          final tool = McpToolInfo.fromJson(
            item.map((k, v) => MapEntry(k.toString(), v)),
          );
          if (tool.name.isNotEmpty) tools[tool.name] = tool;
        }
      }
      final next = result['nextCursor']?.toString();
      if (next == null || next.isEmpty || next == cursor) break;
      cursor = next;
    }
    return tools.values.toList(growable: false);
  }

  /// 调用工具
  Future<McpCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    await connect();
    final result = await _request('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    final rawContent = result['content'];
    final content = rawContent is List ? rawContent : const <dynamic>[];
    var text = _contentText(content);
    if (text.isEmpty && result['structuredContent'] != null) {
      text = const JsonEncoder.withIndent('  ')
          .convert(result['structuredContent']);
    }
    if (text.isEmpty) text = '（工具未返回内容）';
    return McpCallResult(
      text: text,
      isError: result['isError'] == true,
      rawContent: content,
    );
  }

  Future<void> close() async {
    _initialized = false;
    _info = null;
    _sessionId = null;
    if (_ownsClient) {
      _http.close();
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = _nextId++;
    final response = await _post({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    final envelope = _decodeEnvelope(response, id);
    final error = envelope['error'];
    if (error is Map) {
      throw McpException(
        error['message']?.toString() ?? 'MCP 请求失败',
        code: (error['code'] as num?)?.toInt(),
        data: error['data'],
      );
    }
    final result = envelope['result'];
    if (result is Map) return Map<String, dynamic>.from(result);
    return <String, dynamic>{};
  }

  Future<void> _notify(String method, Map<String, dynamic> params) async {
    await _post({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
  }

  Future<http.Response> _post(Map<String, dynamic> body) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      throw McpException('无效的 MCP URL: $url');
    }
    final requestHeaders = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      ...headers,
      if (_sessionId != null && _sessionId!.isNotEmpty)
        'Mcp-Session-Id': _sessionId!,
      if (_protocolVersion != null)
        'MCP-Protocol-Version': _protocolVersion!,
    };
    final response = await _http
        .post(uri, headers: requestHeaders, body: jsonEncode(body))
        .timeout(timeout);
    final session = response.headers['mcp-session-id'];
    if (session != null && session.isNotEmpty) {
      _sessionId = session;
    }
    if (response.statusCode >= 400) {
      throw McpException(
        'HTTP ${response.statusCode}: ${_brief(response.body)}',
        code: response.statusCode,
      );
    }
    return response;
  }

  Map<String, dynamic> _decodeEnvelope(http.Response response, int id) {
    final body = response.body.trim();
    if (body.isEmpty) {
      throw McpException('MCP 返回空响应（id=$id）');
    }
    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.contains('text/event-stream')) {
      return _pickEnvelope(jsonDecode(body), id);
    }

    final events = <dynamic>[];
    final buffer = StringBuffer();
    for (final line in const LineSplitter().convert(body)) {
      if (line.isEmpty) {
        if (buffer.isNotEmpty) {
          events.add(_tryDecode(buffer.toString()));
          buffer.clear();
        }
        continue;
      }
      if (line.startsWith('data:')) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(line.substring(5).trimLeft());
      }
    }
    if (buffer.isNotEmpty) events.add(_tryDecode(buffer.toString()));

    for (final event in events) {
      if (event == null) continue;
      final envelope = _tryPick(event, id);
      if (envelope != null) return envelope;
    }
    throw McpException('SSE 响应中没有 id=$id 的 JSON-RPC 消息');
  }

  dynamic _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _pickEnvelope(dynamic decoded, int id) {
    final envelope = _tryPick(decoded, id);
    if (envelope == null) {
      throw McpException('JSON-RPC 响应缺少 id=$id');
    }
    return envelope;
  }

  Map<String, dynamic>? _tryPick(dynamic decoded, int id) {
    if (decoded is List) {
      for (final item in decoded) {
        final picked = _tryPick(item, id);
        if (picked != null) return picked;
      }
      return null;
    }
    if (decoded is Map) {
      final map = decoded.map((k, v) => MapEntry(k.toString(), v));
      final rawId = map['id'];
      if (rawId is num && rawId.toInt() == id) return map;
      if (rawId is String && rawId == id.toString()) return map;
    }
    return null;
  }

  String _contentText(List<dynamic> content) {
    final parts = <String>[];
    for (final item in content) {
      if (item is! Map) {
        final text = item?.toString() ?? '';
        if (text.isNotEmpty) parts.add(text);
        continue;
      }
      final type = item['type']?.toString() ?? '';
      switch (type) {
        case 'text':
          final text = item['text']?.toString() ?? '';
          if (text.isNotEmpty) parts.add(text);
          break;
        case 'resource':
          final resource = item['resource'];
          if (resource is Map) {
            parts.add('[resource] ${resource['uri'] ?? ''}'.trim());
          } else {
            parts.add('[resource]');
          }
          break;
        case 'image':
          parts.add('[image ${item['mimeType'] ?? ''}]'.trim());
          break;
        case 'audio':
          parts.add('[audio ${item['mimeType'] ?? ''}]'.trim());
          break;
        default:
          if (type.isNotEmpty) parts.add('[$type]');
      }
    }
    return parts.join('\n');
  }

  String _brief(String text) {
    final value = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return value.length > 200 ? '${value.substring(0, 200)}…' : value;
  }
}
