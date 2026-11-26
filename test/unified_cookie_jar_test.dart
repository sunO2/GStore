import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/http/cookie_sync.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';

class _FakePersistence implements CookiePersistencePort {
  String? data;

  @override
  Future<String?> read() async => data;

  @override
  Future<void> write(String value) async {
    data = value;
  }

  @override
  Future<void> clear() async {
    data = null;
  }
}

class _FakeBridge implements CookieBridgePort {
  final Map<String, List<SyncCookie>> cookiesByUrl = {};
  final List<SyncCookie> written = <SyncCookie>[];
  final List<SyncCookie> deleted = <SyncCookie>[];
  bool clearedAll = false;

  @override
  Future<List<SyncCookie>> readCookies(Uri uri) async {
    final result = <SyncCookie>[];
    for (final list in cookiesByUrl.values) {
      for (final cookie in list) {
        final domain = (cookie.domain ?? '')
            .replaceFirst(RegExp(r'^\.'), '')
            .toLowerCase();
        if (domain.isEmpty ||
            uri.host == domain ||
            uri.host.endsWith('.$domain')) {
          result.add(cookie);
        }
      }
    }
    return result;
  }

  @override
  Future<void> writeCookie(Uri uri, SyncCookie cookie) async {
    written.add(cookie);
    final list = cookiesByUrl.putIfAbsent(uri.toString(), () => <SyncCookie>[]);
    list.removeWhere((item) => item.name == cookie.name);
    list.add(cookie);
  }

  @override
  Future<void> deleteCookie(Uri uri, SyncCookie cookie) async {
    deleted.add(cookie);
    cookiesByUrl[uri.toString()]
        ?.removeWhere((item) => item.name == cookie.name);
  }

  @override
  Future<void> deleteAllCookies() async {
    clearedAll = true;
    cookiesByUrl.clear();
  }
}

void main() {
  test('httpRequest 会读取 WebView 登录 Cookie 并持久化', () async {
    final persistence = _FakePersistence();
    final bridge = _FakeBridge();
    bridge.cookiesByUrl['https://api.example.com/user'] = [
      SyncCookie(
        name: 'sid',
        value: 'web-login',
        domain: 'api.example.com',
        hostOnly: true,
        secure: true,
        httpOnly: true,
      ),
    ];
    final jar = DebugCookieJar(bridge: bridge, persistence: persistence);

    final header = await jar.cookieHeaderForUri(
      Uri.parse('https://api.example.com/user'),
    );

    expect(header, contains('sid=web-login'));
    expect(persistence.data, contains('web-login'));
    // 不会发到其它域
    expect(
      await jar.cookieHeaderForUri(Uri.parse('https://other.example/')),
      isEmpty,
    );
  });

  test('WebView 退出登录后不再回发旧 Cookie（持久 Cookie）', () async {
    final persistence = _FakePersistence();
    final bridge = _FakeBridge();
    final uri = Uri.parse('https://api.example.com/user');
    bridge.cookiesByUrl[uri.toString()] = [
      SyncCookie(
        name: 'sid',
        value: 'web-login',
        domain: 'api.example.com',
        hostOnly: true,
        secure: true,
        httpOnly: true,
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      ),
    ];
    final jar = DebugCookieJar(bridge: bridge, persistence: persistence);

    expect(await jar.cookieHeaderForUri(uri), contains('sid=web-login'));

    // 模拟用户在 WebView 退出登录：Cookie 从原生存储消失。
    bridge.cookiesByUrl.clear();
    expect(await jar.cookieHeaderForUri(uri), isEmpty);
    expect(persistence.data, isNot(contains('web-login')));
  });

  test('响应 Set-Cookie 写入 jar、持久化并回写 WebView', () async {
    final persistence = _FakePersistence();
    final bridge = _FakeBridge();
    final jar = DebugCookieJar(bridge: bridge, persistence: persistence);
    final uri = Uri.parse('https://api.example.com/login');

    await jar.captureResponse(uri, <String, String>{
      'set-cookie': 'server=xyz; Path=/; HttpOnly; Max-Age=3600',
    });

    expect(bridge.written.any((c) => c.name == 'server'), isTrue);
    final written = bridge.written.firstWhere((c) => c.name == 'server');
    expect(written.value, 'xyz');
    expect(written.httpOnly, isTrue);
    expect(persistence.data, contains('server'));

    expect(
      await jar.cookieHeaderForUri(Uri.parse('https://api.example.com/')),
      contains('server=xyz'),
    );
  });

  test('session cookie 也持久化，即使 WebView 读不到也仍可回发', () async {
    final persistence = _FakePersistence();
    final jar = DebugCookieJar(persistence: persistence);
    final uri = Uri.parse('https://example.com/');
    await jar.captureResponse(uri, <String, String>{
      'set-cookie': 'session=abc; Path=/',
    });
    expect(persistence.data, contains('session'));

    // 模拟重启后 WebView 的 session cookie 没有落盘（返回空）。
    final restarted = DebugCookieJar(
      bridge: _FakeBridge(),
      persistence: persistence,
    );
    await restarted.ensureLoaded();
    expect(
      await restarted.cookieHeaderForUri(uri),
      contains('session=abc'),
    );
  });

  test('Max-Age=0 会同时删除 jar 与 WebView Cookie', () async {
    final persistence = _FakePersistence();
    final bridge = _FakeBridge();
    final jar = DebugCookieJar(bridge: bridge, persistence: persistence);
    final uri = Uri.parse('https://example.com/');

    await jar.captureResponse(uri, <String, String>{
      'set-cookie': 'sid=abc; Path=/',
    });
    expect(await jar.cookieHeaderForUri(uri), contains('sid=abc'));

    await jar.captureResponse(uri, <String, String>{
      'set-cookie': 'sid=; Path=/; Max-Age=0',
    });
    expect(await jar.cookieHeaderForUri(uri), isNot(contains('sid=abc')));
    expect(bridge.deleted.any((c) => c.name == 'sid'), isTrue);
  });

  test('全部清除会清持久化与 WebView 登录态', () async {
    final persistence = _FakePersistence();
    final bridge = _FakeBridge();
    final jar = DebugCookieJar(bridge: bridge, persistence: persistence);
    final uri = Uri.parse('https://example.com/');
    await jar.captureResponse(uri, <String, String>{
      'set-cookie': 'sid=abc; Path=/',
    });

    await jar.clearAllCookies(includeWebView: true);

    expect(persistence.data, isNull);
    expect(bridge.clearedAll, isTrue);
    expect(await jar.cookieHeaderForUri(uri), isEmpty);
  });
}
