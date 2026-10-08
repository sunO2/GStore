/// T3：`bodyKind` 真正影响线缆编码。
///
/// 覆盖：
/// - 纯编码表驱动（none/json/text/form_urlencoded/multipart/binary）；
/// - `decodeBinaryText` hex/base64/raw；
/// - `DebugSender` 真实 `dart:io` `HttpServer` 集成：form / multipart /
///   binary 的服务端字节断言 + Content-Type；
/// - 编辑器接线（json 自动补 Content-Type、显式头不覆盖）；
/// - 旧 store（无新字段）加载并走旧 `body` 路径发送。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/request_debug/body_encoder.dart';
import 'package:gstore/core/request_debug/body_encoder_io.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/page/request_debug/request_editor_page.dart';
import 'package:path/path.dart' as p;

// ==================== 真实 HttpServer fixture ====================

class _Recorded {
  _Recorded(HttpRequest request)
      : method = request.method,
        path = request.uri.path,
        contentType = request.headers.value('content-type');
  final String method;
  final String path;
  final String? contentType;
  List<int> body = const <int>[];
  String get bodyText => utf8.decode(body, allowMalformed: true);
}

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
      final recorded = _Recorded(request);
      final chunks = await request.toList();
      recorded.body = <int>[for (final c in chunks) ...c];
      fixture.recorded.add(recorded);
      request.response.statusCode = HttpStatus.ok;
      request.response.write('ok');
      await request.response.close();
    });
    return fixture;
  }

  Future<void> close() async {
    await _sub.cancel();
    await _server.close(force: true);
  }
}

/// 极简 multipart 解析（仅 ASCII；测试文件字节用可 latin1 往返的值）。
class _ParsedPart {
  _ParsedPart(this.headers, this.body);
  final Map<String, String> headers;
  final String body;
}

List<_ParsedPart> _parseMultipart(String text, String boundary) {
  final parts = <_ParsedPart>[];
  for (final segment in text.split('--$boundary')) {
    var seg = segment;
    if (seg.startsWith('\r\n')) seg = seg.substring(2);
    if (seg.endsWith('\r\n')) seg = seg.substring(0, seg.length - 2);
    if (seg.isEmpty || seg == '--') continue;
    final split = seg.indexOf('\r\n\r\n');
    if (split < 0) continue;
    final headerBlock = seg.substring(0, split);
    final body = seg.substring(split + 4);
    final headers = <String, String>{};
    for (final line in headerBlock.split('\r\n')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      headers[line.substring(0, colon).trim().toLowerCase()] =
          line.substring(colon + 1).trim();
    }
    parts.add(_ParsedPart(headers, body));
  }
  return parts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_test 默认安装 mock HttpClient（所有请求返回 400）；真实
  // `dart:io` HttpServer fixture 需要恢复真实网络栈。
  setUp(() {
    HttpOverrides.global = null;
  });

  group('encodeBody（纯函数）', () {
    test('none：空字节且无 Content-Type', () {
      final result = encodeBody(
        const BodyEncodeInput(kind: DebugBodyKind.none, text: 'ignored'),
      );
      expect(result.bytes, isEmpty);
      expect(result.contentType, isNull);
    });

    test('json：UTF-8 字节 + application/json', () {
      final result = encodeBody(
        const BodyEncodeInput(kind: DebugBodyKind.json, text: '{"a":1}'),
      );
      expect(result.bytes, utf8.encode('{"a":1}'));
      expect(result.contentType, 'application/json');
    });

    test('text：UTF-8 字节 + text/plain; charset=utf-8', () {
      final result = encodeBody(
        const BodyEncodeInput(kind: DebugBodyKind.text, text: 'hello 世界'),
      );
      expect(result.bytes, utf8.encode('hello 世界'));
      expect(result.contentType, 'text/plain; charset=utf-8');
    });

    test('form_urlencoded：值被 URL 编码（空格→+，+→%2B，非 ASCII）', () {
      final result = encodeBody(
        const BodyEncodeInput(
          kind: DebugBodyKind.formUrlEncoded,
          text: 'name=张三 李四&city=new york&plus=a+b&flag',
        ),
      );
      expect(
        utf8.decode(result.bytes),
        'name=%E5%BC%A0%E4%B8%89+%E6%9D%8E%E5%9B%9B'
        '&city=new+york&plus=a%2Bb&flag=',
      );
      expect(result.contentType, 'application/x-www-form-urlencoded');
    });

    test('multipart：boundary + 文本/文件 part + 结尾 boundary', () {
      final result = encodeBody(
        const BodyEncodeInput(
          kind: DebugBodyKind.multipart,
          boundary: 'TESTBOUNDARY',
          parts: <BodyPart>[
            BodyPart(name: 'field1', value: 'value1'),
            BodyPart(
              name: 'file1',
              fileName: 'hello.txt',
              contentType: 'text/plain',
              fileBytes: <int>[65, 66, 67],
            ),
          ],
        ),
      );
      expect(result.contentType, 'multipart/form-data; boundary=TESTBOUNDARY');
      final text = latin1.decode(result.bytes);
      final parts = _parseMultipart(text, 'TESTBOUNDARY');
      expect(parts, hasLength(2));
      expect(
        parts[0].headers['content-disposition'],
        'form-data; name="field1"',
      );
      expect(parts[0].body, 'value1');
      expect(
        parts[1].headers['content-disposition'],
        'form-data; name="file1"; filename="hello.txt"',
      );
      expect(parts[1].headers['content-type'], 'text/plain');
      expect(parts[1].body, 'ABC');
      expect(text.trimRight(), endsWith('--TESTBOUNDARY--'));
    });

    test('multipart：未指定 boundary 时自动生成且出现在 Content-Type', () {
      final result = encodeBody(
        const BodyEncodeInput(
          kind: DebugBodyKind.multipart,
          parts: <BodyPart>[BodyPart(name: 'a', value: '1')],
        ),
      );
      final boundary = multipartBoundaryOf(result.contentType);
      expect(boundary, isNotNull);
      final text = latin1.decode(result.bytes);
      expect(text, contains('--$boundary'));
      expect(text, contains('name="a"'));
    });

    test('binary：使用已解析字节，不自动设 Content-Type', () {
      final result = encodeBody(
        const BodyEncodeInput(
          kind: DebugBodyKind.binary,
          binaryBytes: <int>[0, 1, 2, 255],
        ),
      );
      expect(result.bytes, <int>[0, 1, 2, 255]);
      expect(result.contentType, isNull);
    });
  });

  group('decodeBinaryText（纯函数）', () {
    test('raw 为 UTF-8', () {
      expect(decodeBinaryText('hi', DebugBinarySource.raw), utf8.encode('hi'));
    });

    test('hex 支持空白/冒号分隔且大小写不敏感', () {
      expect(
        decodeBinaryText('0A:ff 10', DebugBinarySource.hex),
        <int>[0x0A, 0xFF, 0x10],
      );
    });

    test('hex 非法（奇数长度/非 hex）返回 null', () {
      expect(decodeBinaryText('abc', DebugBinarySource.hex), isNull);
      expect(decodeBinaryText('zz', DebugBinarySource.hex), isNull);
    });

    test('base64 解码；非法返回 null', () {
      expect(
        decodeBinaryText('aGVsbG8=', DebugBinarySource.base64),
        utf8.encode('hello'),
      );
      expect(decodeBinaryText('***', DebugBinarySource.base64), isNull);
    });
  });

  group('sender 集成（真实 HttpServer）', () {
    test('form_urlencoded：服务端收到编码体 + 头', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      final encoded = encodeBody(
        const BodyEncodeInput(
          kind: DebugBodyKind.formUrlEncoded,
          text: 'a=1&b=hello world',
        ),
      );
      final response = await sender.send(
        method: 'POST',
        url: '${fixture.origin}/form',
        headers: <DebugHeader>[
          DebugHeader(name: 'Content-Type', value: encoded.contentType!),
        ],
        bodyBytes: encoded.bytes,
      );
      expect(response.error, isNull);
      final recorded = fixture.recorded.single;
      expect(recorded.bodyText, 'a=1&b=hello+world');
      expect(recorded.contentType, 'application/x-www-form-urlencoded');
    });

    test('multipart：服务端收到 boundary + 字段/文件 part', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      final encoded = encodeBody(
        const BodyEncodeInput(
          kind: DebugBodyKind.multipart,
          boundary: 'BND',
          parts: <BodyPart>[
            BodyPart(name: 'field1', value: 'v1'),
            BodyPart(
              name: 'f',
              fileName: 'a.txt',
              fileBytes: <int>[65, 66, 67],
            ),
          ],
        ),
      );
      await sender.send(
        method: 'POST',
        url: '${fixture.origin}/multipart',
        headers: <DebugHeader>[
          DebugHeader(name: 'Content-Type', value: encoded.contentType!),
        ],
        bodyBytes: encoded.bytes,
      );
      final recorded = fixture.recorded.single;
      expect(recorded.contentType, 'multipart/form-data; boundary=BND');
      final text = latin1.decode(recorded.body);
      final parts = _parseMultipart(text, 'BND');
      expect(parts.map((e) => e.body).toList(), <String>['v1', 'ABC']);
      expect(
        parts[1].headers['content-disposition'],
        contains('filename="a.txt"'),
      );
    });

    test('binary：服务端收到完全一致字节', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      const bytes = <int>[0, 1, 2, 127, 128, 255];
      final encoded = encodeBody(
        const BodyEncodeInput(kind: DebugBodyKind.binary, binaryBytes: bytes),
      );
      await sender.send(
        method: 'POST',
        url: '${fixture.origin}/bin',
        headers: const <DebugHeader>[
          DebugHeader(name: 'Content-Type', value: 'application/octet-stream'),
        ],
        bodyBytes: encoded.bytes,
      );
      final recorded = fixture.recorded.single;
      expect(recorded.body, bytes);
      expect(recorded.contentType, 'application/octet-stream');
    });

    test('旧路径：仅传 body 时字节与 Content-Type 行为不变', () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      await sender.send(
        method: 'POST',
        url: '${fixture.origin}/legacy',
        body: '{"legacy":true}',
      );
      final recorded = fixture.recorded.single;
      expect(recorded.bodyText, '{"legacy":true}');
      expect(recorded.contentType, isNull,
          reason: '旧路径不得自动补 Content-Type');
    });
  });

  group('编辑器接线', () {
    testWidgets('json：自动补 Content-Type 并发送 UTF-8 字节', (tester) async {
      final sender = _CapturingSender();
      final facade = _TestFacade(sender: sender);
      await tester.pumpWidget(MaterialApp(
        home: RequestEditorPage(
          facade: facade,
          request: DebugRequest(
            id: 'r1',
            name: 'r1',
            method: 'POST',
            url: 'https://example.com/x',
            body: '{"a":1}',
            bodyKind: DebugBodyKind.json,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pumpAndSettle();

      expect(sender.calls, hasLength(1));
      expect(sender.calls.single.bodyBytes, utf8.encode('{"a":1}'));
      expect(
        sender.calls.single.headerMap['content-type'],
        'application/json',
      );
    });

    testWidgets('json：已显式设置 Content-Type 时不覆盖', (tester) async {
      final sender = _CapturingSender();
      final facade = _TestFacade(sender: sender);
      await tester.pumpWidget(MaterialApp(
        home: RequestEditorPage(
          facade: facade,
          request: DebugRequest(
            id: 'r2',
            name: 'r2',
            method: 'POST',
            url: 'https://example.com/x',
            body: '{"a":1}',
            bodyKind: DebugBodyKind.json,
            headers: const <DebugHeader>[
              DebugHeader(name: 'Content-Type', value: 'application/vnd.x+json'),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pumpAndSettle();

      final call = sender.calls.single;
      final contentTypes = call.headers.entries
          .where((h) => h.key == 'content-type')
          .map((h) => h.value)
          .toList();
      expect(contentTypes, <String>['application/vnd.x+json']);
    });

    testWidgets('form_urlencoded：发送编码后的字节', (tester) async {
      final sender = _CapturingSender();
      final facade = _TestFacade(sender: sender);
      await tester.pumpWidget(MaterialApp(
        home: RequestEditorPage(
          facade: facade,
          request: DebugRequest(
            id: 'r3',
            name: 'r3',
            method: 'POST',
            url: 'https://example.com/x',
            body: 'a=1&b=hello world',
            bodyKind: DebugBodyKind.formUrlEncoded,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pumpAndSettle();

      expect(sender.calls.single.bodyBytes, utf8.encode('a=1&b=hello+world'));
      expect(
        sender.calls.single.headerMap['content-type'],
        'application/x-www-form-urlencoded',
      );
    });
  });

  group('旧 store 兼容', () {
    test('无新字段的旧 fixture 可加载并按旧路径发送', () async {
      final dir = Directory.systemTemp.createTempSync('t3_legacy_store_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, RequestDebugStore.fileName));
      await file.writeAsString(jsonEncode(<String, dynamic>{
        'version': 1,
        'activeEnvironmentId': null,
        'collections': <dynamic>[
          <String, dynamic>{
            'id': 'c1',
            'name': 'C',
            'requests': <dynamic>[
              <String, dynamic>{
                'id': 'r1',
                'name': 'legacy',
                'method': 'POST',
                'url': 'https://example.com/x',
                'headers': <dynamic>[],
                'query': <dynamic>[],
                'body': '{"legacy":true}',
                'bodyKind': 'json',
                'cookies': <dynamic>[],
              },
            ],
          },
        ],
        'environments': <dynamic>[],
        'history': <dynamic>[],
        'rules': <dynamic>[],
      }));

      final store = RequestDebugStore(directoryProvider: () async => dir);
      await store.load();

      final loaded = store.requestById('r1');
      expect(loaded, isNotNull);
      expect(loaded!.bodyKind, DebugBodyKind.json);
      expect(loaded.binarySource, DebugBinarySource.raw);
      expect(loaded.multipartFields, isEmpty);
      expect(loaded.binaryFilePath, isNull);

      final fixture = await _Fixture.start();
      addTearDown(fixture.close);
      final sender = DebugSender();
      addTearDown(sender.close);

      // 旧路径：仅传 body（无 bodyBytes）。
      await sender.send(
        method: loaded.method,
        url: '${fixture.origin}/legacy',
        body: loaded.body,
      );
      final recorded = fixture.recorded.single;
      expect(recorded.bodyText, '{"legacy":true}');
      expect(recorded.contentType, isNull);
    });
  });

  group('resolveMultipartFields（IO 辅助）', () {
    test('文本字段与文件字段解析为 parts', () async {
      final dir = Directory.systemTemp.createTempSync('t3_io_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'data.bin'));
      await file.writeAsBytes(<int>[1, 2, 3]);

      final parts = await resolveMultipartFields(
        <DebugMultipartField>[
          const DebugMultipartField(name: 'a', value: '1'),
          DebugMultipartField(name: 'f', filePath: file.path),
          const DebugMultipartField(name: 'off', value: 'x', enabled: false),
        ],
      );
      expect(parts, hasLength(2));
      expect(parts[0].name, 'a');
      expect(parts[0].value, '1');
      expect(parts[1].isFile, isTrue);
      expect(parts[1].fileName, 'data.bin');
      expect(parts[1].fileBytes, <int>[1, 2, 3]);
    });

    test('resolveBinaryBytes：file 源读取文件，hex 源纯解码', () async {
      final dir = Directory.systemTemp.createTempSync('t3_io_bin_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'b.bin'));
      await file.writeAsBytes(<int>[9, 8, 7]);

      expect(
        await resolveBinaryBytes('', DebugBinarySource.file,
            filePath: file.path),
        <int>[9, 8, 7],
      );
      expect(
        await resolveBinaryBytes('0a ff', DebugBinarySource.hex),
        <int>[10, 255],
      );
    });
  });
}

// ==================== 假实现（本文件局部） ====================

class _Call {
  _Call({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    required this.bodyBytes,
  });
  final String method;
  final String url;
  final Map<String, String> headers;
  final String body;
  final List<int>? bodyBytes;

  Map<String, String> get headerMap =>
      <String, String>{for (final e in headers.entries) e.key: e.value};
}

class _CapturingSender implements DebugSender {
  final List<_Call> calls = <_Call>[];

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
    calls.add(_Call(
      method: method,
      url: url,
      headers: <String, String>{
        for (final h in headers)
          if (h.enabled && h.name.isNotEmpty) h.name.toLowerCase(): h.value,
      },
      body: body,
      bodyBytes: bodyBytes,
    ));
    return const DebugResponse(statusCode: 200, bodyText: 'ok', sizeBytes: 2);
  }

  @override
  void close() {}
}

class _TestFacade extends DefaultRequestDebugFacade {
  _TestFacade({required super.sender})
      : super(
          store: RequestDebugStore(
            directoryProvider: () async => Directory.systemTemp,
          ),
        );

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async => true;
}
