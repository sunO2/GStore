import 'dart:convert';

import 'webview_models.dart';

/// Bounded, redacted request log for one headless WebView page.
///
/// Android WebView gives request metadata through `shouldInterceptRequest`,
/// XHR details through `onAjaxReadyStateChange`, and fetch details through the
/// injected JS hook. Those three sources share one list so the agent sees a
/// single timeline instead of three disconnected streams.
class WebViewRequestStore {
  static const int maxRecords = 200;
  static const int maxBodyChars = 64 * 1024;
  static const int maxHeaderValueChars = 512;

  static const Set<String> _sensitiveHeaders = {
    'authorization',
    'cookie',
    'set-cookie',
    'proxy-authorization',
    'x-api-key',
    'x-auth-token',
    'api-key',
    'token',
  };

  final List<WebViewRequestRecord> _records = <WebViewRequestRecord>[];
  int _nextId = 1;

  List<WebViewRequestRecord> get records =>
      List<WebViewRequestRecord>.unmodifiable(_records);

  int get length => _records.length;

  void clear() {
    _records.clear();
    _nextId = 1;
  }

  /// Adds placeholder metadata observed by `shouldInterceptRequest`.
  WebViewRequestRecord begin({
    required String url,
    required String method,
    Map<String, String> headers = const <String, String>{},
    bool mainFrame = false,
    String? resourceType,
  }) {
    final record = WebViewRequestRecord(
      id: _nextId++,
      url: url,
      method: method.isEmpty ? 'GET' : method.toUpperCase(),
      source: WebViewRequestSource.webview,
      startedAt: DateTime.now(),
      requestHeaders: redactHeaders(headers),
      mainFrame: mainFrame,
      resourceType: resourceType,
    );
    _records.add(record);
    _trim();
    return record;
  }

  /// Completes/creates a record from XHR or fetch.
  ///
  /// A metadata placeholder for the same URL+method within a few seconds is
  /// upgraded in place; otherwise a new detailed record is appended.
  void complete({
    required WebViewRequestSource source,
    required String url,
    required String method,
    Map<String, dynamic>? requestHeaders,
    Object? requestBody,
    int? status,
    Map<String, dynamic>? responseHeaders,
    Object? responseBody,
    int? durationMs,
    String? error,
  }) {
    final normalizedMethod =
        method.isEmpty ? 'GET' : method.trim().toUpperCase();
    final now = DateTime.now();
    WebViewRequestRecord? target;
    for (var i = _records.length - 1; i >= 0; i--) {
      final record = _records[i];
      if (record.status == null &&
          record.url == url &&
          record.method == normalizedMethod &&
          now.difference(record.startedAt).inSeconds <= 5) {
        target = record;
        break;
      }
    }
    target ??= WebViewRequestRecord(
      id: _nextId++,
      url: url,
      method: normalizedMethod,
      source: source,
      startedAt: now,
    );
    if (!_records.contains(target)) _records.add(target);

    target
      ..source = source
      ..status = status
      ..durationMs = durationMs
      ..error = error
      ..responseHeaders = redactHeaders(_stringMap(responseHeaders))
      ..responseBody = _clipBody(responseBody)
      ..requestHeaders = redactHeaders({
        ...target.requestHeaders,
        ..._stringMap(requestHeaders),
      });
    if (requestBody != null) target.requestBody = _clipBody(requestBody);
    _trim();
  }

  /// Compacts the store into the text returned to the agent.
  String format({
    String? filter,
    String? method,
    bool includeBodies = true,
    int limit = 20,
  }) {
    final needle = (filter ?? '').trim().toLowerCase();
    final methodNeedle = (method ?? '').trim().toLowerCase();
    final matches = <WebViewRequestRecord>[];
    for (final record in _records.reversed) {
      if (needle.isNotEmpty &&
          !record.url.toLowerCase().contains(needle) &&
          !(record.resourceType ?? '').toLowerCase().contains(needle)) {
        continue;
      }
      if (methodNeedle.isNotEmpty &&
          record.method.toLowerCase() != methodNeedle) {
        continue;
      }
      matches.add(record);
      if (matches.length >= limit) break;
    }
    if (matches.isEmpty) {
      return '[WebView 请求] 没有匹配的请求（总数 ${_records.length}）';
    }

    final buf = StringBuffer()
      ..writeln('[WebView 请求] 共 ${_records.length} 条，显示最近 ${matches.length} 条');
    for (final record in matches) {
      final status = record.status == null ? '—' : '${record.status}';
      final duration =
          record.durationMs == null ? '' : ' ${record.durationMs}ms';
      final main = record.mainFrame ? ' main' : '';
      final source = record.source.name;
      buf.writeln(
          '#${record.id} [$source] ${record.method} ${_clip(record.url, 300)} '
          '$status$duration$main');
      if (record.error != null && record.error!.isNotEmpty) {
        buf.writeln('  错误: ${_clip(record.error!, 300)}');
      }
      final reqHeaders = _formatHeaders(record.requestHeaders);
      if (reqHeaders.isNotEmpty) buf.writeln('  req: $reqHeaders');
      if (includeBodies && (record.requestBody ?? '').isNotEmpty) {
        buf.writeln('  req body: ${_clip(record.requestBody!, 1200)}');
      }
      final resHeaders = _formatHeaders(record.responseHeaders);
      if (resHeaders.isNotEmpty) buf.writeln('  res: $resHeaders');
      if (includeBodies && (record.responseBody ?? '').isNotEmpty) {
        buf.writeln('  res body: ${_clip(record.responseBody!, 1200)}');
      }
    }
    if (_records.length > matches.length) {
      buf.writeln(
          '…（还有 ${_records.length - matches.length} 条，可用 filter/method/limit 收窄）');
    }
    return buf.toString().trimRight();
  }

  /// HAR 1.2-ish export. Static resources without a captured response still
  /// appear with `status: 0` and no content text.
  String toHar({int limit = 200}) {
    final entries = _records.reversed.take(limit).map((record) {
      final responseContentType = record.responseHeaders.entries
              .where((entry) => entry.key.toLowerCase() == 'content-type')
              .map((entry) => entry.value)
              .firstOrNull ??
          '';
      return <String, dynamic>{
        'startedDateTime': record.startedAt.toUtc().toIso8601String(),
        'time': record.durationMs ?? 0,
        'request': <String, dynamic>{
          'method': record.method,
          'url': record.url,
          'httpVersion': 'HTTP/1.1',
          'headers': [
            for (final entry in record.requestHeaders.entries)
              {'name': entry.key, 'value': entry.value},
          ],
          if ((record.requestBody ?? '').isNotEmpty)
            'postData': <String, dynamic>{
              'mimeType': record.requestHeaders.entries
                      .where((e) => e.key.toLowerCase() == 'content-type')
                      .map((e) => e.value)
                      .firstOrNull ??
                  '',
              'text': record.requestBody,
            },
          'queryString': const <Object?>[],
          'cookies': const <Object?>[],
          'headersSize': -1,
          'bodySize': record.requestBody?.length ?? 0,
        },
        'response': <String, dynamic>{
          'status': record.status ?? 0,
          'statusText': '',
          'httpVersion': 'HTTP/1.1',
          'headers': [
            for (final entry in record.responseHeaders.entries)
              {'name': entry.key, 'value': entry.value},
          ],
          'content': <String, dynamic>{
            'size': record.responseBody?.length ?? 0,
            'mimeType': responseContentType,
            if ((record.responseBody ?? '').isNotEmpty)
              'text': record.responseBody,
          },
          'redirectURL': '',
          'headersSize': -1,
          'bodySize': record.responseBody?.length ?? 0,
        },
        'cache': const <String, dynamic>{},
        'timings': <String, dynamic>{
          'send': 0,
          'wait': record.durationMs ?? 0,
          'receive': 0,
        },
        'comment': <String>[
          record.source.name,
          if (record.mainFrame) 'main-frame',
          if (record.resourceType != null) record.resourceType!,
          if ((record.error ?? '').isNotEmpty) record.error!,
        ].join(' '),
      };
    }).toList();
    return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'log': <String, dynamic>{
        'version': '1.2',
        'creator': <String, dynamic>{
          'name': 'GStore Agent WebView',
          'version': '1.0',
        },
        'entries': entries,
      },
    });
  }

  void _trim() {
    while (_records.length > maxRecords) {
      _records.removeAt(0);
    }
  }

  static Map<String, String> redactHeaders(Map<String, String> headers) {
    final out = <String, String>{};
    headers.forEach((name, value) {
      final lower = name.toLowerCase();
      if (_sensitiveHeaders.contains(lower)) {
        out[name] = lower == 'authorization' &&
                value.toLowerCase().startsWith('bearer ')
            ? 'Bearer ***'
            : '***';
      } else {
        out[name] = _clip(value, maxHeaderValueChars);
      }
    });
    return out;
  }

  static String _formatHeaders(Map<String, String> headers) {
    if (headers.isEmpty) return '';
    final entries = headers.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
    return _clip(entries, 480);
  }

  static Map<String, String> _stringMap(Map<String, dynamic>? map) {
    final out = <String, String>{};
    map?.forEach((key, value) {
      if (value == null) return;
      out[key] = value is String ? value : jsonEncode(value);
    });
    return out;
  }

  static String? _clipBody(Object? raw) {
    if (raw == null) return null;
    final text = raw is String
        ? raw
        : (raw is Map || raw is List || raw is num || raw is bool
            ? jsonEncode(raw)
            : '[${raw.runtimeType}]');
    return _clip(text, maxBodyChars);
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…<截断>';
}
