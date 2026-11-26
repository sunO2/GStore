import '../websearch/url_guard.dart';

/// URL safety policy for the headless WebView.
///
/// Main frames must be public http(s). Subresources additionally allow
/// `data:`/`blob:` (page-local, no network) but still block `file:`,
/// `content:`, `intent:` and other schemes. DNS results are cached per host so
/// `shouldInterceptRequest` does not resolve the same domain repeatedly.
class WebViewUrlPolicy {
  WebViewUrlPolicy({this.enforcePublicHosts = true});

  final bool enforcePublicHosts;
  final Map<String, bool> _hostCache = <String, bool>{};

  Future<bool> allowMainFrame(Uri uri) async {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    return _allowHttp(uri);
  }

  Future<bool> allowSubresource(Uri uri) async {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'data' || scheme == 'blob') return true;
    if (scheme != 'http' && scheme != 'https') return false;
    return _allowHttp(uri);
  }

  Future<bool> _allowHttp(Uri uri) async {
    if (uri.userInfo.isNotEmpty) return false;
    if (!enforcePublicHosts) return true;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    final cached = _hostCache[host];
    if (cached != null) return cached;
    try {
      await UrlGuard.assertPublicHost(uri);
      _hostCache[host] = true;
      return true;
    } catch (_) {
      _hostCache[host] = false;
      return false;
    }
  }

  void clear() => _hostCache.clear();
}
