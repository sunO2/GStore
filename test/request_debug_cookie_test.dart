/// todo 26：`DebugCookieJar` 纯逻辑单元测试。
///
/// 覆盖解析边缘：多 cookie 合一 header、属性（Domain/Path/HttpOnly/Secure）、
/// 含逗号的 Expires 日期不被误切、Max-Age=0 删除、过期剔除、host/domain 匹配、
/// 大小写不敏感的 header 查找、clear()。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';

void main() {
  group('DebugCookieJar.parseSetCookie', () {
    test('parses name / value / domain / path', () {
      final cookies = DebugCookieJar.parseSetCookie(
        'sid=abc; Domain=.example.com; Path=/app; HttpOnly; Secure',
      );
      expect(cookies, hasLength(1));
      final c = cookies.single;
      expect(c.name, 'sid');
      expect(c.value, 'abc');
      expect(c.domain, '.example.com');
      expect(c.path, '/app');
    });

    test('keeps commas inside Expires on a single cookie', () {
      final cookies = DebugCookieJar.parseSetCookie(
        'b=2; Path=/; Expires=Wed, 21 Oct 2099 07:28:00 GMT',
      );
      expect(cookies, hasLength(1), reason: 'Expires 的逗号不得切成两个 cookie');
      expect(cookies.single.name, 'b');
      expect(cookies.single.value, '2');
    });

    test('parses a joined multi-cookie header', () {
      final cookies = DebugCookieJar.parseSetCookie(
        'a=1; Path=/, b=2; Path=/; Expires=Wed, 21 Oct 2099 07:28:00 GMT',
      );
      expect(cookies.map((c) => c.name).toList(), <String>['a', 'b']);
      expect(cookies.map((c) => c.value).toList(), <String>['1', '2']);
    });

    test('ignores empty / malformed fragments', () {
      expect(DebugCookieJar.parseSetCookie(''), isEmpty);
      expect(DebugCookieJar.parseSetCookie('   '), isEmpty);
      expect(DebugCookieJar.parseSetCookie('=noname'), isEmpty);
    });

    test('handles value containing "=" ', () {
      final cookies = DebugCookieJar.parseSetCookie('token=a=b=c; Path=/');
      expect(cookies.single.value, 'a=b=c');
    });
  });

  group('DebugCookieJar', () {
    test('stores from response headers and exposes a Cookie header string', () {
      final jar = DebugCookieJar();
      jar.store('example.com', <String, List<String>>{
        'Content-Type': <String>['text/plain'],
        'Set-Cookie': <String>['sid=abc; Path=/', 'lang=en; Path=/'],
      });

      final header = jar.cookieHeaderFor('example.com');
      expect(header, contains('sid=abc'));
      expect(header, contains('lang=en'));
      expect(header, contains('; '));
      expect(jar.cookiesFor('example.com'), hasLength(2));
    });

    test('header lookup is case-insensitive', () {
      final jar = DebugCookieJar();
      jar.store('example.com', <String, List<String>>{
        'set-cookie': <String>['x=1; Path=/'],
      });
      expect(jar.cookieHeaderFor('example.com'), 'x=1');
    });

    test('Max-Age=0 removes an existing cookie', () {
      final jar = DebugCookieJar();
      jar.store('example.com', <String, List<String>>{
        'set-cookie': <String>['sid=abc; Path=/'],
      });
      expect(jar.cookieHeaderFor('example.com'), 'sid=abc');

      jar.store('example.com', <String, List<String>>{
        'set-cookie': <String>['sid=; Path=/; Max-Age=0'],
      });
      expect(jar.cookieHeaderFor('example.com'), isEmpty,
          reason: 'Max-Age=0 必须删除 cookie');
    });

    test('an already-expired Expires cookie is not returned', () {
      final jar = DebugCookieJar();
      jar.store('example.com', <String, List<String>>{
        'set-cookie': <String>[
          'old=1; Path=/; Expires=Wed, 21 Oct 2015 07:28:00 GMT',
        ],
      });
      expect(jar.cookieHeaderFor('example.com'), isEmpty);
    });

    test('matches cookie domain by suffix', () {
      final jar = DebugCookieJar();
      jar.store('api.example.com', <String, List<String>>{
        'set-cookie': <String>['sess=1; Domain=.example.com; Path=/'],
      });
      expect(jar.cookieHeaderFor('www.example.com'), contains('sess=1'));
      expect(jar.cookieHeaderFor('other.org'), isEmpty);
    });

    test('does not leak cookies to unrelated hosts', () {
      final jar = DebugCookieJar();
      jar.store('a.example.com', <String, List<String>>{
        'set-cookie': <String>['x=1; Path=/'],
      });
      expect(jar.cookieHeaderFor('b.example.org'), isEmpty);
    });

    test('clear removes everything', () {
      final jar = DebugCookieJar();
      jar.store('example.com', <String, List<String>>{
        'set-cookie': <String>['x=1; Path=/'],
      });
      expect(jar.isEmpty, isFalse);
      jar.clear();
      expect(jar.isEmpty, isTrue);
      expect(jar.cookieHeaderFor('example.com'), isEmpty);
    });
  });

  // ==================== domain / path / secure 作用域（R5b，反向断言） ====================
  //
  // 安全不变量：响应**只能**为其请求 host（或其父域）设置 cookie；否则任意
  // 站点都能注入无关 host 的 cookie。以下逐条断言「拒绝」与「接受」。

  group('DebugCookieJar scoping', () {
    test('rejects a Domain attribute that does not match the request host', () {
      final jar = DebugCookieJar();
      jar.store('evil.test', <String, List<String>>{
        'set-cookie': <String>['leak=1; Domain=example.com; Path=/'],
      });
      expect(jar.cookiesFor('example.com'), isEmpty,
          reason: '无关 host 设置的 Domain cookie 必须被拒绝');
      expect(jar.isEmpty, isTrue);
    });

    test('accepts a Domain attribute that domain-matches the request host', () {
      final jar = DebugCookieJar();
      jar.store('api.example.com', <String, List<String>>{
        'set-cookie': <String>['sess=1; Domain=.example.com; Path=/'],
      });
      expect(jar.cookieHeaderFor('www.example.com'), contains('sess=1'),
          reason: 'Domain 命中父域时必须接受');
      expect(jar.cookieHeaderFor('api.example.com'), contains('sess=1'));
    });

    test('host-only cookie (no Domain) is not sent to subdomains', () {
      final jar = DebugCookieJar();
      jar.store('example.com', <String, List<String>>{
        'set-cookie': <String>['h=1; Path=/'],
      });
      expect(jar.cookieHeaderFor('example.com'), contains('h=1'));
      expect(jar.cookieHeaderFor('sub.example.com'), isEmpty,
          reason: 'host-only cookie 只能回发到原 host');
    });

    test('rejects single-label / public-suffix-like Domain', () {
      final jar = DebugCookieJar();
      jar.store('api.example.com', <String, List<String>>{
        'set-cookie': <String>['super=1; Domain=com; Path=/'],
      });
      expect(jar.isEmpty, isTrue, reason: 'TLD 级 Domain 不得作为 supercookie 接受');
    });

    test('path scoping: cookie only sent to a matching request path', () {
      final jar = DebugCookieJar();
      jar.store(
        'example.com',
        <String, List<String>>{
          'set-cookie': <String>['a=1; Path=/admin'],
        },
        path: '/admin/dashboard',
      );
      expect(
        jar.cookieHeaderFor('example.com', path: '/admin/users'),
        contains('a=1'),
      );
      expect(jar.cookieHeaderFor('example.com', path: '/public'), isEmpty,
          reason: '路径不匹配时不得回发 cookie');
    });

    test('Secure cookie only sent over https', () {
      final jar = DebugCookieJar();
      jar.store('example.com', <String, List<String>>{
        'set-cookie': <String>['s=1; Path=/; Secure'],
      });
      expect(jar.cookieHeaderFor('example.com', secure: false), isEmpty,
          reason: 'Secure cookie 不得经 http 回发');
      expect(jar.cookieHeaderFor('example.com', secure: true), contains('s=1'));
    });
  });
}
