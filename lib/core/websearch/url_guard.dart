/// 外链安全校验（SSRF 防护）
///
/// 只允许 http/https 公网地址：拒绝私网、回环、链路本地（含云元数据
/// 169.254.169.254）、CGNAT、保留网段与 `localhost`/`.local`。
/// 重定向由调用方逐跳校验（见 `WebFetchClient`）。
library;

import 'dart:io';

import 'web_search_models.dart';

class UrlGuard {
  UrlGuard._();

  /// 单次抓取的跳转上限
  static const int maxRedirects = 5;

  /// 校验并返回规范化后的 URI（不做 DNS，见 [assertPublicHost]）。
  static Uri parseHttpUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw WebSearchException('blocked_url', 'URL 不能为空');
    }
    final uri = Uri.tryParse(text);
    if (uri == null) {
      throw WebSearchException('blocked_url', '无法解析 URL：$text');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw WebSearchException('blocked_url', '只支持 http/https 链接');
    }
    if (uri.host.isEmpty) {
      throw WebSearchException('blocked_url', 'URL 缺少主机名');
    }
    return uri;
  }

  /// DNS 解析后校验全部地址（防 `localhost`、内网域名）。
  static Future<void> assertPublicHost(Uri uri) async {
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.local') || host.endsWith('.internal')) {
      throw WebSearchException('blocked_url', '拒绝访问内网主机：$host');
    }
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      _assertPublicAddress(literal, uri);
      return;
    }
    // 域名：解析后逐地址校验；解析失败交给 HTTP 层报错
    List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(host);
    } on SocketException {
      return;
    }
    if (addresses.isEmpty) return;
    for (final address in addresses) {
      _assertPublicAddress(address, uri);
    }
  }

  static void _assertPublicAddress(InternetAddress address, Uri uri) {
    if (_isBlocked(address)) {
      throw WebSearchException(
        'blocked_url',
        '拒绝访问内网/保留地址：${uri.host}',
      );
    }
  }

  static bool _isBlocked(InternetAddress address) {
    if (address.isLoopback) return true;
    if (address.type == InternetAddressType.IPv4) {
      final b = address.rawAddress;
      if (b.length != 4) return true;
      final a0 = b[0];
      final a1 = b[1];
      // 0.0.0.0/8, 10/8, 100.64/10 (CGNAT), 127/8, 169.254/16, 172.16/12,
      // 192.0.0/24, 192.0.2/24, 192.168/16, 198.18/15, 224/4 (multicast), 240/4
      if (a0 == 0 || a0 == 10 || a0 == 127) return true;
      if (a0 == 100 && a1 >= 64 && a1 <= 127) return true;
      if (a0 == 169 && a1 == 254) return true;
      if (a0 == 172 && a1 >= 16 && a1 <= 31) return true;
      if (a0 == 192 && a1 == 0) return true;
      if (a0 == 192 && a1 == 168) return true;
      if (a0 == 198 && (a1 == 18 || a1 == 19)) return true;
      if (a0 >= 224) return true;
      return false;
    }
    final b = address.rawAddress;
    if (b.length != 16) return true;
    // ::1 / :: / fc00::/7 (ULA) / fe80::/10 (link local) / ff00::/8 (multicast)
    final allZeroExceptLast = b.sublist(0, 15).every((v) => v == 0);
    if (allZeroExceptLast && (b[15] == 0 || b[15] == 1)) return true;
    if ((b[0] & 0xFE) == 0xFC) return true;
    if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return true;
    if (b[0] == 0xFF) return true;
    // IPv4-mapped ::ffff:a.b.c.d
    if (b.sublist(0, 10).every((v) => v == 0) &&
        b[10] == 0xFF &&
        b[11] == 0xFF) {
      return _isBlocked(
        InternetAddress.fromRawAddress(b.sublist(12, 16)),
      );
    }
    return false;
  }
}
