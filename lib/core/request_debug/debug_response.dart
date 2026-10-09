/// 「请求调试」响应建模（纯逻辑，无 UI）。
///
/// `DebugSender` 把一次发送的原始结果（状态码 / 头 / 字节 / 耗时 / 可选错误）
/// 归一化为本文件的 [DebugResponse]，供 UI 展示与「保存为请求」复用。
///
/// 有界策略：**文本预览限长**（[DebugResponse.maxTextPreviewChars]），
/// 原始字节由发送器按 [DebugSender.maxBodyBytes] 截断，避免无界保留大 Body。
library;

import 'dart:convert';

import 'debug_cookie_jar.dart';
import 'debug_models.dart';

/// 一次请求调试发送的响应快照。
class DebugResponse {
  const DebugResponse({
    this.statusCode = 0,
    this.headers = const <String, List<String>>{},
    this.bodyBytes = const <int>[],
    this.bodyText = '',
    this.cookies = const <DebugCookie>[],
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.error,
    this.cancelled = false,
    this.truncated = false,
  });

  /// HTTP 状态码；失败 / 出错时为 0。
  final int statusCode;

  /// 响应头（键小写；多值头为列表，如 `set-cookie`）。
  final Map<String, List<String>> headers;

  /// 原始响应体字节（发送器按上限截断；不含则空）。
  final List<int> bodyBytes;

  /// 响应体的**限长**文本预览（UTF-8，允许畸形字节）。
  final String bodyText;

  /// 响应携带的 Set-Cookie 解析结果（视图）。
  final List<DebugCookie> cookies;

  /// 端到端耗时（毫秒）。
  final int durationMs;

  /// 实际收到的响应体字节数。
  ///
  /// 优先采用 `Content-Length` 声明的**真实大小**；响应未声明长度（如分块
  /// 传输）时才回退为已读字节数（[bodyBytes] 的长度，截断时即读取上限）。
  final int sizeBytes;

  /// 响应体是否因超过读取上限（`DebugSender.maxBodyBytes`）而被截断。
  ///
  /// 截断后 [bodyBytes] / [bodyText] 只含前 N 字节，但 [sizeBytes] 仍为真实
  /// 大小；UI 据此标注「已截断」。
  final bool truncated;

  /// 结构化错误（连接失败 / 超时为非 null；出错时不抛异常）。
  final String? error;

  /// 是否因调用方**主动取消**而提前结束。
  ///
  /// 取消是独立于成功 / 错误的第三种结构化结果：[statusCode] 为 0、[error]
  /// 为 `null`、[cancelled] 为 `true`，绝不抛异常。
  final bool cancelled;

  /// 是否为**已取消**结果。
  bool get isCancelled => cancelled;

  /// 文本预览上限（字符）：超出即截断，避免无界保留。
  static const int maxTextPreviewChars = 200000;

  /// 是否为成功响应（无错误且 2xx）。
  bool get isSuccess =>
      error == null && statusCode >= 200 && statusCode < 300;

  /// 是否出错。
  bool get hasError => error != null;

  /// 由流式响应的原始字段构建（归一化头、解码限长预览、解析 cookie）。
  ///
  /// [headers] 为 `package:http` 的 `Map<String,String>`（Set-Cookie 可能已
  /// 被合并为单串，[normalizeResponseHeaders] 会重新切分为列表）。
  factory DebugResponse.fromStreamed({
    required int statusCode,
    required Map<String, String> headers,
    required List<int> bodyBytes,
    int durationMs = 0,
    bool truncated = false,
  }) {
    final normalized = normalizeResponseHeaders(headers);
    final cookies = <DebugCookie>[];
    for (final raw in normalized['set-cookie'] ?? const <String>[]) {
      cookies.addAll(DebugCookieJar.parseSetCookie(raw));
    }
    // `Content-Length` 是响应声明的真实实体大小；若它大于实际读到的字节数，
    // 说明发生了截断（即使调用方未显式标记）。
    final declaredLength = _parseContentLength(normalized);
    final isTruncated =
        truncated || (declaredLength != null && declaredLength > bodyBytes.length);
    return DebugResponse(
      statusCode: statusCode,
      headers: normalized,
      bodyBytes: List<int>.unmodifiable(bodyBytes),
      bodyText: textPreview(bodyBytes),
      cookies: cookies,
      durationMs: durationMs,
      sizeBytes: declaredLength ?? bodyBytes.length,
      truncated: isTruncated,
    );
  }

  /// 结构化错误响应（状态码 0，无体）。
  factory DebugResponse.error(String message, {int durationMs = 0}) =>
      DebugResponse(error: message, durationMs: durationMs);

  /// 结构化**已取消**响应（状态码 0、无错误，仅标记 [cancelled]）。
  factory DebugResponse.cancelled({int durationMs = 0}) =>
      DebugResponse(cancelled: true, durationMs: durationMs);

  /// 由响应体字节生成限长文本预览。
  static String textPreview(List<int> bytes) {
    if (bytes.isEmpty) return '';
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.length <= maxTextPreviewChars) return text;
    return text.substring(0, maxTextPreviewChars);
  }
}

/// 把 `package:http` 的 `Map<String,String>` 归一化为小写键的多值头映射。
///
/// `set-cookie` 会被重新切分为列表（`package:http` 用 `,` 合并多条，而
/// `Expires` 内含逗号，需 [DebugCookieJar.splitSetCookieHeader] 智能切分）。
Map<String, List<String>> normalizeResponseHeaders(Map<String, String> headers) {
  final result = <String, List<String>>{};
  headers.forEach((key, value) {
    final lower = key.toLowerCase();
    if (lower == 'set-cookie') {
      final parts = DebugCookieJar.splitSetCookieHeader(value);
      result[lower] = parts.isEmpty ? <String>[value] : parts;
    } else {
      result[lower] = <String>[value];
    }
  });
  return result;
}

/// 从归一化响应头解析 `Content-Length`（首个可解析的非负整数）。
int? _parseContentLength(Map<String, List<String>> headers) {
  final values = headers['content-length'];
  if (values == null) return null;
  for (final value in values) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null && parsed >= 0) return parsed;
  }
  return null;
}

// ==================== 改写响应头卫生（plan todo 14） ====================

/// 保存为改写响应时**必须剥离**的头（小写）。
///
/// * hop-by-hop（RFC 7230 §6.1）：`Connection` / `Keep-Alive` /
///   `Proxy-Authenticate` / `Proxy-Authorization` / `TE` / `Trailer` /
///   `Transfer-Encoding` / `Upgrade`——只属于单跳连接，不能固化进改写规则；
/// * 实体派生头：`Content-Encoding` / `Content-Length`——改写后的响应体由引擎
///   重新编码/计长，沿用上游值会导致响应损坏。
const Set<String> rewriteStrippedResponseHeaders = <String>{
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'content-encoding',
  'content-length',
};

/// 改写响应头卫生：把响应头转换为可安全固化进 `replaceResponse` 规则的
/// [DebugHeader] 列表，剥离 hop-by-hop 头与 `Content-Encoding` /
/// `Content-Length` / `Transfer-Encoding`。
///
/// 另外遵循 RFC 7230：`Connection` 头中列出的自定义 token（如
/// `Connection: x-custom-hop`）同样是 hop-by-hop，一并剥离。
extension DebugResponseRewriteHeaders on DebugResponse {
  List<DebugHeader> rewriteRuleHeaders() {
    final connectionTokens = <String>{};
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != 'connection') continue;
      for (final value in entry.value) {
        for (final token in value.split(',')) {
          final normalized = token.trim().toLowerCase();
          if (normalized.isNotEmpty) connectionTokens.add(normalized);
        }
      }
    }

    final result = <DebugHeader>[];
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      if (rewriteStrippedResponseHeaders.contains(name)) continue;
      if (connectionTokens.contains(name)) continue;
      for (final value in entry.value) {
        result.add(DebugHeader(name: entry.key, value: value));
      }
    }
    return result;
  }
}

/// 响应快照转换（plan todo 6）：把一次发送的 [DebugResponse] 折叠为**有界**的
/// 历史快照，供历史文件持久化与回看。
extension DebugResponseSnapshotting on DebugResponse {
  /// 生成历史快照：Body 文本超过 [maxBodyChars]（默认
  /// [DebugResponseSnapshot.maxBodyChars]）时截断并置 `truncated`；[sizeBytes]
  /// 始终保留截断前的真实值。
  DebugResponseSnapshot toHistorySnapshot({int? maxBodyChars}) {
    final cap = maxBodyChars ?? DebugResponseSnapshot.maxBodyChars;
    final text = bodyText;
    final truncated = text.length > cap;
    return DebugResponseSnapshot(
      statusCode: statusCode,
      headers: headers,
      bodyText: truncated ? text.substring(0, cap) : text,
      cookies: cookies,
      durationMs: durationMs,
      sizeBytes: sizeBytes,
      error: error,
      truncated: truncated,
    );
  }
}

/// 历史快照还原：把 [DebugResponseSnapshot] 还原为响应查看器可消费的
/// [DebugResponse]（原始字节不再保留，文本为快照内的有界预览）。
extension DebugResponseSnapshotRestore on DebugResponseSnapshot {
  DebugResponse toDebugResponse() => DebugResponse(
        statusCode: statusCode,
        headers: headers,
        bodyText: bodyText,
        cookies: cookies,
        durationMs: durationMs,
        sizeBytes: sizeBytes,
        error: error,
        truncated: truncated,
      );
}
