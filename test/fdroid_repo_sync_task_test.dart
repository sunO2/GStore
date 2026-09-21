import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/progress/task_progress.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart' as rust;
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/RustTask.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:gstore/core/rust/generated/task_bridge.dart' show TaskEvent;

/// F-Droid 仓库「下载完成 → 索引同步/解析入库」阶段上报到全局进度卡片的回归。
///
/// 全程 hermetic：无网络、无 FFI、无资源包、无真实文件 IO。
/// - 下载任务经 [rust.FdroidRustRepoManager.debugTaskStarter] 注入合成事件流
///   （`downloading` → `index` 40% → `stored` → `done`/`error`）。
/// - 模块实例经 [rust.FdroidRustRepoManager.debugInstanceFactory] 注入假实例
///   （`appCountIn` 走它路由）。
/// - 全局卡片经 [TaskProgressHub.states] 快照流按顺序断言。
///
/// 关键点：`_loadingProgress` 是**全局**值、本类没有逐源进度状态，因此同步只发
/// **一张**聚合卡片（id=`fdroid-sync`、cardKey=`module:repo`）。

class _Scheduled {
  _Scheduled(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
}

/// 伪造宿主模块句柄：只被 `loadOverride` 原样返回，从不调用其宿主方法。
class _FakeHandle implements ModuleHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Uint8List _jsonBytes(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Map<String, dynamic> _app(String packageName) => {
      'package_name': packageName,
      'name': packageName,
      'summary': 'summary of $packageName',
    };

/// 单个源的"假库"行为。
class _Behavior {
  _Behavior(this.source);

  final FdroidSource source;

  int count = 0;
  List<Map<String, dynamic>> apps = const [];
  bool failDownload = false;
  Completer<void>? gate;

  int downloadStarts = 0;
}

/// 伪造模块实例：实现 [RustModuleInstance] 的公开接口，按绑定行为作答。
class _FakeInstance implements RustModuleInstance {
  _FakeInstance(this._behavior);

  final _Behavior _behavior;

  @override
  String? instanceIdCache;

  @override
  Future<String> get instanceId async => 'instance-${_behavior.source.id}';

  @override
  Future<Uint8List> callModule(String method, [Uint8List? payload]) async {
    switch (method) {
      case 'get_app_count':
        return _jsonBytes({'count': _behavior.count});
      case 'get_repo_meta':
        return _jsonBytes({
          'name': _behavior.source.name,
          'resolved_url': _behavior.source.repoUrl,
        });
      default:
        throw UnimplementedError('unexpected module method: $method');
    }
  }

  @override
  Future<void> dispose() async {}

  @override
  String get moduleName => 'repo';
}

/// 测试世界：绑定源行为、安装两个接缝、统计下载次数。
class _SyncWorld {
  _SyncWorld(this.manager);

  final FdroidRepoManager manager;
  final List<_Behavior> behaviors = [];
  final Map<String, _Behavior> _byIdentity = {};

  int totalDownloads = 0;

  String _keyOf(FdroidSource source) =>
      rust.FdroidRustRepoManager.storageIdentity(source);

  _Behavior track(FdroidSource source) {
    final behavior = _Behavior(source);
    behaviors.add(behavior);
    _byIdentity[_keyOf(source)] = behavior;
    return behavior;
  }

  Future<_Behavior> addTracked(
    String id,
    String url, {
    int priority = 0,
  }) async {
    final source = FdroidSource(id: id, name: id, repoUrl: url, priority: priority);
    await manager.addSource(source);
    return track(source);
  }

  Future<void> prepare() async {
    final queue = behaviors.map((b) => _FakeInstance(b)).toList();
    rust.FdroidRustRepoManager.debugInstanceFactory = (ModuleHandle handle) async {
      if (queue.isEmpty) {
        throw StateError('unexpected extra module instance request');
      }
      return queue.removeAt(0);
    };
    for (final behavior in behaviors) {
      await rust.FdroidRustRepoManager.instanceForSource(behavior.source);
    }
    rust.FdroidRustRepoManager.debugTaskStarter = _startTask;
  }

  Future<RustTask> _startTask(FdroidSource source) async {
    final behavior = _byIdentity[_keyOf(source)];
    if (behavior == null) {
      throw StateError('no behavior bound for download of ${_keyOf(source)}');
    }
    behavior.downloadStarts++;
    totalDownloads++;
    return _taskFor(behavior);
  }

  /// 合成事件序列：downloading → index 40% → stored →（可选 gate）→ done/error。
  RustTask _taskFor(_Behavior behavior) {
    final controller = StreamController<TaskEvent>();
    final taskId = 'task-${behavior.source.id}-${behavior.downloadStarts}';
    var seq = 0;

    void emit(String kind, {Object? json, String error = '', String errorCode = ''}) {
      controller.add(TaskEvent(
        taskId: taskId,
        kind: kind,
        seq: ++seq,
        data: json == null
            ? Uint8List(0)
            : Uint8List.fromList(utf8.encode(jsonEncode(json))),
        error: error,
        errorCode: errorCode,
      ));
    }

    Future<void> tick() => Future<void>.delayed(Duration.zero);

    Future<void> run() async {
      // 先让 _loadOneSource 完成 `await downloadRepositoryTaskFor` 并挂上
      // `task.progress` 监听——否则首个事件会被 broadcast 进度流丢弃。
      await tick();
      emit('progress', json: const {'phase': 'downloading'});
      await tick();
      emit('progress', json: const {'phase': 'index', 'percent': 40});
      await tick();
      emit('progress', json: const {'phase': 'stored', 'total_apps': 1});
      await tick();
      final gate = behavior.gate;
      if (gate != null) await gate.future;
      if (behavior.failDownload) {
        emit('error', error: 'simulated download failure', errorCode: 'SIMULATED');
      } else {
        // 下载成功 → 该源库被填充（后续 appCountIn 才会 > 0）。
        // 终态载荷对齐真实 DownloadResult（signer_fingerprint / total_apps / resolved_url）。
        behavior.count = behavior.apps.length;
        emit('done', json: {
          'signer_fingerprint': 'AB:CD',
          'total_apps': behavior.apps.length,
          'resolved_url': behavior.source.repoUrl,
        });
      }
      await controller.close();
    }

    unawaited(run());
    return RustTask.fromEvents(taskId, controller.stream);
  }
}

/// 从快照流取 `fdroid-sync` 条目的**去重时间线**（stage/progress/phase 任一变化）。
List<TaskProgressState> _syncTimeline(List<List<TaskProgressState>> snapshots) {
  final out = <TaskProgressState>[];
  for (final snapshot in snapshots) {
    TaskProgressState? state;
    for (final s in snapshot) {
      if (s.id == 'fdroid-sync') {
        state = s;
        break;
      }
    }
    if (state == null) continue;
    if (out.isEmpty ||
        out.last.stage != state.stage ||
        out.last.progress != state.progress ||
        out.last.phase != state.phase) {
      out.add(state);
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final hub = TaskProgressHub.instance;
  final bootstrap = ModuleBootstrap.instance;
  final moduleManager = RustModuleManager.instance;
  final pending = <_Scheduled>[];

  setUp(() {
    hub.debugReset();
    bootstrap.debugReset();
    moduleManager.debugReset();
    rust.FdroidRustRepoManager.debugInstanceFactory = null;
    rust.FdroidRustRepoManager.debugTaskStarter = null;
    rust.FdroidRustRepoManager.setActiveSource(null);
    pending.clear();
    // 不排真实定时器：捕获停留回调，测试无需等待。
    hub.debugConfigure(schedule: (Duration duration, void Function() callback) {
      pending.add(_Scheduled(duration, callback));
    });
    bootstrap.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) async =>
          true,
      loadOverride: (String module) async => _FakeHandle(),
      delayOverride: (Duration duration) async {},
    );
  });

  tearDown(() {
    hub.debugReset();
    bootstrap.debugReset();
    moduleManager.debugReset();
    rust.FdroidRustRepoManager.debugInstanceFactory = null;
    rust.FdroidRustRepoManager.debugTaskStarter = null;
    rust.FdroidRustRepoManager.setActiveSource(null);
  });

  test('单源：阶段/进度按顺序上报，含「解析入库」不确定阶段与最终 ready', () async {
    final manager = FdroidRepoManager();
    final world = _SyncWorld(manager);
    final behavior = await world.addTracked('s1', 'https://s1.example/repo');
    behavior.apps = [_app('com.example.one')];
    await world.prepare();

    final snapshots = <List<TaskProgressState>>[];
    final sub = hub.states.listen(snapshots.add);
    await pumpEventQueue();

    final total = await manager.loadAllEnabled();
    await pumpEventQueue();

    expect(total, 1);
    expect(world.totalDownloads, 1);

    final timeline = _syncTimeline(snapshots);
    expect(
      timeline.map((s) => s.stage).toList(),
      ['正在连接', '同步中', '下载索引 40%', '索引已下载', '解析入库…', '已就绪', '已就绪'],
      reason: '阶段必须严格按 连接 → 同步 → 下载索引 → 索引已下载 → 解析入库 → 已就绪 顺序',
    );

    final downloading = timeline.firstWhere((s) => s.stage == '同步中');
    expect(downloading.progress, isNull, reason: 'downloading 事件无字节信息 → 不确定');

    final indexing = timeline.firstWhere((s) => s.stage == '下载索引 40%');
    expect(indexing.progress, closeTo(0.54, 1e-9),
        reason: 'index 40% → 0.3 + 0.6 * 0.4 = 0.54');

    final stored = timeline.firstWhere((s) => s.stage == '索引已下载');
    expect(stored.progress, 0.9, reason: 'stored → 0.9');

    final parsing = timeline.firstWhere((s) => s.stage == '解析入库…');
    expect(parsing.phase, TaskPhase.running);
    expect(parsing.progress, isNull,
        reason: '解析/入库阶段 Rust 不产事件 → 必须是不确定进度（不能停在 90%）');

    final ready = timeline.last;
    expect(ready.stage, '已就绪');
    expect(ready.progress, 1.0);
    expect(ready.phase, TaskPhase.ready, reason: '完成 → ready()');

    // 页面通道保持原样（附加通道不替代它）。
    expect(manager.isLoading, isFalse);
    expect(manager.loadingProgress, 1.0);
    await sub.cancel();
  });

  test('两源并发：始终只有一张聚合卡片（cardKey=module:repo）', () async {
    final manager = FdroidRepoManager();
    final world = _SyncWorld(manager);
    final a = await world.addTracked('s1', 'https://s1.example/repo', priority: 0);
    final b = await world.addTracked('s2', 'https://s2.example/repo', priority: 1);
    a.apps = [_app('com.example.a')];
    b.apps = [_app('com.example.b')];
    a.gate = Completer<void>();
    b.gate = Completer<void>();
    await world.prepare();

    final snapshots = <List<TaskProgressState>>[];
    final sub = hub.states.listen(snapshots.add);
    await pumpEventQueue();

    final future = manager.loadAllEnabled();
    await pumpEventQueue();
    expect(world.totalDownloads, 2, reason: '两个源并发各自触发一次下载');

    a.gate!.complete();
    b.gate!.complete();
    final total = await future;
    await pumpEventQueue();

    expect(total, 2);

    // 任意时刻 id='fdroid-sync' 至多一个条目（Hub 按 id 覆盖，不追加）。
    for (final snapshot in snapshots) {
      expect(
        snapshot.where((s) => s.id == 'fdroid-sync').length,
        lessThanOrEqualTo(1),
        reason: '多源并发不得产生多张卡片',
      );
    }

    final finalSnap = snapshots.last;
    expect(finalSnap, hasLength(1), reason: '全程只有一张卡片');
    expect(finalSnap.single.id, 'fdroid-sync');
    expect(finalSnap.single.cardKey, 'module:repo');
    expect(finalSnap.single.phase, TaskPhase.ready);
    await sub.cancel();
  });

  test('单源失败：卡片终态 failed 且捕获错误', () async {
    final manager = FdroidRepoManager();
    final world = _SyncWorld(manager);
    final behavior = await world.addTracked('s1', 'https://s1.example/repo');
    behavior.failDownload = true;
    await world.prepare();

    final snapshots = <List<TaskProgressState>>[];
    final sub = hub.states.listen(snapshots.add);
    await pumpEventQueue();

    final total = await manager.loadAllEnabled();
    await pumpEventQueue();

    expect(total, 0);
    final state =
        snapshots.last.firstWhere((s) => s.id == 'fdroid-sync');
    expect(state.phase, TaskPhase.failed, reason: '加载失败 → fail()');
    expect(state.error, isNotNull);
    expect(pending, isNotEmpty, reason: '失败终态排定了停留期移除');
    await sub.cancel();
  });
}
