/// 「请求调试」历史分区（plan todo 33）测试。
///
/// 覆盖验收标准：
/// - 记录追加：发送摘要映射进历史（最新在前），完整响应折叠为摘要；
/// - 重发：经门面**真正再次发送**（环境变量替换后的 URL 到达 sender）并追加历史；
/// - 保存到集合：克隆为新请求写入目标集合并落盘；
/// - 删除 / 清空：危险操作必须二次确认，未确认前绝不改动；
/// - 上限淘汰：超出 store 历史上限时最旧被淘汰（历史有界）。
library;

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

/// 假发送器：记录每次发送参数，返回受控响应；**不触碰网络**。
class _FakeSender implements DebugSender {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  DebugResponse response = const DebugResponse(
    statusCode: 200,
    bodyText: 'ok',
    sizeBytes: 2,
  );

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
  }) async {
    calls.add(<String, Object?>{'method': method, 'url': url, 'body': body});
    return response;
  }

  @override
  void close() {}
}

/// 测试门面：真实内存 store（不落盘）+ 假 sender；记录 save 调用。
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

_FakeSender _sender() => _FakeSender();

_RecordingFacade _facade({RequestDebugStore? store, DebugSender? sender}) =>
    _RecordingFacade(
      store: store ?? _memoryStore(),
      sender: sender ?? _sender(),
    );

/// 测试宿主：与生产相同全局通道，使统一底部弹层 / Snackbar 可真实呈现。
Widget _host(RequestDebugHistorySection section) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(body: section),
    );

DebugRequest _request(
  String id, {
  String method = 'GET',
  String url = 'https://api.example/users',
}) =>
    DebugRequest(id: id, name: 'n-$id', method: method, url: url);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('历史追加与摘要', () {
    test('appendDebugHistory 映射摘要并入历史（最新在前）', () {
      final facade = _facade();

      appendDebugHistory(
        facade,
        request: _request('r1', method: 'POST'),
        response: const DebugResponse(
          statusCode: 201,
          durationMs: 42,
          sizeBytes: 10,
        ),
      );
      appendDebugHistory(
        facade,
        request: _request('r2'),
        response: const DebugResponse(statusCode: 200, durationMs: 5),
      );

      expect(facade.store.history, hasLength(2));
      // 最新在前。
      expect(facade.store.history.first.request.id, 'r2');
      final first = facade.store.history.last;
      expect(first.request.method, 'POST');
      expect(first.request.url, 'https://api.example/users');
      expect(first.responseSummary.statusCode, 201);
      expect(first.responseSummary.durationMs, 42);
      expect(first.responseSummary.sizeBytes, 10);
      expect(first.responseSummary.error, isNull);
    });

    test('错误响应折叠为摘要：statusCode 置空、error 保留', () {
      final facade = _facade();
      appendDebugHistory(
        facade,
        request: _request('r1'),
        response: DebugResponse.error('连接失败：boom', durationMs: 7),
      );
      final summary = facade.store.history.single.responseSummary;
      expect(summary.statusCode, isNull);
      expect(summary.error, '连接失败：boom');
      expect(summary.durationMs, 7);
    });

    test('超出上限淘汰最旧（历史有界）', () {
      final facade = _facade(store: _memoryStore(historyLimit: 3));
      for (var i = 1; i <= 5; i++) {
        appendDebugHistory(
          facade,
          request: _request('r$i', url: 'https://api.example/$i'),
          response: const DebugResponse(statusCode: 200),
        );
      }
      expect(facade.store.history, hasLength(3));
      expect(
        facade.store.history.map((e) => e.request.url).toList(),
        ['https://api.example/5', 'https://api.example/4', 'https://api.example/3'],
      );
    });
  });

  group('历史分区渲染', () {
    testWidgets('列表行展示 方法 / URL / 状态 / 耗时 / 时间', (tester) async {
      final facade = _facade();
      appendDebugHistory(
        facade,
        request: _request('r1', method: 'POST', url: 'https://api.example/users'),
        response: const DebugResponse(
          statusCode: 201,
          durationMs: 42,
          sizeBytes: 10,
        ),
      );

      await tester.pumpWidget(_host(RequestDebugHistorySection(facade: facade)));
      await tester.pumpAndSettle();

      expect(find.text('POST'), findsOneWidget);
      expect(find.text('https://api.example/users'), findsOneWidget);
      expect(find.text('201 · 42ms'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空历史渲染空态「暂无历史」', (tester) async {
      final facade = _facade();
      await tester.pumpWidget(_host(RequestDebugHistorySection(facade: facade)));
      await tester.pumpAndSettle();

      expect(find.text('暂无历史'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('重发', () {
    testWidgets('重发经门面真正再次发送（环境替换后 URL 到达 sender）并追加历史',
        (tester) async {
      final sender = _sender();
      final facade = _facade(sender: sender);
      final env = facade.store.addEnvironment(
        name: 'dev',
        vars: <String, String>{'host': 'https://api.example'},
      );
      facade.store.setActiveEnvironment(env.id);
      appendDebugHistory(
        facade,
        request: _request('r1', url: '{{host}}/v1'),
        response: const DebugResponse(statusCode: 200),
      );

      await tester.pumpWidget(_host(RequestDebugHistorySection(facade: facade)));
      await tester.pumpAndSettle();

      final entry = facade.store.history.single;
      await tester.tap(
        find.byKey(Key('request-debug-history-menu-${entry.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('request-debug-history-resend-${entry.id}')),
      );
      await tester.pumpAndSettle();

      // 真正再次发送：sender 收到替换后的 URL。
      expect(sender.calls, hasLength(1));
      expect(sender.calls.single['url'], 'https://api.example/v1');
      expect(sender.calls.single['method'], 'GET');
      // 追加新历史 + 落盘。
      expect(facade.store.history, hasLength(2));
      expect(facade.saveCalls, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('保存到集合', () {
    testWidgets('克隆为新请求写入目标集合并落盘', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      appendDebugHistory(
        facade,
        request: _request('r1', method: 'POST', url: 'https://api.example/login'),
        response: const DebugResponse(statusCode: 200),
      );

      await tester.pumpWidget(_host(RequestDebugHistorySection(facade: facade)));
      await tester.pumpAndSettle();

      final entry = facade.store.history.single;
      await tester.tap(
        find.byKey(Key('request-debug-history-menu-${entry.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('request-debug-history-save-${entry.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('request-debug-history-save-target-${collection.id}')),
      );
      await tester.pumpAndSettle();

      expect(collection.requests, hasLength(1));
      final saved = collection.requests.single;
      expect(saved.url, 'https://api.example/login');
      expect(saved.method, 'POST');
      expect(saved.collectionId, collection.id);
      expect(saved.id, isNot('r1'), reason: '克隆必须换新 id，避免覆盖同名请求');
      expect(facade.saveCalls, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('删除与清空（危险操作二次确认）', () {
    testWidgets('删除需确认：取消不删、确认才删', (tester) async {
      final facade = _facade();
      appendDebugHistory(
        facade,
        request: _request('r1'),
        response: const DebugResponse(statusCode: 200),
      );
      appendDebugHistory(
        facade,
        request: _request('r2'),
        response: const DebugResponse(statusCode: 200),
      );

      await tester.pumpWidget(_host(RequestDebugHistorySection(facade: facade)));
      await tester.pumpAndSettle();

      final target = facade.store.history.first;
      await tester.tap(
        find.byKey(Key('request-debug-history-menu-${target.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('request-debug-history-delete-${target.id}')),
      );
      await tester.pumpAndSettle();

      // 确认弹层已弹出，但尚未删除。
      expect(find.text('删除历史'), findsOneWidget);
      expect(facade.store.history.any((e) => e.id == target.id), isTrue);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        facade.store.history.any((e) => e.id == target.id),
        isTrue,
        reason: '取消确认绝不能删除',
      );

      // 再次发起并确认。
      await tester.tap(
        find.byKey(Key('request-debug-history-menu-${target.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('request-debug-history-delete-${target.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(facade.store.history.any((e) => e.id == target.id), isFalse);
      expect(facade.store.history, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('清空需确认：确认后全部清除', (tester) async {
      final facade = _facade();
      appendDebugHistory(
        facade,
        request: _request('r1'),
        response: const DebugResponse(statusCode: 200),
      );
      appendDebugHistory(
        facade,
        request: _request('r2'),
        response: const DebugResponse(statusCode: 200),
      );

      await tester.pumpWidget(_host(RequestDebugHistorySection(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-debug-history-clear')));
      await tester.pumpAndSettle();
      expect(find.text('清空历史'), findsOneWidget);
      expect(facade.store.history, hasLength(2), reason: '确认前不得清空');

      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();

      expect(facade.store.history, isEmpty);
      expect(find.text('暂无历史'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('载入编辑器', () {
    testWidgets('点击历史行 → 编辑器载入该请求（URL / 方法预填）', (tester) async {
      final facade = _facade();
      appendDebugHistory(
        facade,
        request: _request('r1', method: 'PUT', url: 'https://api.example/thing'),
        response: const DebugResponse(statusCode: 200),
      );

      await tester.pumpWidget(_host(RequestDebugHistorySection(facade: facade)));
      await tester.pumpAndSettle();

      final entry = facade.store.history.single;
      await tester.tap(find.byKey(Key('request-debug-history-${entry.id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('request-editor-url')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('request-editor-url')),
          matching: find.text('https://api.example/thing'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
