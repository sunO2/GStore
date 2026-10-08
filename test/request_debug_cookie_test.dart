/// todo 26：`DebugCookieJar` 纯逻辑单元测试。
///
/// 覆盖解析边缘：多 cookie 合一 header、属性（Domain/Path/HttpOnly/Secure）、
/// 含逗号的 Expires 日期不被误切、Max-Age=0 删除、过期剔除、host/domain 匹配、
/// 大小写不敏感的 header 查找、clear()。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/page/request_debug/cookie_manager_sheet.dart';
import 'package:gstore/page/request_debug/request_editor_page.dart';

/// 服务端实际收到的一次请求（防「假绿」）。
class _Recorded {
  _Recorded(HttpRequest request)
      : cookie = request.headers.value('cookie');

  final String? cookie;
}

/// 极简 `HttpServer` fixture：记录 `Cookie` 头后返回 200。
class _Fixture {
  _Fixture._(this._server);

  final HttpServer _server;
  final List<_Recorded> recorded = <_Recorded>[];
  late final StreamSubscription<HttpRequest> _sub;

  String get origin => 'http://127.0.0.1:${_server.port}';

  static Future<_Fixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _Fixture._(server);
    fixture._sub = server.listen((request) async {
      fixture.recorded.add(_Recorded(request));
      await request.toList();
      try {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('ok');
        await request.response.close();
      } catch (_) {
        // 客户端超时断连后写入抛错，属预期（最佳努力）。
      }
    });
    return fixture;
  }

  Future<void> close() async {
    await _sub.cancel();
    await _server.close(force: true);
  }
}

/// 假发送器：记录每次发送参数，返回受控响应；**不触碰网络**。
class _FakeSender implements DebugSender {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  @override
  final DebugCookieJar cookieJar = DebugCookieJar();

  @override
  Future<DebugResponse> send({
    required String method,
    required String url,
    List<DebugHeader> headers = const <DebugHeader>[],
    List<DebugQueryParam> query = const <DebugQueryParam>[],
    String body = '',
    List<int>? bodyBytes,
    bool followRedirects = true,
    Duration? timeout,
    bool useCookies = true,
    bool skipTlsVerify = false,
  }) async {
    calls.add(<String, Object?>{
      'method': method,
      'url': url,
      'headers': headers
          .where((h) => h.enabled && h.name.isNotEmpty)
          .map((h) => '${h.name}:${h.value}')
          .toList(),
    });
    return const DebugResponse(statusCode: 200, bodyText: 'ok', sizeBytes: 2);
  }

  @override
  void close() {}
}

/// 测试门面：真实内存 store + 假 sender；文件 IO 用空操作覆盖。
class _RecordingFacade extends DefaultRequestDebugFacade {
  _RecordingFacade({required DebugSender debugSender})
      : super(
          store: RequestDebugStore(
            directoryProvider: () async => Directory.systemTemp,
          ),
          sender: debugSender,
        );

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 真实 `dart:io` HttpServer fixture 需要真实网络栈（flutter_test 默认 mock
  // HttpClient 会让所有请求返回 400）。
  setUp(() {
    HttpOverrides.global = null;
  });
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

  // ==================== plan todo 2：编辑器 Cookie 生效 + jar 管理 ====================

  group('DebugCookieJar 特征化基线（供 T12 合成 RFC 修复锁定现状）', () {
    test('当前按属性出现顺序取后出现的过期时间（非 RFC Max-Age 优先）', () {
      final jar = DebugCookieJar();
      jar.store('example.com', <String, List<String>>{
        'set-cookie': <String>[
          'a=1; Path=/; Max-Age=3600; Expires=Wed, 21 Oct 2015 07:28:00 GMT',
        ],
      });
      // 现状：Expires 在 Max-Age 之后出现 → 覆盖为过去时间 → 立即过期。
      // RFC 6265 要求 Max-Age 优先，T12 修复后此断言将更新为命中。
      expect(jar.cookieHeaderFor('example.com'), isEmpty);
    });
  });

  group('DebugCookieJar.snapshot', () {
    test('按 host 分组列出并对不可变视图；过期条目被剔除', () {
      final jar = DebugCookieJar();
      jar.store('a.example', <String, List<String>>{
        'set-cookie': <String>['x=1; Path=/'],
      });
      jar.store('b.example', <String, List<String>>{
        'set-cookie': <String>['y=2; Path=/'],
      });
      jar.store('a.example', <String, List<String>>{
        'set-cookie': <String>['old=1; Path=/; Max-Age=0'],
      });

      final snap = jar.snapshot();
      expect(snap.keys.toSet(), <String>{'a.example', 'b.example'});
      expect(snap['a.example']!.map((c) => c.name).toList(), <String>['x']);
      expect(snap['b.example']!.single.name, 'y');
    });

    test('空 jar 快照为空', () {
      expect(DebugCookieJar().snapshot(), isEmpty);
    });
  });

  group('DebugCookieJar.mergeCookieHeader', () {
    test('显式条目优先，同名去重（先出现者胜出）', () {
      expect(
        DebugCookieJar.mergeCookieHeader('a=1; b=2', 'a=9; c=3'),
        'a=1; b=2; c=3',
      );
    });

    test('空来源被忽略；皆空返回空串', () {
      expect(DebugCookieJar.mergeCookieHeader('', ''), '');
      expect(DebugCookieJar.mergeCookieHeader('a=1', ''), 'a=1');
      expect(DebugCookieJar.mergeCookieHeader('', 'b=2'), 'b=2');
    });
  });

  group('发送路径：编辑器 Cookie 与 jar 合并（真实 HttpServer）', () {
    test('显式 Cookie 头到达服务端（编辑器 cookies 的线缆形态）', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      await sender.send(
        method: 'GET',
        url: '${fixture.origin}/c',
        headers: const <DebugHeader>[
          DebugHeader(name: 'Cookie', value: 'editor=only'),
        ],
      );

      expect(fixture.recorded.single.cookie, 'editor=only');
    });

    test('显式优先且与 jar 同名去重；jar 独有仍发送', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);
      sender.cookieJar.store('127.0.0.1', <String, List<String>>{
        'set-cookie': <String>['shared=jar; Path=/', 'jarOnly=1; Path=/'],
      });

      await sender.send(
        method: 'GET',
        url: '${fixture.origin}/c',
        headers: const <DebugHeader>[
          DebugHeader(name: 'Cookie', value: 'shared=editor; editorOnly=2'),
        ],
      );

      final cookie = fixture.recorded.single.cookie!;
      expect(cookie, contains('shared=editor'), reason: '显式条目必须优先');
      expect(cookie, isNot(contains('shared=jar')), reason: '同名去重');
      expect(cookie, contains('editorOnly=2'));
      expect(cookie, contains('jarOnly=1'), reason: 'jar 独有 cookie 仍须发送');
    });

    test('清除 jar 后旧 jar cookie 不再发送', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);
      sender.cookieJar.store('127.0.0.1', <String, List<String>>{
        'set-cookie': <String>['old=1; Path=/'],
      });

      await sender.send(method: 'GET', url: '${fixture.origin}/first');
      expect(fixture.recorded.last.cookie, contains('old=1'));

      sender.cookieJar.clear();
      await sender.send(
        method: 'GET',
        url: '${fixture.origin}/second',
        headers: const <DebugHeader>[
          DebugHeader(name: 'Cookie', value: 'editor=1'),
        ],
      );

      final cookie = fixture.recorded.last.cookie!;
      expect(cookie, contains('editor=1'));
      expect(cookie, isNot(contains('old=1')), reason: '清空 jar 后旧 cookie 不得回发');
    });
  });

  group('编辑器 _send 写入 Cookie 头（widget）', () {
    testWidgets('编辑器 cookie 随发送作为 Cookie 头到达 sender', (tester) async {
      final sender = _FakeSender();
      final facade = _RecordingFacade(debugSender: sender);
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-cookie-send',
          name: 'cookie',
          method: 'GET',
          url: 'https://api.example/v1',
          cookies: const <DebugCookie>[DebugCookie(name: 'ed', value: '1')],
        ),
      );

      await tester.pumpWidget(MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: RequestEditorPage(
          facade: facade,
          request: request,
          collectionId: collection.id,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pumpAndSettle();

      expect(sender.calls, hasLength(1));
      expect(sender.calls.single['headers'], contains('Cookie:ed=1'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Cookie 分段可打开 jar 管理弹层', (tester) async {
      final facade = _RecordingFacade(debugSender: _FakeSender());
      final collection = facade.store.addCollection(name: 'API');

      await tester.pumpWidget(MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: RequestEditorPage(facade: facade, collectionId: collection.id),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-editor-segment-cookies')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-cookie-manage')));
      await tester.pumpAndSettle();

      expect(find.text('Cookie 管理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('CookieManagerSheet（widget）', () {
    testWidgets('按 host 列出，清除后回到空且无异常', (tester) async {
      final jar = DebugCookieJar()
        ..store('example.com', <String, List<String>>{
          'set-cookie': <String>['sid=abc; Path=/', 'lang=en; Path=/'],
        });

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: CookieManagerSheet(jar: jar))),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('cookie-manager-host-example.com')),
        findsOneWidget,
      );
      expect(find.textContaining('sid'), findsWidgets);
      expect(find.textContaining('lang'), findsWidgets);
      expect(find.byKey(const Key('cookie-manager-empty')), findsNothing);

      await tester.tap(find.byKey(const Key('cookie-manager-clear-all')));
      await tester.pumpAndSettle();

      expect(jar.isEmpty, isTrue);
      expect(find.byKey(const Key('cookie-manager-empty')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('可新增 cookie 并显示', (tester) async {
      final jar = DebugCookieJar();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: CookieManagerSheet(jar: jar))),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cookie-manager-empty')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('cookie-manager-add-host')),
        'api.example',
      );
      await tester.enterText(
        find.byKey(const Key('cookie-manager-add-name')),
        'tok',
      );
      await tester.enterText(
        find.byKey(const Key('cookie-manager-add-value')),
        'v1',
      );
      await tester.tap(find.byKey(const Key('cookie-manager-add-confirm')));
      await tester.pumpAndSettle();

      expect(jar.cookieHeaderFor('api.example'), 'tok=v1');
      expect(
        find.byKey(const Key('cookie-manager-host-api.example')),
        findsOneWidget,
      );
      expect(find.textContaining('tok'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空 host / 名 时给出错误且不写入', (tester) async {
      final jar = DebugCookieJar();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: CookieManagerSheet(jar: jar))),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('cookie-manager-add-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cookie-manager-add-error')), findsOneWidget);
      expect(jar.isEmpty, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
