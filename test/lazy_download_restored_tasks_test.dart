import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/lazy_download_service.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// 回归：应用重启后从 Floor **恢复**的 Dart 任务（不经过 `download()`），在惰性
/// 路由被 promotion 到 Rust 后必须仍然可见 / 可控 / 可监听——即文档所述
/// "post-restart residual" 必须关闭。
///
/// 同时锁定：无固定归属时 [LazyDownloadService.listTasks] / [watchAll] 必须与旧
/// 实现逐字节同语义（不得引入并集），保证既有 lazy-router 测试不受影响。

/// 构造最小 [DownloadTask]；[source] 区分实现（dart / rust）。
DownloadTask _task(
  int id, {
  String source = 'x',
  DownloadStatusEnum status = DownloadStatusEnum.queued,
}) {
  final now = DateTime.now();
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
    createdAt: now,
    updatedAt: now,
  );
}

/// 假下载服务：任务由调用方显式放入 [tasks]（模拟 Floor / Rust store 的内容），
/// 不以 `download()` 为准。可注入 [throwOnListTasks] 模拟列举失败。
class _FakeDownloadService implements IDownloadService {
  _FakeDownloadService(this.tag);

  final String tag;
  final Map<int, DownloadTask> tasks = <int, DownloadTask>{};
  bool throwOnListTasks = false;

  /// 让 [listTasks] **永不完成**：验证 promotion 前的列举是**有界**的。
  bool hangOnListTasks = false;

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
    final task = _task(1, source: tag);
    tasks[1] = task;
    return task;
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
    final task = _task(1, source: tag);
    tasks[1] = task;
    return task;
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
    tasks.remove(id);
  }

  @override
  Future<DownloadTask?> getTask(int id) async {
    getTaskCalls++;
    return tasks[id];
  }

  @override
  Future<List<DownloadTask>> listTasks() async {
    listTasksCalls++;
    if (hangOnListTasks) {
      // 永不完成（无超时注入的调用方会一直等待）。
      await Completer<List<DownloadTask>>().future;
    }
    if (throwOnListTasks) {
      throw StateError('listTasks boom');
    }
    return tasks.values.toList(growable: false);
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

  group('LazyDownloadService 恢复任务（post-restart residual）', () {
    test('promotion 后 Floor 恢复的 Dart 任务不消失：getTask/watch/listTasks/变更都留在 Dart',
        () async {
      final dart = _FakeDownloadService('dart');
      // 模拟上一会话残留：id=7 只存在于 Dart（从未经过 download()）。
      dart.tasks[7] = _task(7, source: 'dart', status: DownloadStatusEnum.paused);

      final rust = _FakeDownloadService('rust');
      rust.tasks[1] = _task(1, source: 'rust');

      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => true,
        rustServiceFactory: () => rust,
      );

      // 下载页在 promotion 之前就为恢复任务建立了订阅（真实时序）。
      final received = <DownloadTask>[];
      final sub = lazy.watch(7).listen(received.add);
      await pumpEventQueue();
      expect(dart.watchCalls, 1, reason: '未固定时先绑定 Dart 流');
      expect(rust.watchCalls, 0);

      // 未固定 id 的变更调用触发 promotion；promotion 必须登记恢复任务归属。
      await lazy.pause(999);
      expect(dart.pauseCalls, 0, reason: '未固定 id 派发到 promotion 后的活跃实现');
      expect(rust.pauseCalls, 1);

      // getTask(7) 仍取回 Dart 任务（否则 Rust 侧没有该 id → null）。
      final fetched = await lazy.getTask(7);
      expect(fetched?.appName, 'dart',
          reason: '恢复的 Dart 任务固定归属 Dart，不随 promotion 消失');

      // listTasks 必须同时含 Dart 的 7 与 Rust 的 1。
      final list = await lazy.listTasks();
      expect(list.map((t) => t.id), containsAll(<int>[7, 1]));
      expect(list.firstWhere((t) => t.id == 7).appName, 'dart');
      expect(list.firstWhere((t) => t.id == 1).appName, 'rust');

      // 变更类调用必须派发到 Dart（否则 7 在 Rust 侧是 no-op）。
      await lazy.pause(7);
      expect(dart.pauseCalls, 1, reason: '归属 Dart 的 7 必须派发 Dart.pause');
      expect(rust.pauseCalls, 1, reason: '不得把 7 误派发到 Rust');

      // 关键意图：promotion 后**同一条**订阅不得换源到 Rust（换源会永久冻结）。
      expect(rust.watchCalls, 0,
          reason: 'promotion 不得把已固定归属 Dart 的 watch 换源到 Rust');

      dart.watcherFor(7).add(
            _task(7, source: 'dart', status: DownloadStatusEnum.completed),
          );
      await pumpEventQueue();
      expect(received, hasLength(1),
          reason: 'Dart 任务终态必须经原订阅送达（换源会永久冻结）');
      expect(received.single.appName, 'dart');
      expect(received.single.status, DownloadStatusEnum.completed);

      await sub.cancel();
    });

    test('getTask 回退读取：未固定且仅存在于 Dart 的 id 在 promotion 后仍可读', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => true,
        rustServiceFactory: () => rust,
      );

      // promotion 时 Dart 侧暂无任务 → 无固定归属。
      await lazy.pause(1);

      // 竞态 / 列举失败后才出现的 Dart-only 任务。
      dart.tasks[8] = _task(8, source: 'dart');

      final fetched = await lazy.getTask(8);
      expect(fetched?.appName, 'dart', reason: 'Rust 取不到 → 回退只读 Dart');
      expect(rust.getTaskCalls, 1, reason: '先问活跃实现 Rust');
      expect(dart.getTaskCalls, 1, reason: '再回退问一次 Dart');
    });

    test('无固定归属时 listTasks/watchAll 与旧实现逐字节同语义（不引入并集）',
        () async {
      final dart = _FakeDownloadService('dart');
      dart.tasks[5] = _task(5, source: 'dart');
      final rust = _FakeDownloadService('rust');
      rust.tasks[1] = _task(1, source: 'rust');
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => false, // 永久回落 Dart → 永无固定归属
        rustServiceFactory: () => rust,
      );

      // listTasks 只问活跃实现（Dart），不合并 Rust。
      final list = await lazy.listTasks();
      expect(list.map((t) => t.id), <int>[5]);
      expect(dart.listTasksCalls, 1);
      expect(rust.listTasksCalls, 0, reason: '无固定归属时不得合并 Rust 任务');

      // watchAll 保持"先 Dart、解析终态后换源"的原始语义，不订阅 Rust。
      final received = <DownloadTask>[];
      final sub = lazy.watchAll().listen(received.add);
      await pumpEventQueue();
      expect(dart.watchAllCalls, 1);
      expect(rust.watchAllCalls, 0, reason: '无固定归属时保持原始合并流语义');

      dart.allController.add(_task(5, source: 'dart'));
      await pumpEventQueue();
      expect(received.single.id, 5);

      await sub.cancel();
    });

    test('promotion 后仍无固定归属时 listTasks/watchAll 完全走活跃实现（不并集）',
        () async {
      final dart = _FakeDownloadService('dart'); // Dart 侧无任务
      final rust = _FakeDownloadService('rust');
      rust.tasks[1] = _task(1, source: 'rust');
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => true,
        rustServiceFactory: () => rust,
      );

      await lazy.pause(999); // promotion，但 Dart 侧无任务 → 无固定归属
      final dartListCallsAfterPromotion = dart.listTasksCalls;

      final list = await lazy.listTasks();
      expect(list.map((t) => t.id), <int>[1]);
      expect(list.single.appName, 'rust');
      expect(dart.listTasksCalls, dartListCallsAfterPromotion,
          reason: '无固定归属：listTasks 只代理活跃实现，不得再列举 Dart');

      final received = <DownloadTask>[];
      final sub = lazy.watchAll().listen(received.add);
      await pumpEventQueue();
      expect(rust.watchAllCalls, 1);
      expect(dart.watchAllCalls, 0,
          reason: '无固定归属：已解析只需绑 Rust，不得并集 Dart');
      rust.allController.add(
        _task(1, source: 'rust', status: DownloadStatusEnum.downloading),
      );
      await pumpEventQueue();
      expect(received.single.id, 1);
      await sub.cancel();
    });

    test('并集冲突：固定 Dart 的 id 与 Rust 同 id 时归属条目获胜', () async {
      final dart = _FakeDownloadService('dart');
      dart.tasks[7] = _task(7, source: 'dart');
      final rust = _FakeDownloadService('rust');
      rust.tasks[7] = _task(7, source: 'rust');
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => true,
        rustServiceFactory: () => rust,
      );

      await lazy.pause(999); // promotion → 固定 Dart 的 7

      final list = await lazy.listTasks();
      expect(list.where((t) => t.id == 7), hasLength(1), reason: '按 id 去重');
      expect(list.firstWhere((t) => t.id == 7).appName, 'dart',
          reason: '归属 Dart 的条目在冲突时获胜');
      expect((await lazy.getTask(7))?.appName, 'dart');
    });

    test('watchAll 在存在固定归属任务时并集 Dart 与 Rust 事件', () async {
      final dart = _FakeDownloadService('dart');
      dart.tasks[7] = _task(7, source: 'dart');
      final rust = _FakeDownloadService('rust');
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => true,
        rustServiceFactory: () => rust,
      );

      await lazy.pause(999); // promotion → 固定 Dart 的 7

      final received = <DownloadTask>[];
      final sub = lazy.watchAll().listen(received.add);
      await pumpEventQueue();
      expect(dart.watchAllCalls, 1, reason: '已解析且有固定归属：同时绑 Dart');
      expect(rust.watchAllCalls, 1, reason: '已解析且有固定归属：同时绑 Rust');

      dart.allController.add(
        _task(7, source: 'dart', status: DownloadStatusEnum.completed),
      );
      rust.allController.add(
        _task(1, source: 'rust', status: DownloadStatusEnum.downloading),
      );
      await pumpEventQueue();
      expect(received.map((t) => t.appName), containsAll(<String>['dart', 'rust']));
      await sub.cancel();
    });

    test('promotion 后同一 watchAll 订阅并集投递 Dart 与 Rust 事件', () async {
      final dart = _FakeDownloadService('dart');
      dart.tasks[7] = _task(7, source: 'dart');
      final rust = _FakeDownloadService('rust');
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => true,
        rustServiceFactory: () => rust,
      );

      // 订阅先于 promotion（模拟启动期 watcher）。
      final received = <DownloadTask>[];
      final sub = lazy.watchAll().listen(received.add);
      await pumpEventQueue();
      expect(dart.watchAllCalls, 1);
      expect(rust.watchAllCalls, 0);

      await lazy.pause(999); // promotion → pin Dart 的 7 → 保留 Dart 并叠加 Rust
      await pumpEventQueue();
      expect(rust.watchAllCalls, 1, reason: 'promotion 后叠加 Rust 流');

      dart.allController.add(
        _task(7, source: 'dart', status: DownloadStatusEnum.completed),
      );
      rust.allController.add(
        _task(1, source: 'rust', status: DownloadStatusEnum.downloading),
      );
      await pumpEventQueue();
      expect(received.map((t) => t.appName), containsAll(<String>['dart', 'rust']));
      await sub.cancel();
    });

    test('promotion 时列举 Dart 任务抛错不中止 promotion，也不从 _resolve 抛出',
        () async {
      final logs = _captureDebugPrint();
      final dart = _FakeDownloadService('dart');
      dart.throwOnListTasks = true;
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

      await lazy.pause(1); // 不得抛出
      expect(rust.pauseCalls, 1, reason: '列举失败仍必须完成 promotion 并切到 Rust');
      expect(probes, 1);

      // promotion 已终态：列举失败不得毒化 _resolved。
      await lazy.pause(2);
      expect(probes, 1, reason: '已终态不得再次探测');
      expect(rust.pauseCalls, 2);
      expect(dart.pauseCalls, 0);
      expect(
        logs.any((l) =>
            l.contains('LazyDownloadService') && l.contains('列举 Dart 任务失败')),
        isTrue,
        reason: '失败必须被记录（禁止空 catch）',
      );
    });

    test('promotion 时列举 Dart 任务挂起（永不完成）必须先超时收口，绝不阻塞 promotion',
        () async {
      final logs = _captureDebugPrint();
      final dart = _FakeDownloadService('dart');
      dart.hangOnListTasks = true;
      // 未被登记的恢复任务：列举超时后仍必须可经 getTask 的回退读取触达。
      dart.tasks[7] = _task(7, source: 'dart', status: DownloadStatusEnum.paused);
      final rust = _FakeDownloadService('rust');
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => true,
        rustServiceFactory: () => rust,
        resolutionTimeout: const Duration(milliseconds: 20),
      );

      // 有界：挂起的列举不得拖住 promotion（否则所有变更类调用会一起挂住）。
      await lazy.pause(1).timeout(const Duration(seconds: 2));
      expect(rust.pauseCalls, 1, reason: '列举挂起仍必须完成 promotion（有界）');
      expect(
        logs.any((l) =>
            l.contains('LazyDownloadService') && l.contains('列举 Dart 任务失败')),
        isTrue,
        reason: '超时必须被记录（禁止静默）',
      );

      // 兜底：未登记归属的 Dart 任务仍可经 getTask 的回退读取触达。
      expect((await lazy.getTask(7))?.id, 7);
    });
  });
}
