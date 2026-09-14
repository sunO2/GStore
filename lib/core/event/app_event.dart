/// 统一应用事件总线（AppEventBus）
///
/// 目的：把分散在应用里的多条事件流收口到一个 broker，并支持**双向**：
/// - 上行：DB / 模块生命周期 / 配置 / Rust 模块 事件 → 统一 [AppEvent] 流
/// - 下行：标记 [AppEvent.downlink] 的事件 → 注册的下行 sink（→ Rust 宿主 → 模块）
///
/// 设计取舍：**适配而非替换**。现有 DatabaseEventBus / ModuleManager.onChange /
/// ConfigService.onChange 的公开 API 保持不变，仅各自被适配进本总线，
/// 避免大面积改动调用点（详见 app_event_bus_bootstrap.dart）。
library;

import 'dart:async';
import 'dart:convert';

/// 事件来源
enum AppEventSource {
  /// 应用内部（Dart 业务代码）
  dart,

  /// Rust 宿主/模块（上行自 emit_event）
  rust,

  /// 配置变化
  config,

  /// 数据库变化
  database,

  /// 模块上下线
  module,
}

/// 事件类型常量（schema 约定；跨 Dart/Rust 边界时以字符串传输，保持稳定）
class AppEventTypes {
  /// 配置变化：data = {key, value}
  static const String configChanged = 'config.changed';

  /// 数据库变化：data = {type, data}
  static const String dbChanged = 'db.changed';

  /// 模块上下线：data = {module, lifecycle}
  static const String moduleLifecycle = 'module.lifecycle';

  /// Rust 模块事件（上行）：data = {eventType, moduleId, instanceId, data(base64)}
  static const String rustEvent = 'rust.event';

  /// 主题变化（示例：可下行到 Rust 模块）
  static const String themeChanged = 'theme.changed';
}

/// 统一应用事件
class AppEvent {
  /// 事件类型（见 [AppEventTypes]；自定义事件建议 `域.动作` 命名）
  final String type;

  /// 事件来源
  final AppEventSource source;

  /// 事件载荷（可 JSON 序列化；下行时经 JSON 编码跨 ABI）
  final Map<String, dynamic>? data;

  /// 是否允许下发到 Rust 模块（只有跨边界有意义的事件才置 true，避免无谓唤醒）
  final bool downlink;

  /// 事件时间戳
  final DateTime timestamp;

  AppEvent({
    required this.type,
    required this.source,
    this.data,
    this.downlink = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'AppEvent{type: $type, source: ${source.name}, downlink: $downlink, data: $data}';
}

/// 下行 sink：把标记 downlink 的事件推给 Rust（由 RustModuleManager 在初始化后注册）
typedef AppEventDownlinkSink = void Function(AppEvent event);

/// 统一事件总线（单例）
class AppEventBus {
  AppEventBus._();

  static AppEventBus? _instance;
  static AppEventBus get instance => _instance ??= AppEventBus._();

  final StreamController<AppEvent> _controller =
      StreamController<AppEvent>.broadcast();

  /// 全量事件流
  Stream<AppEvent> get stream => _controller.stream;

  AppEventDownlinkSink? _downlinkSink;

  // ===== 防回环 / 去重 / 限流（护栏）=====

  /// 去重窗口：相同 (type + payload) 在该窗口内重复出现 → 丢弃（打断 A→B→A 抖动）
  Duration dedupWindow = const Duration(milliseconds: 16);

  /// 同步分发链最大深度：超过视为回环，直接丢弃（防栈溢出/死循环）
  int maxDispatchDepth = 8;

  final Map<String, DateTime> _recent = {};
  final Map<String, Duration> _typeThrottle = {};
  final Map<String, DateTime> _lastTypeTs = {};
  int _depth = 0;

  /// 护栏丢弃计数（可观测）
  int droppedDuplicate = 0;
  int droppedThrottled = 0;
  int droppedLoop = 0;

  /// 对某类型限流：同类型事件在 [minInterval] 内只放行一次
  void throttleType(String type, Duration minInterval) {
    _typeThrottle[type] = minInterval;
  }

  /// 重置护栏状态（测试用；同时恢复去重窗口默认值）
  void resetGuards() {
    _recent.clear();
    _typeThrottle.clear();
    _lastTypeTs.clear();
    _depth = 0;
    droppedDuplicate = 0;
    droppedThrottled = 0;
    droppedLoop = 0;
    dedupWindow = const Duration(milliseconds: 16);
  }

  /// 注册下行 sink（Rust 初始化完成后调用；null 清除）
  void registerDownlinkSink(AppEventDownlinkSink? sink) {
    _downlinkSink = sink;
  }

  String _fingerprint(AppEvent e) {
    Object? payload;
    try {
      payload = jsonEncode(e.data ?? const {});
    } catch (_) {
      payload = e.data?.toString();
    }
    return '${e.type}|$payload';
  }

  /// 发布事件：过护栏（深度/限流/去重）后广播，再按需下行。
  void publish(AppEvent event) {
    final now = DateTime.now();

    // 1) 同步分发深度：过深视为回环
    if (_depth >= maxDispatchDepth) {
      droppedLoop++;
      return;
    }

    // 2) 类型限流
    final throttle = _typeThrottle[event.type];
    if (throttle != null) {
      final last = _lastTypeTs[event.type];
      if (last != null && now.difference(last) < throttle) {
        droppedThrottled++;
        return;
      }
    }

    // 3) 去重窗口（同 type + payload 短时间重复）
    final fp = _fingerprint(event);
    final lastSame = _recent[fp];
    if (lastSame != null && now.difference(lastSame) < dedupWindow) {
      droppedDuplicate++;
      return;
    }
    _pruneRecent(now);
    _recent[fp] = now;
    _lastTypeTs[event.type] = now;

    // 4) 分发（深度计数覆盖同步下行回调链）
    _depth++;
    try {
      if (!_controller.isClosed) {
        _controller.add(event);
      }
      if (event.downlink) {
        _downlinkSink?.call(event);
      }
    } finally {
      _depth--;
    }
  }

  void _pruneRecent(DateTime now) {
    if (_recent.length <= 256) return;
    _recent.removeWhere((_, ts) => now.difference(ts) > dedupWindow);
  }

  /// 便捷发布
  void emit(
    String type, {
    AppEventSource source = AppEventSource.dart,
    Map<String, dynamic>? data,
    bool downlink = false,
  }) {
    publish(AppEvent(
      type: type,
      source: source,
      data: data,
      downlink: downlink,
    ));
  }

  /// 按类型订阅（返回订阅以便取消）
  StreamSubscription<AppEvent> on(String type, void Function(AppEvent) callback) {
    return stream.where((e) => e.type == type).listen(callback);
  }

  /// 类型流
  Stream<AppEvent> streamOf(String type) =>
      stream.where((e) => e.type == type);

  /// 配置变化流（可选按 key 过滤）
  Stream<AppEvent> configEvents([Iterable<String>? keys]) {
    final s = streamOf(AppEventTypes.configChanged);
    if (keys == null) return s;
    final set = keys.toSet();
    return s.where((e) => set.contains(e.data?['key']));
  }

  /// 释放资源（测试/重置用）
  void dispose() {
    _downlinkSink = null;
    resetGuards();
    if (!_controller.isClosed) _controller.close();
  }
}
