/// 「请求调试」历史响应快照（plan todo 6）测试。
///
/// 覆盖验收标准：
/// - 编辑器发送成功后写入历史（`appendDebugHistory` + `save`），快照内容与
///   服务端实际返回一致（真实 `dart:io HttpServer` fixture 防「假绿」）；
/// - 取消的发送**不**追加历史；
/// - 响应体超过快照上限时截断并标注 `truncated`，`sizeBytes` 保留真实值；
/// - 旧格式 store（历史无 `responseSnapshot` 字段）可无异常加载，快照为 null；
/// - 历史有界：超过 `historyLimit` 淘汰最旧条目并**一并清理其快照**；
/// - 历史条目快照可载入响应查看器（widget）。
library;

import 'dart:async';
import 'dart:convert';
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
import 'package:gstore/page/request_debug/history_section.dart';
import 'package:gstore/page/request_debug/request_editor_page.dart';

// ==================== 真实 HttpServer fixture ====================

/// 极简 `HttpServer` fixture：每次请求返回固定响应。
class _Fixture {
  _Fixture._(this._server);

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _sub;

  String get origin => 'http://127.0.0.1:${_server.port}';

  static Future<_Fixture> start(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _Fixture._(server);
    fixture._sub = server.listen((request) async {
      try {
        await handler(request);
      } catch (_) {
        // 客户端断连后写入抛错，属预期（最佳努力）。
      }
    });
    return fixture;
  }

  Future<void> close() async {
    await _sub.cancel();
    await _server.close(force: true);
  }
}

// ==================== 假发送器 / 记录门面 ====================

/// 假发送器：记录每次发送参数，返回受控响应；**不触碰网络**。
class _FakeSender implements DebugSender {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  DebugResponse response = const DebugResponse(
    statusCode: 200,
    bodyText: 'ok',
    sizeBytes: 2,
  );

  /// 为 `true` 时发送挂起直到 `cancelToken` 被取消，返回结构化「已取消」。
  bool blockUntilCancelled = false;

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
    DebugCancellationToken? cancelToken,
  }) async {
    if (blockUntilCancelled && cancelToken != null) {
      await cancelToken.whenCancelled;
      return DebugResponse.cancelled();
    }
    calls.add(<String, Object?>{'method': method, 'url': url, 'body': body});
    return response;
  }

  @override
  void close() {}
}

/// 测试门面：真实内存 store（不落盘）+ 可注入 sender；记录 save 调用。
class _RecordingFacade extends DefaultRequestDebugFacade {
  _RecordingFacade({required super.store, required super.sender});

  int saveCalls = 0;

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async {
    saveCalls++;
    return true;
  }
}

RequestDebugStore _memoryStore({int? historyLimit}) => RequestDebugStore(
      directoryProvider: () async => Directory.systemTemp,
      historyLimit: historyLimit ?? RequestDebugStore.defaultHistoryLimit,
    );

RequestDebugFacade _facade({RequestDebugStore? store, DebugSender? sender}) =>
    _RecordingFacade(
      store: store ?? _memoryStore(),
      sender: sender ?? _FakeSender(),
    );

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('request_debug_history_response_test_');

RequestDebugStore _storeFor(Directory dir, {int? historyLimit}) =>
    RequestDebugStore(
      directoryProvider: () async => dir,
      historyLimit: historyLimit ?? RequestDebugStore.defaultHistoryLimit,
    );

File _storeFile(Directory dir) =>
    File('${dir.path}/${RequestDebugStore.fileName}');

DebugRequest _request(
  String id, {
  String method = 'GET',
  String url = 'https://api.example/users',
}) =>
    DebugRequest(id: id, name: 'n-$id', method: method, url: url);

// ==================== widget 宿主 / 编辑器 ====================

Widget _host(RequestDebugHistorySection section) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(body: section),
    );

/// 把编辑器压入导航栈（先在宿主页点「open-editor」，再进入编辑器）。
///
/// 通过 [request] 预置 URL，**不**经 URL 自适应弹层（弹层确认会触发
/// `onSubmitted → _send`，会污染「精确发送一次」的断言）。
Future<void> _pumpEditor(
  WidgetTester tester, {
  required RequestDebugFacade facade,
  DebugRequest? request,
}) async {
  await tester.pumpWidget(MaterialApp(
    navigatorKey: appNavigatorKey,
    scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: const Key('open-editor'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RequestEditorPage(
                facade: facade,
                request: request,
              ),
            ),
          ),
          child: const Text('open-editor'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open-editor')));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('编辑器发送写历史 + 真实响应快照', () {
    test('真实 HttpServer 发送 → appendDebugHistory 快照内容与收到响应一致', () async {
      // TestWidgetsFlutterBinding 会把所有 HttpClient 请求短路为 400；本用例
      // 需要真实网络，故临时清空 HttpOverrides 并恢复。
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);

      final fixture = await _Fixture.start((request) async {
        request.response.statusCode = 200;
        request.response.headers.contentType =
            ContentType('text', 'plain', charset: 'utf-8');
        request.response.headers.set('X-Trace', 'trace-123');
        request.response.write('hello-from-server');
        await request.response.close();
      });
      addTearDown(fixture.close);

      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final sender = DebugSender();
      addTearDown(sender.close);
      final facade = DefaultRequestDebugFacade(
        store: _storeFor(dir),
        sender: sender,
      );

      final response = await facade.send(
        method: 'GET',
        url: '${fixture.origin}/hello',
      );
      expect(response.statusCode, 200);
      expect(response.bodyText, 'hello-from-server');

      appendDebugHistory(
        facade,
        request: _request('r1', url: '${fixture.origin}/hello'),
        response: response,
      );

      final entry = facade.store.history.single;
      final snapshot = entry.responseSnapshot;
      expect(snapshot, isNotNull, reason: '发送成功后必须写入响应快照');
      expect(snapshot!.statusCode, 200);
      expect(snapshot.bodyText, 'hello-from-server');
      expect(snapshot.headers['x-trace'], contains('trace-123'));
      expect(snapshot.truncated, false);
      // 落盘重载：快照随历史持久化。
      expect(await facade.store.save(), true);
      final reloaded = _storeFor(dir);
      await reloaded.load();
      expect(
        reloaded.history.single.responseSnapshot!.bodyText,
        'hello-from-server',
      );
    });

    testWidgets('编辑器发送成功 → 历史出现并落盘（含快照）', (tester) async {
      final sender = _FakeSender()
        ..response = const DebugResponse(
          statusCode: 201,
          headers: <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          bodyText: 'created',
          sizeBytes: 7,
          durationMs: 4,
        );
      final facade = _RecordingFacade(store: _memoryStore(), sender: sender);

      await _pumpEditor(
        tester,
        facade: facade,
        request: _request('r1', method: 'POST', url: 'https://api.example/create'),
      );

      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pumpAndSettle();

      expect(facade.store.history, hasLength(1));
      final entry = facade.store.history.single;
      expect(entry.request.url, 'https://api.example/create');
      expect(entry.responseSnapshot, isNotNull);
      expect(entry.responseSnapshot!.statusCode, 201);
      expect(entry.responseSnapshot!.bodyText, 'created');
      expect(facade.saveCalls, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('取消发送 → 不追加历史（无半成品快照）', (tester) async {
      final sender = _FakeSender()..blockUntilCancelled = true;
      final facade = _RecordingFacade(store: _memoryStore(), sender: sender);

      await _pumpEditor(
        tester,
        facade: facade,
        request: _request('r1', url: 'https://api.example/slow'),
      );

      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pump();
      expect(find.byKey(const Key('request-editor-cancel')), findsOneWidget);

      await tester.tap(find.byKey(const Key('request-editor-cancel')));
      await tester.pumpAndSettle();

      expect(facade.store.history, isEmpty, reason: '取消绝不能落历史');
      expect(facade.saveCalls, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('快照截断', () {
    test('响应体超过快照上限 → 截断并标注 truncated，sizeBytes 保留真实值', () {
      final body = 'x' * (DebugResponseSnapshot.maxBodyChars + 10);
      final response = DebugResponse(
        statusCode: 200,
        bodyText: body,
        sizeBytes: body.length + 999,
      );

      final snapshot = response.toHistorySnapshot();

      expect(snapshot.truncated, true);
      expect(snapshot.bodyText.length, DebugResponseSnapshot.maxBodyChars);
      expect(snapshot.bodyText, body.substring(0, DebugResponseSnapshot.maxBodyChars));
      expect(snapshot.sizeBytes, body.length + 999, reason: '真实大小不受截断影响');
      expect(snapshot.statusCode, 200);
    });

    test('未超过上限 → 不截断、truncated 为 false', () {
      final response = DebugResponse(statusCode: 200, bodyText: 'small body');
      final snapshot = response.toHistorySnapshot();
      expect(snapshot.truncated, false);
      expect(snapshot.bodyText, 'small body');
    });
  });

  group('旧格式 store 兼容', () {
    test('历史无 responseSnapshot 字段 → 加载无异常且快照为 null', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final payload = {
        'version': 1,
        'collections': <Object>[],
        'environments': <Object>[],
        'rules': <Object>[],
        'history': [
          {
            'id': 'h1',
            'tsMs': 1,
            'request': {
              'id': 'r1',
              'name': '旧请求',
              'method': 'GET',
              'url': 'https://legacy.example/',
              'headers': <Object>[],
              'query': <Object>[],
              'body': '',
              'bodyKind': 'none',
              'cookies': <Object>[],
            },
            'responseSummary': {'statusCode': 200, 'durationMs': 3, 'sizeBytes': 4},
          },
        ],
      };
      await _storeFile(dir).writeAsString(_jsonEncode(payload));

      final store = _storeFor(dir);
      await store.load();

      expect(store.history, hasLength(1));
      expect(store.history.single.responseSnapshot, isNull);
      expect(store.history.single.responseSummary.statusCode, 200);
    });

    test('快照字段损坏 → 条目主体保留、快照降级为 null（不牵连整条）', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final payload = {
        'version': 1,
        'collections': <Object>[],
        'environments': <Object>[],
        'rules': <Object>[],
        'history': [
          {
            'id': 'h1',
            'tsMs': 1,
            'request': {
              'id': 'r1',
              'name': '请求',
              'method': 'GET',
              'url': 'https://legacy.example/',
              'headers': <Object>[],
              'query': <Object>[],
              'body': '',
              'bodyKind': 'none',
              'cookies': <Object>[],
            },
            'responseSummary': {'statusCode': 200},
            'responseSnapshot': 'not-an-object',
          },
        ],
      };
      await _storeFile(dir).writeAsString(_jsonEncode(payload));

      final store = _storeFor(dir);
      await store.load();

      expect(store.history, hasLength(1));
      expect(store.history.single.responseSnapshot, isNull);
    });
  });

  group('历史有界（快照随淘汰清理）', () {
    test('超过 historyLimit 淘汰最旧且一并清理其快照，落盘重载仍有界', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = _storeFor(dir, historyLimit: 2);
      final facade = _RecordingFacade(store: store, sender: _FakeSender());

      for (var i = 1; i <= 3; i++) {
        appendDebugHistory(
          facade,
          request: _request('r$i', url: 'https://api.example/$i'),
          response: DebugResponse(
            statusCode: 200,
            bodyText: 'body-$i',
            sizeBytes: i,
          ),
        );
      }

      expect(store.history, hasLength(2));
      expect(
        store.history.map((e) => e.request.url).toList(),
        ['https://api.example/3', 'https://api.example/2'],
      );
      expect(
        store.history.map((e) => e.responseSnapshot?.bodyText).toList(),
        ['body-3', 'body-2'],
        reason: '淘汰的条目连同其快照一起清理',
      );

      expect(await store.save(), true);
      final reloaded = _storeFor(dir, historyLimit: 2);
      await reloaded.load();
      expect(reloaded.history, hasLength(2));
      expect(reloaded.history.first.responseSnapshot?.bodyText, 'body-3');
    });
  });

  group('历史快照载入响应查看器（widget）', () {
    testWidgets('点击历史行 → 编辑器响应分段展示快照状态码与 Body', (tester) async {
      final facade = _facade();
      appendDebugHistory(
        facade,
        request: _request('r1'),
        response: const DebugResponse(
          statusCode: 418,
          headers: <String, List<String>>{
            'content-type': <String>['text/plain'],
          },
          bodyText: 'snapshot-body',
          sizeBytes: 13,
          durationMs: 3,
        ),
      );

      await tester.pumpWidget(_host(RequestDebugHistorySection(facade: facade)));
      await tester.pumpAndSettle();

      final entry = facade.store.history.single;
      await tester.tap(find.byKey(Key('request-debug-history-${entry.id}')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('request-editor-response-status')),
        findsOneWidget,
        reason: '历史快照必须载入响应查看器',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('request-editor-response-status')))
            .data,
        '418',
      );
      expect(find.byKey(const Key('response-body-text')), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('response-body-text')))
            .data,
        'snapshot-body',
      );
      expect(tester.takeException(), isNull);
    });
  });
}

/// 本地 JSON 编码（避免为测试文件引入 dart:convert 顶层导入命名冲突）。
String _jsonEncode(Object? value) {
  return const JsonEncoder().convert(value);
}
