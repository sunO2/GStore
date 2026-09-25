/// 「请求调试」响应查看器（plan todo 32）测试。
///
/// 覆盖验收标准：
/// - 各 `Content-Type` 渲染（JSON 美化 / XML 缩进 / HTML / 文本）；
/// - `格式化 / 原始` 切换**确实改变**渲染文本；
/// - Cookie 表（名称 / 值 / 域 / 过期）行内容精确；
/// - 超长 Body 分块（首屏只建首个分块的字符数，展开后增长）；
/// - 二进制 / 非文本安全占位，不渲染原始字节、不崩；
/// - `复制` 写入剪贴板；`保存为改写响应` 生成的规则字段精确。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/page/request_debug/response_viewer.dart';

DebugResponse _response({
  int statusCode = 200,
  Map<String, List<String>> headers = const <String, List<String>>{},
  String body = '',
  List<int> bytes = const <int>[],
  List<DebugCookie> cookies = const <DebugCookie>[],
  int durationMs = 0,
  int? sizeBytes,
  String? error,
}) =>
    DebugResponse(
      statusCode: statusCode,
      headers: headers,
      bodyBytes: bytes,
      bodyText: body,
      cookies: cookies,
      durationMs: durationMs,
      sizeBytes: sizeBytes ?? body.length,
      error: error,
    );

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(body: child),
    );

Future<void> _pump(WidgetTester tester, DebugResponse response,
        {ResponseViewer? viewer}) async {
  await tester.pumpWidget(
    _host(viewer ?? ResponseViewer(response: response)),
  );
  await tester.pumpAndSettle();
}

String _textOf(WidgetTester tester, String key) =>
    tester.widget<SelectableText>(find.byKey(Key(key))).data ?? '';

String _bodyText(WidgetTester tester, {String prefix = 'response-body'}) =>
    _textOf(tester, '$prefix-text');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('头部（状态 / 耗时 / 大小 / 开关）', () {
    testWidgets('渲染状态码、耗时、大小，且格式化/原始开关存在', (tester) async {
      await _pump(
        tester,
        _response(
          statusCode: 201,
          durationMs: 1500,
          sizeBytes: 2048,
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: 'hello',
        ),
      );

      final status = tester.widget<Text>(
        find.byKey(const Key('request-editor-response-status')),
      );
      expect(status.data, '201');
      final duration = tester.widget<Text>(
        find.byKey(const Key('response-duration')),
      );
      expect(duration.data, '1.50 s');
      final size = tester.widget<Text>(find.byKey(const Key('response-size')));
      expect(size.data, '2.00 KB');
      expect(
        find.byKey(const Key('response-format-formatted')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('response-format-raw')), findsOneWidget);
      expect(find.byKey(const Key('response-copy')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Body · 按 Content-Type 渲染 + 格式化切换', () {
    testWidgets('application/json → 格式化缩进；原始为单行原文', (tester) async {
      const raw = '{"a":1,"b":[2,3]}';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json; charset=utf-8'],
          },
          body: raw,
        ),
      );

      final formatted = _bodyText(tester);
      expect(formatted, contains('"a": 1'));
      expect(formatted, contains('\n'));

      await tester.tap(find.byKey(const Key('response-format-raw')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester), raw);
      expect(tester.takeException(), isNull);
    });

    testWidgets('application/xml → 格式化按标签缩进', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/xml'],
          },
          body: '<root><a>1</a></root>',
        ),
      );

      final formatted = _bodyText(tester);
      expect(formatted, contains('<root>'));
      expect(formatted, contains('  <a>'));
      expect(formatted, contains('</a>'));
      expect(formatted.split('\n').length, greaterThan(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('text/html → 渲染 HTML 源文本', (tester) async {
      const html = '<h1>hi</h1><p>x</p>';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/html; charset=utf-8'],
          },
          body: html,
        ),
      );
      expect(_bodyText(tester), html);
      expect(tester.takeException(), isNull);
    });

    testWidgets('text/plain → 原文渲染', (tester) async {
      const text = 'hello world\nsecond line';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: text,
        ),
      );
      expect(_bodyText(tester), text);
      expect(tester.takeException(), isNull);
    });

    testWidgets('非法 JSON → 回退原文并提示解析失败', (tester) async {
      const raw = '{not json}';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: raw,
        ),
      );
      expect(_bodyText(tester), raw);
      expect(find.textContaining('JSON 解析失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('原始分段始终展示未格式化原文', (tester) async {
      const raw = '{"a":1}';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: raw,
        ),
      );
      await tester.tap(find.byKey(const Key('response-tab-raw')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester, prefix: 'response-raw'), raw);
      expect(tester.takeException(), isNull);
    });
  });

  group('Cookie 表', () {
    testWidgets('名称 / 值 / 域 / 过期 行内容精确', (tester) async {
      final response = _response(
        headers: const <String, List<String>>{
          'content-type': <String>['text/plain'],
          'set-cookie': <String>[
            'sid=abc; Path=/; Max-Age=3600',
            'theme=dark; Domain=.example.com',
          ],
        },
        body: 'ok',
        cookies: const <DebugCookie>[
          DebugCookie(name: 'sid', value: 'abc', domain: 'api.example.com', path: '/'),
          DebugCookie(name: 'theme', value: 'dark', domain: '.example.com'),
        ],
      );
      await _pump(tester, response);

      await tester.tap(find.byKey(const Key('response-tab-cookies')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('response-cookie-row-sid-0')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('response-cookie-sid-name')))
            .data,
        'sid',
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('response-cookie-sid-value')),
            )
            .data,
        'abc',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('response-cookie-sid-domain')))
            .data,
        'api.example.com',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('response-cookie-sid-expires')))
            .data,
        'Max-Age 3600 s',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('response-cookie-theme-expires')))
            .data,
        '会话',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('无 Cookie → 空态', (tester) async {
      await _pump(tester, _response(body: 'ok'));
      await tester.tap(find.byKey(const Key('response-tab-cookies')));
      await tester.pumpAndSettle();
      expect(find.text('无 Cookie'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('头 表', () {
    testWidgets('逐条渲染响应头', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
            'server': <String>['nginx'],
          },
          body: '{}',
        ),
      );
      await tester.tap(find.byKey(const Key('response-tab-headers')));
      await tester.pumpAndSettle();
      expect(find.text('content-type'), findsOneWidget);
      expect(find.text('application/json'), findsOneWidget);
      expect(find.text('server'), findsOneWidget);
      expect(find.text('nginx'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('重发重置', () {
    testWidgets('换一次响应 → 回到 Body 默认态，格式化回默认，且不抛异常', (tester) async {
      final first = _response(
        headers: const <String, List<String>>{
          'content-type': <String>['application/json'],
        },
        body: '{"first":1}',
      );
      final second = _response(
        headers: const <String, List<String>>{
          'content-type': <String>['application/json'],
        },
        body: '{"second":2}',
      );

      await _pump(tester, first);
      // 手动切到原始分段 + 原始格式，模拟用户上一次交互残留。
      await tester.tap(find.byKey(const Key('response-tab-raw')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('response-format-raw')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester, prefix: 'response-raw'), '{"first":1}');

      // 重发：换一个响应实例，查看器应重置回 Body + 格式化。
      await _pump(tester, second);
      expect(_bodyText(tester), contains('"second": 2'));
      expect(find.byKey(const Key('response-body-text')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('超长 Body 分块', () {
    testWidgets('首屏只建首个分块，展开更多后字符数增长且不崩', (tester) async {
      final huge = 'A' * 200000;
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: huge,
        ),
      );

      expect(_bodyText(tester).length, ResponseViewer.chunkChars);
      final more = find.byKey(const Key('response-body-more'));
      expect(more, findsOneWidget);
      expect(find.textContaining('剩余 180000 字符'), findsOneWidget);

      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(_bodyText(tester).length, ResponseViewer.chunkChars * 2);
      expect(tester.takeException(), isNull);
    });
  });

  group('二进制 / 非文本安全展示', () {
    testWidgets('image/png → 安全占位，不渲染原始文本，不崩', (tester) async {
      final bytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03];
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['image/png'],
          },
          body: DebugResponse.textPreview(bytes),
          bytes: bytes,
          sizeBytes: bytes.length,
        ),
      );

      expect(find.byKey(const Key('response-body-binary')), findsOneWidget);
      expect(find.text('二进制 / 非文本内容'), findsOneWidget);
      expect(find.byKey(const Key('response-body-text')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无 Content-Type 但含 NUL → 判为二进制并安全占位', (tester) async {
      await _pump(
        tester,
        _response(body: 'ab\u0000cd'),
      );
      expect(find.byKey(const Key('response-body-binary')), findsOneWidget);
      expect(find.byKey(const Key('response-body-text')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('动作', () {
    testWidgets('复制 → 剪贴板写入当前展示文本', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: 'copy me',
        ),
      );
      await tester.tap(find.byKey(const Key('response-copy')));
      await tester.pumpAndSettle();
      expect(copied, isNotEmpty);
      expect(copied.last, 'copy me');
      expect(tester.takeException(), isNull);
    });

    testWidgets('保存为改写响应 → 生成的规则字段精确并经门面结果提示', (tester) async {
      DebugRewriteRule? captured;
      final response = _response(
        statusCode: 503,
        durationMs: 12,
        headers: const <String, List<String>>{
          'content-type': <String>['application/json'],
          'x-extra': <String>['v1'],
        },
        body: '{"error":"down"}',
      );
      await _pump(
        tester,
        response,
        viewer: ResponseViewer(
          response: response,
          method: 'POST',
          url: 'https://api.example/x',
          onSaveAsRewrite: (rule) async {
            captured = rule;
            return CaptureRulesResult<DebugRewriteRule>.success(rule);
          },
        ),
      );

      await tester.tap(find.byKey(const Key('response-save-rewrite')));
      await tester.pumpAndSettle();
      expect(find.text('保存为改写响应？'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.url, 'https://api.example/x');
      expect(captured!.method, 'POST');
      expect(captured!.kind, DebugRewriteKind.replaceResponse);
      expect(captured!.statusCode, 503);
      expect(captured!.respBody, '{"error":"down"}');
      expect(
        captured!.respHeaders!.any(
          (h) => h.name == 'x-extra' && h.value == 'v1',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
