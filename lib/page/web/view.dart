import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/webview/web_browser_store.dart';
import 'package:gstore/core/webview/webview_url_normalizer.dart';

import 'web_sheets.dart';

/// 内置浏览器（AI 回复里的链接、外部跳转都走这里）。
///
/// 浏览器级能力：地址/搜索输入（Bing）、历史记录、书签、前进/后退/刷新、
/// 复制链接；底部「更多」宫格菜单汇总全部功能。
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

  Future<void> _clearHistory() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清空历史记录',
      message: '确定清空全部浏览历史吗？书签不受影响。',
      confirmText: '清空',
      isDangerous: true,
    );
    if (ok != true) return;
    await WebBrowserStore.instance.clearHistory();
    if (mounted) AppDialogs.showSuccess('历史记录已清空');
  }

  Future<void> _handleMore() async {
    final action = await showWebMoreSheet(
      context,
      bookmarked: _isBookmarked,
      hasUrl: _currentUrl.isNotEmpty,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case WebMoreAction.openUrl:
        await _openInput();
      case WebMoreAction.search:
        await _openInput(searchMode: true);
      case WebMoreAction.history:
        await _openEntries(bookmarks: false);
      case WebMoreAction.bookmarks:
        await _openEntries(bookmarks: true);
      case WebMoreAction.toggleBookmark:
        await _toggleBookmark();
      case WebMoreAction.refresh:
        if (_loading) {
          await _controller?.stopLoading();
        } else {
          await _controller?.reload();
        }
      case WebMoreAction.copyLink:
        await _copyUrl();
      case WebMoreAction.clearHistory:
        await _clearHistory();
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
          Expanded(
            child: Stack(
              children: [
                InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(initialUrl)),
                  initialSettings: InAppWebViewSettings(
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
                    mixedContentMode:
                        MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                  ),
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
}
