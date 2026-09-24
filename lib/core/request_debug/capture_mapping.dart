/// 「抓包记录 → DebugRequest」映射（plan todo 35，纯函数）。
///
/// 抓包侧（`lib/page/proxy`）与请求调试侧（`lib/core/request_debug`）之间的
/// **字段翻译**：把一条完整 [CaptureDetail]（`captures.detail` 响应）映射为
/// 可保存 / 可重发的 [DebugRequest]。
///
/// 覆盖字段：`method` / `url` / `headers` / `body` / `bodyKind` / `cookies`。
/// 不触碰 FFI / 网络 / 存储；无副作用、可独立单测。
///
/// 设计取舍：
/// * `Cookie` 头既保留在 [DebugRequest.headers]（忠实还原抓包请求），又解析为
///   [DebugRequest.cookies]（供编辑器展示 / 后续 cookie jar 复用）——两者不冲突
///   （[DebugSender] 只按 headers 发送，忽略 cookies 列表）。
/// * Body 用 UTF-8 容错解码；`bodyKind` 依据请求 `Content-Type` 推断，缺省时
///   若正文可解析为 JSON 也归类为 [DebugBodyKind.json]。
/// * **重发编码归一**：抓包 `reqBody` 是代理侧已解码的明文，重发时绝不能沿用
///   上游 `Content-Encoding`（否则对明文再次解压 → 无效请求）。[normalizeReplayHeaders]
///   负责剥离编码声明并修正 `Content-Length`，与 Rust `force_plaintext_body_headers`
///   的「明文 ⇒ 无内容编码 + 长度按实际体计算」规则一致。
library;

import 'dart:convert';

import 'package:gstore/core/rust/proxy/ProxyContract.dart';

import 'debug_models.dart';

/// 把一条抓包详情映射为 [DebugRequest]。
///
/// [id] / [name] / [collectionId] 可由调用方显式指定；缺省时自动生成 id 与
/// 可读名称（如 `POST /api/login`）。
DebugRequest debugRequestFromCapture(
  CaptureDetail detail, {
  String? id,
  String? name,
  String? collectionId,
}) {
  final headers = parseCapturedHeaderText(detail.reqHeaders);
  final bodyBytes = detail.reqBody;
  final body = bodyBytes.isEmpty
      ? ''
      : utf8.decode(bodyBytes, allowMalformed: true);
  final requestContentType = _headerValue(headers, 'content-type') ??
      detail.contentType;

  return DebugRequest(
    id: id ?? generateDebugId('req'),
    name: name ?? defaultCaptureRequestName(detail),
    method: _normalizeMethod(detail.method),
    url: captureRequestUrl(detail),
    headers: normalizeReplayHeaders(headers, body),
    body: body,
    bodyKind: inferDebugBodyKind(requestContentType, body),
    cookies: parseCookieHeader(_headerValue(headers, 'cookie') ?? ''),
    collectionId: collectionId,
  );
}

/// 重发头归一化：抓包 body 已在代理侧解码为明文，因此
///
/// * 剥离全部 `Content-Encoding` 头（明文不得再声明 gzip/br/…）；
/// * 若原头含 `Content-Length`，改写为**实际发送**的明文字节数
///   （`utf8.encode(body).length`），并去掉重复声明；
/// * 其余头原样保留（含未提供的 `Content-Length`——缺省时由发送器按 body 计算）。
///
/// 与 Rust `force_plaintext_body_headers` 语义一致：明文 body ⇒
/// 无内容编码 + 长度与实际体一致。
List<DebugHeader> normalizeReplayHeaders(
  List<DebugHeader> headers,
  String body, {
  int? bodyByteLength,
}) {
  final length = bodyByteLength ?? utf8.encode(body).length;
  final result = <DebugHeader>[];
  var lengthRewritten = false;
  for (final header in headers) {
    final name = header.name.trim().toLowerCase();
    if (name == 'content-encoding') {
      continue;
    }
    if (name == 'content-length') {
      if (lengthRewritten) continue;
      lengthRewritten = true;
      result.add(header.copyWith(value: '$length'));
      continue;
    }
    result.add(header);
  }
  return result;
}

/// 抓包请求的最终 URL：优先 [CaptureDetail.url]，缺省按 `scheme://host+path`。
String captureRequestUrl(CaptureDetail detail) {
  final url = detail.url.trim();
  if (url.isNotEmpty) return url;
  final host = detail.host.trim();
  if (host.isEmpty) return '';
  final scheme = detail.scheme.trim().isEmpty ? 'https' : detail.scheme.trim();
  return '$scheme://$host${detail.path}';
}

/// 抓包请求的默认名称（如 `POST /api/login`，退化到 host / method）。
String defaultCaptureRequestName(CaptureDetail detail) {
  final method = _normalizeMethod(detail.method);
  final path = detail.path.trim();
  if (path.isNotEmpty) return '$method $path';
  final host = detail.host.trim();
  if (host.isNotEmpty) return '$method $host';
  final url = detail.url.trim();
  if (url.isNotEmpty) return '$method $url';
  return method;
}

/// 解析抓包 `reqHeaders` 原文为 [DebugHeader] 列表。
///
/// * 以 `\r?\n` 分行；空行忽略；
/// * 以空白开头的行并入上一行（HTTP 折行）；
/// * 无 `:` 的行忽略（不臆造头）。
List<DebugHeader> parseCapturedHeaderText(String raw) {
  final result = <DebugHeader>[];
  final buffer = StringBuffer();
  var pendingName = '';
  var started = false;

  void flush() {
    if (started && pendingName.isNotEmpty) {
      result.add(DebugHeader(name: pendingName, value: buffer.toString().trim()));
    }
    buffer.clear();
    pendingName = '';
    started = false;
  }

  for (final line in raw.split(RegExp(r'\r?\n'))) {
    if (line.trim().isEmpty) continue;
    if ((line.startsWith(' ') || line.startsWith('\t')) && started) {
      buffer.write(' ${line.trim()}');
      continue;
    }
    flush();
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    pendingName = line.substring(0, idx).trim();
    buffer.write(line.substring(idx + 1).trim());
    started = true;
  }
  flush();
  return result;
}

/// 解析 `Cookie` 头值（`a=1; b=2`）为 [DebugCookie] 列表。
List<DebugCookie> parseCookieHeader(String raw) {
  final cookies = <DebugCookie>[];
  for (final part in raw.split(';')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final idx = trimmed.indexOf('=');
    if (idx <= 0) continue;
    final name = trimmed.substring(0, idx).trim();
    if (name.isEmpty) continue;
    cookies.add(DebugCookie(
      name: name,
      value: trimmed.substring(idx + 1).trim(),
    ));
  }
  return cookies;
}

/// 依据 `Content-Type` 与正文推断 [DebugBodyKind]。
DebugBodyKind inferDebugBodyKind(String contentType, String body) {
  if (body.isEmpty) return DebugBodyKind.none;
  final ct = contentType.toLowerCase();
  if (ct.contains('multipart/form-data')) return DebugBodyKind.multipart;
  if (ct.contains('application/x-www-form-urlencoded')) {
    return DebugBodyKind.formUrlEncoded;
  }
  if (ct.contains('json')) return DebugBodyKind.json;
  if (ct.contains('application/octet-stream') || ct.contains('image/')) {
    return DebugBodyKind.binary;
  }
  final trimmed = body.trimLeft();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      jsonDecode(body);
      return DebugBodyKind.json;
    } on FormatException {
      // 落入 text。
    }
  }
  return DebugBodyKind.text;
}

String _normalizeMethod(String method) {
  final trimmed = method.trim();
  return trimmed.isEmpty ? 'GET' : trimmed.toUpperCase();
}

String? _headerValue(List<DebugHeader> headers, String lowerName) {
  for (final header in headers) {
    if (header.name.toLowerCase() == lowerName) {
      return header.value;
    }
  }
  return null;
}
