import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart' as rust;
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/RustTask.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:gstore/core/rust/generated/task_bridge.dart' show TaskEvent;

/// 读路径「空库补齐」行为回归（修复：空库搜索必须触发下载；已就绪不得重下）。
///
/// 全程 hermetic：无网络、无 FFI、无资源包、无真实文件 IO。
/// - 模块实例经 `FdroidRustRepoManager.debugInstanceFactory` 注入假实例
///   （`appCountIn`/`searchAppsIn` 都经它路由）。
/// - 下载任务经**唯一新增接缝** `FdroidRustRepoManager.debugTaskStarter` 注入：
///   `RustTasks.start` 本身没有任何可注入工厂（仅有 `debugResetBridge`，
///   随后仍走 FFI `TaskBridge.newInstance()`），故必须在任务启动层拦截。
/// - 并发用 [Completer] 闸门驱动，确定性等待，不用 sleep。

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

/// 单个源的"假库"：`get_app_count` 返回 [count]，`search_apps` 返回 [apps]。
///
/// 下载完成时由 [_World] 把 [count] 置为 [apps] 的长度，模拟"下载后库被填充"。
class _SourceBehavior {
  _SourceBehavior(this.source);

  final FdroidSource source;
  int count = 0;
  List<Map<String, dynamic>> apps = const [];
  bool failDownload = false;

  /// 非空时下载完成受此闸门控制（用于确定性并发）。
  Completer<void>? gate;

  int downloadStarts = 0;
  int appCountReads = 0;
}

/// 伪造模块实例：实现 [RustModuleInstance] 的公开接口，按绑定行为作答。
class _FakeInstance implements RustModuleInstance {
  _FakeInstance(this._behavior);

  final _SourceBehavior _behavior;

  @override
  String? instanceIdCache;

  @override
  Future<String> get instanceId async => 'instance-${_behavior.source.id}';

  @override
  Future<Uint8List> callModule(String method, [Uint8List? payload]) async {
    switch (method) {
      case 'get_app_count':
        _behavior.appCountReads++;
        return _jsonBytes({'count': _behavior.count});
      case 'search_apps':
        return _jsonBytes(_behavior.apps);
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

/// 测试世界：管理源行为 + 统计下载次数。
class _World {
  _World(this.manager);

  final FdroidRepoManager manager;
  final List<_SourceBehavior> behaviors = [];
  final Map<String, _SourceBehavior> _byIdentity = {};

  /// 全部源累计触发的下载任务数（跨源）。
  int totalDownloads = 0;

  String _keyOf(FdroidSource source) =>
      rust.FdroidRustRepoManager.storageIdentity(source);

  _SourceBehavior track(FdroidSource source) {
    final behavior = _SourceBehavior(source);
    behaviors.add(behavior);
    _byIdentity[_keyOf(source)] = behavior;
    return behavior;
  }

  Future<_SourceBehavior> addTracked(
    String id,
    String url, {
    int priority = 0,
  }) async {
    final source = FdroidSource(id: id, name: id, repoUrl: url, priority: priority);
    await manager.addSource(source);
    return track(source);
  }

  /// 预绑定假实例（按 [behaviors] 顺序），并安装下载任务接缝。
  ///
  /// 先显式调用 `instanceForSource` 把"哪个行为 → 哪个身份键"确定性对上，
  /// 之后生产路径命中门缓存，不会再请求新实例。
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

  RustTask _taskFor(_SourceBehavior behavior) {
    final controller = StreamController<TaskEvent>();
    final taskId = 'task-${behavior.source.id}-${behavior.downloadStarts}';

    void emitTerminal() {
      if (behavior.failDownload) {
        controller.add(TaskEvent(
          taskId: taskId,
          kind: 'error',
          seq: 1,
          data: Uint8List(0),
          error: 'simulated download failure',
          errorCode: 'SIMULATED',
        ));
      } else {
        // 下载成功 → 该源库被填充（后续 appCountIn 才会 > 0）。
        // 终态载荷对齐真实 DownloadResult（`_fingerprintOf` 读 signer_fingerprint、
        // `_logDownloadSummary` 读 total_apps/resolved_url）——否则回填路径永不触发。
        behavior.count = behavior.apps.length;
        controller.add(TaskEvent(
          taskId: taskId,
          kind: 'done',
          seq: 1,
          data: _jsonBytes({
            'signer_fingerprint': 'AB:CD',
            'total_apps': behavior.apps.length,
            'resolved_url': behavior.source.repoUrl,
          }),
          error: '',
          errorCode: '',
        ));
      }
      controller.close();
    }

    final gate = behavior.gate;
    if (gate != null) {
      unawaited(gate.future.then((_) => emitTerminal()));
    } else {
      scheduleMicrotask(emitTerminal);
    }
    return RustTask.fromEvents(taskId, controller.stream);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bootstrap = ModuleBootstrap.instance;
  final moduleManager = RustModuleManager.instance;

  setUp(() {
    bootstrap.debugReset();
    moduleManager.debugReset();
    rust.FdroidRustRepoManager.debugInstanceFactory = null;
    rust.FdroidRustRepoManager.debugTaskStarter = null;
    rust.FdroidRustRepoManager.setActiveSource(null);
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
    bootstrap.debugReset();
    moduleManager.debugReset();
    rust.FdroidRustRepoManager.debugInstanceFactory = null;
    rust.FdroidRustRepoManager.debugTaskStarter = null;
    rust.FdroidRustRepoManager.setActiveSource(null);
  });

  group('行为1 - 空库 ⇒ 触发下载', () {
    test('searchApps 在 appCount==0 时恰好触发一次 downloadRepositoryTaskFor，再搜索', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final behavior = await world.addTracked('s1', 'https://s1.example/repo');
      behavior.apps = [_app('com.example.one')];
      await world.prepare();

      final results = await manager.searchApps('one');

      expect(behavior.downloadStarts, 1,
          reason: '空库必须触发恰好一次该源下载');
      expect(world.totalDownloads, 1);
      expect(behavior.count, 1, reason: '下载完成后该源库应有 1 个应用');
      expect(results, hasLength(1));
      expect(results.single['packageName'], 'com.example.one');
    });
  });

  group('行为2 - 已就绪 ⇒ 不下载', () {
    test('appCount>0 时 searchApps 不触发任何下载', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final behavior = await world.addTracked('s1', 'https://s1.example/repo');
      behavior.count = 2;
      behavior.apps = [_app('com.example.one'), _app('com.example.two')];
      await world.prepare();

      final results = await manager.searchApps('example');

      expect(world.totalDownloads, 0, reason: '已就绪的源不得重复下载');
      expect(behavior.downloadStarts, 0);
      expect(results, hasLength(2));
    });
  });

  group('行为3 - 单飞', () {
    test('并发 searchApps + getAppByPackageName ⇒ 每身份仅一次下载且都等待它', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final behavior = await world.addTracked('s1', 'https://s1.example/repo');
      behavior.apps = [_app('com.example.x')];
      behavior.gate = Completer<void>();
      await world.prepare();

      final searchFuture = manager.searchApps('a');
      final detailFuture = manager.getAppByPackageName('com.example.x');
      var searchDone = false;
      var detailDone = false;
      unawaited(searchFuture.then((_) => searchDone = true));
      unawaited(detailFuture.then((_) => detailDone = true));

      await pumpEventQueue();
      expect(world.totalDownloads, 1,
          reason: '两个并发读共享同一身份键的在途下载，恰好一次');
      expect(searchDone, isFalse, reason: '搜索必须等待在途下载完成');
      expect(detailDone, isFalse, reason: '精确查询必须等待同一在途下载完成');

      behavior.gate!.complete();
      final searchResults = await searchFuture;
      final detail = await detailFuture;

      expect(world.totalDownloads, 1, reason: '并发等待不新增下载');
      expect(searchResults, hasLength(1));
      expect(detail, isNotNull);
      expect(detail!['packageName'], 'com.example.x');
    });
  });

  group('行为4 - 部分失败', () {
    test('一个源加载失败、另一个有数据 ⇒ 返回成功源结果且不抛', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final failing = await world.addTracked('s1', 'https://s1.example/repo',
          priority: 0);
      failing.failDownload = true;
      final healthy = await world.addTracked('s2', 'https://s2.example/repo',
          priority: 1);
      healthy.count = 1;
      healthy.apps = [_app('com.example.healthy')];
      await world.prepare();

      final results = await manager.searchApps('any');

      expect(results, hasLength(1));
      expect(results.single['packageName'], 'com.example.healthy');
      expect(results.single['sourceId'], 's2');
      expect(world.totalDownloads, 1, reason: '仅失败的源触发下载');
      expect(failing.downloadStarts, 1);
      expect(healthy.downloadStarts, 0, reason: '已就绪的源不下载');
    });
  });

  group('行为5 - 全部失败 ⇒ 抛 StateError', () {
    test('全部零数据且至少一个加载失败 ⇒ searchAppsAcross 抛 StateError', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final failing = await world.addTracked('s1', 'https://s1.example/repo',
          priority: 0);
      failing.failDownload = true;
      final empty = await world.addTracked('s2', 'https://s2.example/repo',
          priority: 1);
      empty.apps = const [];
      await world.prepare();

      await expectLater(
        manager.searchApps('any'),
        throwsA(isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('加载失败'),
        )),
      );
      expect(world.totalDownloads, 2, reason: '两个空源各触发一次下载');
    });

    test('全部零数据但下载未抛错 ⇒ 合法空仓库，返回空列表、不抛', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      await world.addTracked('s1', 'https://s1.example/repo', priority: 0);
      await world.addTracked('s2', 'https://s2.example/repo', priority: 1);
      await world.prepare();

      // Part B 修正：加载**成功**但索引为空 ⇒ 合法空仓库，返回空列表而非抛
      // 「F-Droid 仓库不可用」（旧实现把 0 同时当作"空"与"失败"）。
      final results = await manager.searchApps('any');

      expect(results, isEmpty, reason: '合法空仓库不得被误报为故障');
      expect(world.totalDownloads, 2);
    });
  });

  group('行为6 - loadRepository 与搜索共享在途', () {
    test('搜索触发在途时调用 loadRepository ⇒ 等待同一 Future，仅一次下载', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      // 走 initialize 以获得 _currentSource（loadRepository 前置条件）。
      moduleManager.debugConfigure(readyOverride: () async {});
      await manager.initialize();
      expect(world.totalDownloads, 0, reason: 'initialize 期间零下载');

      final behavior = world.track(FdroidSource.official);
      behavior.apps = [_app('com.example.official')];
      behavior.gate = Completer<void>();
      await world.prepare();

      final searchFuture = manager.searchApps('x');
      await pumpEventQueue();
      expect(world.totalDownloads, 1, reason: '搜索已触发在途下载');

      final loadFuture = manager.loadRepository();
      await pumpEventQueue();
      expect(world.totalDownloads, 1,
          reason: 'loadRepository 必须等待同一在途下载，而非早退/重复下载');

      behavior.gate!.complete();
      await loadFuture;
      final results = await searchFuture;

      expect(world.totalDownloads, 1, reason: '整个过程恰好一次下载');
      expect(results, hasLength(1));
      expect(manager.isLoading, isFalse);
    });
  });

  group('行为7 - initialize 设置活动源且不下载', () {
    test('initialize 后 _ensureInstance 不抛（活动源已设）且零下载', () async {
      final manager = FdroidRepoManager();
      moduleManager.debugConfigure(readyOverride: () async {});
      final world = _World(manager);

      await manager.initialize();

      expect(world.totalDownloads, 0, reason: '启动路径绝不下载');
      expect(manager.currentSource, isNotNull);
      expect(manager.currentSource!.id, 'official');

      final behavior = world.track(FdroidSource.official);
      behavior.count = 7;
      await world.prepare();

      // getAppCount 经 _ensureInstance → 活动源为空会抛 StateError；此处必须正常返回。
      final count = await rust.FdroidRustRepoManager.getAppCount();
      expect(count, 7, reason: '活动源已设置，_ensureInstance 正常解析身份');
      expect(world.totalDownloads, 0, reason: '初始化+读取统计均不触发下载');
    });
  });

  group('行为8 - getStatistics 只读', () {
    test('getStatistics 绝不触发下载，返回该源库计数', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final behavior = await world.addTracked('s1', 'https://s1.example/repo');
      behavior.count = 3;
      await world.prepare();

      final stats = await manager.getStatistics();

      expect(world.totalDownloads, 0, reason: '统计只读，绝不下载');
      expect(behavior.downloadStarts, 0);
      expect(stats, hasLength(1));
      expect(stats.single.appCount, 3);
    });
  });
}
