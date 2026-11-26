import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/webview/webview_session_service.dart';
import 'package:gstore/core/webview/webview_url_policy.dart';

/// Visible WebView for login/CAPTCHA flows.
///
/// This page is intentionally independent from the agent's headless WebView,
/// but Android shares the app's WebView cookie/localStorage jar, so logging in
/// here makes the same authenticated session visible to `webView open`.
class AgentWebViewDebugPage extends StatefulWidget {
  const AgentWebViewDebugPage({super.key});

  @override
  State<AgentWebViewDebugPage> createState() => _AgentWebViewDebugPageState();
}

class _AgentWebViewDebugPageState extends State<AgentWebViewDebugPage> {
  final TextEditingController _urlController = TextEditingController();
  final WebViewUrlPolicy _policy = WebViewUrlPolicy();

  InAppWebViewController? _controller;
  String? _initialUrl;
  String _currentUrl = '';
  String _title = 'WebView 调试';
  double _progress = 0;
  bool _loading = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String? _normalizeUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme.isEmpty) {
      final withScheme = Uri.tryParse('https://$text');
      return withScheme?.toString();
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.toString();
  }

  Future<void> _open() async {
    final url = _normalizeUrl(_urlController.text);
    if (url == null) {
      AppDialogs.showError('请输入 http/https 地址');
      return;
    }
    final uri = Uri.parse(url);
    if (!await _policy.allowMainFrame(uri)) {
      if (mounted) AppDialogs.showError('只允许公网 http/https 地址');
      return;
    }
    if (mounted) {
      setState(() {
        _initialUrl = url;
        _loading = true;
      });
    }
    final controller = _controller;
    if (controller != null) {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  Future<void> _showRequests() async {
    final text = WebViewSessionService.instance.debugRequestsText();
    await AppDialogs.showContentSheet(
      title: 'WebView 抓包',
      subtitle: '来自当前 headless 页面',
      content: SelectableText(
        text,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  Future<void> _copyUrl() async {
    final url = _currentUrl.isNotEmpty ? _currentUrl : _urlController.text;
    if (url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      AppDialogs.showSuccess('已复制当前 URL，可回到 AI 对话继续');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final initialUrl = _initialUrl;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
            tooltip: '后退',
            icon: const Icon(TablerIcons.arrow_left),
            onPressed: () => _controller?.goBack(),
          ),
          IconButton(
            tooltip: '前进',
            icon: const Icon(TablerIcons.arrow_right),
            onPressed: () => _controller?.goForward(),
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(TablerIcons.refresh),
            onPressed: () => _controller?.reload(),
          ),
          IconButton(
            tooltip: '查看 AI 抓包',
            icon: const Icon(TablerIcons.list_details),
            onPressed: _showRequests,
          ),
          IconButton(
            tooltip: '复制当前 URL',
            icon: const Icon(TablerIcons.copy),
            onPressed: _copyUrl,
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    TablerIcons.info_circle,
                    size: AppTypography.iconSM,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '此页面与 AI 的 webView 共用 Cookie。'
                      '登录/验证码完成后复制 URL，回到对话让 AI 用 webView 继续。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_loading)
            LinearProgressIndicator(
              value: _progress > 0 && _progress < 1 ? _progress : null,
              minHeight: 2,
            ),
          Expanded(
            child: initialUrl == null
                ? Center(
                    child: Padding(
                      padding: AppSpacing.allXL,
                      child: Text(
                        '输入网址开始调试，或先登录需要账号的站点。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : InAppWebView(
                    initialUrlRequest:
                        URLRequest(url: WebUri(initialUrl)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      useShouldInterceptRequest: true,
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
                    shouldInterceptRequest: (controller, request) async {
                      final uri = Uri.tryParse(request.url.toString());
                      if (uri == null) return null;
                      final allowed = request.isForMainFrame == true
                          ? await _policy.allowMainFrame(uri)
                          : await _policy.allowSubresource(uri);
                      if (allowed) return null;
                      return WebResourceResponse(
                        contentType: 'text/plain',
                        contentEncoding: 'utf-8',
                        data: Uint8List(0),
                        statusCode: 403,
                        reasonPhrase: 'Forbidden',
                        headers: const {'content-type': 'text/plain'},
                      );
                    },
                    shouldOverrideUrlLoading: (controller, action) async {
                      final raw = action.request.url;
                      if (raw == null) return NavigationActionPolicy.ALLOW;
                      final uri = Uri.tryParse(raw.toString());
                      if (uri == null) return NavigationActionPolicy.CANCEL;
                      if (uri.scheme == 'about') {
                        return NavigationActionPolicy.ALLOW;
                      }
                      return await _policy.allowMainFrame(uri)
                          ? NavigationActionPolicy.ALLOW
                          : NavigationActionPolicy.CANCEL;
                    },
                    onWebViewCreated: (controller) {
                      _controller = controller;
                    },
                    onLoadStart: (controller, url) {
                      if (mounted) {
                        setState(() {
                          _loading = true;
                          _currentUrl = url?.toString() ?? _currentUrl;
                          if (_currentUrl.isNotEmpty) {
                            _urlController.text = _currentUrl;
                          }
                        });
                      }
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
                        _currentUrl = url?.toString() ?? _currentUrl;
                        if (_currentUrl.isNotEmpty) {
                          _urlController.text = _currentUrl;
                        }
                      });
                    },
                    onUpdateVisitedHistory: (controller, url, isReload) {
                      if (!mounted) return;
                      setState(() {
                        _currentUrl = url?.toString() ?? _currentUrl;
                        if (_currentUrl.isNotEmpty) {
                          _urlController.text = _currentUrl;
                        }
                      });
                    },
                    onTitleChanged: (controller, title) {
                      if (!mounted) return;
                      setState(() {
                        _title = (title == null || title.trim().isEmpty)
                            ? 'WebView 调试'
                            : title.trim();
                      });
                    },
                    onCreateWindow: (controller, action) async {
                      final url = action.request.url;
                      if (url != null) {
                        await controller.loadUrl(urlRequest: URLRequest(url: url));
                      }
                      return true;
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) => _open(),
                      decoration: const InputDecoration(
                        hintText: 'https://example.com',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: _open,
                    child: const Text('打开'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
