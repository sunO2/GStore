import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show TaskBridge;
import 'package:gstore/core/rust/generated/task_bridge.dart' show TaskEvent;

/// 任务终态类型（与宿主 `kind` 对应）
enum RustTaskOutcome { done, error, cancelled }

/// 任务进度通知（`progress` / `chunk` 事件）
class RustTaskProgress {
  const RustTaskProgress({
    required this.kind,
    required this.seq,
    required this.data,
  });

  /// `progress`（阶段/百分比）或 `chunk`（流式片段）
  final String kind;
  final int seq;
  final Uint8List data;

  /// 载荷按 JSON 解析（失败返回 null）
  Map<String, dynamic>? get json {
    try {
      final decoded = jsonDecode(utf8.decode(data));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'RustTaskProgress($kind, seq=$seq, ${data.length}B)';
}

/// 长任务结果
class RustTaskResult {
  const RustTaskResult({
    required this.outcome,
    required this.taskId,
    this.payload = const <int>[],
    this.error = '',
    this.errorCode = '',
  });

  final RustTaskOutcome outcome;
  final String taskId;
  final List<int> payload;
  final String error;
  final String errorCode;

  bool get isOk => outcome == RustTaskOutcome.done;
}

/// 长任务客户端句柄：**进度流 + 完成 Future + 取消**。
///
/// 对应宿主 `task_bridge` 的 Task 模型：
/// - 任务是**本地同步启动、宿主自有线程执行**（不占用 FRB 任务池）
/// - 进度/结果经 `Stream<TaskEvent>` 送达，**天然异步 marshal**，不会重入
/// - 取消是**协作式**：只是请求，模块在检查点退出，可能已产生副作用
///
/// 典型用法：
/// ```dart
/// final task = await RustTasks.start(module: 'repo', instance: id,
///     method: 'download_repo', payload: bytes);
/// task.progress.listen((p) => debugPrint('${p.kind}'));
/// final result = await task.completion;
/// ```
class RustTask {
  RustTask._({
    required this.taskId,
    required this.progress,
    required Future<RustTaskResult> completion,
    required Future<void> Function() cancel,
  })  : _completion = completion,
        _cancel = cancel;

  final String taskId;

  /// 进度通知流（`progress` / `chunk`）；终态事件不进此流
  final Stream<RustTaskProgress> progress;

  final Future<RustTaskResult> _completion;
  final Future<void> Function() _cancel;

  /// 完成（含失败/取消，不抛异常——失败体现在 [RustTaskResult.outcome]）
  Future<RustTaskResult> get completion => _completion;

  /// 请求取消（协作式；不保证立即停止）
  Future<void> cancel() => _cancel();

  /// 把宿主事件流映射为「进度流 + 完成 Future」。
  ///
  /// 抽成静态方法以便**不依赖模块**做单测：直接喂合成事件流即可验证
  /// 终态识别、seq 单调性与错误传播。
  static RustTask fromEvents(String taskId, Stream<TaskEvent> events) {
    final progressController = StreamController<RustTaskProgress>.broadcast();
    final completer = Completer<RustTaskResult>();
    StreamSubscription<TaskEvent>? sub;

    var lastSeq = 0;
    void complete(RustTaskResult result) {
      if (!completer.isCompleted) completer.complete(result);
      if (!progressController.isClosed) progressController.close();
      final s = sub;
      if (s != null) unawaited(s.cancel());
    }

    sub = events.listen(
      (event) {
        // 单任务内 seq 应单调递增；乱序事件直接丢弃（宿主侧不会，但保持防御）
        if (event.seq <= lastSeq) return;
        lastSeq = event.seq;

        switch (event.kind) {
          case 'progress':
          case 'chunk':
            if (!progressController.isClosed) {
              progressController.add(
                RustTaskProgress(
                  kind: event.kind,
                  seq: event.seq,
                  data: event.data,
                ),
              );
            }
          case 'done':
            complete(RustTaskResult(
              outcome: RustTaskOutcome.done,
              taskId: taskId,
              payload: event.data,
            ));
          case 'cancelled':
            complete(RustTaskResult(
              outcome: RustTaskOutcome.cancelled,
              taskId: taskId,
            ));
          case 'error':
            complete(RustTaskResult(
              outcome: RustTaskOutcome.error,
              taskId: taskId,
              error: event.error,
              errorCode: event.errorCode,
            ));
          default:
            break; // started 等仅用于时序，不透出
        }
      },
      onError: (Object e) => complete(RustTaskResult(
        outcome: RustTaskOutcome.error,
        taskId: taskId,
        error: '$e',
      )),
      // 流被宿主关闭而未见终态（异常情况）→ 兜底为取消，避免 Future 永久悬挂
      onDone: () => complete(RustTaskResult(
        outcome: RustTaskOutcome.cancelled,
        taskId: taskId,
      )),
      cancelOnError: true,
    );

    return RustTask._(
      taskId: taskId,
      progress: progressController.stream,
      completion: completer.future,
      cancel: () => RustTasks.cancel(taskId),
    );
  }
}

/// 长任务入口（宿主 `TaskBridge` 的门面）
class RustTasks {
  RustTasks._();

  static TaskBridge? _bridge;

  /// 惰性获取宿主 TaskBridge（RustLib.init 已自动创建实例）
  static Future<TaskBridge> _ensureBridge() async {
    return _bridge ??= await TaskBridge.newInstance();
  }

  /// 启动长任务：**立即返回**句柄（宿主侧同步返回 task_id，工作跑在宿主自有线程）
  static Future<RustTask> start({
    required String module,
    int? instance,
    required String method,
    List<int> payload = const [],
  }) async {
    final bridge = await _ensureBridge();
    final taskId = await bridge.start(
      module: module,
      instance: instance == null ? null : BigInt.from(instance),
      method: method,
      payload: payload,
    );
    final events = bridge.watch(taskId: taskId);
    appLog.debug('RustTasks: 启动任务 $module.$method -> $taskId');
    return RustTask.fromEvents(taskId, events);
  }

  /// 取消任务（协作式）
  static Future<void> cancel(String taskId) async {
    try {
      final bridge = await _ensureBridge();
      await bridge.cancel(taskId: taskId);
    } catch (e) {
      appLog.error('RustTasks: 取消任务失败 $taskId - $e');
    }
  }

  /// 在跑任务数（诊断）
  static Future<int> runningCount() async {
    try {
      final bridge = await _ensureBridge();
      return await bridge.runningCount();
    } catch (_) {
      return 0;
    }
  }

  @visibleForTesting
  static void debugResetBridge() => _bridge = null;
}
