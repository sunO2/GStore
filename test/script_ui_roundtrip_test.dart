import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/script_ui_request_router.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/script/script_ui_handler_registry.dart';

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
  tearDown(ScriptUiHandlerRegistry.instance.resetForTest);

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

  test('无活动详情页 → typed CORE_E_SCRIPT_UI_NO_ACTIVE_DETAIL（不是未注册）', () async {
    ScriptUiHandlerRegistry.instance.resetForTest();
    final backend = _RecordingBackend();
    final router = ScriptUiRequestRouter(backend: backend);
    ScriptUiHandlerRegistry.instance.registerOn(router);

    await router.handle(
      ScriptUiRequestRouter.eventType,
      _event(
          requestId: 'req-no-page',
          kind: 'showUAPicker',
          message: <String, Object?>{'options': <Object?>[]}),
    );

    expect(backend.calls, hasLength(1));
    final body = _decoded(backend.calls.single.payloadJson);
    expect(body['ok'], isFalse);
    expect(body['error'], ScriptUiHandlerRegistry.noActiveDetailCode);
    expect(body['error'], isNot(contains('未注册')));
  });

  test('活动详情页绑定 → showUAPicker 返回真实选择值，且重复注册不叠加 handler', () async {
    ScriptUiHandlerRegistry.instance.resetForTest();
    final backend = _RecordingBackend();
    final router = ScriptUiRequestRouter(backend: backend);
    final callbacks = _FakeDetailCallbacks()..uaResult = 'Chrome';
    final binding = ScriptUiHandlerRegistry.instance.bind(
      callbacks: callbacks,
      appId: () => 'com.example.app',
      channelKey: () => 'js_demo',
    );
    // initialize 幂等：两次注册仍是同样的 8 个 kind，不会叠加回包。
    ScriptUiHandlerRegistry.instance.registerOn(router);
    ScriptUiHandlerRegistry.instance.registerOn(router);

    for (final kind in ScriptUiRequestRouter.uiKinds) {
      expect(router.isRegistered(kind), isTrue, reason: '$kind 必须已注册');
    }

    await router.handle(
      ScriptUiRequestRouter.eventType,
      _event(
        requestId: 'req-active-ua',
        kind: 'showUAPicker',
        message: <String, Object?>{
          'options': <Object?>[
            <String, Object?>{'ua': 'Firefox'},
            <String, Object?>{'ua': 'Chrome'},
          ],
          'current': 'Firefox',
        },
      ),
    );

    expect(backend.calls, hasLength(1), reason: '重复 registerAll 不得造成二次回包');
    expect(jsonDecode(backend.calls.single.payloadJson), 'Chrome');
    expect(callbacks.lastUaOptions, <String>['Firefox', 'Chrome']);
    expect(callbacks.lastUaAppId, 'com.example.app');
    expect(callbacks.lastUaCurrent, 'Firefox');

    await router.handle(
      ScriptUiRequestRouter.eventType,
      _event(
        requestId: 'req-active-refresh',
        kind: 'refreshDetail',
        message: <String, Object?>{'name': 'Demo', 'version': '1.2.3'},
      ),
    );
    expect(callbacks.refreshCalls, hasLength(1));
    expect(callbacks.refreshCalls.single, <String, dynamic>{
      'name': 'Demo',
      'version': '1.2.3',
    });

    ScriptUiHandlerRegistry.instance.unbind(binding);
    expect(ScriptUiHandlerRegistry.instance.hasActivePage, isFalse);
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

/// 最小 DetailCallbacks fake：记录 `ui.*` 真正驱动的参数。
class _FakeDetailCallbacks implements DetailCallbacks {
  String? uaResult;
  List<String>? lastUaOptions;
  String? lastUaAppId;
  String? lastUaCurrent;
  final List<Map<String, dynamic>> refreshCalls = <Map<String, dynamic>>[];

  @override
  Future<String?> showUAPicker({
    required List<String>? uaOptions,
    required String appId,
    String? current,
  }) async {
    lastUaOptions = uaOptions;
    lastUaAppId = appId;
    lastUaCurrent = current;
    return uaResult;
  }

  @override
  Future<void> refreshDetail({
    required Map<String, dynamic> detailData,
  }) async {
    refreshCalls.add(Map<String, dynamic>.from(detailData));
  }

  @override
  Future<void> showVersionPicker({
    required Map<String, dynamic> options,
    required String appId,
  }) async {}

  @override
  Future<void> showBuildHistory({
    required List<Map<String, dynamic>> builds,
    required String appId,
    required String version,
    required String env,
  }) async {}

  @override
  Future<void> updateDetail({required Map<String, dynamic> partial}) async {}

  @override
  Future<void> setActionBusy({required bool visible, String? label}) async {}

  @override
  Future<void> updateDownloadList({
    required List<DownloadInfo> downloads,
  }) async {}

  @override
  void syncDownloadToFB(DownloadInfo download) {}

  @override
  Future<void> startDownload(
    DownloadInfo download, {
    int? downloadSize,
    bool fromScript = false,
  }) async {}

  @override
  void showSuccess(String message, {String? title}) {}

  @override
  void showError(String message, {String? title}) {}

  @override
  Future<bool?> showWarningDialog({
    required String title,
    required String content,
    String? confirmText,
    String? cancelText,
    bool isDangerous = false,
  }) async =>
      null;

  @override
  void startApp(String packageName) {}

  @override
  void openBrowser(String url) {}

  @override
  void openProjectBrowser() {}

  @override
  Future<void> submitAppMetadata() async {}

  @override
  Future<List<String>?> showMoreActionsSheet({
    required String appName,
    required List<String> presetTags,
    required List<String> currentTags,
    required List<DetailAction> actions,
  }) async =>
      null;
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
