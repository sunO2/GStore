import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/logger/LogManager.dart';

/// 日志查看器筛选级别（页面局部状态）。
class LogViewerFilterNotifier extends Notifier<LogLevel> {
  @override
  LogLevel build() => LogLevel.all;

  void set(LogLevel level) => state = level;
}

final logViewerFilterProvider =
    NotifierProvider<LogViewerFilterNotifier, LogLevel>(
  LogViewerFilterNotifier.new,
);

/// 是否自动滚动到最新日志（页面局部状态）。
class AutoScrollNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
}

final autoScrollProvider = NotifierProvider<AutoScrollNotifier, bool>(
  AutoScrollNotifier.new,
);

/// 日志条目快照（订阅 LogManager 的 broadcast 流）。
///
/// 历史教训：StreamProvider + `async*` 种子流（先 yield 快照再 `yield*`
/// logsStream）会把后续变更事件丢弃——Riverpod 将单订阅生成器转 broadcast
/// 订阅后，`yield*` 转发的事件不进入 StreamProvider 的 state，导致页面内
/// 新增日志/清空不实时刷新（重进页面因重新订阅快照才显示）。
///
/// 因此改为 Notifier：build 时先取当前日志快照，再订阅 logsStream，每次
/// 变更同步更新 state——页面实时刷新稳定可靠。
class LogEntriesNotifier extends Notifier<List<LogEntry>> {
  StreamSubscription<List<LogEntry>>? _sub;

  @override
  List<LogEntry> build() {
    // 先取当前快照（避免订阅前已存在的日志丢失）
    final initial = List<LogEntry>.from(LogManager.instance.logs);
    // 订阅后续变更（broadcast：每次写入推送完整列表）
    _sub = LogManager.instance.logsStream.listen((logs) {
      state = List<LogEntry>.from(logs);
    });
    ref.onDispose(() => _sub?.cancel());
    return initial;
  }
}

/// 全局日志快照（实时响应 LogManager 写入/清空）。
final logEntriesProvider =
    NotifierProvider<LogEntriesNotifier, List<LogEntry>>(
  LogEntriesNotifier.new,
);

/// 按当前筛选级别过滤日志（组合日志快照 + 筛选状态）。
final filteredLogsProvider = Provider<List<LogEntry>>((ref) {
  final logs = ref.watch(logEntriesProvider);
  final level = ref.watch(logViewerFilterProvider);
  if (level == LogLevel.all) return logs;
  return logs.where((log) => log.level == level).toList();
});
