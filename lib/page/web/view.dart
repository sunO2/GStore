import 'dart:collection';

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
import 'package:gstore/core/webview/web_userscript.dart';
import 'package:gstore/core/webview/web_userscript_store.dart';
import 'package:gstore/core/webview/web_view_settings.dart';
import 'package:gstore/core/webview/webview_url_normalizer.dart';

import 'browser_tabs_sheet.dart';
import 'web_address_bar.dart';
import 'web_sheets.dart';
import 'web_tools_sheets.dart';
import 'web_userscript_sheets.dart';

/// 内置浏览器（AI 回复里的链接、外部跳转都走这里）。
///
/// 地址/搜索（必应建议）、历史、书签、页内查找、夜间模式、电脑模式、
/// 字体大小、查看源码、页面信息、资源嗅探、用户脚本、多标签页。
///
/// 本类是**标签页外壳**：每个标签页是一个独立的 [BrowserTabPage]，
/// 放进 IndexedStack 保活；切换/关闭/新建由这里统一管理。
class WebPage extends StatefulWidget {
  const WebPage({super.key, this.url, this.title});

  /// 要打开的地址；可以是裸域名，内部会补 `https://`。
  final String? url;

  /// 标题栏文案；为空时用网页标题或域名。
  final String? title;

  @override
  State<WebPage> createState() => _WebPageState();
}

/// 一个标签页在外壳里的句柄。
class _BrowserTabHandle {
  _BrowserTabHandle({
    required this.id,
    this.url,
    this.title,
    required this.lastUsed,
  });

  final int id;
  final GlobalKey<BrowserTabPageState> key =
      GlobalKey<BrowserTabPageState>();

  /// 标签页当前地址；为空表示主页（恢复时重新加载主页而不是 gstore.home）。
  String? url;
  String? title;

  /// 切换出去时抓的截图，标签页列表用它当缩略图。
  Uint8List? thumbnail;

  /// 超出保活上限后释放 WebView，切回时按 [url] 重新加载。
  bool suspended = false;

  int lastUsed;
}

class _WebPageState extends State<WebPage> {
  /// 同时保活的 WebView 上限；超出的按 LRU 释放（保留标签页与缩略图）。
  static const int _maxLiveTabs = 5;

  final List<_BrowserTabHandle> _tabs = <_BrowserTabHandle>[];
  final ValueNotifier<List<BrowserTabCardData>> _tabCards =
      ValueNotifier<List<BrowserTabCardData>>(const []);
  int _active = 0;
  int _nextId = 1;
  int _clock = 0;

  @override
  void initState() {
    super.initState();
    _tabs.add(_createTab(url: widget.url, title: widget.title));
    _syncCards();
  }

  @override
  void dispose() {
    _tabCards.dispose();
    super.dispose();
  }

  _BrowserTabHandle _createTab({String? url, String? title}) {
    return _BrowserTabHandle(
      id: _nextId++,
      url: url,
      title: title,
      lastUsed: ++_clock,
    );
  }

  void _syncCards() {
    _tabCards.value = [
      for (var index = 0; index < _tabs.length; index++)
        BrowserTabCardData(
          index: index,
          title: _tabs[index].title ?? '',
          url: _tabs[index].url ?? '',
          thumbnail: _tabs[index].thumbnail,
          active: index == _active,
          suspended: _tabs[index].suspended,
        ),
    ];
  }

  void _refreshTabMeta(_BrowserTabHandle tab) {
    final state = tab.key.currentState;
    if (state == null) return;
    tab.url = state.isShowingHome ? null : state.currentUrl;
    tab.title = state.currentTitle;
  }

  Future<void> _newTab() async {
    if (!mounted) return;
    setState(() {
      final handle = _createTab();
      _tabs.insert(_active + 1, handle);
      _active = _tabs.indexOf(handle);
    });
    _syncCards();
    await _enforceLimit();
  }

  Future<void> _activate(int index) async {
    if (index == _active || index < 0 || index >= _tabs.length) return;
    final outgoing = _tabs[_active];
    _refreshTabMeta(outgoing);
    outgoing.thumbnail ??=
        await outgoing.key.currentState?.captureThumbnail();
    if (!mounted) return;
    setState(() {
      final target = _tabs[index];
      target.suspended = false;
      target.lastUsed = ++_clock;
      _active = index;
    });
    _syncCards();
    await _enforceLimit();
  }

  Future<void> _closeTab(int index) async {
    if (index < 0 || index >= _tabs.length) return;
    if (_tabs.length == 1) {
      if (!mounted) return;
      // 关掉标签页后就没有浏览器页面了：退到首页（同时把标签页面板一起关掉）。
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    setState(() {
      _tabs.removeAt(index);
      if (_active >= _tabs.length) {
        _active = _tabs.length - 1;
      } else if (index < _active) {
        _active -= 1;
      }
      _tabs[_active].suspended = false;
    });
    _syncCards();
    await _enforceLimit();
  }

  /// 超过保活上限时，把最久未使用的非活动标签页挂起。
  Future<void> _enforceLimit() async {
    final live = _tabs.where((tab) => !tab.suspended).toList();
    if (live.length <= _maxLiveTabs) return;
    final activeId = _tabs[_active].id;
    final candidates = live.where((tab) => tab.id != activeId).toList()
      ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    if (candidates.isEmpty) return;
    final victim = candidates.first;
    _refreshTabMeta(victim);
    victim.thumbnail = await victim.key.currentState?.captureThumbnail();
    if (!mounted) return;
    setState(() => victim.suspended = true);
    _syncCards();
  }

  Future<void> _openTabs() async {
    final current = _tabs[_active];
    _refreshTabMeta(current);
    current.thumbnail ??= await current.key.currentState?.captureThumbnail();
    _syncCards();
    if (!mounted) return;
    await showBrowserTabsSheet(
      context,
      cards: _tabCards,
      onSelect: (index) => unawaited(_activate(index)),
      onClose: (index) => unawaited(_closeTab(index)),
      onNewTab: () => unawaited(_newTab()),
    );
    if (mounted) _syncCards();
  }

  Widget _buildTab(_BrowserTabHandle tab) {
    if (tab.suspended) {
      return _SuspendedTab(
        title: tab.title,
        url: tab.url,
        thumbnail: tab.thumbnail,
        onRestore: () => unawaited(_activate(_tabs.indexOf(tab))),
        onClose: () => unawaited(_closeTab(_tabs.indexOf(tab))),
      );
    }
    return BrowserTabPage(
      key: tab.key,
      initialUrl: tab.url,
      title: tab.title,
      tabCount: _tabs.length,
      onOpenTabs: () => unawaited(_openTabs()),
      onNewTab: () => unawaited(_newTab()),
      onTabMeta: (url, title) {
        tab.url = isWebHomeUrl(url) ? null : url;
        tab.title = title;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      // 每页都是 Scaffold，必须拿到紧约束，否则会被压成内容高度。
      sizing: StackFit.expand,
      index: _active.clamp(0, _tabs.length - 1),
      children: [for (final tab in _tabs) _buildTab(tab)],
    );
  }
}

/// 被释放的标签页占位（正常情况下不会被选中，选中前会先恢复）。
class _SuspendedTab extends StatelessWidget {
  const _SuspendedTab({
    required this.title,
    required this.url,
    required this.thumbnail,
    required this.onRestore,
    required this.onClose,
  });

  final String? title;
  final String? url;
  final Uint8List? thumbnail;
  final VoidCallback onRestore;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final host = Uri.tryParse(url ?? '')?.host ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          (title == null || title!.trim().isEmpty) ? '标签页' : title!,
        ),
        actions: [
          IconButton(
            tooltip: '关闭标签页',
            icon: const Icon(TablerIcons.x),
            onPressed: onClose,
          ),
        ],
      ),
      body: Center(
        child: InkWell(
          onTap: onRestore,
          borderRadius: AppRadius.allSM,
          child: Padding(
            padding: AppSpacing.allLG,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (thumbnail != null)
                  ClipRRect(
                    borderRadius: AppRadius.allSM,
                    child: Image.memory(
                      thumbnail!,
                      width: 180,
                      fit: BoxFit.cover,
                    ),
                  )
                else
                  Icon(
                    TablerIcons.photo,
                    size: 48,
                    color: scheme.onSurfaceVariant,
                  ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  host.isEmpty ? '已释放的标签页' : host,
                  style: textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '点按重新加载',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个标签页的浏览内容（不含标签管理）。
///
/// 每个标签页拥有独立的 WebView、地址条、页内查找和用户脚本注入状态；
/// 由 [WebPage] 放进 IndexedStack 保活。
class BrowserTabPage extends StatefulWidget {
  const BrowserTabPage({
    super.key,
    this.initialUrl,
    this.title,
    required this.tabCount,
    required this.onOpenTabs,
    required this.onNewTab,
    required this.onTabMeta,
  });

  /// 要打开的地址；可以是裸域名，内部会补 `https://`。为空时从主页开始。
  final String? initialUrl;

  /// 标题栏文案；为空时用网页标题或域名。
  final String? title;

  /// 当前标签页总数（底部标签按钮上的数字）。
  final int tabCount;

  final VoidCallback onOpenTabs;
  final VoidCallback onNewTab;

  /// URL/标题变化时回传给 shell，供标签页列表展示。
  final void Function(String url, String title) onTabMeta;

  @override
  State<BrowserTabPage> createState() => BrowserTabPageState();
}

class BrowserTabPageState extends State<BrowserTabPage> {
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

  /// 入口原始地址。
  late final String _rawUrl = (widget.initialUrl ?? '').trim();

  /// 从外部/地址栏打开的 `.user.js`：不加载源码，直接走安装确认。
  late final bool _startsWithUserScript = looksLikeUserScriptUrl(_rawUrl);

  /// 没有传 url（点「主页」/ 新标签页）时从内置主页开始。
  late final bool _startsAtHome = _rawUrl.isEmpty || _startsWithUserScript;
  late final String? _initialUrl =
      _startsAtHome ? null : normalizeWebViewUrl(widget.initialUrl);

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

  /// 命中当前页面的用户脚本（用于导航头角标与「本页脚本」面板）。
  List<WebUserScript> _pageScripts = const [];
  bool _scriptsReady = false;

  /// 每个脚本一枚 token，只出现在注入脚本的闭包里；桥调用据此反查脚本。
  final Map<String, String> _userScriptTokens = <String, String>{};
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
    if (_startsWithUserScript) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_installUserScript(_rawUrl));
      });
    }
    WebUserScriptStore.instance.load().then((_) {
      if (!mounted) return;
      setState(() {
        _scriptsReady = true;
        _pageScripts = WebUserScriptStore.instance.scriptsForUrl(
          _currentUrl.isEmpty ? null : _currentUrl,
        );
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

  /// 当前地址（shell 用来做标签页卡片）。
  String get currentUrl => _currentUrl;

  /// 当前标题（shell 用来做标签页卡片）。
  String get currentTitle => _displayTitle;

  bool get isShowingHome => _atHome;

  /// 切换标签前抓一张缩略图；隐藏的 WebView 抓不到图，所以只在可见时调用。
  Future<Uint8List?> captureThumbnail() async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      return await controller.takeScreenshot();
    } catch (_) {
      return null;
    }
  }

  void _notifyMeta() {
    try {
      widget.onTabMeta(_currentUrl, _displayTitle);
    } catch (_) {
      // shell 已经销毁时忽略。
    }
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
      // WebView 的错误页也会被记成一次访问（标题是「网页无法打开」），
      // 这类条目放进常用网站只会得到一个打不开的入口。
      if (_isErrorPageTitle(entry.title)) continue;
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

  bool _isErrorPageTitle(String title) {
    final text = title.trim();
    if (text.isEmpty) return true;
    return text.contains('网页无法打开') ||
        text.contains('Web page not available') ||
        text.contains('Webpage not available');
  }


  // ==================== 用户脚本 ====================

  String _tokenForScript(String scriptId) =>
      _userScriptTokens.putIfAbsent(scriptId, newUserScriptToken);

  String? _scriptIdForToken(String token) {
    if (token.isEmpty) return null;
    for (final entry in _userScriptTokens.entries) {
      if (entry.value == token) return entry.key;
    }
    return null;
  }

  List<UserScript> _buildUserScripts() {
    final result = <UserScript>[];
    for (final script in WebUserScriptStore.instance.enabledScripts) {
      final source = buildUserScriptBootstrap(
        script,
        token: _tokenForScript(script.id),
      );
      if (source.isEmpty) continue;
      result.add(
        UserScript(
          source: source,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          allowedOriginRules: script.originRules,
        ),
      );
    }
    return result;
  }

  /// 重建注入列表：GM_setValue 的值是内联进脚本的，页面加载后刷新一次，
  /// 下一次导航就能读到最新值。
  Future<void> _refreshUserScripts() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.removeAllUserScripts();
      for (final script in _buildUserScripts()) {
        await controller.addUserScript(userScript: script);
      }
    } catch (error) {
      debugPrint('WebPage: 刷新用户脚本失败 - $error');
    }
  }

  void _registerUserScriptBridge(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'gstoreUserscript',
      callback: (args) async {
        final raw = args.isNotEmpty ? args.first : null;
        if (raw is! Map) return null;
        final payload = raw.map((key, value) => MapEntry(key.toString(), value));
        final scriptId = _scriptIdForToken(payload['token']?.toString() ?? '');
        if (scriptId == null) return null;
        switch (payload['op']?.toString() ?? '') {
          case 'value.set':
            await WebUserScriptStore.instance.setValue(
              scriptId,
              payload['key']?.toString() ?? '',
              payload['value'],
            );
            return true;
          case 'value.delete':
            await WebUserScriptStore.instance.deleteValue(
              scriptId,
              payload['key']?.toString() ?? '',
            );
            return true;
          case 'log':
            final parts = payload['args'];
            debugPrint(
              '[userscript] ${parts is List ? parts.join(' ') : '$parts'}',
            );
            return null;
          case 'notify':
            if (mounted) {
              final title = payload['title']?.toString() ?? '';
              final text = payload['text']?.toString() ?? '';
              AppDialogs.showSuccess(text.isEmpty ? title : '$title：$text');
            }
            return null;
          case 'open':
            final url = payload['url']?.toString() ?? '';
            if (mounted && url.isNotEmpty) await _submitAddress(url);
            return null;
          case 'clipboard':
            await Clipboard.setData(
              ClipboardData(text: payload['text']?.toString() ?? ''),
            );
            return null;
          case 'xhr':
            return _userscriptXhr(payload);
        }
        return null;
      },
    );
  }

  Future<Map<String, Object?>> _userscriptXhr(
    Map<String, Object?> payload,
  ) async {
    final url = payload['url']?.toString() ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw StateError('只有 http(s) 地址可以请求');
    }
    final headers = <String, String>{};
    final rawHeaders = payload['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (key != null && value != null) {
          headers[key.toString()] = value.toString();
        }
      });
    }
    // 带上 WebView 里该站点的 Cookie，脚本才能访问登录后的接口。
    try {
      final cookies =
          await CookieManager.instance().getCookies(url: WebUri(url));
      final hasCookie =
          headers.keys.any((key) => key.toLowerCase() == 'cookie');
      if (cookies.isNotEmpty && !hasCookie) {
        headers['Cookie'] =
            cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
      }
    } catch (_) {
      // 读不到 Cookie 就退化成匿名请求。
    }
    final timeoutMs = (payload['timeout'] as num?)?.toInt() ?? 30000;
    final response = await WebUserScriptFetcher.request(
      method: payload['method']?.toString() ?? 'GET',
      url: url,
      headers: headers,
      data: payload['data']?.toString(),
      timeout: Duration(milliseconds: timeoutMs.clamp(1000, 120000)),
    );
    return {
      'status': response.status,
      'statusText': response.statusText,
      'responseText': response.body,
      'responseHeaders': response.headers,
      'finalUrl': response.url,
    };
  }

  Future<void> _installUserScript(String url) async {
    AppDialogs.showLoading(message: '正在获取脚本…');
    WebUserScriptParseResult parsed;
    try {
      parsed = await WebUserScriptFetcher.fetch(url);
    } catch (error) {
      AppDialogs.dismissLoading();
      if (mounted) AppDialogs.showError('获取脚本失败：$error');
      return;
    }
    AppDialogs.dismissLoading();
    if (!mounted) return;
    final script = parsed.script;
    if (script == null) {
      AppDialogs.showError(parsed.error ?? '不是用户脚本');
      return;
    }
    final update = WebUserScriptStore.instance.scripts
        .any((item) => item.key == script.key);
    final ok = await showUserScriptInstallSheet(
      context,
      script,
      update: update,
    );
    if (ok != true || !mounted) return;
    final result = await WebUserScriptStore.instance.upsert(script);
    if (!mounted) return;
    setState(() {
      _pageScripts = WebUserScriptStore.instance.scriptsForUrl(_currentUrl);
    });
    await _refreshUserScripts();
    if (!mounted) return;
    AppDialogs.showSuccess(
      result.updated
          ? '已更新：${result.script.name}'
          : '已安装：${result.script.name}',
      actionLabel: '刷新页面',
      onAction: () => _controller?.reload(),
    );
  }

  Future<void> _showPageScripts() async {
    await showPageUserScriptsSheet(
      context,
      url: _currentUrl,
      onChanged: () async {
        await _refreshUserScripts();
        if (!mounted) return;
        setState(() {
          _pageScripts = WebUserScriptStore.instance.scriptsForUrl(_currentUrl);
        });
      },
      onManage: () => unawaited(_manageUserScripts()),
    );
  }

  Future<void> _manageUserScripts() async {
    await context.push(AppRoute.webViewUserscripts);
    if (!mounted) return;
    await WebUserScriptStore.instance.load(force: true);
    await _refreshUserScripts();
    if (!mounted) return;
    setState(() {
      _pageScripts = WebUserScriptStore.instance.scriptsForUrl(_currentUrl);
    });
  }

  bool _looksLikeUserScriptRequest(DownloadStartRequest request) {
    if (looksLikeUserScriptUrl(request.url.toString())) return true;
    final name = request.suggestedFilename?.toLowerCase() ?? '';
    return name.endsWith('.user.js');
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
    _pageScripts = WebUserScriptStore.instance.scriptsForUrl(next);
    _notifyMeta();
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
    // 地址栏粘贴 / 书签 / 历史里也可能是安装链接，统一走安装确认。
    if (looksLikeUserScriptUrl(url)) {
      await _installUserScript(url);
      return;
    }
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
      bookmarked: _isBookmarked,
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
      case WebMoreAction.bookmarkPage:
        await _toggleBookmark();
      case WebMoreAction.settings:
        await _openSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final initialUrl = _initialUrl;
    final enabledScripts =
        _pageScripts.where((script) => script.enabled).length;

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
                  widget.initialUrl ?? '',
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

    if (!_settingsReady || !_homeReady || !_scriptsReady) {
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
            tooltip: '本页脚本',
            icon: Badge.count(
              count: enabledScripts,
              isLabelVisible: enabledScripts > 0,
              child: const Icon(TablerIcons.code),
            ),
            onPressed: _showPageScripts,
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
                          initialUserScripts:
                              UnmodifiableListView(_buildUserScripts()),
                          onWebViewCreated: (controller) {
                            _controller = controller;
                            _registerHomeBridge(controller);
                            _registerUserScriptBridge(controller);
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
                            // GM 存储值是内联进脚本的：页面加载完后重建一次，
                            // 下次导航就是最新值。
                            unawaited(_refreshUserScripts());
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
                            _notifyMeta();
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
                            // Greasy Fork 之类的「安装」按钮就是一个 .user.js
                            // 导航；拦下来走安装确认，而不是把源码当网页打开。
                            if (looksLikeUserScriptUrl(raw.toString())) {
                              unawaited(_installUserScript(raw.toString()));
                              return NavigationActionPolicy.CANCEL;
                            }
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
                            if (_looksLikeUserScriptRequest(request)) {
                              unawaited(
                                _installUserScript(request.url.toString()),
                              );
                              return;
                            }
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
              Expanded(
                child: Align(
                  // heightFactor: 1 防止 Align 撑满工具栏高度（会把整条底栏
                  // 撑到全屏，按钮跑到屏幕中间）。
                  heightFactor: 1,
                  child: _TabsButton(
                    count: widget.tabCount,
                    onPressed: widget.onOpenTabs,
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


/// 底部工具栏中间的标签页按钮（方框数字，和 Chrome 一致）。
class _TabsButton extends StatelessWidget {
  const _TabsButton({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Tooltip(
      message: '标签页',
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadius.allSM,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outline, width: 1.4),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                '$count',
                style: textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
