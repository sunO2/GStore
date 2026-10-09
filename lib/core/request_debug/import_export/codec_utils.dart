/// 「请求调试」导入 / 导出：跨格式共享的纯辅助函数（plan todo 16）。
///
/// 仅依赖模型与 `dart:convert`，无 IO / UI / 平台通道。
library;

import 'dart:convert';

import 'package:gstore/core/request_debug/debug_models.dart';

/// 合并 base URL 与**启用**的 query 参数为完整 URL（禁用项忽略）。
String debugFullUrl(String url, List<DebugQueryParam> query) {
  final pairs = <String>[];
  for (final q in query) {
    if (!q.enabled || q.name.isEmpty) continue;
    pairs.add(
      '${Uri.encodeQueryComponent(q.name)}=${Uri.encodeQueryComponent(q.value)}',
    );
  }
  if (pairs.isEmpty) return url;
  final String separator;
  if (!url.contains('?')) {
    separator = '?';
  } else if (url.endsWith('?') || url.endsWith('&')) {
    separator = '';
  } else {
    separator = '&';
  }
  return '$url$separator${pairs.join('&')}';
}

/// 完整 URL 拆分为 base URL + query 列表（`?` 之后部分）。
({String url, List<DebugQueryParam> query}) debugSplitUrl(String fullUrl) {
  final idx = fullUrl.indexOf('?');
  if (idx < 0) return (url: fullUrl, query: const <DebugQueryParam>[]);
  final base = fullUrl.substring(0, idx);
  final query = <DebugQueryParam>[];
  for (final part in fullUrl.substring(idx + 1).split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    final name = eq < 0 ? part : part.substring(0, eq);
    final value = eq < 0 ? '' : part.substring(eq + 1);
    query.add(
      DebugQueryParam(
        name: _safeDecode(name),
        value: _safeDecode(value),
      ),
    );
  }
  return (url: base, query: query);
}

String _safeDecode(String value) {
  try {
    return Uri.decodeQueryComponent(value);
  } on ArgumentError {
    return value;
  } on FormatException {
    return value;
  }
}

/// 请求体类型 → 建议 MIME（`none` 返回空串）。
String debugMimeOf(DebugBodyKind kind) => switch (kind) {
      DebugBodyKind.none => '',
      DebugBodyKind.json => 'application/json',
      DebugBodyKind.text => 'text/plain; charset=utf-8',
      DebugBodyKind.formUrlEncoded =>
        'application/x-www-form-urlencoded',
      DebugBodyKind.multipart => 'multipart/form-data',
      DebugBodyKind.binary => 'application/octet-stream',
    };

/// MIME / Content-Type → 请求体类型（未知降级为 [DebugBodyKind.text]；
/// 空 MIME 返回 [DebugBodyKind.none]）。
DebugBodyKind debugBodyKindFromMime(String? mime) {
  if (mime == null || mime.trim().isEmpty) return DebugBodyKind.none;
  final m = mime.toLowerCase();
  if (m.contains('json')) return DebugBodyKind.json;
  if (m.contains('x-www-form-urlencoded')) {
    return DebugBodyKind.formUrlEncoded;
  }
  if (m.contains('multipart/form-data')) return DebugBodyKind.multipart;
  if (m.contains('octet-stream')) return DebugBodyKind.binary;
  return DebugBodyKind.text;
}

/// 从响应 / 请求头列表中取首个匹配（大小写不敏感）的头值；缺失返回 `null`。
String? debugHeaderValue(List<DebugHeader> headers, String name) {
  final lower = name.toLowerCase();
  for (final h in headers) {
    if (h.name.toLowerCase() == lower) return h.value;
  }
  return null;
}

/// 解析 `name=value&...` 文本为键值对（供 form-urlencoded 映射）。
List<({String key, String value})> debugParseFormPairs(String text) {
  final out = <({String key, String value})>[];
  for (final part in text.split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    final key = eq < 0 ? part : part.substring(0, eq);
    final value = eq < 0 ? '' : part.substring(eq + 1);
    out.add((key: _safeDecode(key), value: _safeDecode(value)));
  }
  return out;
}

/// 尝试把文本按 JSON 解析；失败返回原文本（OpenAPI example 用）。
Object? debugTryJson(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  try {
    return jsonDecode(trimmed);
  } on FormatException {
    return text;
  }
}

// ==================== 容错读取辅助 ====================

/// 取字符串字段；非字符串 → 空串。
String debugStr(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

/// 取可空字符串；`null` → `null`，其余 `toString`。
String? debugStrOrNull(Object? value) {
  if (value == null) return null;
  return value is String ? value : value.toString();
}

/// 取整数字段；非数字 → `fallback`。
int debugInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}
