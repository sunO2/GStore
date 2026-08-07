import 'package:get/get.dart';
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

/// 数据库事件总线 - 使用 Rx 实现全局响应式
class DatabaseEventBus extends GetxController {
  static DatabaseEventBus get instance => Get.find<DatabaseEventBus>();

  /// 当前事件（响应式）
  final Rx<DatabaseChangeEvent?> _currentEvent = Rx<DatabaseChangeEvent?>(null);

  /// 获取当前事件流
  Rx<DatabaseChangeEvent?> get eventStream => _currentEvent;

  /// 发送数据库变化事件
  void send(DatabaseChangeEvent event) {
    appLog.info('DatabaseEventBus: 发送事件 - ${event.type}');
    _currentEvent.value = event;
  }

  /// 监听特定类型的事件
  void on(DatabaseChangeType type, Function(DatabaseChangeEvent) callback) {
    ever(_currentEvent, (event) {
      if (event?.type == type) {
        callback(event!);
      }
    });
  }

  /// 监听多个类型的事件
  void onTypes(List<DatabaseChangeType> types, Function(DatabaseChangeEvent) callback) {
    ever(_currentEvent, (event) {
      if (event != null && types.contains(event.type)) {
        callback(event);
      }
    });
  }
}
