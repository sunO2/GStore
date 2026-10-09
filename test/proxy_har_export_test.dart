// Todo 35 验收测试：抓包 → HAR 1.2 导出（纯 Dart）。
//
// 覆盖（plan todo 35 契约）：
// * 导出 HAR 结构合法（`log.version` / `creator` / `entries`）；
// * 每条 entry 含 request / response / timings；
// * 可被既有 HAR 解析器（`decodeHar`，T16 codec）读回；
// * 大 body / 二进制 body 不崩（大文本原样；二进制 base64 + `encoding`）；
// * 空列表产出合法空 HAR；
// * 详情页「导出为 HAR」入口经注入的 `saveFile` 接缝落地，写入字节可解析。
//
// 密闭式：纯函数单测 + 注入假门面 / 假存盘接缝，不触碰 FFI / 原生模块。
// 不重复请求 Tree：导出为**扁平** `log.entries`，每条 entry 只映射一条抓包。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/import_export/har_codec.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_capture_detail_page.dart';
import 'package:gstore/page/proxy/proxy_har_export.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

/// 解析一帧（避免 `pumpAndSettle` 与常驻 [AppLoading] 动画冲突）。
Future<void> _settleLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

class _FakeDetailFacade implements ProxyCaptureDetailFacade {
  _FakeDetailFacade(this.value);

  CaptureDetail value;

  @override
  Future<CaptureDetail> detail(int recordId) async => value;
}

// ==================== 样例数据 ====================

CaptureDetail _detail({
  int recordId = 7,
  String method = 'POST',
  String url = 'https://example.com/api/data?q=1&lang=zh',
  String reqHeaders = 'Accept: application/json\r\n'
      'Content-Type: application/json\r\n'
      'Cookie: sid=abc',
  String respHeaders = 'Content-Type: application/json\r\n'
      'Set-Cookie: token=xyz; Path=/; HttpOnly',
  List<int> reqBody = const <int>[],
  List<int> respBody = const <int>[],
  int reqBytes = 0,
  int respBytes = 0,
  String contentType = 'application/json',
  int statusCode = 200,
  int startedAtMs = 1700000000000,
  int finishedAtMs = 1700000000100,
  int durationMs = 100,
}) {
  return CaptureDetail(
    recordId: recordId,
    requestRecordId: 3,
    connId: 'conn-1',
    host: 'example.com',
    method: method,
    scheme: 'https',
    url: url,
    statusCode: statusCode,
    protocol: 'h2',
    reqHeaders: reqHeaders,
    respHeaders: respHeaders,
    reqBody: reqBody,
    respBody: respBody,
    reqBytes: reqBytes == 0 ? reqBody.length : reqBytes,
    respBytes: respBytes == 0 ? respBody.length : respBytes,
    contentType: contentType,
    startedAtMs: startedAtMs,
    finishedAtMs: finishedAtMs,
    durationMs: durationMs,
  );
}

Map<String, dynamic> _logOf(String har) =>
    (jsonDecode(har) as Map<String, dynamic>)['log'] as Map<String, dynamic>;

List<Map<String, dynamic>> _entriesOf(String har) =>
    (_logOf(har)['entries'] as List)
        .cast<Map<String, dynamic>>()
        .toList();

// ==================== 测试 ====================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encodeCaptureHar', () {
    test('生成合法 HAR 1.2 且含 request/response/timing', () {
      final har = encodeCaptureHar(<CaptureDetail>[
        _detail(reqBody: utf8.encode('{"a":1}')),
      ]);

      final log = _logOf(har);
      expect(log['version'], '1.2');
      expect(log['creator'], isA<Map<String, dynamic>>());
      expect((log['creator'] as Map)['name'], isNotEmpty);

      final entries = _entriesOf(har);
      expect(entries, hasLength(1));
      final entry = entries.single;

      // 时间线字段。
      expect(entry['startedDateTime'], isA<String>());
      expect(entry['time'], 100);
      expect(entry['timings'], isA<Map<String, dynamic>>());

      // 请求。
      final request = entry['request'] as Map<String, dynamic>;
      expect(request['method'], 'POST');
      expect(request['url'], 'https://example.com/api/data?q=1&lang=zh');
      expect(request['headers'], isA<List>());
      expect(
        (request['headers'] as List)
            .any((h) => (h as Map)['name'] == 'Content-Type'),
        isTrue,
      );
      expect(request['queryString'], isA<List>());
      expect(request['postData'], isA<Map<String, dynamic>>());

      // 响应。
      final response = entry['response'] as Map<String, dynamic>;
      expect(response['status'], 200);
      expect(
        (response['content'] as Map)['mimeType'],
        contains('application/json'),
      );
      expect(
        (response['headers'] as List)
            .any((h) => (h as Map)['name'] == 'Set-Cookie'),
        isTrue,
      );

      expect(entry['cache'], isA<Map<String, dynamic>>());
    });

    test('可被既有 HAR 解析器（decodeHar）读回同一请求', () {
      final har = encodeCaptureHar(<CaptureDetail>[
        _detail(
          method: 'PUT',
          url: 'https://api.test/v1/items?id=9',
          reqBody: utf8.encode('{"name":"gstore"}'),
        ),
      ]);

      final result = decodeHar(har);
      expect(
        result.isSuccess,
        isTrue,
        reason: '标准 HAR 必须可被 T16 解析器读回：${result.error}',
      );
      final collections = result.requireValue();
      final requests = [
        for (final c in collections) ...c.requests,
      ];
      expect(requests, hasLength(1));
      expect(requests.single.method, 'PUT');
      expect(requests.single.url, 'https://api.test/v1/items');
      expect(requests.single.body, '{"name":"gstore"}');
      expect(requests.single.query.single.name, 'id');
      expect(requests.single.query.single.value, '9');
    });

    test('大 body（2 MiB 文本）不崩且 size 正确', () {
      final big = utf8.encode('x' * (2 * 1024 * 1024));
      late String har;
      expect(
        () => har = encodeCaptureHar(<CaptureDetail>[
          _detail(
            method: 'GET',
            reqBody: const <int>[],
            respBody: big,
            contentType: 'text/plain',
            respHeaders: 'Content-Type: text/plain',
          ),
        ]),
        returnsNormally,
      );
      final content =
          _entriesOf(har).single['response']['content'] as Map<String, dynamic>;
      expect(content['size'], big.length);
      expect(content['text'], isA<String>());
    });

    test('二进制 body：base64 编码不崩且可读回', () {
      final binary = List<int>.generate(4096, (i) => (i * 7) % 256);
      final har = encodeCaptureHar(<CaptureDetail>[
        _detail(
          method: 'GET',
          respBody: binary,
          contentType: 'application/octet-stream',
          respHeaders: 'Content-Type: application/octet-stream',
        ),
      ]);

      final content =
          _entriesOf(har).single['response']['content'] as Map<String, dynamic>;
      expect(content['encoding'], 'base64');
      expect(base64Decode(content['text'] as String), equals(binary));

      // 结构仍可被解析器读回（请求侧不受响应 body 影响）。
      expect(decodeHar(har).isSuccess, isTrue);
    });

    test('空列表：合法空 HAR', () {
      final har = encodeCaptureHar(const <CaptureDetail>[]);
      expect(_logOf(har)['version'], '1.2');
      expect(_entriesOf(har), isEmpty);
      expect(decodeHar(har).isSuccess, isTrue);
    });
  });

  testWidgets('详情页「导出为 HAR」经存盘接缝写入可解析的 HAR', (tester) async {
    Uint8List? saved;
    String? savedName;
    List<String>? savedExt;

    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(_detail(reqBody: utf8.encode('{"a":1}'))),
      saveFile: ({
        required String fileName,
        required Uint8List bytes,
        required List<String> allowedExtensions,
      }) async {
        saved = bytes;
        savedName = fileName;
        savedExt = allowedExtensions;
        return '/tmp/$fileName';
      },
    )));
    await _settleLoad(tester);

    await tester.tap(find.byKey(const Key('detail_actions_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action_export_har')));
    await tester.pumpAndSettle();

    expect(saved, isNotNull, reason: '导出为 HAR 必须调用存盘接缝');
    expect(savedName, endsWith('.har'));
    expect(savedExt, contains('har'));
    final entries = _entriesOf(utf8.decode(saved!));
    expect(entries, hasLength(1));
    expect(entries.single['request']['url'], 'https://example.com/api/data?q=1&lang=zh');
    expect(entries.single['response']['status'], 200);
    expect(tester.takeException(), isNull);
  });
}
