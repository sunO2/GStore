/// Models for the agent WebView tool.
library;

class WebViewException implements Exception {
  const WebViewException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum WebViewRequestSource { webview, xhr, fetch }

/// One observed HTTP request/response in the headless page.
class WebViewRequestRecord {
  WebViewRequestRecord({
    required this.id,
    required this.url,
    required this.method,
    required this.source,
    required this.startedAt,
    this.requestHeaders = const <String, String>{},
    this.requestBody,
    this.status,
    this.responseHeaders = const <String, String>{},
    this.responseBody,
    this.resourceType,
    this.mainFrame = false,
    this.durationMs,
    this.error,
  });

  final int id;
  final String url;
  final String method;
  WebViewRequestSource source;
  final DateTime startedAt;

  Map<String, String> requestHeaders;
  String? requestBody;
  int? status;
  Map<String, String> responseHeaders;
  String? responseBody;
  String? resourceType;
  bool mainFrame;
  int? durationMs;
  String? error;
}

class WebViewConsoleEntry {
  const WebViewConsoleEntry({
    required this.time,
    required this.level,
    required this.message,
  });

  final DateTime time;
  final String level;
  final String message;
}

class WebViewPageInfo {
  const WebViewPageInfo({
    required this.url,
    required this.title,
    required this.readyState,
    required this.requestCount,
  });

  final String url;
  final String title;
  final String readyState;
  final int requestCount;
}
