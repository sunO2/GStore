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

/// PART B 回归：区分「加载成功但索引为空」与「加载失败」。
///
/// 旧缺陷：`_loadOneSource` 用 `0` 同时表示"成功但 0 应用"与"失败"，读路径据此
/// 把**合法空仓库**误报成 `F-Droid 仓库不可用`。新契约：成功（含 0 应用）⇒
/// 返回空列表；仅"确有失败"才抛错。
///
/// 全程 hermetic（无网络/FFI/资源包）：实例经 `debugInstanceFactory`、下载任务经
/// `debugTaskStarter` + `RustTask.fromEvents` 注入。

class _FakeHandle implements ModuleHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List _jsonBytes(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Map<String, dynamic> _app(String packageName) => {
      'package_name': packageName,
      'name': packageName,
      'summary': 'summary of $packageName',
    };

/// 单个源的"假库"：`get_app_count` 返回 [count]，`search_apps` 返回 [apps]。
class _SourceBehavior {
  _SourceBehavior(this.source);

  final FdroidSource source;
  int count = 0;
  List<Map<String, dynamic>> apps = const [];
  bool failDownload = false;

  int downloadStarts = 0;
}

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

class _World {
  _World(this.manager);

  final FdroidRepoManager manager;
  final List<_SourceBehavior> behaviors = [];
  final Map<String, _SourceBehavior> _byIdentity = {};

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

    scheduleMicrotask(emitTerminal);
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

  test('B1 合法空仓库：成功加载 0 应用 ⇒ 返回空列表、不抛', () async {
    final manager = FdroidRepoManager();
    final world = _World(manager);
    await world.addTracked('s1', 'https://s1.example/repo');
    // apps 保持空 → 下载成功但索引 0 应用。
    await world.prepare();

    final results = await manager.searchApps('any');

    expect(results, isEmpty, reason: '合法空仓库不得被误报为「仓库不可用」');
    expect(world.totalDownloads, 1, reason: '空库仍需触发一次补齐下载');
  });

  test('B2 加载失败：仍抛真实错误信息', () async {
    final manager = FdroidRepoManager();
    final world = _World(manager);
    final failing = await world.addTracked('s1', 'https://s1.example/repo');
    failing.failDownload = true;
    await world.prepare();

    await expectLater(
      manager.searchApps('any'),
      throwsA(isA<StateError>().having(
        (StateError e) => e.message,
        'message',
        contains('加载失败'),
      )),
    );
    expect(world.totalDownloads, 1);
  });

  test('B3 混合：空源 + 失败源 ⇒ 仍抛（真故障必须上报）', () async {
    final manager = FdroidRepoManager();
    final world = _World(manager);
    final empty = await world.addTracked('s1', 'https://s1.example/repo',
        priority: 0);
    empty.apps = const [];
    final failing = await world.addTracked('s2', 'https://s2.example/repo',
        priority: 1);
    failing.failDownload = true;
    await world.prepare();

    await expectLater(
      manager.searchApps('any'),
      throwsA(isA<StateError>().having(
        (StateError e) => e.message,
        'message',
        contains('加载失败'),
      )),
    );
    expect(world.totalDownloads, 2);
  });

  test('B4 有数据的源：正常返回结果（回归）', () async {
    final manager = FdroidRepoManager();
    final world = _World(manager);
    final behavior = await world.addTracked('s1', 'https://s1.example/repo');
    behavior.apps = [_app('com.example.one')];
    await world.prepare();

    final results = await manager.searchApps('one');

    expect(results, hasLength(1));
    expect(results.single['packageName'], 'com.example.one');
  });

  test('B5 loadAllEnabled：多源成功路径总数与旧实现一致', () async {
    final manager = FdroidRepoManager();
    final world = _World(manager);
    final a = await world.addTracked('s1', 'https://s1.example/repo',
        priority: 0);
    final b = await world.addTracked('s2', 'https://s2.example/repo',
        priority: 1);
    a.apps = [_app('com.example.a1'), _app('com.example.a2')];
    b.apps = [_app('com.example.b1')];
    await world.prepare();

    final total = await manager.loadAllEnabled();

    expect(total, 3, reason: '求和仍只取 count：2 + 1');
    expect(world.totalDownloads, 2);
  });

  test('B6 loadRepository：成功路径不抛且完成', () async {
    final manager = FdroidRepoManager();
    moduleManager.debugConfigure(readyOverride: () async {});
    final world = _World(manager);
    await manager.initialize();
    expect(world.totalDownloads, 0, reason: 'initialize 零下载');

    final behavior = world.track(FdroidSource.official);
    behavior.apps = [_app('com.example.official')];
    await world.prepare();

    await manager.loadRepository();

    expect(world.totalDownloads, 1);
    expect(manager.isLoading, isFalse);
    expect(manager.loadingProgress, 1.0);
  });
}
