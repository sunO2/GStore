import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/lazy_download_service.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// 构造最小 [DownloadTask]；[source] 用于区分实现（dart / rust）。
DownloadTask _task(
  int id, {
  String source = 'x',
  DownloadStatusEnum status = DownloadStatusEnum.queued,
}) {
  return DownloadTask(
    id: id,
    appId: 'app$id',
    appName: source,
    version: '1',
    fileName: 'file$id',
    url: 'https://example.com/file$id',
    filePath: '/tmp/file$id',
    total: 100,
    received: 0,
    status: status,
    speedBps: 0,
    etaSec: null,
    error: null,
    segments: null,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

/// 记录调用次数、可手动推事件的假下载服务（无 FFI / 无网络）。
class _FakeDownloadService implements IDownloadService {
  _FakeDownloadService(this.tag);

  final String tag;

  int downloadCalls = 0;
  int downloadWithContextCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int cancelCalls = 0;
  int retryCalls = 0;
  int restartCalls = 0;
  int removeCalls = 0;
  int getTaskCalls = 0;
  int listTasksCalls = 0;
  int watchCalls = 0;
  int watchAllCalls = 0;

  final StreamController<DownloadTask> allController =
      StreamController<DownloadTask>.broadcast();

  final Map<int, StreamController<DownloadTask>> _watchers = {};

  StreamController<DownloadTask> watcherFor(int id) => _watchers.putIfAbsent(
        id,
        () => StreamController<DownloadTask>.broadcast(),
      );

  @override
  Future<DownloadTask> download(
    String appid,
    String appName,
    String version,
    String url,
    String fileName, {
    int? downloadSize,
    bool breakPoint = true,
    String? saveFileName,
    bool forceDownload = false,
    bool installAfterDownload = true,
  }) async {
    downloadCalls++;
    return _task(1, source: tag);
  }

  @override
  Future<DownloadTask> downloadWithContext(
    DownloadRequest request,
    String appid,
    String appName,
    String version,
    String fileName, {
    bool breakPoint = true,
    String? saveFileName,
    bool installAfterDownload = true,
  }) async {
    downloadWithContextCalls++;
    return _task(1, source: tag);
  }

  @override
  Future<void> pause(int id) async {
    pauseCalls++;
  }

  @override
  Future<void> resume(int id) async {
    resumeCalls++;
  }

  @override
  Future<void> cancel(int id) async {
    cancelCalls++;
  }

  @override
  Future<void> retry(int id) async {
    retryCalls++;
  }

  @override
  Future<void> restart(int id) async {
    restartCalls++;
  }

  @override
  Future<void> remove(int id) async {
    removeCalls++;
  }

  @override
  Future<DownloadTask?> getTask(int id) async {
    getTaskCalls++;
    return _task(id, source: tag);
  }

  @override
  Future<List<DownloadTask>> listTasks() async {
    listTasksCalls++;
    return <DownloadTask>[_task(1, source: tag)];
  }

  @override
  Stream<DownloadTask> watch(int id) {
    watchCalls++;
    return watcherFor(id).stream;
  }

  @override
  Stream<DownloadTask> watchAll() {
    watchAllCalls++;
    return allController.stream;
  }
}

/// 捕获 `debugPrint` 输出，测试结束自动还原。
List<String> _captureDebugPrint() {
  final logs = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) logs.add(message);
  };
  addTearDown(() => debugPrint = original);
  return logs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LazyDownloadService 解析', () {
    test('首个变更类调用解析 Rust 且只探测一次，后续继续走 Rust', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async {
          probes++;
          return true;
        },
        rustServiceFactory: () => rust,
      );

      final first = await lazy.download('a', 'n', '1', 'u', 'f.apk');
      expect(probes, 1, reason: '首次 download 应触发一次探测');
      expect(dart.downloadCalls, 0, reason: '内核可用时不应走 Dart');
      expect(rust.downloadCalls, 1);
      expect(first.appName, 'rust');

      await lazy.download('a', 'n', '1', 'u', 'f2.apk');
      expect(probes, 1, reason: '解析结果应缓存，不得再次探测');
      expect(rust.downloadCalls, 2);
    });

    test('探测返回 false 时回退 Dart，且只告警一次', () async {
      final logs = _captureDebugPrint();
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async {
          probes++;
          return false;
        },
        rustServiceFactory: () => rust,
      );

      final task = await lazy.download('a', 'n', '1', 'u', 'f.apk');
      expect(task.appName, 'dart');
      expect(dart.downloadCalls, 1);
      expect(rust.downloadCalls, 0);
      expect(probes, 1);
      expect(
        logs.where((l) => l.contains('LazyDownloadService')).length,
        1,
        reason: '回退只应打印一条告警',
      );

      // 已回退后不再探测
      await lazy.resume(1);
      expect(probes, 1);
      expect(dart.resumeCalls, 1);
    });

    test('探测抛异常时回退 Dart，且只告警一次', () async {
      final logs = _captureDebugPrint();
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async {
          probes++;
          throw StateError('gate down');
        },
        rustServiceFactory: () => rust,
      );

      await lazy.pause(7);
      expect(dart.pauseCalls, 1);
      expect(rust.pauseCalls, 0);
      expect(probes, 1);
      expect(
        logs.where((l) => l.contains('LazyDownloadService')).length,
        1,
        reason: '异常回退同样只应打印一条告警',
      );
    });

    test('hung kernel probe times out and the service stays functional on Dart', () async {
      final logs = _captureDebugPrint();
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final never = Completer<bool>();
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () {
          probes++;
          return never.future; // 永不完成：模拟内核探测挂起
        },
        rustServiceFactory: () => rust,
        resolutionTimeout: const Duration(milliseconds: 50),
      );

      final task = await lazy.download('a', 'n', '1', 'u', 'f.apk');
      expect(task.appName, 'dart', reason: '超时后当前调用应回落到 Dart（不挂起）');
      expect(dart.downloadCalls, 1);
      expect(rust.downloadCalls, 0);
      expect(probes, 1);

      // 冷却期内：服务仍可用，后续变更类调用走 Dart，不再探测、不再挂起。
      await lazy.resume(1);
      expect(dart.resumeCalls, 1);
      expect(rust.resumeCalls, 0);
      expect(probes, 1, reason: '冷却期内不得重复探测');
      expect(
        logs.where((l) => l.contains('LazyDownloadService')).length,
        1,
        reason: '每次解析尝试只应打印一条告警',
      );
    });

    test('超时后可恢复：冷却结束后的调用重新解析并成功切到 Rust', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final never = Completer<bool>();
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () {
          probes++;
          // 首次挂起（超时），之后内核已就绪返回 true。
          return probes == 1 ? never.future : Future<bool>.value(true);
        },
        rustServiceFactory: () => rust,
        resolutionTimeout: const Duration(milliseconds: 20),
        resolutionRetryCooldown: Duration.zero,
      );

      final first = await lazy.download('a', 'n', '1', 'u', 'f.apk');
      expect(first.appName, 'dart', reason: '首次超时，当前调用回落 Dart');
      expect(dart.downloadCalls, 1);
      expect(probes, 1);

      final second = await lazy.download('a', 'n', '1', 'u', 'f2.apk');
      expect(second.appName, 'rust', reason: '冷却后重试成功，应切到 Rust');
      expect(probes, 2);
      expect(rust.downloadCalls, 1);
      expect(dart.downloadCalls, 1, reason: '首次已走 Dart，之后不再走 Dart');

      // 解析已终态：后续调用不再探测。
      await lazy.resume(1);
      expect(probes, 2);
      expect(rust.resumeCalls, 1);
    });

    test('超时重试预算耗尽后永久回落 Dart，每次尝试各一条告警', () async {
      final logs = _captureDebugPrint();
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final never = Completer<bool>();
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () {
          probes++;
          return never.future; // 始终挂起
        },
        rustServiceFactory: () => rust,
        resolutionTimeout: const Duration(milliseconds: 10),
        maxResolutionAttempts: 3,
        resolutionRetryCooldown: Duration.zero,
      );

      await lazy.pause(1); // 尝试 1 → 超时，可恢复
      await lazy.pause(2); // 尝试 2 → 超时，可恢复
      await lazy.pause(3); // 尝试 3 → 超时，预算耗尽，永久回落
      expect(probes, 3);
      expect(dart.pauseCalls, 3);

      // 已终态：不再探测。
      await lazy.pause(4);
      expect(probes, 3, reason: '预算耗尽的超时不再重试');
      expect(dart.pauseCalls, 4);
      expect(rust.pauseCalls, 0);
      expect(
        logs.where((l) => l.contains('LazyDownloadService')).length,
        3,
        reason: '每次尝试一条告警，共 3 条',
      );
    });

    test('超时可恢复期间合并流保持 Dart，重试成功后同一订阅切到 Rust', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final never = Completer<bool>();
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () {
          probes++;
          return probes == 1 ? never.future : Future<bool>.value(true);
        },
        rustServiceFactory: () => rust,
        resolutionTimeout: const Duration(milliseconds: 20),
        resolutionRetryCooldown: Duration.zero,
      );

      final received = <DownloadTask>[];
      final sub = lazy.watchAll().listen(received.add);
      await pumpEventQueue();
      expect(probes, 0, reason: '订阅事件流不触发解析');

      // 首次变更类调用 → 超时可恢复，流仍绑定 Dart。
      await lazy.download('a', 'n', '1', 'u', 'f.apk');
      await pumpEventQueue();
      expect(rust.watchAllCalls, 0, reason: '可恢复期间不得换到 Rust 流');

      dart.allController.add(_task(5, source: 'dart'));
      await pumpEventQueue();
      expect(received.map((t) => t.appName), contains('dart'));

      // 冷却后重试成功 → 同一条订阅换到 Rust。
      await lazy.resume(1);
      await pumpEventQueue();
      expect(probes, 2);
      expect(rust.watchAllCalls, 1, reason: '重试成功后应换到 Rust 流');

      rust.allController.add(
        _task(6, source: 'rust', status: DownloadStatusEnum.downloading),
      );
      await pumpEventQueue();
      expect(received.last.appName, 'rust');

      await sub.cancel();
    });

    test('并发首个变更类调用只解析一次', () async {
      final gate = Completer<bool>();
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () {
          probes++;
          return gate.future;
        },
        rustServiceFactory: () => rust,
      );

      // 使用非 1 的 id：假 Dart 实现的 listTasks 常驻 id=1（模拟恢复任务），
      // promotion 会把 id=1 固定归属 Dart；本测试验证的是「未固定 id」的并发
      // 单飞与派发，故避开该 id。
      final f1 = lazy.pause(101);
      final f2 = lazy.cancel(102);
      final f3 = lazy.resume(103);
      await pumpEventQueue();
      expect(probes, 1, reason: '并发调用共享同一次解析');
      expect(rust.pauseCalls, 0, reason: '解析未完成前不得下发');

      gate.complete(true);
      await Future.wait<void>([f1, f2, f3]);
      expect(probes, 1);
      expect(rust.pauseCalls, 1);
      expect(rust.cancelCalls, 1);
      expect(rust.resumeCalls, 1);
      expect(dart.pauseCalls, 0);
      expect(dart.cancelCalls, 0);
      expect(dart.resumeCalls, 0);
    });
  });

  group('LazyDownloadService 只读代理', () {
    test('解析前 getTask/listTasks 代理 Dart 且不触发解析', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async {
          probes++;
          return true;
        },
        rustServiceFactory: () => rust,
      );

      final task = await lazy.getTask(3);
      expect(task?.appName, 'dart');
      final list = await lazy.listTasks();
      expect(list.single.appName, 'dart');
      expect(probes, 0, reason: '只读入口不得触发内核解析');
      expect(dart.getTaskCalls, 1);
      expect(dart.listTasksCalls, 1);
      expect(rust.getTaskCalls, 0);
      expect(rust.listTasksCalls, 0);
    });

    test('解析后 getTask/listTasks 委派 Rust', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => true,
        rustServiceFactory: () => rust,
      );

      // 变更类调用触发解析（promotion）。假 Dart 实现的 listTasks 常驻 id=1
      // （模拟 Floor 恢复任务），promotion 会把它固定归属 Dart——这正是本修复
      // 的核心：恢复任务在 promotion 后仍派发到 Dart。
      await lazy.remove(1);
      expect(dart.removeCalls, 1, reason: '恢复任务 id=1 固定归属 Dart，变异派发到 Dart');
      expect(rust.removeCalls, 0);

      // remove 已清除该 id 的固定归属；未固定 id 仍委派活跃实现 Rust。
      final task = await lazy.getTask(5);
      expect(task?.appName, 'rust');
      final list = await lazy.listTasks();
      expect(list.single.appName, 'rust');
      expect(dart.getTaskCalls, 0);
      expect(dart.listTasksCalls, 1,
          reason: 'promotion 时列举一次 Dart 任务以登记恢复任务归属');
    });

    test('解析后全部变更类方法委派 Rust', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => true,
        rustServiceFactory: () => rust,
      );

      await lazy.download('a', 'n', '1', 'u', 'f.apk');
      await lazy.downloadWithContext(
        DownloadRequest(url: 'https://e/x', savePath: '/tmp/x'),
        'a',
        'n',
        '1',
        'f.apk',
      );
      await lazy.pause(1);
      await lazy.resume(1);
      await lazy.cancel(1);
      await lazy.retry(1);
      await lazy.restart(1);
      await lazy.remove(1);

      expect(rust.downloadCalls, 1);
      expect(rust.downloadWithContextCalls, 1);
      expect(rust.pauseCalls, 1);
      expect(rust.resumeCalls, 1);
      expect(rust.cancelCalls, 1);
      expect(rust.retryCalls, 1);
      expect(rust.restartCalls, 1);
      expect(rust.removeCalls, 1);
      expect(dart.downloadCalls, 0);
      expect(dart.downloadWithContextCalls, 0);
      expect(dart.pauseCalls, 0);
      expect(dart.resumeCalls, 0);
      expect(dart.cancelCalls, 0);
      expect(dart.retryCalls, 0);
      expect(dart.restartCalls, 0);
      expect(dart.removeCalls, 0);
    });
  });

  group('LazyDownloadService 合并流', () {
    test('watchAll 订阅不触发解析，解析后同一订阅投递 Rust 事件', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async {
          probes++;
          return true;
        },
        rustServiceFactory: () => rust,
      );

      final received = <DownloadTask>[];
      final sub = lazy.watchAll().listen(received.add);
      await pumpEventQueue();

      expect(probes, 0, reason: '订阅 watchAll 不得触发解析');
      expect(rust.watchAllCalls, 0);
      expect(dart.watchAllCalls, 1, reason: '订阅后应先用 Dart 流顶着');

      // 首次变更类调用触发解析
      await lazy.download('a', 'n', '1', 'u', 'f.apk');
      await pumpEventQueue();
      expect(probes, 1, reason: '变更类调用触发一次解析');
      expect(rust.watchAllCalls, 1, reason: '解析完成后换到 Rust 流');

      // 同一条订阅现在应收到 Rust 事件
      rust.allController.add(
        _task(42, source: 'rust', status: DownloadStatusEnum.downloading),
      );
      await pumpEventQueue();
      expect(received.map((t) => t.id), contains(42));
      expect(received.every((t) => t.appName == 'rust'), isTrue);

      await sub.cancel();
    });

    test('watch(id) 解析前投递 Dart 事件，解析后投递 Rust 事件', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async {
          probes++;
          return true;
        },
        rustServiceFactory: () => rust,
      );

      final received = <DownloadTask>[];
      final sub = lazy.watch(9).listen(received.add);
      await pumpEventQueue();

      expect(probes, 0);
      dart.watcherFor(9).add(_task(9, source: 'dart'));
      await pumpEventQueue();
      expect(received.single.appName, 'dart');

      await lazy.resume(9);
      await pumpEventQueue();
      expect(probes, 1);

      rust.watcherFor(9).add(
        _task(9, source: 'rust', status: DownloadStatusEnum.downloading),
      );
      await pumpEventQueue();
      expect(received.length, 2);
      expect(received.last.appName, 'rust');

      await sub.cancel();
    });

    test('解析失败回退时合并流继续投递 Dart 事件且只告警一次', () async {
      final logs = _captureDebugPrint();
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => false,
        rustServiceFactory: () => rust,
      );

      final received = <DownloadTask>[];
      final sub = lazy.watchAll().listen(received.add);
      await pumpEventQueue();

      await lazy.pause(1); // 触发解析 → 回退 Dart
      await pumpEventQueue();
      expect(rust.watchAllCalls, 0, reason: '回退后不得订阅 Rust 流');
      expect(logs.where((l) => l.contains('LazyDownloadService')).length, 1);

      dart.allController.add(_task(11, source: 'dart'));
      await pumpEventQueue();
      expect(received.map((t) => t.id), contains(11));

      await sub.cancel();
    });
  });

  // 回归：任务在 Dart 上创建后，惰性路由被 promotion 到 Rust 时，**不得**把该任务
  // 的 watch 订阅换源到 Rust——否则 Dart 任务的终态事件永远丢失，调用方挂到超时。
  // 修正为按创建任务 id「固定归属」：id → 创建它的实现。
  group('LazyDownloadService 按任务固定归属', () {
    test('固定归属：promotion 后 Dart 任务的终态仍经同一条 watch 订阅送达', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final never = Completer<bool>();
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () {
          probes++;
          // 首次挂起（超时）→ download 落在 Dart；之后内核已就绪。
          return probes == 1 ? never.future : Future<bool>.value(true);
        },
        rustServiceFactory: () => rust,
        resolutionTimeout: const Duration(milliseconds: 20),
        resolutionRetryCooldown: Duration.zero,
      );

      // 探测 #1 超时 ⇒ 首个 download 在 Dart 上创建任务 id=1，并固定归属 Dart。
      final task = await lazy.download('a', 'n', '1', 'u', 'f.apk');
      expect(task.appName, 'dart');
      final dartId = task.id!;

      final received = <DownloadTask>[];
      final sub = lazy.watch(dartId).listen(received.add);
      await pumpEventQueue();
      expect(dart.watchCalls, 1, reason: '固定 Dart 任务应直接绑定 Dart 流');
      expect(rust.watchCalls, 0);

      // 冷却后由一次「未固定 id」的变更调用触发成功解析，全局切到 Rust。
      await lazy.pause(999);
      await pumpEventQueue();
      expect(probes, 2, reason: '未固定调用仍会解析内核');
      expect(rust.pauseCalls, 1);

      // 关键意图：固定 Dart 任务的 watch 不得在 promotion 时重绑到 Rust。
      expect(rust.watchCalls, 0,
          reason: 'fixed task must not rebind its watch to Rust on promotion');

      // 推动 Dart 侧终态事件——必须经**同一条**订阅送达。
      dart.watcherFor(dartId).add(
            _task(dartId, source: 'dart', status: DownloadStatusEnum.completed),
          );
      await pumpEventQueue();
      expect(received.length, 1, reason: 'Dart 任务终态必须经原订阅送达（重绑会丢事件）');
      expect(received.single.appName, 'dart');
      expect(received.single.status, DownloadStatusEnum.completed);

      // 固定归属：getTask 仍解析到 Dart，而非 promotion 后的全局活跃实现。
      final fetched = await lazy.getTask(dartId);
      expect(fetched?.appName, 'dart', reason: '固定 id 的 getTask 仍走 Dart');

      await sub.cancel();
    });

    test('promotion 后固定 id 走原实现，未固定 id 走当前活跃实现', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final never = Completer<bool>();
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () {
          probes++;
          return probes == 1 ? never.future : Future<bool>.value(true);
        },
        rustServiceFactory: () => rust,
        resolutionTimeout: const Duration(milliseconds: 20),
        resolutionRetryCooldown: Duration.zero,
      );

      final task = await lazy.download('a', 'n', '1', 'u', 'f.apk');
      final dartId = task.id!;
      await lazy.pause(999); // 触发 promotion，全局切到 Rust

      expect((await lazy.getTask(dartId))?.appName, 'dart',
          reason: '固定 id 仍是创建它的 Dart 实现');
      expect((await lazy.getTask(999))?.appName, 'rust',
          reason: '未固定 id 走当前活跃实现 Rust');
    });

    test('固定 Dart 任务上的变更调用仍触发解析，但派发到 Dart', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final never = Completer<bool>();
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () {
          probes++;
          return probes == 1 ? never.future : Future<bool>.value(true);
        },
        rustServiceFactory: () => rust,
        resolutionTimeout: const Duration(milliseconds: 20),
        resolutionRetryCooldown: Duration.zero,
      );

      final task = await lazy.download('a', 'n', '1', 'u', 'f.apk');
      expect(probes, 1);

      await lazy.pause(task.id!);
      expect(probes, 2, reason: '固定归属不阻止解析内核（promotion 仍会发生）');
      expect(dart.pauseCalls, 1, reason: '变更派发到创建任务的 Dart 实现');
      expect(rust.pauseCalls, 0);
    });

    test('remove 后清除固定归属，后续 getTask 回到活跃实现', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;
      final never = Completer<bool>();
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () {
          probes++;
          return probes == 1 ? never.future : Future<bool>.value(true);
        },
        rustServiceFactory: () => rust,
        resolutionTimeout: const Duration(milliseconds: 20),
        resolutionRetryCooldown: Duration.zero,
      );

      final task = await lazy.download('a', 'n', '1', 'u', 'f.apk');
      final dartId = task.id!;
      await lazy.pause(999); // promotion → Rust

      expect((await lazy.getTask(dartId))?.appName, 'dart');
      await lazy.remove(dartId); // 固定 → 派发 Dart.remove，并清除固定
      expect(dart.removeCalls, 1, reason: 'remove 派发到创建任务的原实现');
      expect((await lazy.getTask(dartId))?.appName, 'rust',
          reason: 'remove 后固定归属被清除，getTask 回到活跃实现');
    });
  });
}
