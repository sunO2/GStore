import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/event_bridge.dart' show ModuleEvent;

/// 单个 `ui.*` 请求处理器：入参是脚本 `host.ui.call` 的 payload。
///
/// 与 `JSNativeHost` 的 handler 同形（`Future<Object?> Function(Map)`），
/// 便于详情页把已有的 8 个 UI 实现原样注册进来。
typedef ScriptUiHandler = Future<Object?> Function(
    Map<String, dynamic> payload);

/// `UiApi.respond` 的可注入后端（生产走 FRB，测试不触碰 FFI）。
abstract interface class ScriptUiBackend {
  /// 用同一 `request_id` 唤醒被挂起的 Rust 脚本线程。
  Future<void> respond({
    required String requestId,
    required String payloadJson,
  });
}

/// 生成代码 [rust.UiApi] 的生产实现。
class FrbScriptUiBackend implements ScriptUiBackend {
  Future<rust.UiApi>? _api;

  Future<rust.UiApi> get _instance => _api ??= rust.UiApi.default_();

  @override
  Future<void> respond({
    required String requestId,
    required String payloadJson,
  }) async {
    await (await _instance)
        .respond(requestId: requestId, payloadJson: payloadJson);
  }
}

/// Rust `script.ui_request` 事件 → Dart `ui.*` handler → `UiApi.respond`。
///
/// 事件由 `gstore_host::ui_api` 在既有模块事件桥上以 wire 名
/// `script.ui_request` 发出，body 形如：
/// ```
/// {"event":"script.ui_request","payload":{
///   "key":"js_demo","app_id":"com.x","request_id":"ui-...",
///   "kind":"showVersionPicker","title":"选择版本",
///   "message":"{\"envs\":[...]}","fields":[]}}
/// ```
/// [kind] 是八个 handler 名之一，[message] 是该 handler payload 的 JSON 字符串。
///
/// 职责只有三件：路由、`respond` 一次、绝不把异常抛回事件循环。
/// handler 注册由 UI 层（详情页/下一波）通过 [register] 完成；未注册的 kind
/// 立即回显 `{"ok":false,"error":"ui.<kind> 未注册"}`，不把脚本挂到超时。
class ScriptUiRequestRouter {
  ScriptUiRequestRouter({
    required ScriptUiBackend backend,
    Map<String, ScriptUiHandler> handlers = const <String, ScriptUiHandler>{},
  })  : _backend = backend,
        _handlers = Map<String, ScriptUiHandler>.of(handlers);

  /// Rust 事件 wire 名（`gstore_core::EVT_SCRIPT_UI_REQUEST`）。
  static const String eventType = 'script.ui_request';

  /// Rust `UI_METHODS` 的 Dart 镜像（顺序一致，便于诊断）。
  static const List<String> uiKinds = <String>[
    'showVersionPicker',
    'showBuildHistory',
    'refreshDetail',
    'updateDownloadList',
    'showUAPicker',
    'updateDetail',
    'setBusy',
    'download',
  ];

  static ScriptUiRequestRouter? _singleton;

  /// 生产单例（FRB responder）。handler 由 UI 层注册。
  static ScriptUiRequestRouter get instance =>
      _singleton ??= ScriptUiRequestRouter(backend: FrbScriptUiBackend());

  final ScriptUiBackend _backend;
  final Map<String, ScriptUiHandler> _handlers;

  /// 已响应过的 request_id（结构性保证每个请求只 `respond` 一次）。
  final Set<String> _answered = <String>{};

  StreamSubscription<ModuleEvent>? _moduleEventsSub;

  /// 注册/覆盖一个 kind 的处理器。
  void register(String kind, ScriptUiHandler handler) {
    _handlers[kind] = handler;
  }

  /// 批量注册（逐项覆盖）。
  void registerAll(Map<String, ScriptUiHandler> handlers) {
    _handlers.addAll(handlers);
  }

  /// 移除处理器（不存在时静默忽略）。
  void unregister(String kind) {
    _handlers.remove(kind);
  }

  /// 某个 kind 是否已注册。
  bool isRegistered(String kind) => _handlers.containsKey(kind);

  /// 订阅既有的模块事件广播流（`RustModuleManager.moduleEvents`），
  /// 只处理 [eventType]，其它事件原样流过，不影响既有订阅者。
  ///
  /// 幂等：重复调用只建立一次订阅。
  void attachToModuleEvents(Stream<ModuleEvent> events) {
    if (_moduleEventsSub != null) return;
    _moduleEventsSub = events.listen((event) {
      unawaited(handle(event.eventType, event.data));
    });
  }

  /// 取消模块事件订阅（测试/模块重启用）。
  Future<void> detach() async {
    final sub = _moduleEventsSub;
    _moduleEventsSub = null;
    await sub?.cancel();
  }

  /// 处理一条模块事件。[data] 接受 `ModuleEvent.data`（UTF-8 JSON 字节）、
  /// JSON 字符串，或已解码的 `Map`，方便直接单元测试。
  ///
  /// 非 [eventType] 直接忽略；畸形事件 / 缺 `request_id` 只记日志后丢弃，
  /// 绝不抛回事件循环。
  Future<void> handle(String eventType, Object? data) async {
    if (eventType != ScriptUiRequestRouter.eventType) return;

    final payload = _decodePayload(data);
    if (payload == null) {
      appLog.warning(
          'ScriptUiRequestRouter: 丢弃畸形的 script.ui_request（无法解析 payload）');
      return;
    }

    final rawId = payload['request_id'];
    final requestId = rawId is String ? rawId.trim() : '';
    if (requestId.isEmpty) {
      appLog.warning(
          'ScriptUiRequestRouter: 丢弃缺少 request_id 的 script.ui_request');
      return;
    }

    final rawKind = payload['kind'];
    final kind =
        rawKind is String && rawKind.isNotEmpty ? rawKind : '<unknown>';

    final handler = _handlers[kind];
    if (handler == null) {
      await _respond(requestId, <String, Object?>{
        'ok': false,
        'error': 'ui.$kind 未注册',
      });
      return;
    }

    final args = _decodeMessage(payload['message']);
    if (args == null) {
      await _respond(requestId, <String, Object?>{
        'ok': false,
        'error': 'script.ui_request message 不是合法 JSON 对象',
      });
      return;
    }

    try {
      final result = await handler(args);
      await _respond(requestId, result);
    } catch (error) {
      await _respond(requestId, <String, Object?>{
        'ok': false,
        'error': error.toString(),
      });
    }
  }

  /// 每个 request_id 只真正调用一次后端（map 写入是同步的，即使并发也安全）。
  Future<void> _respond(String requestId, Object? value) async {
    if (!_answered.add(requestId)) {
      appLog.warning('ScriptUiRequestRouter: request_id=$requestId 已响应，忽略重复回包');
      return;
    }
    if (_answered.length > 1024) _answered.clear();
    try {
      await _backend.respond(
        requestId: requestId,
        payloadJson: jsonEncode(value),
      );
    } catch (error) {
      // 未知/过期 id 等后端错误只记录；脚本侧由 Rust 超时兜底。
      appLog.error(
          'ScriptUiRequestRouter: UiApi.respond 失败 request_id=$requestId - $error');
    }
  }

  static Map<String, dynamic>? _decodePayload(Object? data) {
    Object? decoded;
    try {
      if (data is Map) {
        decoded = data;
      } else if (data is Uint8List) {
        decoded = jsonDecode(utf8.decode(data));
      } else if (data is List<int>) {
        decoded = jsonDecode(utf8.decode(data));
      } else if (data is String) {
        decoded = jsonDecode(data);
      } else {
        return null;
      }
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final root = _stringKeyed(decoded);
    final payload = root['payload'];
    // 兼容直接投递 payload（不含 event/content 外壳）。
    return payload is Map ? _stringKeyed(payload) : root;
  }

  static Map<String, dynamic>? _decodeMessage(Object? message) {
    if (message == null) return <String, dynamic>{};
    if (message is Map) return _stringKeyed(message);
    if (message is! String) return null;
    if (message.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(message);
      if (decoded == null) return <String, dynamic>{};
      if (decoded is Map) return _stringKeyed(decoded);
      return null;
    } on FormatException {
      return null;
    }
  }

  static Map<String, dynamic> _stringKeyed(Map<Object?, Object?> raw) {
    final out = <String, dynamic>{};
    for (final entry in raw.entries) {
      out[entry.key.toString()] = entry.value;
    }
    return out;
  }

  /// 测试用：丢弃单例与订阅（避免 handler/订阅跨用例泄漏）。
  @visibleForTesting
  static Future<void> resetForTest() async {
    await _singleton?.detach();
    _singleton = null;
  }
}
