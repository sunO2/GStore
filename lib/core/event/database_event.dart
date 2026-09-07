import 'package:gstore/core/core.dart';

/// 数据库变化事件类型
enum DatabaseChangeType {
  /// 应用添加
  appAdded,
  /// 应用删除
  appDeleted,
  /// 应用更新
  appUpdated,
  /// 批量导入
  batchImport,
  /// 批量删除
  batchDelete,
  /// 全量刷新
  fullRefresh,
}

/// 数据库变化事件
class DatabaseChangeEvent {
  final DatabaseChangeType type;
  final Map<String, dynamic>? data;

  const DatabaseChangeEvent({
    required this.type,
    this.data,
  });

  @override
  String toString() => 'DatabaseChangeEvent(type: $type, data: $data)';
}

/// 数据库事件总线 - broadcast 流全局事件分发
class DatabaseEventBus {
  DatabaseEventBus._();

  static DatabaseEventBus? _instance;

  static DatabaseEventBus get instance => _instance ??= DatabaseEventBus._();

  /// 事件广播流
  final StreamController<DatabaseChangeEvent> _controller =
      StreamController<DatabaseChangeEvent>.broadcast();

  /// 事件流（数据库变化广播，发送后推送给订阅方）
  Stream<DatabaseChangeEvent> get eventStream => _controller.stream;

  /// 发送数据库变化事件
  void send(DatabaseChangeEvent event) {
    appLog.info('DatabaseEventBus: 发送事件 - ${event.type}');
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  /// 监听特定类型的事件（返回订阅，调用方可取消）
  StreamSubscription<DatabaseChangeEvent> on(
    DatabaseChangeType type,
    Function(DatabaseChangeEvent) callback,
  ) {
    return _controller.stream
        .where((e) => e.type == type)
        .listen(callback);
  }

  /// 监听多个类型的事件（返回订阅，调用方可取消）
  StreamSubscription<DatabaseChangeEvent> onTypes(
    List<DatabaseChangeType> types,
    Function(DatabaseChangeEvent) callback,
  ) {
    return _controller.stream
        .where((e) => types.contains(e.type))
        .listen(callback);
  }

  /// 释放资源（测试/重置用）
  void dispose() {
    if (!_controller.isClosed) _controller.close();
  }
}
