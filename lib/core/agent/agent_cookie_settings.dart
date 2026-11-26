import 'package:shared_preferences/shared_preferences.dart';

/// `httpRequest` 是否自动携带 / 回写 WebView 登录 Cookie。
///
/// 默认开启：WebView 登录后，同域接口请求自动复用登录态。
class AgentCookieSettings {
  AgentCookieSettings._();

  static const String key = 'agent_http_use_webview_cookies';

  static Future<bool> loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? true;
  }

  static Future<void> saveEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, enabled);
  }
}
