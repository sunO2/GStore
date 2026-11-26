import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:gstore/core/http/cookie_sync.dart';

/// 通过 Android/iOS WebView 原生 CookieManager 读写登录态。
///
/// 关键说明：
/// - Android 只能按 URL 查询（`getCookies`），不能枚举全部 Cookie；
/// - 新版 System WebView 会返回 HttpOnly / Secure / SameSite / 过期信息；
/// - 所有平台异常都降级为“读不到 / 写入忽略”，绝不阻塞 HTTP 请求。
class WebViewCookieBridge implements CookieBridgePort {
  const WebViewCookieBridge();

  @override
  Future<List<SyncCookie>?> readCookies(Uri uri) async {
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(uri.toString()),
      );
      return [
        for (final cookie in cookies)
          if (cookie.name.isNotEmpty) _fromWebView(uri, cookie),
      ];
    } catch (error) {
      debugPrint('WebViewCookieBridge: 读取 Cookie 失败 - $error');
      return null;
    }
  }

  @override
  Future<void> writeCookie(Uri uri, SyncCookie cookie) async {
    try {
      await CookieManager.instance().setCookie(
        url: WebUri(uri.toString()),
        name: cookie.name,
        value: cookie.value,
        domain: cookie.hostOnly ? null : cookie.domain,
        path: cookie.path,
        expiresDate: cookie.expiresAt?.millisecondsSinceEpoch,
        isSecure: cookie.secure,
        isHttpOnly: cookie.httpOnly,
        sameSite: HTTPCookieSameSitePolicy.fromValue(cookie.sameSite),
      );
    } catch (error) {
      debugPrint('WebViewCookieBridge: 写入 Cookie 失败 - $error');
    }
  }

  @override
  Future<void> deleteCookie(Uri uri, SyncCookie cookie) async {
    try {
      await CookieManager.instance().deleteCookie(
        url: WebUri(uri.toString()),
        name: cookie.name,
        domain: cookie.hostOnly ? null : cookie.domain,
        path: cookie.path,
      );
    } catch (error) {
      debugPrint('WebViewCookieBridge: 删除 Cookie 失败 - $error');
    }
  }

  @override
  Future<void> deleteAllCookies() async {
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (error) {
      debugPrint('WebViewCookieBridge: 清空 Cookie 失败 - $error');
    }
  }

  static SyncCookie _fromWebView(Uri uri, Cookie cookie) {
    final domain = cookie.domain?.trim();
    final normalizedHost = uri.host.toLowerCase();
    final normalizedDomain =
        domain?.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
    final hostOnly = normalizedDomain == null ||
        normalizedDomain.isEmpty ||
        normalizedDomain == normalizedHost;

    // 插件在 Android 上把 `Max-Age` 的“秒”直接加到了毫秒时间戳上（已知
    // 兼容性问题），会得到“即将过期”的假时间。这里只信任明显在未来的
    // 过期时间；其余按会话 Cookie 处理，避免刚登录的 Cookie 被误删。
    DateTime? expiresAt;
    final rawExpires = cookie.expiresDate;
    if (rawExpires != null) {
      final parsed = DateTime.fromMillisecondsSinceEpoch(rawExpires);
      if (parsed.isAfter(
        DateTime.now().add(const Duration(minutes: 1)),
      )) {
        expiresAt = parsed;
      }
    }

    return SyncCookie(
      name: cookie.name,
      value: cookie.value?.toString() ?? '',
      domain: hostOnly ? uri.host : domain,
      path: cookie.path?.trim().isNotEmpty == true ? cookie.path!.trim() : '/',
      expiresAt: expiresAt,
      hostOnly: hostOnly,
      secure: cookie.isSecure ?? uri.scheme == 'https',
      httpOnly: cookie.isHttpOnly ?? false,
      sameSite: cookie.sameSite?.toValue(),
    );
  }
}
