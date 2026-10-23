import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/script_ui_request_router.dart';

/// 记录 `UiApi.respond` 调用的假后端（不触碰 FFI）。
class _RecordingBackend implements ScriptUiBackend {
  final List<({String requestId, String payloadJson})> calls =
      <({String requestId, String payloadJson})>[];

  @override
  Future<void> respond({
    required String requestId,
    required String payloadJson,
  }) async {
    calls.add((requestId: requestId, payloadJson: payloadJson));
  }
}

/// 构造 `script.ui_request` 模块事件（Rust serde tag/content 外壳）。
Uint8List _event({
  String? requestId = 'req-1',
  String kind = 'refreshDetail',
  Object? message = '{}',
  bool includeRequestId = true,
}) {
  final payload = <String, Object?>{
    'key': 'js_demo',
    'app_id': 'com.example.app',
    'kind': kind,
    'title': '标题',
    'fields': <Object?>[],
    'message': message is String ? message : jsonEncode(message),
  };
  if (includeRequestId) payload['request_id'] = requestId;
  return Uint8List.fromList(
    utf8.encode(jsonEncode(<String, Object?>{
      'event': ScriptUiRequestRouter.eventType,
      'payload': payload,
    })),
  );
}

Map<String, Object?> _decoded(String payloadJson) =>
    jsonDecode(payloadJson) as Map<String, Object?>;

void main() {
  test('八个 ui.* kind 都路由到对应 handler，并用同一 request_id 回包一次', () async {
    final backend = _RecordingBackend();
    final received = <String, Map<String, dynamic>>{};
    final router = ScriptUiRequestRouter(
      backend: backend,
      handlers: <String, ScriptUiHandler>{
        for (final kind in ScriptUiRequestRouter.uiKinds)
          kind: (payload) async {
            received[kind] = payload;
            return <String, Object?>{'ok': true, 'kind': kind};
          },
      },
    );

    for (var i = 0; i < ScriptUiRequestRouter.uiKinds.length; i++) {
      final kind = ScriptUiRequestRouter.uiKinds[i];
      await router.handle(
        ScriptUiRequestRouter.eventType,
        _event(
            requestId: 'req-$i',
            kind: kind,
            message: <String, Object?>{'i': i}),
      );
    }

    expect(ScriptUiRequestRouter.uiKinds, hasLength(8));
    expect(backend.calls, hasLength(8));
    for (var i = 0; i < ScriptUiRequestRouter.uiKinds.length; i++) {
      final kind = ScriptUiRequestRouter.uiKinds[i];
      expect(received[kind], <String, Object?>{'i': i},
          reason: '$kind 必须收到 message 解码后的 payload');
      expect(backend.calls[i].requestId, 'req-$i',
          reason: '$kind 回包必须使用同一 request_id');
      expect(_decoded(backend.calls[i].payloadJson),
          <String, Object?>{'ok': true, 'kind': kind});
    }
  });

  test('未知 kind → 显式 ui.<kind> 未注册 错误回包', () async {
    final backend = _RecordingBackend();
    final router = ScriptUiRequestRouter(backend: backend);

    await router.handle(
      ScriptUiRequestRouter.eventType,
      _event(requestId: 'req-unknown', kind: 'notAHandler'),
    );

    expect(backend.calls, hasLength(1));
    expect(backend.calls.single.requestId, 'req-unknown');
    expect(_decoded(backend.calls.single.payloadJson), <String, Object?>{
      'ok': false,
      'error': 'ui.notAHandler 未注册',
    });
  });

  test('handler 抛错 → 回 {ok:false,error} 且只回一次', () async {
    final backend = _RecordingBackend();
    final router = ScriptUiRequestRouter(
      backend: backend,
      handlers: <String, ScriptUiHandler>{
        'setBusy': (_) async => throw StateError('boom'),
      },
    );

    await router.handle(
      ScriptUiRequestRouter.eventType,
      _event(requestId: 'req-throw', kind: 'setBusy'),
    );
    // 同一个 request_id 的重复事件不得二次回包。
    await router.handle(
      ScriptUiRequestRouter.eventType,
      _event(requestId: 'req-throw', kind: 'setBusy'),
    );

    expect(backend.calls, hasLength(1), reason: '每个 request_id 只 respond 一次');
    expect(backend.calls.single.requestId, 'req-throw');
    final body = _decoded(backend.calls.single.payloadJson);
    expect(body['ok'], isFalse);
    expect(body['error'], contains('boom'));
  });

  test('缺 request_id → 丢弃、不回包、不抛', () async {
    final backend = _RecordingBackend();
    final router = ScriptUiRequestRouter(backend: backend);

    await router.handle(
      ScriptUiRequestRouter.eventType,
      _event(kind: 'refreshDetail', includeRequestId: false),
    );

    expect(backend.calls, isEmpty);
  });

  test('事件 JSON 畸形 → 丢弃、不回包、不抛', () async {
    final backend = _RecordingBackend();
    final router = ScriptUiRequestRouter(backend: backend);

    await router.handle(
      ScriptUiRequestRouter.eventType,
      Uint8List.fromList(utf8.encode('{not json')),
    );

    expect(backend.calls, isEmpty);
  });

  test('message 不是合法 JSON → 回错误信封（不让脚本挂到超时）', () async {
    final backend = _RecordingBackend();
    final router = ScriptUiRequestRouter(
      backend: backend,
      handlers: <String, ScriptUiHandler>{
        'refreshDetail': (_) async => <String, Object?>{'ok': true},
      },
    );

    await router.handle(
      ScriptUiRequestRouter.eventType,
      _event(requestId: 'req-bad-message', message: '{bad'),
    );

    expect(backend.calls, hasLength(1));
    expect(backend.calls.single.requestId, 'req-bad-message');
    final body = _decoded(backend.calls.single.payloadJson);
    expect(body['ok'], isFalse);
    expect(body['error'], contains('message'));
  });

  test('非 script.ui_request 事件与后端失败都不会抛回事件循环', () async {
    final router = ScriptUiRequestRouter(backend: _ThrowingBackend());
    await router.handle(
      ScriptUiRequestRouter.eventType,
      _event(requestId: 'req-backend-fail', kind: 'setBusy'),
    );

    var ignored = 0;
    final silent = ScriptUiRequestRouter(
      backend: _RecordingBackend(),
      handlers: <String, ScriptUiHandler>{
        'setBusy': (_) async {
          ignored++;
          return null;
        },
      },
    );
    await silent.handle('catalog.changed', _event(kind: 'setBusy'));
    expect(ignored, 0);
  });
}

class _ThrowingBackend implements ScriptUiBackend {
  @override
  Future<void> respond({
    required String requestId,
    required String payloadJson,
  }) async {
    throw StateError('backend down');
  }
}
