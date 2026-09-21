import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/progress/task_progress.dart';

/// 经 [TaskProgressHub.debugConfigure] 注入的调度记录。
///
/// 测试**从不等待真实定时器**：只把 (duration, callback) 捕获下来，需要时手动
/// 触发 callback。
class _Scheduled {
  _Scheduled(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
}

/// 从快照列表中取某 id 的条目。
TaskProgressState? _state(List<TaskProgressState> list, String id) {
  for (final state in list) {
    if (state.id == id) return state;
  }
  return null;
}

void main() {
  late TaskProgressHub hub;
  late List<_Scheduled> pending;

  setUp(() {
    hub = TaskProgressHub.instance;
    hub.debugReset();
    pending = <_Scheduled>[];
    hub.debugConfigure(
      readyLinger: const Duration(milliseconds: 1500),
      failedLinger: const Duration(milliseconds: 4000),
      schedule: (Duration duration, void Function() callback) {
        pending.add(_Scheduled(duration, callback));
      },
    );
  });

  tearDown(() {
    hub.debugReset();
  });

  test('1. begin 发布 running 条目：id/cardKey/label/generation 正确', () async {
    final events = <List<TaskProgressState>>[];
    final sub = hub.states.listen(events.add);
    await pumpEventQueue();
    expect(events, hasLength(1));
    expect(events.first, isEmpty);

    final ticket = hub.begin(id: 'module:repo', label: '仓库模块');
    await pumpEventQueue();

    expect(events, hasLength(2));
    final snapshot = events.last;
    expect(snapshot, hasLength(1));
    final state = snapshot.single;
    expect(state.id, 'module:repo');
    expect(state.cardKey, 'module:repo');
    expect(state.phase, TaskPhase.running);
    expect(state.label, '仓库模块');
    expect(state.generation, ticket.generation);
    expect(ticket.id, 'module:repo');
    await sub.cancel();
  });

  test('2. groupKey 覆盖 cardKey；null 时 cardKey == id', () async {
    final events = <List<TaskProgressState>>[];
    final sub = hub.states.listen(events.add);
    await pumpEventQueue();

    hub.begin(id: 'module:repo', label: '仓库模块', groupKey: 'module-group');
    hub.begin(id: 'fdroid-sync', label: '索引同步');
    await pumpEventQueue();

    final snapshot = events.last;
    expect(_state(snapshot, 'module:repo')!.cardKey, 'module-group');
    expect(_state(snapshot, 'fdroid-sync')!.cardKey, 'fdroid-sync');
    await sub.cancel();
  });

  test('3. update 变更 progress/stage/detail/sizeBytes 并发布', () async {
    final events = <List<TaskProgressState>>[];
    final sub = hub.states.listen(events.add);
    await pumpEventQueue();

    final ticket = hub.begin(id: 'fdroid-sync', label: '索引同步');
    ticket.update(
      progress: 0.42,
      stage: '下载索引 42%',
      detail: '约 12.3 MB · 仅需一次',
      sizeBytes: 12897484,
    );
    await pumpEventQueue();

    final state = _state(events.last, 'fdroid-sync')!;
    expect(state.phase, TaskPhase.running);
    expect(state.progress, 0.42);
    expect(state.stage, '下载索引 42%');
    expect(state.detail, '约 12.3 MB · 仅需一次');
    expect(state.sizeBytes, 12897484);
    await sub.cancel();
  });

  test('4. ready → phase ready 且保留 progress；停留回调后条目被移除', () async {
    final events = <List<TaskProgressState>>[];
    final sub = hub.states.listen(events.add);
    await pumpEventQueue();

    final ticket = hub.begin(id: 'module:repo', label: '仓库模块');
    ticket.update(progress: 0.7);
    ticket.ready();
    await pumpEventQueue();

    final ready = _state(events.last, 'module:repo')!;
    expect(ready.phase, TaskPhase.ready);
    expect(ready.progress, 0.7);

    expect(pending, hasLength(1));
    expect(pending.single.duration, const Duration(milliseconds: 1500));
    pending.single.callback();
    await pumpEventQueue();

    expect(_state(events.last, 'module:repo'), isNull);
    expect(events.last, isEmpty);
    await sub.cancel();
  });

  test('5. fail → phase failed 且捕获 error；停留回调后条目被移除', () async {
    final events = <List<TaskProgressState>>[];
    final sub = hub.states.listen(events.add);
    await pumpEventQueue();

    final ticket = hub.begin(id: 'module:repo', label: '仓库模块');
    final boom = StateError('boom');
    ticket.fail(boom);
    await pumpEventQueue();

    final failed = _state(events.last, 'module:repo')!;
    expect(failed.phase, TaskPhase.failed);
    expect(failed.error, same(boom));

    expect(pending, hasLength(1));
    expect(pending.single.duration, const Duration(milliseconds: 4000));
    pending.single.callback();
    await pumpEventQueue();

    expect(_state(events.last, 'module:repo'), isNull);
    await sub.cancel();
  });

  test('6. 过期票据守卫：首个票据的 update/ready/fail 被忽略', () async {
    final events = <List<TaskProgressState>>[];
    final sub = hub.states.listen(events.add);
    await pumpEventQueue();

    final first = hub.begin(id: 'module:repo', label: '旧');
    final second = hub.begin(id: 'module:repo', label: '新');
    expect(first.generation, isNot(second.generation));

    first.update(progress: 0.9, stage: '旧阶段', detail: '旧详情', sizeBytes: 999);
    first.ready();
    first.fail(StateError('旧失败'));
    await pumpEventQueue();

    final state = _state(events.last, 'module:repo')!;
    expect(state.label, '新');
    expect(state.phase, TaskPhase.running);
    expect(state.progress, isNull);
    expect(state.stage, isNull);
    expect(state.detail, isNull);
    expect(state.sizeBytes, isNull);
    expect(state.error, isNull);
    expect(pending, isEmpty); // 旧票据的 ready 未排定任何停留回调。

    // 新票据仍可正常写入。
    second.update(progress: 0.5);
    await pumpEventQueue();
    expect(_state(events.last, 'module:repo')!.progress, 0.5);
    await sub.cancel();
  });

  test('7. 过期停留守卫：旧回调不得删除同 id 的新条目', () async {
    final events = <List<TaskProgressState>>[];
    final sub = hub.states.listen(events.add);
    await pumpEventQueue();

    final first = hub.begin(id: 'x', label: '第一');
    first.ready();
    expect(pending, hasLength(1));
    final oldCallback = pending.single.callback;

    final second = hub.begin(id: 'x', label: '第二'); // 取代并失效旧令牌。
    expect(second.generation, isNot(first.generation));

    oldCallback(); // 触发旧停留回调。
    await pumpEventQueue();

    final state = _state(events.last, 'x')!;
    expect(state.phase, TaskPhase.running);
    expect(state.label, '第二');
    await sub.cancel();
  });

  test('8. clear 立即移除，并阻止待触发停留误删/复活', () async {
    final events = <List<TaskProgressState>>[];
    final sub = hub.states.listen(events.add);
    await pumpEventQueue();

    final first = hub.begin(id: 'x', label: '第一');
    first.ready();
    expect(pending, hasLength(1));
    final oldCallback = pending.single.callback;

    hub.clear('x');
    await pumpEventQueue();
    expect(_state(events.last, 'x'), isNull);

    oldCallback();
    await pumpEventQueue();
    expect(_state(events.last, 'x'), isNull); // 不会复活。

    hub.begin(id: 'x', label: '第二');
    oldCallback(); // 旧回调仍应空转，不得删除新条目。
    await pumpEventQueue();
    expect(_state(events.last, 'x')!.label, '第二');
    await sub.cancel();
  });

  test('9. 快照即订阅：首事件为当前快照，订阅后立即变更不丢', () async {
    final ticket = hub.begin(id: 'pre', label: '预置');
    ticket.update(progress: 0.3);

    final events = <List<TaskProgressState>>[];
    final sub = hub.states.listen(events.add);
    // 订阅后立刻（同一同步窗口内）再变更：快照与变更都不得丢失。
    final later = hub.begin(id: 'post', label: '订阅后');
    later.update(progress: 0.8);
    await pumpEventQueue();

    expect(events, isNotEmpty);
    final first = events.first;
    expect(first, hasLength(1));
    expect(first.single.id, 'pre');
    expect(first.single.progress, 0.3);

    final last = events.last;
    expect(_state(last, 'pre'), isNotNull);
    final post = _state(last, 'post')!;
    expect(post.progress, 0.8);
    await sub.cancel();
  });

  test('10. watch(id)：首事件 + 后续更新；移除后不再发事件，再次 begin 恢复', () async {
    final watched = <TaskProgressState>[];
    final sub = hub.watch('x').listen(watched.add);
    await pumpEventQueue();
    expect(watched, isEmpty); // 订阅时无条目。

    final first = hub.begin(id: 'x', label: '第一');
    await pumpEventQueue();
    expect(watched, hasLength(1));
    expect(watched.single.phase, TaskPhase.running);
    expect(watched.single.label, '第一');

    first.update(progress: 0.25);
    await pumpEventQueue();
    expect(watched.last.progress, 0.25);

    first.ready();
    await pumpEventQueue();
    expect(watched.last.phase, TaskPhase.ready);
    final countAtReady = watched.length;

    // 停留回调移除条目：watch 不发布移除事件、也不关闭。
    pending.single.callback();
    await pumpEventQueue();
    expect(watched, hasLength(countAtReady));

    // 同一 id 再次 begin：同一订阅恢复收到事件。
    hub.begin(id: 'x', label: '第二');
    await pumpEventQueue();
    expect(watched.last.label, '第二');
    await sub.cancel();
  });

  test('10b. watch(id) 订阅已存在条目时给出当前快照', () async {
    final ticket = hub.begin(id: 'y', label: '已有');
    ticket.update(progress: 0.6);

    final watched = <TaskProgressState>[];
    final sub = hub.watch('y').listen(watched.add);
    await pumpEventQueue();

    expect(watched, hasLength(1));
    expect(watched.single.label, '已有');
    expect(watched.single.progress, 0.6);
    await sub.cancel();
  });

  test('11. 两个并发监听者列表一致；已发出列表不被原地修改', () async {
    final a = <List<TaskProgressState>>[];
    final b = <List<TaskProgressState>>[];
    final subA = hub.states.listen(a.add);
    final subB = hub.states.listen(b.add);
    await pumpEventQueue();

    final ticket = hub.begin(id: 'x', label: 'X');
    ticket.update(progress: 0.1);
    await pumpEventQueue();

    expect(a.last.length, b.last.length);
    expect(a.last.single.progress, b.last.single.progress);

    final captured = a.last; // 持有已发出的列表引用。
    expect(captured.single.progress, 0.1);

    ticket.update(progress: 0.9);
    await pumpEventQueue();

    expect(captured.single.progress, 0.1); // 旧列表未被原地修改。
    expect(a.last.single.progress, 0.9);
    expect(b.last.single.progress, 0.9);
    expect(identical(captured, a.last), isFalse);
    await subA.cancel();
    await subB.cancel();
  });
}
