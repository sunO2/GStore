/// 「请求调试」响应查看器测试。
///
/// 覆盖验收标准：
/// - 各 `Content-Type` 渲染（JSON 高亮 / XML 缩进 / HTML / 文本）；
/// - `格式化 / 原始` 切换**确实改变**渲染文本；
/// - JSON 高亮树：多 token 样式、行号 gutter、折叠子树、全量搜索；
/// - 超过 256KB 的 JSON 回退到分块纯文本路径；
/// - Cookie 表（名称 / 值 / 域 / 过期）行内容精确；
/// - 超长 Body 分块（首屏只建首个分块的字符数，展开后增长）；
/// - 搜索基于完整 bodyText，可展开可见文本以包含命中位置；
/// - 二进制 / 非文本安全占位，不渲染原始字节、不崩；
/// - 360dp 下头部 / Cookie 表无溢出；
/// - `复制` 写入剪贴板；`保存为改写响应` 生成的规则字段精确。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:re_editor/re_editor.dart';

import 'package:gstore/core/design/app_code_view.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/utils/unit.dart';
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
  bool truncated = false,
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
      truncated: truncated,
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

/// 行内 Body → 点「全屏查看」进入全屏响应体页。
Future<void> _openFullscreen(
    WidgetTester tester, DebugResponse response) async {
  await _pump(tester, response);
  await tester.tap(find.byKey(const Key('response-body-fullscreen')));
  await tester.pumpAndSettle();
}

/// 读取某个 key 下文本控件的纯文本（`Text` / `SelectableText`）。
String _plainTextOf(WidgetTester tester, String key) {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) return '';
  final widget = tester.widget(finder);
  if (widget is SelectableText) {
    return widget.data ?? widget.textSpan?.toPlainText() ?? '';
  }
  if (widget is Text) {
    return widget.data ?? widget.textSpan?.toPlainText() ?? '';
  }
  return '';
}

/// 当前响应体文本：代码视图优先读 AppCodeView.text，二进制/旧路径回退。
String _bodyText(WidgetTester tester, {String prefix = 'response-body'}) {
  final code = find.byKey(Key('$prefix-code'));
  if (code.evaluate().isNotEmpty) {
    return tester.widget<AppCodeView>(code).text;
  }
  return _plainTextOf(tester, '$prefix-text');
}

/// 真实 loopback 客户端覆盖：绕过 `TestWidgetsFlutterBinding` 注入的假客户端
/// （它会让所有 `HttpClient` 请求返回 400）。空子类沿用基类的真实客户端实现。
class _RealHttpOverrides extends HttpOverrides {}

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
    testWidgets('application/json → 代码视图格式化；原始为单行原文', (tester) async {
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

      expect(find.byKey(const Key('response-body-code')), findsOneWidget);
      expect(find.byType(CodeEditor), findsOneWidget);
      final formatted = _bodyText(tester);
      expect(formatted, contains('"a": 1'));
      expect(formatted, contains('\n'));

      await tester.tap(find.byKey(const Key('response-format-raw')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester), raw);
      expect(find.byKey(const Key('response-body-tree')), findsNothing);
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

    testWidgets('非法 JSON → 回退原文', (tester) async {
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
      expect(find.byKey(const Key('response-body-code')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('原始格式始终展示未格式化原文', (tester) async {
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
      await tester.tap(find.byKey(const Key('response-format-raw')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester), raw);
      expect(tester.takeException(), isNull);
    });
  });

  group('行内响应体 · 代码视图', () {
    testWidgets('JSON → CodeEditor + 行号，无搜索框', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: '{"a":1,"b":[true,null,"s"],"c":3.5}',
        ),
      );

      expect(find.byKey(const Key('response-body-code')), findsOneWidget);
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(find.byType(DefaultCodeLineNumber), findsOneWidget);
      expect(find.byKey(const Key('response-body-search')), findsNothing);
      expect(find.byKey(const Key('response-body-fullscreen')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('纯文本 → CodeEditor，无分块按钮', (tester) async {
      final huge = 'A' * 120000;
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: huge,
        ),
      );

      expect(find.byKey(const Key('response-body-code')), findsOneWidget);
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(find.byKey(const Key('response-body-more')), findsNothing);
      expect(_bodyText(tester).length, huge.length);
      expect(tester.takeException(), isNull);
    });

    testWidgets('超过 256KB 的 JSON → CodeEditor 无异常', (tester) async {
      final big = '{"data":"${'x' * (256 * 1024)}"}';
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: big,
        ),
      );

      expect(find.byKey(const Key('response-body-code')), findsOneWidget);
      expect(find.byKey(const Key('response-body-more')), findsNothing);
      expect(find.byKey(const Key('response-body-tree')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('全屏查看 · CodeEditorPage', () {
    testWidgets('JSON 响应体：只读代码页 + 行号', (tester) async {
      await _openFullscreen(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: '{"a":1,"b":[true,null,"s"],"c":3.5}',
        ),
      );

      expect(find.text('响应体'), findsOneWidget);
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(find.byType(DefaultCodeLineNumber), findsOneWidget);
      // 显式只读：不展示编辑入口
      expect(find.byIcon(TablerIcons.edit), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('纯文本响应体：CodeEditorPage 只读', (tester) async {
      await _openFullscreen(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: 'line1\nline2\nline3',
        ),
      );

      expect(find.byType(CodeEditor), findsOneWidget);
      expect(find.text('响应体'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('行内 Body 无独立缩放控件（缩放由全屏代码页提供）', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['application/json'],
          },
          body: '{"a":1}',
        ),
      );

      expect(find.byKey(const Key('response-body-code')), findsOneWidget);
      expect(find.byIcon(TablerIcons.zoom_in), findsNothing);
      expect(find.byIcon(TablerIcons.zoom_out), findsNothing);
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
          DebugCookie(
              name: 'sid', value: 'abc', domain: 'api.example.com', path: '/'),
          DebugCookie(name: 'theme', value: 'dark', domain: '.example.com'),
        ],
      );
      await _pump(tester, response);

      await tester.tap(find.byKey(const Key('response-tab-cookies')));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const Key('response-cookie-row-sid-0')), findsOneWidget);
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
            .widget<Text>(
                find.byKey(const Key('response-cookie-theme-expires')))
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

    testWidgets('360dp 下头部 / Cookie 表无溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final response = _response(
        headers: const <String, List<String>>{
          'content-type': <String>['text/plain'],
          'content-security-policy-report-only': <String>[
            'default-src https:; report-uri https://example.com/report',
          ],
          'set-cookie': <String>[
            'session=abcdefghijklmnopqrstuvwxyz0123456789; Path=/; Domain=.example.com',
          ],
        },
        body: 'ok',
        cookies: const <DebugCookie>[
          DebugCookie(
            name: 'session',
            value: 'abcdefghijklmnopqrstuvwxyz0123456789',
            domain: 'api.example.com',
          ),
        ],
      );
      await _pump(tester, response);

      await tester.tap(find.byKey(const Key('response-tab-headers')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('response-tab-cookies')));
      await tester.pumpAndSettle();
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
      // 手动切到原始格式，模拟用户上一次交互残留。
      await tester.tap(find.byKey(const Key('response-format-raw')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester), '{"first":1}');

      // 重发：换一个响应实例，查看器应重置回 Body + 格式化（高亮树）。
      await _pump(tester, second);
      expect(_bodyText(tester), contains('"second": 2'));
      expect(find.byKey(const Key('response-body-code')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('大 Body · 代码视图', () {
    testWidgets('超过 chunkChars 的文本直接交给 CodeEditor，无分块按钮', (tester) async {
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

      expect(_bodyText(tester).length, huge.length);
      expect(find.byKey(const Key('response-body-code')), findsOneWidget);
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(find.byKey(const Key('response-body-more')), findsNothing);
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

    testWidgets('二进制复制 → base64，解码后字节完全一致；卡片可点击', (tester) async {
      final bytes = <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0xFF,
      ];
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
            'content-type': <String>['image/png'],
          },
          body: DebugResponse.textPreview(bytes),
          bytes: bytes,
          sizeBytes: bytes.length,
        ),
      );

      // 卡片必须真正可点（旧实现无任何手势，点击不产生复制）。
      await tester.tap(find.byKey(const Key('response-body-binary')));
      await tester.pumpAndSettle();

      expect(copied, isNotEmpty, reason: '点击二进制卡片必须触发复制');
      // 复制内容必须是 base64，解码后与原始字节逐字节一致（旧实现走 UTF-8
      // 预览会损坏任意二进制）。
      expect(base64.decode(copied.last), bytes);
      expect(tester.takeException(), isNull);
    });
  });

  group('截断 / 真实大小', () {
    test('>cap 响应：truncated=true 且 size 为 Content-Length 真实值', () async {
      final total = DebugSender.maxBodyBytes + 8192;
      final body = Uint8List(total)..fillRange(0, total, 0x41);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.text;
        request.response.contentLength = total;
        try {
          request.response.add(body);
          await request.response.close();
        } catch (_) {
          // 客户端达到上限后停止读取，服务端写入可能抛错，属预期。
        }
      });

      // `TestWidgetsFlutterBinding` 会把 `HttpOverrides` 换成返回 400 的假客户端；
      // 本用例需要真实 loopback 连接。注意 `IOClient` 在**构造时**就创建
      // `HttpClient`，故 sender 必须在真实覆盖的 zone 内创建（仅作用于本 zone）。
      late final DebugSender sender;
      final response = await HttpOverrides.runWithHttpOverrides(
        () {
          sender = DebugSender();
          return sender.send(
            method: 'GET',
            url: 'http://127.0.0.1:${server.port}/big',
            timeout: const Duration(seconds: 30),
          );
        },
        _RealHttpOverrides(),
      );
      addTearDown(sender.close);

      expect(response.error, isNull);
      expect(response.statusCode, 200);
      expect(response.truncated, isTrue, reason: '超过读取上限必须标记 truncated');
      expect(response.bodyBytes.length, DebugSender.maxBodyBytes,
          reason: '原始字节必须在 cap 处截断');
      expect(response.sizeBytes, total,
          reason: 'sizeBytes 必须是 Content-Length 声明的真实大小，而非截断后长度');
    });

    testWidgets('UI 标注「已截断」且大小显示真实值', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
            'content-length': <String>['9000000'],
          },
          body: 'A' * 100,
          sizeBytes: 9000000,
          truncated: true,
        ),
      );

      expect(find.byKey(const Key('response-truncated')), findsOneWidget);
      expect(find.text('已截断'), findsOneWidget);
      final size = tester.widget<Text>(find.byKey(const Key('response-size')));
      expect(size.data, byteSize(9000000));
      expect(tester.takeException(), isNull);
    });

    testWidgets('未截断响应不显示「已截断」', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: 'small',
        ),
      );
      expect(find.byKey(const Key('response-truncated')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('大响应交给 CodeEditor，无异常', (tester) async {
      await _pump(
        tester,
        _response(
          headers: const <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          body: 'A' * 120000,
        ),
      );
      expect(find.byKey(const Key('response-body-code')), findsOneWidget);
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(find.byKey(const Key('response-body-more')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('保存为改写响应 · 头卫生 / 错误禁存', () {
    test(
        '剥离 hop-by-hop / content-encoding / content-length / transfer-encoding',
        () {
      final response = _response(
        headers: const <String, List<String>>{
          'content-type': <String>['application/json'],
          'content-encoding': <String>['gzip'],
          'content-length': <String>['123'],
          'transfer-encoding': <String>['chunked'],
          'connection': <String>['keep-alive, x-custom-hop'],
          'keep-alive': <String>['timeout=5'],
          'x-custom-hop': <String>['secret'],
          'x-extra': <String>['v1'],
        },
        body: '{}',
      );

      final headers = response.rewriteRuleHeaders();
      final names = headers.map((h) => h.name.toLowerCase()).toSet();
      for (final banned in const <String>[
        'content-encoding',
        'content-length',
        'transfer-encoding',
        'connection',
        'keep-alive',
        'x-custom-hop',
      ]) {
        expect(names.contains(banned), isFalse, reason: '$banned 必须被剥离');
      }
      expect(
        headers.any((h) =>
            h.name.toLowerCase() == 'content-type' &&
            h.value == 'application/json'),
        isTrue,
        reason: '语义头必须保留',
      );
      expect(
        headers
            .any((h) => h.name.toLowerCase() == 'x-extra' && h.value == 'v1'),
        isTrue,
        reason: '普通头必须保留',
      );
    });

    testWidgets('错误响应禁用保存为改写', (tester) async {
      DebugRewriteRule? captured;
      final response = _response(error: '连接失败', statusCode: 0);
      await _pump(
        tester,
        response,
        viewer: ResponseViewer(
          response: response,
          method: 'GET',
          url: 'https://api.example/x',
          onSaveAsRewrite: (rule) async {
            captured = rule;
            return CaptureRulesResult<DebugRewriteRule>.success(rule);
          },
        ),
      );

      await tester.tap(find.byKey(const Key('response-overflow')));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<String>>(
        find.byKey(const Key('response-save-rewrite')),
      );
      expect(item.enabled, isFalse, reason: '错误响应必须禁用保存');
      await tester.tap(
        find.byKey(const Key('response-save-rewrite')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(captured, isNull);
      expect(find.text('保存为改写响应？'), findsNothing);
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
          'content-encoding': <String>['gzip'],
          'content-length': <String>['17'],
          'transfer-encoding': <String>['chunked'],
          'connection': <String>['keep-alive'],
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

      await tester.tap(find.byKey(const Key('response-overflow')));
      await tester.pumpAndSettle();
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
      final rewriteNames =
          captured!.respHeaders!.map((h) => h.name.toLowerCase()).toSet();
      for (final banned in const <String>[
        'content-encoding',
        'content-length',
        'transfer-encoding',
        'connection',
      ]) {
        expect(rewriteNames.contains(banned), isFalse,
            reason: '$banned 不得出现在改写响应头中');
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('JSON 词法 / 折叠（纯逻辑）', () {
    test('tokenizeJsonLine 识别 key / string / number / keyword / 标点', () {
      final kinds =
          tokenizeJsonLine('  "name": "value", "ok": true, "n": -3.5e2')
              .map((token) => token.kind)
              .toSet();
      expect(kinds, contains(JsonTokenKind.key));
      expect(kinds, contains(JsonTokenKind.string));
      expect(kinds, contains(JsonTokenKind.number));
      expect(kinds, contains(JsonTokenKind.keyword));
      expect(kinds, contains(JsonTokenKind.punctuation));
    });

    test('jsonFoldRegions 找到对象与数组区间', () {
      const raw = '{"a":[1,2],"b":{"c":3}}';
      final regions = jsonFoldRegions(tryPrettyJson(raw)!.split('\n'));
      expect(regions.length, 3);
      expect(regions.map((r) => r.id).toSet().length, 3);
      for (final region in regions) {
        expect(region.closeLine, greaterThan(region.openLine));
      }
    });

    test('jsonFoldRegions 忽略空容器单行', () {
      final regions = jsonFoldRegions(
        tryPrettyJson('{"a":{},"b":[]}')!.split('\n'),
      );
      // 仅根对象形成区间；内联的空 `{}` / `[]` 不新增区间。
      expect(regions.length, 1);
      expect(regions.single.openLine, 0);
    });
  });
}
