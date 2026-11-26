import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'webview_models.dart';
import 'webview_request_store.dart';
import 'webview_scripts.dart';
import 'webview_url_policy.dart';

/// Owns one headless Android WebView and exposes a small agent-facing tool API.
///
/// Phase 1 is deliberately single-page: `open` loads/reuses the page, the other
/// actions operate on that page, and `close` disposes it. Requests are captured
/// from three layers (WebView metadata, XHR callbacks, an injected fetch hook)
/// and stored in one bounded, redacted timeline.
class WebViewSessionService {
  WebViewSessionService({WebViewUrlPolicy? urlPolicy})
      : _policy = urlPolicy ?? WebViewUrlPolicy();

  static WebViewSessionService instance = WebViewSessionService();

  @visibleForTesting
  static void debugSetInstance(WebViewSessionService? service) {
    instance = service ?? WebViewSessionService();
  }

  static const String _requestHandler = 'gstoreWebviewRequest';
  static const int _maxConsoleEntries = 50;
  static const Duration _idleTimeout = Duration(minutes: 3);

  final WebViewUrlPolicy _policy;
  final WebViewRequestStore _store = WebViewRequestStore();
  final List<WebViewConsoleEntry> _logs = <WebViewConsoleEntry>[];

  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Future<void>? _starting;
  Completer<void>? _loadCompleter;
  Timer? _idleTimer;

  String? _url;
  String _title = '';
  int? _lastStatus;
  String? _lastError;
  DateTime _lastRequestAt = DateTime.now();

  /// Executes one tool action and returns model-facing text.
  Future<String> handle(Map<String, dynamic> params) async {
    final action = params['action']?.toString().trim() ?? '';
    try {
      switch (action) {
        case 'open':
          return await _open(params);
        case 'content':
          return await _content(params);
        case 'requests':
          return _requests(params);
        case 'eval':
          return await _eval(params);
        case 'click':
          return await _click(params);
        case 'type':
          return await _type(params);
        case 'wait':
          return await _wait(params);
        case 'scroll':
          return await _scroll(params);
        case 'har':
          return _har(params);
        case 'status':
          return await _status();
        case 'logs':
          return _formatLogs();
        case 'close':
          await close();
          return 'WebView 已关闭';
        default:
          return '未知 action：$action（支持 open/content/requests/eval/click/type/wait/scroll/har/status/logs/close）';
      }
    } on WebViewException catch (error) {
      return 'WebView 失败：${error.message}';
    } catch (error) {
      return 'WebView 失败：$error';
    }
  }

  /// Read-only request dump for the visible debug page.
  String debugRequestsText({int limit = 50}) {
    if (_store.length == 0) {
      return '当前没有捕获到请求。先让 AI 用 webView open 一个页面，再回来查看。';
    }
    return _store.format(limit: limit, includeBodies: false);
  }

  /// Disposes the headless page and releases per-page state.
  Future<void> close() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final view = _webView;
    _webView = null;
    _controller = null;
    _loadCompleter = null;
    _policy.clear();
    _store.clear();
    _logs.clear();
    _url = null;
    _title = '';
    _lastStatus = null;
    _lastError = null;
    if (view != null) {
      try {
        await view.dispose();
      } catch (_) {}
    }
  }

  Future<void> _ensureStarted() async {
    if (_controller != null && (_webView?.isRunning() ?? false)) return;
    final running = _starting;
    if (running != null) return running;
    final future = _start();
    _starting = future;
    try {
      await future;
    } finally {
      _starting = null;
    }
  }

  Future<void> _start() async {
    final created = Completer<void>();
    final view = HeadlessInAppWebView(
      initialSize: const Size(1080, 1920),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldInterceptRequest: true,
        useShouldInterceptAjaxRequest: true,
        interceptOnlyAsyncAjaxRequests: true,
        // The JS hook captures fetch responses; the plugin's fetch interceptor
        // only exposes the request side.
        useShouldInterceptFetchRequest: false,
        supportMultipleWindows: false,
        javaScriptCanOpenWindowsAutomatically: false,
        mediaPlaybackRequiresUserGesture: true,
        allowFileAccess: false,
        allowContentAccess: false,
        domStorageEnabled: true,
        databaseEnabled: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
        thirdPartyCookiesEnabled: true,
        safeBrowsingEnabled: true,
        cacheEnabled: true,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: webViewFetchHookScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
        UserScript(
          source: webViewNavigationHookScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
      ]),
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: _requestHandler,
          callback: _onFetchPayload,
        );
        if (!created.isCompleted) created.complete();
      },
      shouldInterceptRequest: _onInterceptRequest,
      shouldOverrideUrlLoading: _onOverrideUrl,
      onLoadStart: (controller, url) {
        _url = url?.toString() ?? _url;
        _lastError = null;
        _lastStatus = null;
        _lastRequestAt = DateTime.now();
      },
      onLoadStop: (controller, url) {
        _url = url?.toString() ?? _url;
        _lastRequestAt = DateTime.now();
        final completer = _loadCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete();
        }
      },
      onUpdateVisitedHistory: (controller, url, isReload) {
        _url = url?.toString() ?? _url;
      },
      onTitleChanged: (controller, title) {
        _title = title?.trim() ?? '';
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame == true) {
          _lastError = error.description;
          final completer = _loadCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.completeError(WebViewException(error.description));
          }
        }
      },
      onReceivedHttpError: (controller, request, errorResponse) {
        if (request.isForMainFrame == true) {
          _lastStatus = errorResponse.statusCode;
        }
      },
      onConsoleMessage: (controller, message) {
        _logs.add(WebViewConsoleEntry(
          time: DateTime.now(),
          level: _levelName(message.messageLevel),
          message: message.message,
        ));
        if (_logs.length > _maxConsoleEntries) {
          _logs.removeAt(0);
        }
      },
      onAjaxReadyStateChange: _onAjax,
      onCreateWindow: (controller, action) async {
        final url = action.request.url;
        if (url != null) {
          try {
            await controller.loadUrl(urlRequest: URLRequest(url: url));
          } catch (_) {}
        }
        return true;
      },
      onJsAlert: (controller, request) async => JsAlertResponse(
        message: request.message ?? '',
        handledByClient: true,
        action: JsAlertResponseAction.CONFIRM,
      ),
      onJsConfirm: (controller, request) async => JsConfirmResponse(
        message: request.message ?? '',
        handledByClient: true,
        action: JsConfirmResponseAction.CANCEL,
      ),
      onJsPrompt: (controller, request) async => JsPromptResponse(
        message: request.message ?? '',
        handledByClient: true,
        action: JsPromptResponseAction.CANCEL,
      ),
    );

    try {
      await view.run();
      await created.future.timeout(const Duration(seconds: 8));
      _webView = view;
      _touch();
    } catch (error) {
      try {
        await view.dispose();
      } catch (_) {}
      throw WebViewException('WebView 启动失败：$error');
    }
  }

  Future<WebResourceResponse?> _onInterceptRequest(
    InAppWebViewController controller,
    WebResourceRequest request,
  ) async {
    final url = request.url.toString();
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final mainFrame = request.isForMainFrame == true;
    final allowed = mainFrame
        ? await _policy.allowMainFrame(uri)
        : await _policy.allowSubresource(uri);
    if (!allowed) {
      if (mainFrame) {
        _lastError = '拒绝访问内网或非 http(s) 地址：${uri.host}';
      }
      return WebResourceResponse(
        contentType: 'text/plain',
        contentEncoding: 'utf-8',
        data: Uint8List(0),
        statusCode: 403,
        reasonPhrase: 'Forbidden',
        headers: const <String, String>{'content-type': 'text/plain'},
      );
    }
    // data: URLs are page-local and can be huge; never put them in the log.
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      _store.begin(
        url: url,
        method: request.method ?? 'GET',
        headers: request.headers ?? const <String, String>{},
        mainFrame: mainFrame,
        resourceType: request.headers?['sec-fetch-dest'],
      );
      _lastRequestAt = DateTime.now();
    }
    return null;
  }

  Future<NavigationActionPolicy?> _onOverrideUrl(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final raw = action.request.url;
    if (raw == null) return NavigationActionPolicy.ALLOW;
    final uri = Uri.tryParse(raw.toString());
    if (uri == null) return NavigationActionPolicy.CANCEL;
    if (uri.scheme == 'about') return NavigationActionPolicy.ALLOW;
    return await _policy.allowMainFrame(uri)
        ? NavigationActionPolicy.ALLOW
        : NavigationActionPolicy.CANCEL;
  }

  Future<AjaxRequestAction?> _onAjax(
    InAppWebViewController controller,
    AjaxRequest request,
  ) async {
    if (request.readyState != AjaxRequestReadyState.DONE) return null;
    final url = request.responseURL?.toString() ?? request.url?.toString() ?? '';
    if (url.isEmpty) return null;
    _store.complete(
      source: WebViewRequestSource.xhr,
      url: url,
      method: request.method ?? 'GET',
      requestHeaders: request.headers?.getHeaders(),
      requestBody: request.data,
      status: request.status,
      responseHeaders: request.responseHeaders,
      responseBody: request.responseText ?? request.response,
    );
    _lastRequestAt = DateTime.now();
    return null;
  }

  dynamic _onFetchPayload(List<dynamic> args) {
    final raw = args.isNotEmpty ? args.first : null;
    if (raw is! Map) return null;
    final payload = _stringKeyedMap(raw);
    final url = payload['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    _store.complete(
      source: WebViewRequestSource.fetch,
      url: url,
      method: payload['method']?.toString() ?? 'GET',
      requestHeaders: _mapValue(payload['requestHeaders']),
      requestBody: payload['requestBody'],
      status: (payload['status'] as num?)?.toInt(),
      responseHeaders: _mapValue(payload['responseHeaders']),
      responseBody: payload['responseBody'],
      durationMs: (payload['durationMs'] as num?)?.toInt(),
      error: payload['error']?.toString(),
    );
    _lastRequestAt = DateTime.now();
    return null;
  }

  Future<String> _open(Map<String, dynamic> params) async {
    final url = params['url']?.toString().trim() ?? '';
    if (url.isEmpty) return 'open 需要 url';
    final uri = Uri.tryParse(url);
    if (uri == null || !await _policy.allowMainFrame(uri)) {
      return '拒绝访问：只允许公网 http/https 地址';
    }
    if (uri.scheme == 'http' && !kDebugMode) {
      return 'Android Release 默认禁止明文 HTTP，请使用 https:// 地址';
    }

    await _ensureStarted();
    final controller = _controller;
    if (controller == null) throw const WebViewException('WebView 未就绪');

    _store.clear();
    _logs.clear();
    _title = '';
    _lastStatus = null;
    _lastError = null;
    _url = url;
    _lastRequestAt = DateTime.now();
    final completer = _loadCompleter = Completer<void>();
    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } catch (error) {
      throw WebViewException('加载失败：$error');
    }

    final timeoutMs = _clampInt(params['timeoutMs'], 20000, 3000, 60000);
    try {
      await completer.future.timeout(Duration(milliseconds: timeoutMs));
    } on TimeoutException {
      throw WebViewException('页面加载超时（${timeoutMs}ms）');
    }
    if (_lastError != null) {
      throw WebViewException(_lastError!);
    }

    final waitUntil = params['waitUntil']?.toString() ?? 'load';
    if (waitUntil == 'networkIdle') {
      await _waitNetworkIdle(timeoutMs);
    }
    final settleMs = _clampInt(params['settleMs'], 700, 0, 10000);
    if (settleMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: settleMs));
    }

    _touch();
    final preview = await _readText(maxChars: 600);
    final title = _displayTitle();
    final status = _lastStatus == null ? '' : '\n状态：HTTP $_lastStatus';
    return '[WebView] 已加载\n'
        'URL：${_url ?? url}\n'
        '标题：$title$status\n'
        '请求：${_store.length} 条\n'
        '正文预览：\n${preview.text}${preview.truncated ? '\n…（已截断）' : ''}';
  }

  Future<String> _content(Map<String, dynamic> params) async {
    final format = params['format']?.toString() ?? 'text';
    final maxChars = _clampInt(params['maxChars'], 32000, 500, 64000);
    final String text;
    final String title;
    final String url;
    if (format == 'html') {
      final data = await _evalMap(webViewContentHtmlScript);
      text = data['html']?.toString() ?? '';
      title = data['title']?.toString() ?? _displayTitle();
      url = data['url']?.toString() ?? _url ?? '';
    } else {
      final data = await _evalMap(webViewContentTextScript(
        readable: format == 'readability',
      ));
      text = data['text']?.toString() ?? '';
      title = data['title']?.toString() ?? _displayTitle();
      url = data['url']?.toString() ?? _url ?? '';
    }
    final clipped = text.length > maxChars ? '${text.substring(0, maxChars)}…<截断>' : text;
    _touch();
    return '[WebView 内容｜$format]\nURL：$url\n标题：$title\n\n$clipped';
  }

  String _requests(Map<String, dynamic> params) {
    _touch();
    return _store.format(
      filter: params['filter']?.toString(),
      method: params['method']?.toString(),
      includeBodies: params['includeBodies'] != false,
      limit: _clampInt(params['limit'], 20, 1, 50),
    );
  }

  Future<String> _eval(Map<String, dynamic> params) async {
    final script = params['script']?.toString().trim() ?? '';
    if (script.isEmpty) return 'eval 需要 script';
    final controller = _controller;
    if (controller == null) return '还没有打开页面，请先 open';
    // `callAsyncJavaScript` treats the string as an async function body, so
    // the caller's script must use `return` for the value it wants back.
    final body = 'return await (async () => { $script })();';
    final result = await controller.callAsyncJavaScript(functionBody: body);
    if (result == null) return 'eval 没有返回值';
    if (result.error != null && result.error!.isNotEmpty) {
      return 'eval 失败：${result.error}';
    }
    final maxChars = _clampInt(params['maxChars'], 32000, 500, 64000);
    final text = _formatValue(result.value);
    _touch();
    return text.length > maxChars
        ? '${text.substring(0, maxChars)}…<截断>'
        : text;
  }

  Future<String> _click(Map<String, dynamic> params) async {
    final selector = params['selector']?.toString().trim() ?? '';
    if (selector.isEmpty) return 'click 需要 selector';
    final index = _clampInt(params['index'], 0, 0, 100);
    final force = params['force'] == true;
    final result = await _evalMap(webViewClickScript(selector, index, force));
    if (result['ok'] != true) {
      return '点击失败：${result['error'] ?? '未找到元素'}（匹配 ${result['count'] ?? 0} 个）';
    }
    final waitMs = _clampInt(params['waitMs'], 500, 0, 5000);
    if (waitMs > 0) await Future<void>.delayed(Duration(milliseconds: waitMs));
    final info = await _pageInfo();
    _touch();
    return '已点击 $selector（${result['method']}）\n'
        'URL：${info['url'] ?? _url ?? ''}\n'
        '标题：${info['title'] ?? _displayTitle()}\n'
        '请求：${_store.length} 条';
  }

  Future<String> _type(Map<String, dynamic> params) async {
    final selector = params['selector']?.toString().trim() ?? '';
    final text = params['text']?.toString() ?? '';
    if (selector.isEmpty) return 'type 需要 selector';
    final index = _clampInt(params['index'], 0, 0, 100);
    final submit = params['submit'] == true;
    final result = await _evalMap(
      webViewTypeScript(selector, index, text, submit),
    );
    if (result['ok'] != true) {
      return '输入失败：${result['error'] ?? '未找到元素'}（匹配 ${result['count'] ?? 0} 个）';
    }
    final waitMs = _clampInt(params['waitMs'], 400, 0, 5000);
    if (waitMs > 0) await Future<void>.delayed(Duration(milliseconds: waitMs));
    _touch();
    return '已输入 $selector${submit ? ' 并提交' : ''}\n'
        'URL：${await _currentUrl()}\n'
        '标题：${await _currentTitle()}';
  }

  Future<String> _wait(Map<String, dynamic> params) async {
    final selector = params['selector']?.toString().trim() ?? '';
    final ms = _clampInt(params['ms'], 0, 0, 30000);
    final timeoutMs = _clampInt(params['timeoutMs'], 10000, 1000, 60000);
    if (selector.isNotEmpty) {
      final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
      while (DateTime.now().isBefore(deadline)) {
        if (await _evalBool(webViewWaitSelectorScript(selector))) {
          _touch();
          return '已找到元素：$selector';
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      return '等待超时：未找到 $selector（${timeoutMs}ms）';
    }
    if (ms > 0) await Future<void>.delayed(Duration(milliseconds: ms));
    _touch();
    return '已等待 ${ms > 0 ? '${ms}ms' : '页面稳定'}';
  }

  Future<String> _scroll(Map<String, dynamic> params) async {
    final selector = params['selector']?.toString().trim() ?? '';
    final x = _clampInt(params['x'], 0, -100000, 100000);
    final y = _clampInt(params['y'], 700, -100000, 100000);
    final result = await _evalMap(webViewScrollScript(selector, x, y));
    if (result['ok'] != true) {
      return '滚动失败：${result['error'] ?? '未知错误'}';
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final info = await _pageInfo();
    _touch();
    return '已滚动${selector.isNotEmpty ? '到 $selector' : '（x=$x, y=$y）'}\n'
        'URL：${info['url'] ?? _url ?? ''}\n'
        '标题：${info['title'] ?? _displayTitle()}';
  }

  String _har(Map<String, dynamic> params) {
    if (_store.length == 0) return '[WebView HAR] 当前没有捕获到请求';
    _touch();
    final limit = _clampInt(params['limit'], 200, 1, 500);
    return _store.toHar(limit: limit);
  }

  Future<String> _status() async {
    if (_controller == null) return 'WebView 未打开';
    final info = await _pageInfo();
    return '[WebView 状态]\n'
        'URL：${info['url'] ?? _url ?? ''}\n'
        '标题：${info['title'] ?? _displayTitle()}\n'
        'readyState：${info['readyState'] ?? ''}\n'
        '请求：${_store.length} 条\n'
        '控制台：${_logs.length} 条';
  }

  String _formatLogs() {
    if (_logs.isEmpty) return '[WebView 控制台] 暂无日志';
    final buf = StringBuffer('[WebView 控制台] 最近 ${_logs.length} 条\n');
    for (final entry in _logs.reversed.take(20)) {
      buf.writeln('[${entry.level}] ${_clip(entry.message, 500)}');
    }
    return buf.toString().trimRight();
  }

  Future<({String text, bool truncated})> _readText({required int maxChars}) async {
    try {
      final data = await _evalMap(
        webViewContentTextScript(readable: false),
      );
      final text = data['text']?.toString() ?? '';
      return (
        text: text.length > maxChars ? text.substring(0, maxChars) : text,
        truncated: text.length > maxChars,
      );
    } catch (_) {
      return (text: '（无法读取正文）', truncated: false);
    }
  }

  Future<Map<String, dynamic>> _evalMap(String source) async {
    final controller = _controller;
    if (controller == null) throw const WebViewException('还没有打开页面，请先 open');
    final raw = await controller.evaluateJavascript(source: source);
    return _stringKeyedMap(raw);
  }

  Future<bool> _evalBool(String source) async {
    final controller = _controller;
    if (controller == null) return false;
    final raw = await controller.evaluateJavascript(source: source);
    return raw == true;
  }

  Future<Map<String, dynamic>> _pageInfo() async {
    try {
      return await _evalMap(webViewPageInfoScript);
    } catch (_) {
      return <String, dynamic>{
        'url': _url ?? '',
        'title': _displayTitle(),
        'readyState': '',
      };
    }
  }

  Future<String> _currentUrl() async => (await _pageInfo())['url']?.toString() ?? _url ?? '';

  Future<String> _currentTitle() async =>
      (await _pageInfo())['title']?.toString() ?? _displayTitle();

  String _displayTitle() {
    if (_title.isNotEmpty) return _title;
    final raw = _url;
    if (raw == null) return '';
    return Uri.tryParse(raw)?.host ?? raw;
  }

  Future<void> _waitNetworkIdle(int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      final quietFor = DateTime.now().difference(_lastRequestAt).inMilliseconds;
      if (quietFor >= 600) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  void _touch() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, () {
      unawaited(close());
    });
  }

  static int _clampInt(Object? raw, int fallback, int min, int max) {
    final parsed = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
    if (parsed == null) return fallback;
    return parsed.clamp(min, max);
  }

  static String _formatValue(Object? value) {
    if (value == null) return 'null';
    if (value is String) return value;
    if (value is num || value is bool) return '$value';
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }

  static Map<String, dynamic> _stringKeyedMap(Object? raw) {
    var value = raw;
    if (value is String) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return <String, dynamic>{};
      }
    }
    if (value is! Map) return <String, dynamic>{};
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  static Map<String, dynamic>? _mapValue(Object? raw) {
    if (raw is! Map) return null;
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  static String _levelName(ConsoleMessageLevel level) {
    if (level == ConsoleMessageLevel.ERROR) return 'error';
    if (level == ConsoleMessageLevel.WARNING) return 'warn';
    if (level == ConsoleMessageLevel.DEBUG) return 'debug';
    if (level == ConsoleMessageLevel.TIP) return 'tip';
    return 'log';
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…<截断>';
}
