import 'package:flutter/foundation.dart';

import 'package:gstore/core/http/cookie_persistence.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/webview/webview_cookie_bridge.dart';

/// 进程级统一 Cookie jar：WebView / httpRequest / 请求调试共用。
///
/// - WebView 登录态按 URL 实时拉取；
/// - httpRequest 响应 Set-Cookie 同步回 WebView；
/// - 全部 Cookie（含 session cookie）持久化到安全存储，重启后仍在。
class UnifiedCookieJar {
  UnifiedCookieJar._();

  static DebugCookieJar? _instance;

  static DebugCookieJar get instance => _instance ??= DebugCookieJar(
        bridge: const WebViewCookieBridge(),
        persistence: const SecureCookiePersistence(),
      );

  /// 测试 / 宿主重置：下一次访问重建（不清理安全存储）。
  static void reset() {
    _instance = null;
  }

  @visibleForTesting
  static void debugSetInstance(DebugCookieJar? jar) {
    _instance = jar;
  }
}
