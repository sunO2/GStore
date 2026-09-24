/// 「请求调试」发送器（纯逻辑，无 UI）。
///
/// **HTTP 客户端决策**（见 `.omo/plans/proxy-http-capture.md` todo 26）：
/// 使用 `package:http` 的 `IOClient`（Dart 原生 socket）。理由同
/// `lib/core/agent/agent_http_client.dart:1-22`：标准 http 流式解码可靠，
/// 且为仓库既有、稳定依赖。网络路径**跟随应用默认**（不额外 protect）。
///
/// 所有失败（连接 / TLS / 超时 / 非法 URL）都归一化为 [DebugResponse.error]，
/// **绝不抛异常**；超时由整体 deadline 约束，绝不挂起。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'debug_cookie_jar.dart';
import 'debug_models.dart';
import 'debug_response.dart';

/// 使用 `package:http`（`IOClient`）的请求调试发送器。
class DebugSender {
  DebugSender({http.Client? client, DebugCookieJar? cookieJar})
      : _client = client ?? IOClient(),
        _ownsClient = client == null,
        cookieJar = cookieJar ?? DebugCookieJar();

  final http.Client _client;
  final bool _ownsClient;

  /// 本次发送使用的 cookie jar（可注入 / 查看 / 清除）。
  final DebugCookieJar cookieJar;

  /// 默认超时。
  static const Duration defaultTimeout = Duration(seconds: 30);

  /// 原始响应体读取上限（字节）：超过即截断，避免无界保留大 Body。
  static const int maxBodyBytes = 8 * 1024 * 1024;

  /// 发送一次请求并返回 [DebugResponse]。
  ///
  /// [headers] / [query] 仅发送 `enabled=true` 项；[body] 非空时按 UTF-8
  /// 编成字节。`useCookies=true` 时自动带上 jar 中匹配 [url] host 的 cookie，
  /// 并在响应后把 `Set-Cookie` 存入 jar。失败返回结构化错误，不抛。
  Future<DebugResponse> send({
    required String method,
    required String url,
    List<DebugHeader> headers = const <DebugHeader>[],
    List<DebugQueryParam> query = const <DebugQueryParam>[],
    String body = '',
    bool followRedirects = true,
    Duration? timeout,
    bool useCookies = true,
  }) async {
    final effectiveTimeout = timeout ?? defaultTimeout;
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _perform(
        method: method,
        url: url,
        headers: headers,
        query: query,
        body: body,
        followRedirects: followRedirects,
        useCookies: useCookies,
      ).timeout(effectiveTimeout);
      stopwatch.stop();
      return response;
    } on TimeoutException {
      stopwatch.stop();
      return DebugResponse.error(
        '请求超时（${effectiveTimeout.inMilliseconds}ms）',
        durationMs: stopwatch.elapsedMilliseconds,
      );
    } catch (error) {
      stopwatch.stop();
      return DebugResponse.error(
        _describeError(error),
        durationMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  /// 释放底层客户端（仅当本对象自行创建时）。
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<DebugResponse> _perform({
    required String method,
    required String url,
    required List<DebugHeader> headers,
    required List<DebugQueryParam> query,
    required String body,
    required bool followRedirects,
    required bool useCookies,
  }) async {
    final stopwatch = Stopwatch()..start();
    final uri = _buildUri(url, query);

    final request = http.Request(method.toUpperCase(), uri);
    request.followRedirects = followRedirects;
    request.maxRedirects = followRedirects ? 5 : 0;

    for (final header in headers) {
      if (!header.enabled || header.name.trim().isEmpty) continue;
      request.headers[header.name] = header.value;
    }

    if (useCookies) {
      final cookieHeader = cookieJar.cookieHeaderFor(uri.host);
      if (cookieHeader.isNotEmpty) {
        final existing = request.headers['Cookie'] ?? request.headers['cookie'];
        request.headers['Cookie'] = (existing == null || existing.isEmpty)
            ? cookieHeader
            : '$existing; $cookieHeader';
      }
    }

    if (body.isNotEmpty) {
      request.bodyBytes = utf8.encode(body);
    }

    final streamed = await _client.send(request);
    final bytes = await _readBounded(streamed.stream);
    stopwatch.stop();

    final response = DebugResponse.fromStreamed(
      statusCode: streamed.statusCode,
      headers: streamed.headers,
      bodyBytes: bytes,
      durationMs: stopwatch.elapsedMilliseconds,
    );

    if (useCookies) {
      cookieJar.store(uri.host, response.headers);
    }
    return response;
  }

  /// 把 URL 与启用的查询参数合并为最终 [Uri]（保留 URL 原有查询）。
  static Uri _buildUri(String url, List<DebugQueryParam> query) {
    final base = Uri.parse(url);
    final enabled =
        query.where((p) => p.enabled && p.name.isNotEmpty).toList();
    if (enabled.isEmpty) return base;

    final merged = <String, dynamic>{};
    base.queryParametersAll.forEach((key, values) {
      merged[key] = List<String>.from(values);
    });
    for (final param in enabled) {
      final existing = merged[param.name];
      if (existing is List<String>) {
        existing.add(param.value);
      } else if (existing is String) {
        merged[param.name] = <String>[existing, param.value];
      } else {
        merged[param.name] = <String>[param.value];
      }
    }
    return base.replace(queryParameters: merged);
  }

  /// 读取响应流，最多 [maxBodyBytes] 字节（超出即停止读取）。
  static Future<List<int>> _readBounded(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in stream) {
      final remaining = maxBodyBytes - total;
      if (remaining <= 0) break;
      if (chunk.length > remaining) {
        builder.add(chunk.sublist(0, remaining));
        break;
      }
      builder.add(chunk);
      total += chunk.length;
    }
    return builder.takeBytes();
  }

  static String _describeError(Object error) {
    if (error is TimeoutException) {
      return '请求超时：${error.message ?? ''}'.trim();
    }
    if (error is SocketException) {
      final os = error.osError?.message;
      return os == null || os.isEmpty
          ? '连接失败：${error.message}'
          : '连接失败：${error.message}（$os）';
    }
    if (error is HandshakeException) {
      return 'TLS 握手失败：${error.message}';
    }
    if (error is http.ClientException) {
      return '请求失败：${error.message}';
    }
    if (error is FormatException) {
      return 'URL 非法：${error.message}';
    }
    return error.toString();
  }
}
