import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/webview/web_browser_store.dart';
import 'package:gstore/core/webview/web_download.dart';
import 'package:gstore/core/webview/web_home.dart';
import 'package:gstore/core/webview/web_view_settings.dart';
import 'package:gstore/core/webview/webview_url_normalizer.dart';

import 'web_address_bar.dart';
import 'web_sheets.dart';
import 'web_tools_sheets.dart';

/// 内置浏览器（AI 回复里的链接、外部跳转都走这里）。
///
/// 地址/搜索（必应建议）、历史、书签、页内查找、夜间模式、电脑模式、
/// 字体大小、查看源码、页面信息、资源嗅探、清除数据。
class WebPage extends StatefulWidget {
  const WebPage({super.key, this.url, this.title});

  /// 要打开的地址；可以是裸域名，内部会补 `https://`。
  final String? url;

  /// 标题栏文案；为空时用网页标题或域名。
  final String? title;

  @override
  State<WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<WebPage> {
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const String _nightCss = '''
html { filter: invert(1) hue-rotate(180deg) !important; background: #111 !important; }
img, video, picture, canvas, svg, iframe {
  filter: invert(1) hue-rotate(180deg) !important;
}
''';

  static const String _resourceScript = r'''
(function () {
  var out = [];
  var seen = {};
  function add(u) {
    if (!u) return;
    if (!/^https?:/i.test(u)) return;
    if (seen[u]) return;
    seen[u] = 1;
    out.push(u);
  }
  document.querySelectorAll('img[src]').forEach(function (e) {
    add(e.currentSrc || e.src);
  });
  document.querySelectorAll('video[src], audio[src], source[src]').forEach(function (e) {
    add(e.src);
  });
  document.querySelectorAll('a[href]').forEach(function (e) {
    var u = e.href;
    if (/\.(apk|zip|pdf|mp4|webm|mp3|m4a|png|jpe?g|gif|webp|svg)(\?|$)/i.test(u)) add(u);
  });
  return JSON.stringify(out.slice(0, 100));
})();
''';

  InAppWebViewController? _controller;

  /// 没有传 url（点「主页」/ 新标签页）时从内置主页开始。
  late final bool _startsAtHome = (widget.url ?? '').trim().isEmpty;
  late final String? _initialUrl =
      _startsAtHome ? null : normalizeWebViewUrl(widget.url);

  WebHomeConfig _homeConfig = WebHomeConfig.defaults;
  bool _homeReady = false;

  String _currentUrl = '';
  String _pageTitle = '';
  double _progress = 0;
  // WebView 首次创建（系统 WebView 冷启动）期间不会有任何回调，
  // 先按加载中处理，避免用户看到空白页。
  bool _loading = true;

  /// 当前显示的是不是主页（内置 / 在线主题 / 本地 HTML）。
  bool _atHome = false;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _isBookmarked = false;

  WebViewSettings _settings = WebViewSettings.defaults;
  bool _settingsReady = false;

  /// 正在等待用户输入的 HTTP 认证；并发 challenge 共用一个弹层。
  Future<HttpAuthResponse>? _pendingHttpAuth;

  bool _addressVisible = false;

  bool _findVisible = false;
  bool _findHasQuery = false;
  final TextEditingController _findController = TextEditingController();
  final FocusNode _findFocus = FocusNode();

  /// 内置主页模板（`assets/web/home.html`）。
  String _homeTemplate = '';

  @override
  void initState() {
    super.initState();
    _atHome = _startsAtHome;
    _currentUrl = _initialUrl ?? (_startsAtHome ? kWebHomeOrigin : '');
    _isBookmarked = WebBrowserStore.instance.isBookmarked(_currentUrl);
    WebBrowserStore.instance.load().then((_) {
      if (!mounted) return;
      setState(() {
        _isBookmarked = WebBrowserStore.instance.isBookmarked(_currentUrl);
      });
    });
    WebViewSettingsStore.instance.load().then((_) {
      if (!mounted) return;
      setState(() {
        _settings = WebViewSettingsStore.instance.settings;
        _settingsReady = true;
      });
    });
    _prepareHome();
  }

  /// 启动主页：配置 + 内置模板都准备好之后再创建 WebView，避免先闪一下
  /// 默认主页再跳到用户配置的在线主题。
  Future<void> _prepareHome() async {
    if (!_startsAtHome) {
      _homeReady = true;
      unawaited(
        WebHomeStore.instance.load().then((_) {
          if (mounted) {
            setState(() => _homeConfig = WebHomeStore.instance.config);
          }
        }),
      );
      return;
    }
    await WebHomeStore.instance.load();
    final config = WebHomeStore.instance.config;
    if (_startsAtHome &&
        config.entryUrl == null) {
      try {
        _homeTemplate = await primeWebHomeTemplate();
      } catch (error) {
        debugPrint('WebPage: 读取内置主页失败 - $error');
      }
    }
    if (!mounted) return;
    setState(() {
      _homeConfig = config;
      _homeReady = true;
      _atHome = _startsAtHome;
      _currentUrl = _initialUrl ?? (_atHome ? _homeAddress : '');
    });
  }

  @override
  void dispose() {
    _findController.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  Brightness? _lastBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    final changed = _lastBrightness != null && _lastBrightness != brightness;
    _lastBrightness = brightness;
    if (changed && _atHome && _controller != null) {
      _applyHomeTheme();
    }
  }

  InAppWebViewSettings _webViewSettings({int? textZoom, String? userAgent}) =>
      InAppWebViewSettings(
        javaScriptEnabled: _settings.javaScriptEnabled,
        supportMultipleWindows: false,
        javaScriptCanOpenWindowsAutomatically: false,
        mediaPlaybackRequiresUserGesture: true,
        allowFileAccess: _homeConfig.mode == WebHomeMode.local,
        allowContentAccess: false,
        domStorageEnabled: true,
        databaseEnabled: true,
        thirdPartyCookiesEnabled: _settings.thirdPartyCookies,
        cacheEnabled: _settings.cacheEnabled,
        blockNetworkImage: !_settings.loadImages,
        safeBrowsingEnabled: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
        textZoom: textZoom ?? _settings.textZoom,
        userAgent:
            userAgent ?? (_settings.desktopMode ? _desktopUserAgent : null),
      );

  String get _displayTitle {
    if (_atHome) return '新标签页';
    final explicit = widget.title?.trim();
    if (_pageTitle.trim().isNotEmpty) return _pageTitle.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final host = Uri.tryParse(_currentUrl)?.host ?? '';
    return host.isEmpty ? '浏览器' : host;
  }

  String get _host {
    if (_atHome) return '';
    final uri = Uri.tryParse(_currentUrl);
    if (uri == null || uri.host.isEmpty) return _currentUrl;
    return uri.host;
  }

  // ==================== 主页 ====================

  /// 当前主页地址：内置主页是伪 origin，在线主题/本地 HTML 是真实地址。
  String get _homeAddress {
    return _homeConfig.entryUrl ?? kWebHomeOrigin;
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  /// 把 App 主题映射成主页的 CSS 变量，保证主页和 App 观感一致。
  Map<String, String> _homeThemeCss() {
    final scheme = Theme.of(context).colorScheme;
    String css(Color color) =>
        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return {
      '--bg': css(scheme.surface),
      '--surface': css(scheme.surfaceContainer),
      '--surface-2': css(scheme.surfaceContainerHigh),
      '--fg': css(scheme.onSurface),
      '--muted': css(scheme.onSurfaceVariant),
      '--primary': css(scheme.primary),
      '--outline': css(scheme.outlineVariant),
    };
  }

  bool _isHomeAddress(String? url) {
    if (url == null || url.isEmpty) return false;
    final entry = _homeConfig.entryUrl;
    if (entry == null) return isWebHomeUrl(url);
    return url == entry || url.startsWith('$entry?') || url.startsWith('$entry#');
  }

  /// 构建内置主页文档（主题变量直接写进首帧，避免闪白）。
  String _buildHomeDocument() {
    if (_homeTemplate.isEmpty) return '';
    return buildWebHomeHtml(css: _homeThemeCss(), dark: _isDark);
  }

  InAppWebViewInitialData? _initialHomeData() {
    if (!_atHome) return null;
    if (_homeConfig.entryUrl != null) return null;
    final html = _buildHomeDocument();
    if (html.isEmpty) return null;
    return InAppWebViewInitialData(
      data: html,
      baseUrl: WebUri(kWebHomeOrigin),
      historyUrl: WebUri(kWebHomeOrigin),
    );
  }

  /// 回到主页（更多菜单 / 刷新主页时调用）。
  Future<void> _openHome() async {
    await WebHomeStore.instance.load(force: true);
    if (!mounted) return;
    final config = WebHomeStore.instance.config;
    final controller = _controller;
    setState(() {
      _homeConfig = config;
      _atHome = true;
      _currentUrl = config.entryUrl ?? kWebHomeOrigin;
      _loading = true;
      _progress = 0;
      _isBookmarked = false;
    });
    if (controller == null) return;
    if (config.entryUrl == null) {
      if (_homeTemplate.isEmpty) {
        try {
          _homeTemplate = await primeWebHomeTemplate();
        } catch (error) {
          debugPrint('WebPage: 读取内置主页失败 - $error');
        }
      }
      await controller.loadData(
        data: _buildHomeDocument(),
        baseUrl: WebUri(kWebHomeOrigin),
        historyUrl: WebUri(kWebHomeOrigin),
        mimeType: 'text/html',
        encoding: 'utf-8',
      );
      return;
    }
    if (config.mode == WebHomeMode.local) {
      // 本地 HTML 需要相对资源（css/js/图片），只在用户显式选择本地模式时
      // 打开 file:// 访问；远程页面仍然会被 shouldOverrideUrlLoading 拦住。
      await controller.setSettings(settings: _webViewSettings());
    }
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(config.entryUrl!)));
  }

  /// 主题变化时把新的变量推给已打开的主页。
  Future<void> _applyHomeTheme() async {
    final controller = _controller;
    if (controller == null) return;
    final payload = jsonEncode({
      'dark': _isDark,
      'css': _homeThemeCss(),
    });
    await controller.evaluateJavascript(
      source: 'window.__gstoreHome && window.__gstoreHome.setTheme($payload);',
    );
  }

  /// 主页拉取的数据：常用网站（按 host 聚合历史）+ 书签 + 主题 + 引擎名。
  Map<String, Object?> _homeData() {
    if (!mounted) return const {};
    final counts = <String, int>{};
    final latest = <String, WebPageEntry>{};
    for (final entry in WebBrowserStore.instance.history) {
      final host = entry.host.toLowerCase();
      if (host.isEmpty) continue;
      counts[host] = (counts[host] ?? 0) + 1;
      latest.putIfAbsent(host, () => entry);
    }
    final hosts = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    Map<String, Object?> item(WebPageEntry entry) => {
          'url': entry.url,
          'title': entry.title,
          'host': entry.host,
        };
    return {
      'engine': kSearchEngineLabels[_settings.searchEngine] ?? '必应',
      'placeholder': '搜索或输入网址',
      'shortcuts': [
        for (final host in hosts.take(8)) item(latest[host]!),
      ],
      'bookmarks': [
        for (final entry in WebBrowserStore.instance.bookmarks.take(8))
          item(entry),
      ],
      'theme': {'dark': _isDark, 'css': _homeThemeCss()},
    };
  }

  void _registerHomeBridge(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'gstoreHome',
      callback: (args) {
        final raw = args.isNotEmpty ? args.first : null;
        if (raw is! Map) return null;
        switch (raw['action']?.toString() ?? '') {
          case 'data':
            return _homeData();
          case 'address':
            if (mounted) _openAddressBar();
            return null;
          case 'open':
            final url = raw['url']?.toString();
            if (mounted && url != null && url.isNotEmpty) {
              _submitAddress(url);
            }
            return null;
          case 'bookmarks':
            if (mounted) _openEntries(bookmarks: true);
            return null;
          case 'history':
            if (mounted) _openEntries(bookmarks: false);
            return null;
          case 'settings':
            if (mounted) _openSettings();
            return null;
        }
        return null;
      },
    );
  }

  Future<void> _syncNavigationState(InAppWebViewController controller) async {
    final canBack = await controller.canGoBack();
    final canForward = await controller.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = canBack;
      _canGoForward = canForward;
    });
  }

  void _syncUrl(String? url) {
    final next = url?.toString();
    if (next == null) return;
    final home = _isHomeAddress(next);
    if (!home && next == _currentUrl) return;
    _currentUrl = next;
    _atHome = home;
    _isBookmarked = home ? false : WebBrowserStore.instance.isBookmarked(next);
  }

  void _recordVisit() {
    if (_atHome) return;
    final url = _currentUrl;
    if (url.isEmpty) return;
    // http→https 之类的重定向中间页会带 "Redirecting…" 标题，
    // 记进去会多出一条无意义的重复记录。
    final title = _pageTitle.trim();
    if (title.startsWith('Redirecting') ||
        title.contains('重定向') ||
        title.contains('正在跳转')) {
      return;
    }
    WebBrowserStore.instance.recordVisit(url, title);
  }

  Future<void> _copyUrl() async {
    if (_atHome) return;
    final url = _currentUrl.isNotEmpty ? _currentUrl : (_initialUrl ?? '');
    if (url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) AppDialogs.showSuccess('已复制链接');
  }

  Future<void> _handleDownload(DownloadStartRequest request) async {
    final url = request.url.toString();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      AppDialogs.showError('不支持下载该链接');
      return;
    }
    final service = ModuleManager.instance.get<IDownloadService>();
    if (service == null) {
      AppDialogs.showError('下载模块未启用');
      return;
    }
    final name = resolveWebDownloadFileName(
      suggestedFilename: request.suggestedFilename,
      contentDisposition: request.contentDisposition,
      mimeType: request.mimeType,
      url: Uri.tryParse(url) ?? Uri(),
    );
    try {
      await service.download(
        'web:${request.url.host.isEmpty ? 'download' : request.url.host}',
        name,
        '',
        url,
        name,
        downloadSize: request.contentLength > 0 ? request.contentLength : null,
        installAfterDownload: false,
      );
      if (!mounted) return;
      AppDialogs.showSuccess(
        '已加入下载：$name',
        actionLabel: '查看',
        onAction: () {
          if (mounted) context.push(AppRoute.downloadCenter);
        },
      );
    } catch (error) {
      if (mounted) AppDialogs.showError('下载失败：$error');
    }
  }

  Future<HttpAuthResponse> _handleHttpAuth(
    URLAuthenticationChallenge challenge,
  ) {
    final pending = _pendingHttpAuth;
    if (pending != null) return pending;
    final future = _promptHttpAuth(challenge);
    _pendingHttpAuth = future;
    future.whenComplete(() => _pendingHttpAuth = null);
    return future;
  }

  Future<HttpAuthResponse> _promptHttpAuth(
    URLAuthenticationChallenge challenge,
  ) async {
    final space = challenge.protectionSpace;
    final credentials = await showWebHttpAuthSheet(
      context,
      host: space.host,
      realm: space.realm,
    );
    if (credentials == null) return HttpAuthResponse();
    return HttpAuthResponse(
      action: HttpAuthResponseAction.PROCEED,
      username: credentials.username,
      password: credentials.password,
      permanentPersistence: true,
    );
  }

  Future<void> _loadUrl(String url) async {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _currentUrl = url;
      _atHome = false;
      _loading = true;
      _progress = 0;
      _isBookmarked = WebBrowserStore.instance.isBookmarked(url);
    });
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _openAddressBar() {
    if (_findVisible) _closeFind();
    setState(() => _addressVisible = true);
  }

  void _closeAddressBar() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!mounted) return;
    setState(() => _addressVisible = false);
  }

  Future<void> _submitAddress(String raw) async {
    _closeAddressBar();
    final resolved = resolveWebInput(
      raw,
      searchTemplate: _settings.searchTemplate,
    );
    if (resolved == null) {
      AppDialogs.showError('这个地址不能打开');
      return;
    }
    await _loadUrl(resolved);
  }

  Future<void> _openEntries({required bool bookmarks}) async {
    final entry = await showWebEntriesSheet(context, bookmarks: bookmarks);
    if (entry == null) return;
    await _loadUrl(entry.url);
  }

  Future<void> _toggleBookmark() async {
    final url = _currentUrl;
    if (url.isEmpty || _atHome) return;
    final saved =
        await WebBrowserStore.instance.toggleBookmark(url, _pageTitle);
    if (!mounted) return;
    setState(() => _isBookmarked = saved);
    AppDialogs.showSuccess(saved ? '已收藏' : '已取消收藏');
  }

  // ==================== 工具菜单动作 ====================

  Future<void> _toggleNightMode() async {
    final next = _settings.copyWith(nightMode: !_settings.nightMode);
    setState(() => _settings = next);
    await WebViewSettingsStore.instance.save(next);
    await _applyNightMode();
    if (mounted) {
      AppDialogs.showSuccess(next.nightMode ? '已开启夜间模式' : '已关闭夜间模式');
    }
  }

  Future<void> _applyNightMode() async {
    final controller = _controller;
    // 主页是 App 自己的界面，跟随主题，不做反色。
    if (controller == null || _atHome) return;
    final css = jsonEncode(_nightCss);
    final enabled = _settings.nightMode ? 'true' : 'false';
    await controller.evaluateJavascript(
      source: '''
(function () {
  var id = '__gs_night_mode';
  var old = document.getElementById(id);
  if (old) old.remove();
  if (!$enabled) return;
  var style = document.createElement('style');
  style.id = id;
  style.textContent = $css;
  (document.head || document.documentElement).appendChild(style);
})();
''',
    );
  }

  Future<void> _toggleDesktopMode() async {
    final controller = _controller;
    if (controller == null) return;
    final next = _settings.copyWith(desktopMode: !_settings.desktopMode);
    setState(() => _settings = next);
    await WebViewSettingsStore.instance.save(next);
    await controller.setSettings(settings: _webViewSettings());
    await controller.reload();
    if (mounted) {
      AppDialogs.showSuccess(next.desktopMode ? '已切换到电脑模式' : '已切回手机模式');
    }
  }

  Future<void> _changeFontSize(int value) async {
    final next = _settings.copyWith(textZoom: value);
    setState(() => _settings = next);
    await WebViewSettingsStore.instance.save(next);
    await _controller?.setSettings(settings: _webViewSettings());
  }

  Future<void> _openFind() async {
    setState(() => _findVisible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _findFocus.requestFocus();
    });
  }

  Future<void> _closeFind() async {
    // ignore: deprecated_member_use
    await _controller?.clearMatches();
    if (!mounted) return;
    setState(() {
      _findVisible = false;
      _findHasQuery = false;
      _findController.clear();
    });
  }

  Future<void> _find({required bool forward}) async {
    final text = _findController.text.trim();
    final controller = _controller;
    if (text.isEmpty || controller == null) return;
    if (_findHasQuery) {
      // findNext/findAllAsync 在 6.x 标记为 deprecated，但替代的
      // FindInteractionController 还没有挂到 InAppWebViewController。
      // ignore: deprecated_member_use
      await controller.findNext(forward: forward);
    } else {
      // ignore: deprecated_member_use
      await controller.findAllAsync(find: text);
      _findHasQuery = true;
    }
  }

  Future<void> _showSource() async {
    final raw = await _controller?.evaluateJavascript(
      source: 'document.documentElement.outerHTML',
    );
    final html = _decodeJsString(raw);
    if (!mounted) return;
    // 页面正在导航/重载时 DOM 可能还是空的，直接提示稍后再试。
    if (html.trim().isEmpty ||
        html.contains('<body></body>') ||
        html.length < 120) {
      AppDialogs.showError('页面还没加载完成，请稍后再试');
      return;
    }
    await showWebSourceSheet(context, html: html, url: _currentUrl);
  }

  Future<void> _showPageInfo() async {
    SslCertificate? certificate;
    try {
      certificate = await _controller?.getCertificate();
    } catch (_) {
      certificate = null;
    }
    if (!mounted) return;
    await showWebInfoSheet(
      context,
      title: _pageTitle,
      url: _currentUrl,
      certificate: certificate,
    );
  }

  Future<void> _showResources() async {
    final raw = await _controller?.evaluateJavascript(source: _resourceScript);
    var urls = <String>[];
    try {
      final decoded = jsonDecode(_decodeJsString(raw));
      if (decoded is List) {
        urls = [for (final item in decoded) item.toString()];
      }
    } catch (_) {
      urls = <String>[];
    }
    if (!mounted) return;
    await showWebResourcesSheet(
      context,
      urls: urls,
      onOpen: _loadUrl,
    );
  }

  Future<void> _openSettings() async {
    final before = _settings;
    final beforeHome = _homeConfig;
    await context.push(AppRoute.webViewSettings);
    if (!mounted) return;
    await WebViewSettingsStore.instance.load(force: true);
    await WebHomeStore.instance.load(force: true);
    final next = WebViewSettingsStore.instance.settings;
    final home = WebHomeStore.instance.config;
    final homeChanged =
        beforeHome.mode != home.mode || beforeHome.location != home.location;
    setState(() {
      _settings = next;
      _homeConfig = home;
    });
    if (homeChanged && _atHome) {
      await _openHome();
      return;
    }
    final controller = _controller;
    if (controller == null) return;
    await controller.setSettings(settings: _webViewSettings());
    await _applyNightMode();
    if (before.desktopMode != next.desktopMode ||
        before.javaScriptEnabled != next.javaScriptEnabled ||
        before.cacheEnabled != next.cacheEnabled ||
        before.thirdPartyCookies != next.thirdPartyCookies ||
        before.loadImages != next.loadImages) {
      await controller.reload();
    }
  }

  String _decodeJsString(dynamic raw) {
    final text = raw?.toString() ?? '';
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is String) return decoded;
      } catch (_) {
        // 保留原始值
      }
    }
    return text;
  }

  Future<void> _handleMore() async {
    final action = await showWebMoreSheet(
      context,
      hasUrl: !_atHome && _currentUrl.isNotEmpty,
      nightMode: _settings.nightMode,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case WebMoreAction.bookmarks:
        await _openEntries(bookmarks: true);
      case WebMoreAction.history:
        await _openEntries(bookmarks: false);
      case WebMoreAction.downloads:
        await context.push(AppRoute.downloadCenter);
      case WebMoreAction.findInPage:
        await _openFind();
      case WebMoreAction.nightMode:
        await _toggleNightMode();
      case WebMoreAction.desktopMode:
        await _toggleDesktopMode();
      case WebMoreAction.fontSize:
        await showWebFontSizeSheet(
          context,
          current: _settings.textZoom,
          onChanged: _changeFontSize,
        );
      case WebMoreAction.viewSource:
        await _showSource();
      case WebMoreAction.pageInfo:
        await _showPageInfo();
      case WebMoreAction.resources:
        await _showResources();
      case WebMoreAction.settings:
        await _openSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final initialUrl = _initialUrl;

    // 只有「传了 url 但解析不出来」才显示错误页；没传 url 是新标签页。
    if (!_startsAtHome && initialUrl == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title ?? '浏览器')),
        body: Center(
          child: Padding(
            padding: AppSpacing.allXL,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  TablerIcons.link_off,
                  size: 40,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '这个链接不能在内置浏览器打开',
                  style: textTheme.titleSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xs),
                SelectableText(
                  widget.url ?? '',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_settingsReady || !_homeReady) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title ?? '浏览器')),
        body: const Center(child: AppLoading()),
      );
    }

    // 内置主页模板读不到（极少数资源损坏场景）：给一个明确的错误页，
    // 而不是创建一只什么都不显示的 WebView。
    if (_startsAtHome && _homeConfig.entryUrl == null && _homeTemplate.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('浏览器')),
        body: Center(
          child: Padding(
            padding: AppSpacing.allXL,
            child: Text(
              '主页加载失败，请到浏览器设置里切换主页来源',
              style: Theme.of(context).textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    // 系统返回始终退出本页；网页历史的返回交给底部按钮，避免被
    // about:blank/重定向产生的历史条目困在页面里出不去。
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: _openAddressBar,
          borderRadius: AppRadius.allSM,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: AppSpacing.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleMedium,
                      ),
                    ),
                    Icon(
                      TablerIcons.chevron_down,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                Text(
                  _host.isEmpty ? '输入网址或搜索' : _host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '主页',
            icon: const Icon(TablerIcons.home),
            onPressed: _openHome,
          ),
          IconButton(
            tooltip: _isBookmarked ? '取消收藏' : '收藏',
            icon: Icon(
              _isBookmarked ? TablerIcons.star_filled : TablerIcons.star,
              color: _isBookmarked ? scheme.primary : null,
            ),
            onPressed: _atHome || _currentUrl.isEmpty ? null : _toggleBookmark,
          ),
          IconButton(
            tooltip: '复制链接',
            icon: const Icon(TablerIcons.link),
            onPressed: _atHome ? null : _copyUrl,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              // 输入条出现时页面轻微上推，和 Chrome 的观感一致。
              padding: EdgeInsets.only(bottom: _addressVisible ? 10 : 0),
              child: Column(
                children: [
                  if (_loading)
                    LinearProgressIndicator(
                      value: _progress > 0 && _progress < 1 ? _progress : null,
                      minHeight: 2,
                    ),
                  if (_findVisible) _buildFindBar(scheme, textTheme),
                  Expanded(
                    child: Stack(
                      children: [
                        InAppWebView(
                          key: const ValueKey('gstore-webview'),
                          initialUrlRequest: _startsAtHome
                              ? (_homeConfig.entryUrl != null
                                  ? URLRequest(
                                      url: WebUri(_homeConfig.entryUrl!))
                                  : null)
                              : URLRequest(url: WebUri(initialUrl!)),
                          initialData: _initialHomeData(),
                          initialSettings: _webViewSettings(),
                          onWebViewCreated: (controller) {
                            _controller = controller;
                            _registerHomeBridge(controller);
                          },
                          onLoadStart: (controller, url) {
                            if (!mounted) return;
                            setState(() {
                              _loading = true;
                              _progress = 0;
                              _syncUrl(url?.toString());
                            });
                          },
                          onProgressChanged: (controller, progress) {
                            if (!mounted) return;
                            setState(() => _progress = progress / 100);
                          },
                          onLoadStop: (controller, url) {
                            if (!mounted) return;
                            setState(() {
                              _loading = false;
                              _progress = 1;
                              _syncUrl(url?.toString());
                            });
                            _recordVisit();
                            _syncNavigationState(controller);
                            if (_atHome) {
                              _applyHomeTheme();
                            } else if (_settings.nightMode) {
                              // 注入样式只对当前文档生效，换页后需要重新注入。
                              _applyNightMode();
                            }
                          },
                          onTitleChanged: (controller, title) {
                            final text = title?.trim() ?? '';
                            if (!mounted || text.isEmpty) return;
                            setState(() => _pageTitle = text);
                            _recordVisit();
                          },
                          onUpdateVisitedHistory: (controller, url, isReload) {
                            if (!mounted) return;
                            setState(() => _syncUrl(url?.toString()));
                            _syncNavigationState(controller);
                          },
                          shouldOverrideUrlLoading: (controller, action) async {
                            final raw = action.request.url;
                            if (raw == null) {
                              return NavigationActionPolicy.ALLOW;
                            }
                            final uri = Uri.tryParse(raw.toString());
                            if (uri == null) {
                              return NavigationActionPolicy.CANCEL;
                            }
                            final scheme = uri.scheme.toLowerCase();
                            if (scheme == 'about' ||
                                scheme == 'http' ||
                                scheme == 'https') {
                              return NavigationActionPolicy.ALLOW;
                            }
                            // 本地 HTML 主页自己的相跳（同目录文件）放行；其他
                            // file:// 一律拦掉，避免页面借机打开本地文件。
                            if (scheme == 'file' &&
                                _homeConfig.mode == WebHomeMode.local &&
                                _isHomeAddress(raw.toString())) {
                              return NavigationActionPolicy.ALLOW;
                            }
                            // mailto:/tel:/intent: 等交给系统会跳出 App，这里直接忽略。
                            return NavigationActionPolicy.CANCEL;
                          },
                          onDownloadStartRequest: (controller, request) {
                            _handleDownload(request);
                          },
                          onReceivedHttpAuthRequest: (controller, challenge) =>
                              _handleHttpAuth(challenge),
                          onReceivedClientCertRequest:
                              (controller, challenge) async {
                            if (mounted) {
                              AppDialogs.showWarning('该网站要求客户端证书，暂不支持');
                            }
                            return ClientCertResponse(
                              action: ClientCertResponseAction.CANCEL,
                              certificatePath: '',
                            );
                          },
                          onReceivedError: (controller, request, error) {
                            // 只处理主文档失败；子资源失败不影响整页。
                            if (request.isForMainFrame != true) return;
                            if (!mounted) return;
                            setState(() => _loading = false);
                          },
                        ),
                        // WebView 首次初始化可能要十几秒（系统 WebView 冷启动），
                        // 这期间不要留白，给一个明确的加载态。
                        if (_loading && (_progress <= 0 || _progress >= 1))
                          const Center(child: AppLoading()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_addressVisible) ...[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeAddressBar,
                child: ColoredBox(
                  color: scheme.scrim.withValues(alpha: 0.25),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) => Transform.translate(
                  offset: Offset(0, (1 - value) * 28),
                  child: Opacity(opacity: value, child: child),
                ),
                child: WebAddressBar(
                  initialText: _atHome ? '' : _currentUrl,
                  onSubmit: _submitAddress,
                ),
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: '后退',
                icon: const Icon(TablerIcons.arrow_left),
                onPressed: _canGoBack ? () => _controller?.goBack() : null,
              ),
              IconButton(
                tooltip: '前进',
                icon: const Icon(TablerIcons.arrow_right),
                onPressed:
                    _canGoForward ? () => _controller?.goForward() : null,
              ),
              IconButton(
                tooltip: _loading ? '停止' : '刷新',
                icon: Icon(_loading ? TablerIcons.x : TablerIcons.refresh),
                onPressed: _loading
                    ? () => _controller?.stopLoading()
                    : () => _atHome ? _openHome() : _controller?.reload(),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  _atHome ? '主页' : _host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: '更多',
                icon: const Icon(TablerIcons.dots),
                onPressed: _handleMore,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFindBar(ColorScheme scheme, TextTheme textTheme) {
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 2,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _findController,
                focusNode: _findFocus,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (_) => _findHasQuery = false,
                onSubmitted: (_) => _find(forward: true),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '页内查找',
                  border: InputBorder.none,
                  prefixIcon: Icon(TablerIcons.search, size: 18),
                ),
                style: textTheme.bodyMedium,
              ),
            ),
            IconButton(
              tooltip: '上一个',
              icon: const Icon(TablerIcons.chevron_up),
              onPressed: () => _find(forward: false),
            ),
            IconButton(
              tooltip: '下一个',
              icon: const Icon(TablerIcons.chevron_down),
              onPressed: () => _find(forward: true),
            ),
            IconButton(
              tooltip: '关闭',
              icon: const Icon(TablerIcons.x),
              onPressed: _closeFind,
            ),
          ],
        ),
      ),
    );
  }
}
