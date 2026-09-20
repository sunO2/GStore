import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/download_task_watcher.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/lazy_download_service.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart' show ModuleManager;
import 'package:gstore/core/service/download_notification_service.dart';
import 'package:gstore/core/service/install_manager.dart'
    show InstallManager, InstallMethod;

/// todo 25 接线验收（hermetic，seams/fakes，无 FFI / 无网络 / 无 Flutter 插件）。
///
/// 覆盖：
/// - `DownloadModule.onRegister` 的等价接线：把 [LazyDownloadService] 交给
///   [DownloadTaskWatcher] **只 `start` 一次**；
/// - 注入的 Rust 解析成功后，**同一条** watcher 订阅在首次 `download` 之后
///   收到 Rust `watchAll` 事件，且不重绑（无第二次 `start` / `_started.clear`）；
/// - 解析失败回落 Dart 时 watcher 继续消费 Dart 事件，同一任务 id 不重复发
///   "开始"通知。
///
/// `flutter test` 未在本环境执行（系统盘故障，任务环境明令禁止）——见
/// `.omo/evidence/unified-module-onuse-install/t25-watcher*.txt`。

/// 构造最小 [DownloadTask]；[source] 区分内核（dart / rust）。
DownloadTask _task(
  int id, {
  String source = 'x',
  DownloadStatusEnum status = DownloadStatusEnum.queued,
  bool installAfterDownload = false,
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
    installAfterDownload: installAfterDownload,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

/// 伪造的安装管理器：`installApk` 抛错，用于验证自动安装异常被捕获上报。
class _ThrowingInstallManager implements InstallManager {
  int installCalls = 0;

  @override
  Future<(bool, InstallMethod)> installApk(String filePath) async {
    installCalls++;
    throw StateError('installApk boom: $filePath');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 记录调用次数、可手动推事件的假下载服务（无 FFI / 无网络）。
class _FakeDownloadService implements IDownloadService {
  _FakeDownloadService(this.tag);

  final String tag;

  int downloadCalls = 0;
  int pauseCalls = 0;
  int watchAllCalls = 0;

  final StreamController<DownloadTask> allController =
      StreamController<DownloadTask>.broadcast();

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
    return _task(1, source: tag);
  }

  @override
  Future<void> pause(int id) async {
    pauseCalls++;
  }

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> retry(int id) async {}

  @override
  Future<void> restart(int id) async {}

  @override
  Future<void> remove(int id) async {}

  @override
  Future<DownloadTask?> getTask(int id) async => _task(id, source: tag);

  @override
  Future<List<DownloadTask>> listTasks() async => <DownloadTask>[
        _task(1, source: tag),
      ];

  @override
  Stream<DownloadTask> watch(int id) => const Stream<DownloadTask>.empty();

  @override
  Stream<DownloadTask> watchAll() {
    watchAllCalls++;
    return allController.stream;
  }
}

void main() {
  group('DownloadTaskWatcher + LazyDownloadService 接线', () {
    test('解析 Rust 后同一条 watcher 订阅收到 Rust 事件，且不重绑', () async {
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

      // 等价于 DownloadModule.onRegister：绑定惰性路由并只 start 一次。
      final watcher = DownloadTaskWatcher.debug();
      watcher.start(lazy);

      expect(watcher.debugStartCount, 1, reason: 'onRegister 只应绑定一次');
      expect(dart.watchAllCalls, 1, reason: '绑定后立即用 Dart 流顶着');
      expect(probes, 0, reason: '订阅 watchAll 不得触发内核解析');
      expect(rust.watchAllCalls, 0);

      DownloadNotificationService.debugResetCallCount();

      // 首次真实下载 → 触发单飞解析。
      await lazy.download('a', 'n', '1', 'u', 'f.apk');
      await pumpEventQueue();

      expect(probes, 1, reason: '首个变更类调用解析一次');
      expect(rust.watchAllCalls, 1, reason: '解析完成后合并流换到 Rust');
      expect(watcher.debugStartCount, 1, reason: '换源不得重绑、不得重启 watcher');
      expect(DownloadNotificationService.debugCallCount, 0,
          reason: '解析本身不产生下载通知');

      // 同一条 watcher 订阅现在应收到 Rust 事件并驱动通知。
      rust.allController.add(
        _task(42, source: 'rust', status: DownloadStatusEnum.downloading),
      );
      await pumpEventQueue();

      expect(watcher.debugStartedIds, contains(42),
          reason: 'Rust 事件经同一条订阅送达 watcher');
      expect(DownloadNotificationService.debugCallCount, 2,
          reason: 'queued/downloading → 开始通知 + 进度通知各一次');
      expect(watcher.debugStartCount, 1,
          reason: '收到 Rust 事件后仍无第二次 start');
    });

    test('同一实现重复 start 为空操作：不清空已发开始标记', () async {
      final dart = _FakeDownloadService('dart');
      final lazy = LazyDownloadService(dart, rustProbe: () async => false);

      final watcher = DownloadTaskWatcher.debug();
      watcher.start(lazy);
      expect(watcher.debugStartCount, 1);
      expect(dart.watchAllCalls, 1);

      // 先来一条事件，让 id=7 进入"已发开始通知"集合。
      dart.allController.add(_task(7, source: 'dart'));
      await pumpEventQueue();
      expect(watcher.debugStartedIds, contains(7));

      // 模拟一次无意的重入（例如模块重复注册）：同一实现必须整段跳过。
      watcher.start(lazy);

      expect(watcher.debugStartCount, 1, reason: '同一实现不得二次绑定');
      expect(dart.watchAllCalls, 1, reason: '不得重新订阅 watchAll');
      expect(watcher.debugStartedIds, contains(7),
          reason: '_started 未被清空（不重复发开始通知的前提）');
    });

    test('换成另一个实现时才替换订阅（start 未被削弱）', () async {
      final a = _FakeDownloadService('a');
      final b = _FakeDownloadService('b');

      final watcher = DownloadTaskWatcher.debug();
      watcher.start(a);
      expect(watcher.debugStartCount, 1);
      expect(a.watchAllCalls, 1);

      watcher.start(b);
      expect(watcher.debugStartCount, 2, reason: '不同实现应真正重绑');
      expect(b.watchAllCalls, 1);
    });
  });

  group('DownloadTaskWatcher + LazyDownloadService 回落', () {
    test('解析失败时继续消费 Dart 事件，同一任务不重复发开始通知', () async {
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      final lazy = LazyDownloadService(
        dart,
        rustProbe: () async => false, // 内核不可用 → 回落 Dart
        rustServiceFactory: () => rust,
      );

      final watcher = DownloadTaskWatcher.debug();
      watcher.start(lazy);
      expect(dart.watchAllCalls, 1);

      // 变更类调用触发解析，失败后回落 Dart；watcher 订阅无需变化。
      await lazy.pause(1);
      await pumpEventQueue();

      expect(dart.pauseCalls, 1, reason: '回落后变更类调用走 Dart');
      expect(rust.watchAllCalls, 0, reason: '回退后不得订阅 Rust 流');
      expect(watcher.debugStartCount, 1);

      DownloadNotificationService.debugResetCallCount();

      // Dart 事件继续经同一条订阅送达。
      dart.allController.add(
        _task(7, source: 'dart', status: DownloadStatusEnum.downloading),
      );
      await pumpEventQueue();

      final afterFirst = DownloadNotificationService.debugCallCount;
      expect(afterFirst, 2, reason: '开始 + 进度各通知一次');
      expect(watcher.debugStartedIds, contains(7));

      // 假设发生一次无意的重入（重复绑定同一实现）——必须保持空操作。
      watcher.start(lazy);

      // 同一任务 id 再来一条进度：只应发进度通知，不得重复"开始"。
      dart.allController.add(
        _task(7, source: 'dart', status: DownloadStatusEnum.downloading),
      );
      await pumpEventQueue();

      expect(DownloadNotificationService.debugCallCount - afterFirst, 1,
          reason: '同一 id 不得重复发开始通知（_started 未被清空）');
      expect(watcher.debugStartCount, 1, reason: '重入未触发二次绑定');
      expect(watcher.debugStartedIds, contains(7));
    });
  });

  group('DownloadTaskWatcher 自动安装', () {
    test('installApk 抛错被捕获上报，不产生未处理异步错误', () async {
      final dart = _FakeDownloadService('dart');
      final watcher = DownloadTaskWatcher.debug();
      watcher.start(dart);

      final fakeInstall = _ThrowingInstallManager();
      ModuleManager.instance.bind<InstallManager>(fakeInstall);
      addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

      final printed = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) printed.add(message);
      };
      addTearDown(() => debugPrint = originalDebugPrint);

      dart.allController.add(
        _task(
          9,
          source: 'dart',
          status: DownloadStatusEnum.completed,
          installAfterDownload: true,
        ),
      );
      await pumpEventQueue();

      expect(fakeInstall.installCalls, 1, reason: '完成且标记自动安装 → 触发一次安装');
      expect(
        printed.any((m) => m.contains('自动安装失败') && m.contains('installApk boom')),
        isTrue,
        reason: '安装异常必须被捕获并上报（而非未处理异步错误）',
      );
    });
  });
}
