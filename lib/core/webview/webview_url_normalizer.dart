/// 内置浏览器地址归一化。
///
/// AI 回复里的 Markdown 链接经常是裸域名（`github.com/termux/termux-app`），
/// 或者带协议但大小写/空白不规范。`InAppWebView` 只接受完整 URL，
/// 这里统一补 `https://` 并过滤掉不能在内置浏览器打开的协议。
library;

/// 把用户/AI 给的链接规范成可加载的 http(s) 地址；不可用时返回 null。
///
/// - 空串、`#anchor` → null
/// - 裸域名 / 协议相对地址 → 补 `https://`
/// - 非 http(s)（`mailto:` / `tel:` / `intent:` / `javascript:` …）→ null
String? normalizeWebViewUrl(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  if (text.startsWith('#')) return null;

  final lower = text.toLowerCase();
  if (lower.startsWith('mailto:') ||
      lower.startsWith('tel:') ||
      lower.startsWith('sms:') ||
      lower.startsWith('intent:') ||
      lower.startsWith('javascript:') ||
      lower.startsWith('file:') ||
      lower.startsWith('content:') ||
      lower.startsWith('data:')) {
    return null;
  }

  // 协议相对地址：//example.com/path
  if (text.startsWith('//')) {
    return _httpOrNull('https:$text');
  }

  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  if (uri.scheme.isEmpty) {
    return _httpOrNull('https://$text');
  }
  if (uri.scheme.toLowerCase() != 'http' &&
      uri.scheme.toLowerCase() != 'https') {
    return null;
  }
  return uri.toString();
}

String? _httpOrNull(String candidate) {
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) return null;
  return uri.toString();
}

/// 默认搜索引擎（Bing；国内可直连，页面轻）。
const String kWebSearchTemplate = 'https://www.bing.com/search?q=';

/// 把关键词拼成搜索地址。
String webSearchUrl(String query) =>
    '$kWebSearchTemplate${Uri.encodeComponent(query.trim())}';

/// 地址栏输入：网址直接打开，其它内容交给搜索引擎。
///
/// 判定「像网址」的条件（满足其一）：
/// - 带 `http://` / `https://` 协议；
/// - 主机名含点且顶级段以字母开头（`termux.dev` / `www.foo.com:8080`）；
/// - IPv4 地址。
/// 其余输入（`termux`、`怎么安装 termux`）走搜索。
String? resolveWebInput(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  final lower = text.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return normalizeWebViewUrl(text);
  }

  final authority = text.split('/').first.split('?').first.split('#').first;
  final host = authority.split(':').first;
  if (_ipv4.hasMatch(host)) return normalizeWebViewUrl(text);
  final labels = host.split('.');
  if (labels.length >= 2) {
    final tld = labels.last;
    if (tld.length >= 2 && _tld.hasMatch(tld)) {
      return normalizeWebViewUrl(text);
    }
  }
  return webSearchUrl(text);
}

final RegExp _ipv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');
final RegExp _tld = RegExp(r'^[A-Za-z][A-Za-z0-9-]*$');
