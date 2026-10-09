/// 「请求调试」原始 HTTP 编解码（plan todo 16）。
///
/// **纯函数**：`List<DebugRequest>` ⇄ `.http` / REST Client 风格文本。多请求以
/// `###`（可跟名称）分隔；请求行为 `METHOD <绝对 URL> HTTP/1.1`，其后为头，
/// 空行后为请求体。只输出启用头；bodyKind 由 Content-Type 或 JSON 启发式还原。
library;

import 'dart:convert';

import 'package:gstore/core/request_debug/debug_models.dart';

import 'codec_utils.dart';
import 'import_export_types.dart';

/// 请求列表 → 原始 HTTP 文本。
String encodeRawHttp(List<DebugRequest> requests) {
  final blocks = <String>[];
  for (final request in requests) {
    final buffer = StringBuffer();
    final name = request.name.isEmpty ? request.url : request.name;
    buffer.writeln('### $name');
    buffer.writeln(
      '${request.method} ${debugFullUrl(request.url, request.query)} HTTP/1.1',
    );
    for (final header in request.headers) {
      if (!header.enabled || header.name.isEmpty) continue;
      buffer.writeln('${header.name}: ${header.value}');
    }
    if (request.body.isNotEmpty) {
      buffer.writeln();
      buffer.write(request.body);
    }
    blocks.add(buffer.toString().trimRight());
  }
  return blocks.join('\n\n');
}

/// 原始 HTTP 文本 → 请求列表（非法 / 无请求行 → 结构化失败）。
DebugTransferResult<List<DebugRequest>> decodeRawHttp(String text) {
  if (text.trim().isEmpty) {
    return const DebugTransferResult.failure(
      DebugTransferError(DebugTransferErrorKind.empty, '原始 HTTP 内容为空'),
    );
  }
  final normalized = text.replaceAll('\r\n', '\n');
  final lines = const LineSplitter().convert(normalized);

  final requests = <DebugRequest>[];
  var name = '';
  var block = <String>[];

  void flush() {
    if (block.isEmpty) return;
    final request = _parseBlock(block, name);
    if (request != null) requests.add(request);
    block = <String>[];
    name = '';
  }

  for (final line in lines) {
    if (line.trimLeft().startsWith('###')) {
      flush();
      name = line.trimLeft().substring(3).trim();
      continue;
    }
    block.add(line);
  }
  flush();

  if (requests.isEmpty) {
    return const DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidStructure,
        '未找到合法的 HTTP 请求行（应为 METHOD URL HTTP/1.1）',
      ),
    );
  }
  return DebugTransferResult.success(requests);
}

DebugRequest? _parseBlock(List<String> lines, String name) {
  var i = 0;
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  if (i >= lines.length) return null;

  final parts = lines[i].trim().split(RegExp(r'\s+'));
  i++;
  if (parts.length < 2) return null;
  final method = parts[0];
  if (!RegExp(r'^[A-Z]+$').hasMatch(method)) return null;
  final target = parts[1];
  if (target.isEmpty) return null;

  final headers = <DebugHeader>[];
  while (i < lines.length && lines[i].trim().isNotEmpty) {
    final idx = lines[i].indexOf(':');
    if (idx > 0) {
      headers.add(
        DebugHeader(
          name: lines[i].substring(0, idx).trim(),
          value: lines[i].substring(idx + 1).trim(),
        ),
      );
    }
    i++;
  }
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  final body = lines.sublist(i).join('\n').replaceFirst(RegExp(r'\n+$'), '');

  final String url;
  if (target.startsWith('http://') || target.startsWith('https://')) {
    url = target;
  } else {
    final host = debugHeaderValue(headers, 'host') ?? '';
    url = host.isEmpty ? target : 'https://$host$target';
  }
  final split = debugSplitUrl(url);

  return DebugRequest(
    id: generateDebugId('req'),
    name: name,
    method: method,
    url: split.url,
    query: split.query,
    headers: headers,
    body: body,
    bodyKind: _kindFrom(headers, body),
  );
}

DebugBodyKind _kindFrom(List<DebugHeader> headers, String body) {
  final mime = debugHeaderValue(headers, 'content-type');
  if (mime != null && mime.trim().isNotEmpty) {
    return debugBodyKindFromMime(mime);
  }
  if (body.trim().isEmpty) return DebugBodyKind.none;
  // 无 Content-Type：JSON 启发式（合法 JSON → json，否则 text）。
  try {
    jsonDecode(body);
    return DebugBodyKind.json;
  } on FormatException {
    return DebugBodyKind.text;
  }
}
