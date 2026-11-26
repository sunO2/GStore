import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/http/cookie_persistence.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/websearch/web_search_service.dart';
import 'package:gstore/core/webview/webview_cookie_bridge.dart';
import 'package:gstore/core/webview/webview_session_service.dart';
import 'package:integration_test/integration_test.dart';

/// On-device smoke test for the unified Cookie layer.
///
/// Run on a device:
///   flutter test integration_test/cookie_sync_smoke_test.dart -d <deviceId>
///
/// Covers:
/// 1. WebView login cookie -> httpRequest;
/// 2. httpRequest Set-Cookie -> WebView;
/// 3. session cookie survives a new jar instance (secure storage).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const base = 'https://httpbin.org';
  const ttl = 'agent_cookie_it_v1';

  testWidgets('WebView cookie <-> httpRequest 双向同步 + session 持久化',
      (tester) async {
    final persistence = const SecureCookiePersistence(key: ttl);
    final jar = DebugCookieJar(
      bridge: const WebViewCookieBridge(),
      persistence: persistence,
    );
    final webView = WebViewSessionService();
    addTearDown(webView.close);

    // 清理上次可能残留的测试 Cookie（不影响其它站点）。
    Future<void> cleanup() async {
      for (final name in ['agent_test', 'from_http', 'it_session']) {
        await CookieManager.instance().deleteCookie(
          url: WebUri('$base/'),
          name: name,
        );
      }
      await persistence.clear();
      jar.clear();
    }

    await cleanup();

    await tester.runAsync(() async {
      // 1) WebView 打开设置 Cookie 的地址（等价于 H5 登录后写入登录态）。
      final opened = await webView.handle({
        'action': 'open',
        'url': '$base/cookies/set?agent_test=1',
        'waitUntil': 'load',
        'settleMs': 800,
        'timeoutMs': 20000,
      });
      expect(opened, contains('已加载'), reason: opened);

      final header = await jar.cookieHeaderForUri(Uri.parse('$base/cookies'));
      expect(header, contains('agent_test=1'), reason: header);

      // 2) httpRequest 自动携带 WebView Cookie。
      final response = await WebSearchService.instance.httpRequest(
        '$base/cookies',
        cookies: jar,
      );
      expect(response.body, contains('agent_test'), reason: response.body);

      // 3) httpRequest 收到 Set-Cookie 后回写 WebView。
      await WebSearchService.instance.httpRequest(
        '$base/cookies/set?from_http=1',
        cookies: jar,
      );
      final webCookies = await CookieManager.instance().getCookies(
        url: WebUri('$base/'),
      );
      expect(
        webCookies.any((c) => c.name == 'from_http' && c.value == '1'),
        isTrue,
        reason: webCookies.map((c) => '${c.name}=${c.value}').join(','),
      );

      // 4) session cookie 持久化：新实例仍能读到。
      await jar.captureResponse(
        Uri.parse('$base/'),
        <String, String>{'set-cookie': 'it_session=abc; Path=/'},
      );
      final restarted = DebugCookieJar(
        persistence: const SecureCookiePersistence(key: ttl),
      );
      await restarted.ensureLoaded();
      expect(
        await restarted.cookieHeaderForUri(Uri.parse('$base/')),
        contains('it_session=abc'),
      );

      await cleanup();
    });
  });
}
