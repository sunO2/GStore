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

  /// 实际收到的响应体字节数（截断前的已读长度即此值）。
  final int sizeBytes;

  /// 结构化错误（连接失败 / 超时为非 null；出错时不抛异常）。
  final String? error;

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
  }) {
    final normalized = normalizeResponseHeaders(headers);
    final cookies = <DebugCookie>[];
    for (final raw in normalized['set-cookie'] ?? const <String>[]) {
      cookies.addAll(DebugCookieJar.parseSetCookie(raw));
    }
    return DebugResponse(
      statusCode: statusCode,
      headers: normalized,
      bodyBytes: List<int>.unmodifiable(bodyBytes),
      bodyText: textPreview(bodyBytes),
      cookies: cookies,
      durationMs: durationMs,
      sizeBytes: bodyBytes.length,
    );
  }

  /// 结构化错误响应（状态码 0，无体）。
  factory DebugResponse.error(String message, {int durationMs = 0}) =>
      DebugResponse(error: message, durationMs: durationMs);

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
