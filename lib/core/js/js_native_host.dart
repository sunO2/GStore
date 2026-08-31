/// 通用 JS→Flutter 能力注册表。
///
/// 脚本侧通过 `host.native.call(name, payload)` 路由到 Dart 侧已注册的
/// [JsNativeHandler]，新增一项原生能力只需两步：
/// 1. JS 侧加一行 `host.native.call('能力名', payload)`；
/// 2. Dart 侧调一次 [JSNativeHost.register]（或 [registerAll] 批量注册）。
///
/// ## 命名语义
/// [JSNativeHost] 覆盖 UI 及未来的平台能力（非仅 UI）：name 采用命名空间
/// 形式（如 `ui.showVersionPicker`、`platform.share`），保持与既有
/// `host.ui.xxx` / `host.env.xxx` 一致的扩展路径，避免未来平台能力
/// 混入 UI 命名空间。本类不依赖 Flutter，可纯 Dart 编译，便于单元测试。
library;

/// 单个 JS→Flutter 原生能力的处理回调。
///
/// - [payload]：JS 经 `host.native.call(name, payload)` 传入的 JSON 可序列化参数；
/// - 返回值：JSON 可序列化值（经引擎桥转回 JS Promise），失败可抛异常由调用方包装。
typedef JsNativeHandler = Future<Object?> Function(
  Map<String, dynamic> payload,
);

/// JS→Flutter 原生能力注册表：按 name 路由到对应 [JsNativeHandler]。
///
/// 线程/隔离语义：本身无状态，仅做查找；同 name 重复 [register] 会覆盖旧实现
/// （可用于热更新能力），[unregister] 移除后 JS 侧调用由调用方兜底报错。
class JSNativeHost {
  /// 已注册能力表（name → handler）
  final Map<String, JsNativeHandler> _handlers = {};

  /// 注册单个能力。
  ///
  /// 三参数形式：`register('ui', 'showVersionPicker', handler)` → key = `'ui.showVersionPicker'`（命名空间）。
  /// 两参数形式：`register('download', handler)` → key = `'download'`（无命名空间）。
  void register(String nameOrNs, [String? method, JsNativeHandler? handler]) {
    if (method != null && handler != null) {
      _handlers['$nameOrNs.$method'] = handler;
    } else if (handler != null) {
      _handlers[nameOrNs] = handler;
    } else {
      _handlers[nameOrNs] = method as JsNativeHandler;
    }
  }

  /// 批量注册能力（逐项覆盖同名旧实现）
  void registerAll(Map<String, JsNativeHandler> handlers) {
    _handlers.addAll(handlers);
  }

  /// 移除指定能力（不存在时静默忽略）
  void unregister(String name) {
    _handlers.remove(name);
  }

  /// 按 name 取 handler，未注册返回 null
  JsNativeHandler? operator [](String name) => _handlers[name];

  /// 是否没有任何已注册能力
  bool get isEmpty => _handlers.isEmpty;

  /// 已注册能力数量
  int get length => _handlers.length;

  /// 全部已注册能力名
  Set<String> get names => _handlers.keys.toSet();
}