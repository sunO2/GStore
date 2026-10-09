/// 抓包 → HAR 1.2 导出（plan todo 35，**纯 Dart**）。
///
/// ## 位置决策
/// **纯 Dart**：由 `captures.detail`（[CaptureDetail]，`API.md` §2.18）在 Dart 侧
/// 拼装标准 HAR 1.2，**不新增 Rust 契约方法**。理由：
/// * 抓包数据已经由 `captures.detail` 完整投递（含完整 body / 头 / url / 时间），
///   Rust 侧再写一份 HAR 只会重复数据面；
/// * 复用既有 T16 HAR 约定（`log.version` / `creator` / `entries`），产出标准
///   HAR，可被 `decodeHar`（`import_export/har_codec.dart`）**原样读回**；
/// * 无 FFI / 平台通道依赖，可纯单测。
///
/// ## 不重复请求 Tree
/// 导出为**扁平** `log.entries`：每条抓包 → 一条 entry，直接取自 [CaptureDetail]，
/// 不另建集合 / 文件夹树，也不嵌入 `_gstore` 私有请求快照。
///
/// ## 大 / 二进制 body
/// * 文本 body：UTF-8 容错解码进 `text`（大 body 原样，不截断）；
/// * 疑似二进制：base64 进 `text` 并置 `encoding: "base64"`，绝不崩。
library;

import 'dart:convert';

import 'package:gstore/core/rust/proxy/ProxyContract.dart';

/// 抓包详情列表 → HAR 1.2 JSON 文本。
///
/// [creatorName] / [creatorVersion] 写入 `log.creator`（默认 GStore 标识）。
/// 空列表产出合法的空 HAR（`entries: []`）。
String encodeCaptureHar(
  List<CaptureDetail> captures, {
  String creatorName = 'GStore Proxy Capture',
  String creatorVersion = '1.0',
}) {
  final entries = <Map<String, dynamic>>[
    for (final capture in captures) _entry(capture),
  ];
  final document = <String, dynamic>{
    'log': <String, dynamic>{
      'version': '1.2',
      'creator': <String, dynamic>{
        'name': creatorName,
        'version': creatorVersion,
      },
      'entries': entries,
    },
  };
  return const JsonEncoder.withIndent('  ').convert(document);
}

// ==================== entry 组装 ====================

Map<String, dynamic> _entry(CaptureDetail capture) {
  final url = captureUrl(capture);
  final reqHeaderPairs = _parseHeaderPairs(capture.reqHeaders);
  final respHeaderPairs = _parseHeaderPairs(capture.respHeaders);
  final reqMime = _firstHeader(reqHeaderPairs, 'content-type') ?? '';
  final reqBodySize = capture.reqBytes > 0 ? capture.reqBytes : capture.reqBody.length;
  final respBodySize =
      capture.respBytes > 0 ? capture.respBytes : capture.respBody.length;
  final postData = _postData(capture.reqBody, reqMime);

  return <String, dynamic>{
    'startedDateTime': _isoUtc(capture.startedAtMs),
    'time': capture.durationMs,
    'request': <String, dynamic>{
      'method': capture.method.trim().isEmpty ? 'GET' : capture.method,
      'url': url,
      'httpVersion': _httpVersion(capture.protocol),
      'cookies': _requestCookies(reqHeaderPairs),
      'headers': <Map<String, dynamic>>[
        for (final h in reqHeaderPairs)
          <String, dynamic>{'name': h.$1, 'value': h.$2},
      ],
      'queryString': _queryString(url),
      if (postData != null) 'postData': postData,
      'headersSize': -1,
      'bodySize': reqBodySize,
    },
    'response': <String, dynamic>{
      'status': capture.statusCode,
      'statusText': '',
      'httpVersion': _httpVersion(capture.protocol),
      'cookies': _responseCookies(respHeaderPairs),
      'headers': <Map<String, dynamic>>[
        for (final h in respHeaderPairs)
          <String, dynamic>{'name': h.$1, 'value': h.$2},
      ],
      'content': _content(capture.respBody, capture.contentType, respBodySize),
      'redirectURL': _firstHeader(respHeaderPairs, 'location') ?? '',
      'headersSize': -1,
      'bodySize': respBodySize,
    },
    'cache': <String, dynamic>{},
    'timings': <String, dynamic>{
      'send': 0,
      'wait': capture.durationMs,
      'receive': 0,
    },
  };
}

/// 抓包详情的最终 URL：优先 `url`，缺省按 `scheme://host` 回退（与详情页一致）。
String captureUrl(CaptureDetail detail) {
  final url = detail.url.trim();
  if (url.isNotEmpty) return url;
  final host = detail.host.trim();
  if (host.isEmpty) return '';
  final scheme = detail.scheme.trim().isEmpty ? 'https' : detail.scheme.trim();
  return '$scheme://$host${detail.path}';
}

// ==================== body ====================

Map<String, dynamic>? _postData(List<int> bytes, String mime) {
  if (bytes.isEmpty) return null;
  final data = <String, dynamic>{'mimeType': mime};
  if (_looksBinary(bytes)) {
    data['encoding'] = 'base64';
    data['text'] = base64Encode(bytes);
  } else {
    data['text'] = utf8.decode(bytes, allowMalformed: true);
  }
  return data;
}

Map<String, dynamic> _content(List<int> bytes, String mime, int declaredSize) {
  final size = declaredSize > 0 ? declaredSize : bytes.length;
  final data = <String, dynamic>{'size': size, 'mimeType': mime};
  if (bytes.isEmpty) return data;
  if (_looksBinary(bytes)) {
    data['encoding'] = 'base64';
    data['text'] = base64Encode(bytes);
  } else {
    data['text'] = utf8.decode(bytes, allowMalformed: true);
  }
  return data;
}

/// 是否疑似二进制（含 NUL，或控制字符占比 > 10%）。
bool _looksBinary(List<int> bytes) {
  if (bytes.isEmpty) return false;
  const sample = 1024;
  final n = bytes.length > sample ? sample : bytes.length;
  var controls = 0;
  for (var i = 0; i < n; i++) {
    final b = bytes[i];
    if (b == 0) return true;
    final isText = b == 9 || b == 10 || b == 13 || (b >= 32 && b != 127);
    if (!isText) controls++;
  }
  return controls * 10 > n;
}

// ==================== URL / 头 / Cookie / 时间 ====================

/// 解析 URL 查询串为 HAR `queryString`（解码失败回退原文）。
List<Map<String, dynamic>> _queryString(String url) {
  final query = Uri.tryParse(url)?.queryParametersAll ?? const {};
  return <Map<String, dynamic>>[
    for (final entry in query.entries)
      for (final value in entry.value)
        <String, dynamic>{'name': entry.key, 'value': value},
  ];
}

/// 解析 `Name: value` 头文本为 `(name, value)` 列表（续行以空白开头时并入）。
List<(String, String)> _parseHeaderPairs(String raw) {
  final result = <(String, String)>[];
  String? name;
  final buffer = StringBuffer();

  void flush() {
    if (name != null) result.add((name!, buffer.toString().trim()));
    name = null;
    buffer.clear();
  }

  for (final line in raw.split(RegExp(r'\r?\n'))) {
    if (line.trim().isEmpty) continue;
    if ((line.startsWith(' ') || line.startsWith('\t')) && name != null) {
      buffer.write(' ${line.trim()}');
      continue;
    }
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    flush();
    name = line.substring(0, idx).trim();
    buffer.write(line.substring(idx + 1).trim());
  }
  flush();
  return result;
}

String? _firstHeader(List<(String, String)> headers, String lowerName) {
  for (final h in headers) {
    if (h.$1.toLowerCase() == lowerName) return h.$2;
  }
  return null;
}

List<Map<String, dynamic>> _requestCookies(List<(String, String)> headers) {
  final out = <Map<String, dynamic>>[];
  for (final h in headers) {
    if (h.$1.toLowerCase() != 'cookie') continue;
    for (final part in h.$2.split(';')) {
      final pair = part.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      out.add(<String, dynamic>{
        'name': pair.substring(0, eq).trim(),
        'value': pair.substring(eq + 1).trim(),
      });
    }
  }
  return out;
}

List<Map<String, dynamic>> _responseCookies(List<(String, String)> headers) {
  final out = <Map<String, dynamic>>[];
  for (final h in headers) {
    if (h.$1.toLowerCase() != 'set-cookie') continue;
    final parts = h.$2.split(';');
    if (parts.isEmpty) continue;
    final nameValue = parts.first.trim();
    final eq = nameValue.indexOf('=');
    if (eq <= 0) continue;
    final cookie = <String, dynamic>{
      'name': nameValue.substring(0, eq).trim(),
      'value': nameValue.substring(eq + 1).trim(),
    };
    for (final attr in parts.skip(1)) {
      final trimmed = attr.trim();
      final colon = trimmed.indexOf('=');
      if (colon <= 0) continue;
      final key = trimmed.substring(0, colon).trim().toLowerCase();
      final value = trimmed.substring(colon + 1).trim();
      if (key == 'domain') cookie['domain'] = value;
      if (key == 'path') cookie['path'] = value;
      if (key == 'expires') cookie['expires'] = value;
      if (key == 'max-age' && int.tryParse(value) != null) {
        cookie['maxAge'] = int.parse(value);
      }
      if (key == 'httponly') cookie['httpOnly'] = true;
      if (key == 'secure') cookie['secure'] = true;
    }
    out.add(cookie);
  }
  return out;
}

String _httpVersion(String protocol) => switch (protocol.toLowerCase()) {
      'h2' => 'HTTP/2',
      _ => 'HTTP/1.1',
    };

String _isoUtc(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();
