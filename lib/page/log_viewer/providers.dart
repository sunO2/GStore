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

/// 全局日志流（订阅 LogManager 的 RxList 变更）。
///
/// LogManager 仍由全局 GetX 服务持有（渐进迁移：页面层已切 Riverpod，
/// 底层服务暂不动）。GetX `RxList.stream` 是 broadcast 流——只在写入新日志时
/// 推送、不会向新订阅者重放当前已有内容。若直接暴露该 stream，首次进入页面时
/// 拿不到已存在的日志（`StreamProvider` 停在 loading，列表为空）。
///
/// 因此这里包一层种子流：订阅建立后先发送一次当前日志快照，再透传后续变更。
final logEntriesStreamProvider = StreamProvider<List<LogEntry>>((ref) {
  return _logSnapshotStream();
});

Stream<List<LogEntry>> _logSnapshotStream() async* {
  yield List.unmodifiable(LogManager.instance.logs);
  yield* LogManager.instance.logs.stream;
}

/// 按当前筛选级别过滤日志（组合 logs 流 + 筛选状态）。
final filteredLogsProvider = Provider<List<LogEntry>>((ref) {
  final logs = ref.watch(logEntriesStreamProvider).value ?? const [];
  final level = ref.watch(logViewerFilterProvider);
  if (level == LogLevel.all) return logs;
  return logs.where((log) => log.level == level).toList();
});
