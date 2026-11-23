/// 工具执行调度（P2-1）
///
/// 只读工具可并行；写/敏感工具串行。调度只负责“谁先谁后/并发度”，
/// 具体执行由调用方注入，便于单测并发行为。
///
/// 规则：
/// - 并行组要求 **groupKey 互不相同**（同名 action 的 executionId 只按毫秒生成，
///   并行可能撞 id；也让写操作的顺序保持可预测）。
/// - 返回顺序始终与输入索引一致，供模型 tool response 稳定回灌。
class AgentToolScheduler {
  AgentToolScheduler._();

  /// 执行 [count] 个任务。
  ///
  /// [parallelSafe] 标记可并行的任务；[groupKey] 用于同名去重；
  /// [execute] 执行单个任务。
  static Future<List<T>> run<T>({
    required int count,
    required bool Function(int index) parallelSafe,
    required String Function(int index) groupKey,
    required Future<T> Function(int index) execute,
  }) async {
    final results = List<T?>.filled(count, null);
    final parallel = <int>[];
    final sequential = <int>[];
    for (var i = 0; i < count; i++) {
      if (parallelSafe(i)) {
        parallel.add(i);
      } else {
        sequential.add(i);
      }
    }

    final keys = <String>{for (final i in parallel) groupKey(i)};
    if (parallel.isNotEmpty && keys.length == parallel.length) {
      final values = await Future.wait([
        for (final i in parallel) execute(i),
      ]);
      for (var k = 0; k < parallel.length; k++) {
        results[parallel[k]] = values[k];
      }
    } else {
      // 同名任务串行，避免 ActionController executionId 冲突
      for (final i in parallel) {
        results[i] = await execute(i);
      }
    }

    for (final i in sequential) {
      results[i] = await execute(i);
    }

    return <T>[for (var i = 0; i < count; i++) results[i] as T];
  }
}
