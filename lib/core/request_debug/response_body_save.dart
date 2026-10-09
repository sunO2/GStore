/// 「请求调试」响应体存盘纯逻辑（plan todo 18）。
///
/// 决定写入磁盘的**字节**与建议文件名；实际文件选择 / 写入由页面层接缝
/// （`saveDebugResponseBody`）负责。纯函数、无 IO。
library;

import 'dart:convert';

import 'debug_response.dart';

/// 待存盘的响应体字节。
///
/// **优先返回原始字节** [DebugResponse.bodyBytes]，保证二进制 / 文本均
/// **逐字节一致**（含无可解码内容）。仅在无原始字节（如历史快照还原）时，
/// 回退为 [DebugResponse.bodyText] 的 UTF-8 编码。
List<int> responseBodyBytesForSave(DebugResponse response) {
  if (response.bodyBytes.isNotEmpty) return List<int>.of(response.bodyBytes);
  return utf8.encode(response.bodyText);
}

/// 依据 `Content-Type` 推断建议的文件名（含扩展名）。
String suggestResponseBodyFileName(DebugResponse response) {
  final mime = _contentTypeOf(response);
  return 'response-body${_extensionFor(mime)}';
}

String? _contentTypeOf(DebugResponse response) {
  for (final entry in response.headers.entries) {
    if (entry.key.toLowerCase() == 'content-type' && entry.value.isNotEmpty) {
      final value = entry.value.first;
      if (value.isEmpty) return null;
      return value.split(';').first.trim().toLowerCase();
    }
  }
  return null;
}

String _extensionFor(String? mime) {
  if (mime == null) return '.bin';
  if (mime == 'application/json' ||
      mime == 'text/json' ||
      mime.endsWith('+json')) {
    return '.json';
  }
  if (mime == 'application/xml' ||
      mime == 'text/xml' ||
      mime.endsWith('+xml')) {
    return '.xml';
  }
  if (mime == 'text/html' || mime == 'application/xhtml+xml') return '.html';
  if (mime == 'text/plain') return '.txt';
  return '.bin';
}
