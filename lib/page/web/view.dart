import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/webview/web_browser_store.dart';
import 'package:gstore/core/webview/webview_url_normalizer.dart';

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
  late final String? _initialUrl = normalizeWebViewUrl(widget.url);

  String _currentUrl = '';
  String _pageTitle = '';
  double _progress = 0;
  // WebView 首次创建（系统 WebView 冷启动）期间不会有任何回调，
  // 先按加载中处理，避免用户看到空白页。
  bool _loading = true;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _isBookmarked = false;

  bool _nightMode = false;
  bool _desktopMode = false;
  int _textZoom = 100;

  bool _findVisible = false;
  bool _findHasQuery = false;
  final TextEditingController _findController = TextEditingController();
  final FocusNode _findFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _currentUrl = _initialUrl ?? '';
    _isBookmarked = WebBrowserStore.instance.isBookmarked(_currentUrl);
    WebBrowserStore.instance.load().then((_) {
      if (!mounted) return;
      setState(() {
        _isBookmarked = WebBrowserStore.instance.isBookmarked(_currentUrl);
      });
    });
  }

  @override
  void dispose() {
    _findController.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  InAppWebViewSettings _settings({int? textZoom, String? userAgent}) =>
      InAppWebViewSettings(
        javaScriptEnabled: true,
        supportMultipleWindows: false,
        javaScriptCanOpenWindowsAutomatically: false,
        mediaPlaybackRequiresUserGesture: true,
        allowFileAccess: false,
        allowContentAccess: false,
        domStorageEnabled: true,
        databaseEnabled: true,
        thirdPartyCookiesEnabled: true,
        safeBrowsingEnabled: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
        textZoom: textZoom ?? _textZoom,
        userAgent: userAgent,
      );

  String get _displayTitle {
    final explicit = widget.title?.trim();
    if (_pageTitle.trim().isNotEmpty) return _pageTitle.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final host = Uri.tryParse(_currentUrl)?.host ?? '';
    return host.isEmpty ? '浏览器' : host;
  }

  String get _host {
    final uri = Uri.tryParse(_currentUrl);
    if (uri == null || uri.host.isEmpty) return _currentUrl;
    return uri.host;
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
    if (next == null || next == _currentUrl) return;
    _currentUrl = next;
    _isBookmarked = WebBrowserStore.instance.isBookmarked(next);
  }

  void _recordVisit() {
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
    final url = _currentUrl.isNotEmpty ? _currentUrl : (_initialUrl ?? '');
    if (url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) AppDialogs.showSuccess('已复制链接');
  }

  Future<void> _loadUrl(String url) async {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _currentUrl = url;
      _loading = true;
      _progress = 0;
      _isBookmarked = WebBrowserStore.instance.isBookmarked(url);
    });
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _openInput({bool searchMode = false}) async {
    final input = await showWebInputSheet(
      context,
      initial: searchMode ? null : (_currentUrl.isEmpty ? null : _currentUrl),
      searchMode: searchMode,
    );
    if (input == null) return;
    final resolved = resolveWebInput(input);
    if (resolved == null) {
      if (mounted) AppDialogs.showError('这个地址不能打开');
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
    if (url.isEmpty) return;
    final saved =
        await WebBrowserStore.instance.toggleBookmark(url, _pageTitle);
    if (!mounted) return;
    setState(() => _isBookmarked = saved);
    AppDialogs.showSuccess(saved ? '已收藏' : '已取消收藏');
  }

  // ==================== 工具菜单动作 ====================

  Future<void> _toggleNightMode() async {
    setState(() => _nightMode = !_nightMode);
    await _applyNightMode();
    if (mounted) AppDialogs.showSuccess(_nightMode ? '已开启夜间模式' : '已关闭夜间模式');
  }

  Future<void> _applyNightMode() async {
    final controller = _controller;
    if (controller == null) return;
    final css = jsonEncode(_nightCss);
    final enabled = _nightMode ? 'true' : 'false';
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
    setState(() => _desktopMode = !_desktopMode);
    await controller.setSettings(
      settings: _settings(userAgent: _desktopMode ? _desktopUserAgent : null),
    );
    await controller.reload();
    if (mounted) {
      AppDialogs.showSuccess(_desktopMode ? '已切换到电脑模式' : '已切回手机模式');
    }
  }

  Future<void> _changeFontSize(int value) async {
    setState(() => _textZoom = value);
    await _controller?.setSettings(settings: _settings(textZoom: value));
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

  Future<void> _clearData() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清除浏览数据',
      message: '将清除所有网站的 Cookie、本地存储与缓存。'
          '所有站点（包括 AI 网页工具）都会退出登录，且不可恢复。',
      confirmText: '清除',
      isDangerous: true,
    );
    if (ok != true) return;
    await CookieManager.instance().deleteAllCookies();
    await WebStorageManager.instance().deleteAllData();
    await InAppWebViewController.clearAllCache();
    if (!mounted) return;
    AppDialogs.showSuccess('浏览数据已清除');
    await _controller?.reload();
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
      hasUrl: _currentUrl.isNotEmpty,
      nightMode: _nightMode,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case WebMoreAction.bookmarks:
        await _openEntries(bookmarks: true);
      case WebMoreAction.history:
        await _openEntries(bookmarks: false);
      case WebMoreAction.findInPage:
        await _openFind();
      case WebMoreAction.nightMode:
        await _toggleNightMode();
      case WebMoreAction.desktopMode:
        await _toggleDesktopMode();
      case WebMoreAction.fontSize:
        await showWebFontSizeSheet(
          context,
          current: _textZoom,
          onChanged: _changeFontSize,
        );
      case WebMoreAction.viewSource:
        await _showSource();
      case WebMoreAction.pageInfo:
        await _showPageInfo();
      case WebMoreAction.resources:
        await _showResources();
      case WebMoreAction.clearData:
        await _clearData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final initialUrl = _initialUrl;

    if (initialUrl == null) {
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

    // 系统返回始终退出本页；网页历史的返回交给底部按钮，避免被
    // about:blank/重定向产生的历史条目困在页面里出不去。
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: _openInput,
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
            tooltip: _isBookmarked ? '取消收藏' : '收藏',
            icon: Icon(
              _isBookmarked ? TablerIcons.star_filled : TablerIcons.star,
              color: _isBookmarked ? scheme.primary : null,
            ),
            onPressed: _currentUrl.isEmpty ? null : _toggleBookmark,
          ),
          IconButton(
            tooltip: '复制链接',
            icon: const Icon(TablerIcons.link),
            onPressed: _copyUrl,
          ),
        ],
      ),
      body: Column(
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
                  initialUrlRequest: URLRequest(url: WebUri(initialUrl)),
                  initialSettings: _settings(),
                  onWebViewCreated: (controller) {
                    _controller = controller;
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
                    // 注入样式只对当前文档生效，换页后需要重新注入。
                    if (_nightMode) _applyNightMode();
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
                    if (raw == null) return NavigationActionPolicy.ALLOW;
                    final uri = Uri.tryParse(raw.toString());
                    if (uri == null) return NavigationActionPolicy.CANCEL;
                    final scheme = uri.scheme.toLowerCase();
                    if (scheme == 'about' ||
                        scheme == 'http' ||
                        scheme == 'https') {
                      return NavigationActionPolicy.ALLOW;
                    }
                    // mailto:/tel:/intent: 等交给系统会跳出 App，这里直接忽略。
                    return NavigationActionPolicy.CANCEL;
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
                    : () => _controller?.reload(),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  _host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: '浏览器工具',
                icon: const Icon(TablerIcons.tool),
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
