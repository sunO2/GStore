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

/// 存储身份（`storageIdentity`）与逻辑身份（`sourceIdentity`）解耦的回归。
///
/// 线上事故：指纹只在首个下载过程中才学到，而旧实现用它决定库槽位 → 首次加载
/// 先写 `url:` 库、再读 `fp:` 空库 → 第二次全量下载 + 列表空到下拉刷新。
///
/// 全程 hermetic：无网络、无 FFI、无资源包、无真实文件 IO。

/// 伪造宿主模块句柄：只被 `loadOverride` 原样返回。
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
class _Behavior {
  _Behavior(this.source);

  final FdroidSource source;
  int count = 0;
  List<Map<String, dynamic>> apps = const [];
  Completer<void>? gate;

  int downloadStarts = 0;
  int clearCalls = 0;
}

/// 伪造模块实例：实现 [RustModuleInstance] 的公开接口。
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
      case 'search_apps':
        return _jsonBytes(_behavior.apps);
      case 'get_repo_meta':
        return _jsonBytes({
          'name': _behavior.source.name,
          'resolved_url': _behavior.source.repoUrl,
        });
      case 'clear_apps':
        _behavior.clearCalls++;
        return _jsonBytes({'count': 0});
      default:
        throw UnimplementedError('unexpected module method: $method');
    }
  }

  @override
  Future<void> dispose() async {}

  @override
  String get moduleName => 'repo';
}

/// 测试世界：源行为按 **storageIdentity** 绑定，统计下载/清槽。
class _World {
  _World(this.manager);

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

  Future<_Behavior> addTracked(String id, String url) async {
    final source = FdroidSource(id: id, name: id, repoUrl: url);
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

  RustTask _taskFor(_Behavior behavior) {
    final controller = StreamController<TaskEvent>();
    final taskId = 'task-${behavior.source.id}-${behavior.downloadStarts}';

    void emitTerminal() {
      // 真实 DownloadResult 载荷：`_fingerprintOf` 读 signer_fingerprint，
      // `_logDownloadSummary` 读 total_apps/resolved_url。
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

  group('T1 - 指纹回填不翻槽：首次加载恰好一次下载', () {
    test('首次 searchApps 下载一次并回填指纹；第二次 searchApps 零新增且仍有数据', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final behavior = await world.addTracked('s1', 'https://s1.example/repo');
      behavior.apps = [_app('com.example.one')];
      await world.prepare();

      final first = await manager.searchApps('one');
      expect(first, hasLength(1));
      expect(world.totalDownloads, 1, reason: '首次加载恰好一次下载');
      expect(manager.sources.first.fingerprint, 'AB:CD',
          reason: '指纹已从签名回填');

      final second = await manager.searchApps('one');
      expect(second, hasLength(1), reason: '第二次读仍返回数据');
      expect(world.totalDownloads, 1,
          reason: '指纹发现后不得再触发第二次下载（槽位未翻转）');
    });
  });

  group('T2 - 回填后立即读取：不为空、不新增下载', () {
    test('getStatistics/syncInfoFor/cachedBaseFor 在回填后立即可用', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final behavior = await world.addTracked('s1', 'https://s1.example/repo');
      behavior.apps = [_app('com.example.one')];
      await world.prepare();

      await manager.searchApps('one');

      final stats = await manager.getStatistics();
      expect(stats, hasLength(1));
      expect(stats.single.appCount, 1, reason: '回填后统计不空（症状2回归）');

      final s = manager.sources.first;
      expect(manager.syncInfoFor(s), isNotNull,
          reason: '同步信息按存储身份记账，回填后即可查到');
      expect(manager.cachedBaseFor(s), isNotNull,
          reason: 'resolved_url 同样按存储身份记账');
      expect(world.totalDownloads, 1);
    });
  });

  group('T3 - identityKeyFor 对指纹发现不变', () {
    test('同一源在 copyWith(fingerprint:) 前后身份键相同', () {
      final manager = FdroidRepoManager();
      final s = FdroidSource(
        id: 'official',
        name: 'Official',
        repoUrl: 'https://f-droid.org/repo',
      );
      expect(manager.identityKeyFor(s), 'official');
      expect(
        manager.identityKeyFor(s),
        manager.identityKeyFor(s.copyWith(fingerprint: 'AB:CD')),
        reason: '指纹发现不得改变存储身份键',
      );
    });
  });

  group('T4 - storageIdentity / identityMatches 纯单元', () {
    test('storageIdentity 恒为源 id，且不受指纹影响', () {
      final fresh = FdroidSource(
        id: 'official',
        name: 'Official',
        repoUrl: 'https://f-droid.org/repo',
      );
      expect(rust.FdroidRustRepoManager.storageIdentity(fresh), 'official');
      expect(
        rust.FdroidRustRepoManager.storageIdentity(fresh.copyWith(fingerprint: 'AB:CD')),
        'official',
      );
    });

    test('identityMatches 接受 id / 原始指纹 / 旧 fp: / 旧 url: 形式', () {
      final s = FdroidSource(
        id: 'official',
        name: 'Official',
        repoUrl: 'https://f-droid.org/repo',
        fingerprint: 'AB:CD',
      );
      final noFp = FdroidSource(
        id: 'official',
        name: 'Official',
        repoUrl: 'https://f-droid.org/repo',
      );

      expect(rust.FdroidRustRepoManager.identityMatches(s, 'official'), isTrue);
      expect(rust.FdroidRustRepoManager.identityMatches(s, 'AB:CD'), isTrue);
      expect(rust.FdroidRustRepoManager.identityMatches(s, 'abcd'), isTrue);
      expect(rust.FdroidRustRepoManager.identityMatches(s, 'fp:ABCD'), isTrue);
      expect(rust.FdroidRustRepoManager.identityMatches(s, 'fp:AB:CD'), isTrue);
      expect(
        rust.FdroidRustRepoManager.identityMatches(
            s, 'url:https://f-droid.org/repo'),
        isTrue,
      );
      expect(
        rust.FdroidRustRepoManager.identityMatches(
            noFp, 'url:https://f-droid.org/repo'),
        isTrue,
      );
      expect(rust.FdroidRustRepoManager.identityMatches(noFp, 'official'), isTrue);

      expect(rust.FdroidRustRepoManager.identityMatches(s, 'fp:DEAD'), isFalse);
      expect(
        rust.FdroidRustRepoManager.identityMatches(
            s, 'url:https://other.example/repo'),
        isFalse,
      );
      expect(rust.FdroidRustRepoManager.identityMatches(s, 'nonsense'), isFalse);
      expect(rust.FdroidRustRepoManager.identityMatches(s, ''), isFalse);
      expect(rust.FdroidRustRepoManager.identityMatches(s, null), isFalse);
    });
  });

  group('T5 - 回填窗口内单飞', () {
    test('两个并发读共享同一在途下载，闸门放行后都拿到数据', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final behavior = await world.addTracked('s1', 'https://s1.example/repo');
      behavior.apps = [_app('com.example.x')];
      behavior.gate = Completer<void>();
      await world.prepare();

      final searchFuture = manager.searchApps('a');
      final detailFuture = manager.getAppByPackageName('com.example.x');
      var searchDone = false;
      unawaited(searchFuture.then((_) => searchDone = true));

      await pumpEventQueue();
      expect(world.totalDownloads, 1,
          reason: '并发读共享同一存储身份的在途下载');
      expect(searchDone, isFalse, reason: '搜索必须等待在途下载完成');

      behavior.gate!.complete();
      final searchResults = await searchFuture;
      final detail = await detailFuture;

      expect(world.totalDownloads, 1, reason: '回填后不得新增下载');
      expect(searchResults, hasLength(1));
      expect(detail, isNotNull);
      expect(detail!['packageName'], 'com.example.x');
    });
  });

  group('T6 - updateSource：仅逻辑身份变化才清槽', () {
    test('repoUrl 变化 → clear_apps 调用一次', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final behavior = await world.addTracked('s1', 'https://s1.example/repo');
      await world.prepare();

      await manager.updateSource(
          behavior.source.copyWith(repoUrl: 'https://s1.example/other'));

      expect(behavior.clearCalls, 1,
          reason: '地址变化 = 逻辑身份变化 → 旧库数据必须清空');
    });

    test('仅镜像变化（逻辑身份不变）→ 不 clear_apps', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final behavior = await world.addTracked('s1', 'https://s1.example/repo');
      await world.prepare();

      await manager.updateSource(behavior.source.copyWith(
        mirrors: const [FdroidMirror(url: 'https://mirror.example/repo')],
      ));

      expect(behavior.clearCalls, 0,
          reason: '同一身份的配置改动不得清库');
    });

    test('指纹仅写法变化（逻辑身份不变）→ 不 clear_apps', () async {
      final manager = FdroidRepoManager();
      final world = _World(manager);
      final source = FdroidSource(
        id: 's1',
        name: 's1',
        repoUrl: 'https://s1.example/repo',
        fingerprint: 'AB:CD',
      );
      await manager.addSource(source);
      final behavior = world.track(source);
      await world.prepare();

      await manager.updateSource(source.copyWith(fingerprint: 'ab:cd'));

      expect(behavior.clearCalls, 0,
          reason: '归一化后指纹一致 = 逻辑身份一致 → 不清库');
    });
  });
}
