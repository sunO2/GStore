import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/RustTask.dart';
import 'package:gstore/core/rust/generated/task_bridge.dart' show TaskEvent;

TaskEvent _event(
  String kind, {
  int seq = 1,
  List<int> data = const [],
  String error = '',
  String errorCode = '',
}) =>
    TaskEvent(
      taskId: 'task-1',
      kind: kind,
      seq: seq,
      data: Uint8List.fromList(data),
      error: error,
      errorCode: errorCode,
    );

void main() {
  group('RustTask：事件流 → 进度 + 完成', () {
    test('done 事件解析载荷并完成 Future', () async {
      final controller = StreamController<TaskEvent>();
      final task = RustTask.fromEvents('task-1', controller.stream);
      final progress = <RustTaskProgress>[];
      task.progress.listen(progress.add);

      controller.add(_event('started', seq: 1));
      controller.add(_event('progress', seq: 2, data: utf8.encode('{"phase":"downloading"}')));
      controller.add(_event('done', seq: 3, data: utf8.encode('{"total_apps":42}')));
      await controller.close();

      final result = await task.completion;
      expect(result.outcome, RustTaskOutcome.done);
      expect(result.isOk, isTrue);
      expect(utf8.decode(result.payload), '{"total_apps":42}');

      // started 不透出；progress 一条
      expect(progress, hasLength(1));
      expect(progress.single.kind, 'progress');
      expect(progress.single.json?['phase'], 'downloading');
    });

    test('chunk 事件进进度流（流式片段）', () async {
      final controller = StreamController<TaskEvent>();
      final task = RustTask.fromEvents('task-1', controller.stream);
      final chunks = <String>[];
      task.progress.where((p) => p.kind == 'chunk').listen(
            (p) => chunks.add(utf8.decode(p.data)),
          );

      controller.add(_event('chunk', seq: 1, data: utf8.encode('Hel')));
      controller.add(_event('chunk', seq: 2, data: utf8.encode('lo')));
      controller.add(_event('done', seq: 3));
      await controller.close();
      await task.completion;

      expect(chunks.join(), 'Hello');
    });

    test('error 事件带错误码且完成 Future 不抛异常', () async {
      final controller = StreamController<TaskEvent>();
      final task = RustTask.fromEvents('task-1', controller.stream);

      controller.add(_event('started', seq: 1));
      controller.add(_event('error', seq: 2, error: '下载失败', errorCode: 'IO_ERROR'));
      await controller.close();

      final result = await task.completion;
      expect(result.outcome, RustTaskOutcome.error);
      expect(result.isOk, isFalse);
      expect(result.error, '下载失败');
      expect(result.errorCode, 'IO_ERROR');
    });

    test('cancelled 事件映射为已取消', () async {
      final controller = StreamController<TaskEvent>();
      final task = RustTask.fromEvents('task-1', controller.stream);
      controller.add(_event('cancelled', seq: 1));
      await controller.close();

      final result = await task.completion;
      expect(result.outcome, RustTaskOutcome.cancelled);
    });

    test('乱序/重复 seq 被丢弃（单任务内保证有序）', () async {
      final controller = StreamController<TaskEvent>();
      final task = RustTask.fromEvents('task-1', controller.stream);
      final kinds = <String>[];
      task.progress.listen((p) => kinds.add(p.kind));

      controller.add(_event('progress', seq: 5));
      controller.add(_event('progress', seq: 3)); // 乱序 → 丢
      controller.add(_event('progress', seq: 5)); // 重复 → 丢
      controller.add(_event('progress', seq: 6));
      controller.add(_event('done', seq: 7));
      await controller.close();
      await task.completion;

      expect(kinds, ['progress', 'progress']);
    });

    test('流意外关闭（未见终态）兜底为取消，Future 不会永久悬挂', () async {
      final controller = StreamController<TaskEvent>();
      final task = RustTask.fromEvents('task-1', controller.stream);
      controller.add(_event('started', seq: 1));
      await controller.close();

      final result = await task.completion.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('Future 悬挂未兜底'),
      );
      expect(result.outcome, RustTaskOutcome.cancelled);
    });

    test('完成后再来的事件不影响结果', () async {
      final controller = StreamController<TaskEvent>();
      final task = RustTask.fromEvents('task-1', controller.stream);
      controller.add(_event('done', seq: 1, data: utf8.encode('first')));
      controller.add(_event('done', seq: 2, data: utf8.encode('second')));
      await controller.close();

      final result = await task.completion;
      expect(utf8.decode(result.payload), 'first');
    });
  });
}
