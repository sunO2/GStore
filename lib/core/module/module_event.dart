/// 模块事件
library;

/// 模块生命周期状态
enum ModuleLifecycle {
  /// 已注册（上线）
  registered,

  /// 已注销（下线）
  unregistered,
}

/// 模块上下线事件
///
/// 订阅 [ModuleManager.onChange] 可实现热插拔感知：
/// 模块下线后，持有其接口引用的调用方应重新获取或降级处理。
class ModuleEvent {
  /// 模块名
  final String moduleName;

  /// 生命周期状态
  final ModuleLifecycle lifecycle;

  /// 事件时间戳
  final DateTime timestamp;

  ModuleEvent({
    required this.moduleName,
    required this.lifecycle,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'ModuleEvent{module: $moduleName, lifecycle: ${lifecycle.name}}';
}
