/// 「请求调试」响应存盘 + 原始请求视图（plan todo 18）测试。
///
/// 覆盖验收标准：
/// - 存盘字节**逐字节一致**（含二进制原始字节）；
/// - 无原始字节时回退为 UTF-8 文本编码；
/// - `ResponseViewer` 的「保存响应体」按钮把注入接缝收到的字节写入磁盘后与
///   原始字节完全一致；
/// - 「原始请求」视图（方法 / URL / 头 / 体）与草稿一致；
/// - 空草稿展示空态。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/request_debug.dart';
import 'package:gstore/page/request_debug/raw_request_view.dart';
import 'package:gstore/page/request_debug/response_save_actions.dart';
import 'package:gstore/page/request_debug/response_viewer.dart';

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(body: child),
    );

DebugRequest _draft() => DebugRequest(
      id: 'r1',
      name: '草稿',
      method: 'POST',
      url: 'https://api.example/users',
      headers: const <DebugHeader>[
        DebugHeader(name: 'Content-Type', value: 'application/json'),
        DebugHeader(name: 'X-Token', value: 'abc'),
        DebugHeader(name: 'X-Off', value: 'no', enabled: false),
      ],
      query: const <DebugQueryParam>[
        DebugQueryParam(name: 'page', value: '2'),
        DebugQueryParam(name: 'q', value: 'a b'),
        DebugQueryParam(name: 'off', value: 'x', enabled: false),
      ],
      body: '{"a":1}',
      bodyKind: DebugBodyKind.json,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('responseBodyBytesForSave（逐字节）', () {
    test('含原始字节（二进制）→ 原样返回，逐字节一致', () {
      final bytes = <int>[0x00, 0xff, 0x10, 0x80, 0x7f, 0x0a];
      final response = DebugResponse(
        statusCode: 200,
        bodyBytes: bytes,
        bodyText: 'preview',
        sizeBytes: bytes.length,
      );

      final saved = responseBodyBytesForSave(response);
      expect(saved, equals(bytes));
    });

    test('无原始字节 → UTF-8 编码 bodyText', () {
      final response = const DebugResponse(
        statusCode: 200,
        bodyText: '你好',
        sizeBytes: 6,
      );
      expect(responseBodyBytesForSave(response), equals(utf8.encode('你好')));
    });
  });

  group('suggestResponseBodyFileName', () {
    test('按 Content-Type 选择扩展名', () {
      final json = DebugResponse(
        statusCode: 200,
        headers: const <String, List<String>>{
          'content-type': <String>['application/json'],
        },
      );
      expect(suggestResponseBodyFileName(json), endsWith('.json'));

      final binary = DebugResponse(
        statusCode: 200,
        headers: const <String, List<String>>{
          'content-type': <String>['image/png'],
        },
      );
      expect(suggestResponseBodyFileName(binary), endsWith('.bin'));
    });
  });

  group('保存响应体到磁盘（真实文件）', () {
    testWidgets('二进制存盘后读回与原始字节完全一致', (tester) async {
      final bytes = <int>[0x89, 0x50, 0x4e, 0x47, 0x00, 0x01, 0xfe];
      final response = DebugResponse(
        statusCode: 200,
        bodyBytes: bytes,
        bodyText: 'png',
        sizeBytes: bytes.length,
      );

      final dir = Directory.systemTemp.createTempSync('save_body_test_');
      addTearDown(() => dir.deleteSync(recursive: true));

      await tester.pumpWidget(_host(const SizedBox(key: Key('save-ctx'))));
      final context = tester.element(find.byKey(const Key('save-ctx')));

      List<int>? captured;
      String? capturedName;
      final ok = await saveDebugResponseBody(
        context,
        response,
        saveFile: (name, data) async {
          capturedName = name;
          captured = data;
          File('${dir.path}/$name').writeAsBytesSync(data);
          return true;
        },
      );

      expect(ok, true);
      expect(captured, equals(bytes));
      final onDisk = File('${dir.path}/$capturedName').readAsBytesSync();
      expect(onDisk, equals(bytes), reason: '磁盘字节必须与原始响应字节一致');
    });
  });

  group('ResponseViewer 保存响应体按钮', () {
    testWidgets('点击保存 → 接缝收到逐字节一致的原始字节', (tester) async {
      final bytes = <int>[0x01, 0x02, 0x03, 0xff];
      final response = DebugResponse(
        statusCode: 200,
        bodyBytes: bytes,
        bodyText: 'x',
        sizeBytes: bytes.length,
      );

      List<int>? captured;
      await tester.pumpWidget(_host(ResponseViewer(
        response: response,
        saveFile: (name, data) async {
          captured = data;
          return true;
        },
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('response-overflow')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('response-save-body')), findsOneWidget);
      await tester.tap(find.byKey(const Key('response-save-body')));
      await tester.pumpAndSettle();

      expect(captured, equals(bytes));
      expect(tester.takeException(), isNull);
    });
  });

  group('RawRequestView（原始请求）', () {
    test('composeRawRequest 含方法 / 完整 URL / 启用头 / 体', () {
      final text = composeRawRequest(_draft());
      expect(text, startsWith('POST https://api.example/users?page=2&q=a%20b'));
      expect(text, contains('Content-Type: application/json'));
      expect(text, contains('X-Token: abc'));
      expect(text, isNot(contains('X-Off')));
      expect(text, isNot(contains('off=x')));
      expect(text, contains('{"a":1}'));
    });

    testWidgets('视图文本与草稿一致', (tester) async {
      await tester.pumpWidget(_host(RawRequestView(request: _draft())));
      await tester.pumpAndSettle();

      final text = tester
          .widget<SelectableText>(find.byKey(const Key('raw-request-text')))
          .data!;
      expect(text, contains('POST '));
      expect(text, contains('https://api.example/users?page=2'));
      expect(text, contains('Content-Type: application/json'));
      expect(text, contains('X-Token: abc'));
      expect(text, contains('{"a":1}'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('空草稿 → 空态', (tester) async {
      await tester.pumpWidget(_host(const RawRequestView()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('raw-request-empty')), findsOneWidget);
    });
  });
}
