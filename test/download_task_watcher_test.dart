import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/download_task_watcher.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart' show ModuleManager;
import 'package:gstore/core/service/install_manager.dart'
    show InstallManager, InstallMethod;

/// Hermetic watcher lifecycle tests: no FFI, no network, no Flutter plugins.
///
/// [DownloadNotificationService] silently no-ops before initialization, so the
/// emitted tasks only exercise the watcher's subscription bookkeeping.
class _FakeDownloadService implements IDownloadService {
  final StreamController<DownloadTask> _all =
      StreamController<DownloadTask>.broadcast();

  int watchAllCalls = 0;

  void emit(DownloadTask task) => _all.add(task);

  Future<void> close() => _all.close();

  @override
  Stream<DownloadTask> watchAll() {
    watchAllCalls++;
    return _all.stream;
  }

  @override
  Stream<DownloadTask> watch(int id) => const Stream<DownloadTask>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadTask _task(
  int id, {
  DownloadStatusEnum status = DownloadStatusEnum.downloading,
  bool installAfterDownload = false,
}) =>
    DownloadTask(
      id: id,
      appId: 'app$id',
      appName: 'App $id',
      version: '1.0.0',
      fileName: 'file$id.apk',
      url: 'https://example.com/file$id.apk',
      filePath: '/tmp/file$id.apk',
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

/// Core-cutover install seam: [installTask] throws so the watcher's catch is
/// exercised; [installApk] must never be reached.
class _ThrowingInstallManager implements InstallManager {
  int installTaskCalls = 0;
  int installApkCalls = 0;
  String? lastModuleTaskId;

  @override
  Future<(InstallOutcome, InstallMethod)> installTask(
    String moduleTaskId,
    String filePath, {
    bool force = false,
  }) async {
    installTaskCalls++;
    lastModuleTaskId = moduleTaskId;
    throw StateError('installTask boom: $moduleTaskId');
  }

  @override
  Future<(InstallOutcome, InstallMethod)> installApk(
    String filePath, {
    bool moduleInstall = false,
    bool force = false,
  }) async {
    installApkCalls++;
    throw StateError('installApk must not be used after the cutover');
  }

  @override
  Future<int> consumeInstallRequests() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingInstallManager implements InstallManager {
  int installTaskCalls = 0;
  int consumeCalls = 0;
  String? lastModuleTaskId;

  @override
  Future<(InstallOutcome, InstallMethod)> installTask(
    String moduleTaskId,
    String filePath, {
    bool force = false,
  }) async {
    installTaskCalls++;
    lastModuleTaskId = moduleTaskId;
    return (InstallOutcome.installed, InstallMethod.shizuku);
  }

  @override
  Future<int> consumeInstallRequests() async {
    consumeCalls++;
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DownloadTaskWatcher watcher;

  setUp(() {
    watcher = DownloadTaskWatcher.debug();
    // 默认探针返回可重试状态 'failed'：满足 FAIL-CLOSED（null => 不安装），
    // 同时让「活跃态→completed」的用例可以真正触发安装。
    DownloadTaskWatcher.installStatusProbeForTest = (_) async => 'failed';
  });

  tearDown(() {
    watcher.dispose();
    DownloadTaskWatcher.installStatusProbeForTest = null;
  });

  test('start subscribes exactly once', () {
    final service = _FakeDownloadService();
    addTearDown(service.close);

    watcher.start(service);

    expect(watcher.debugStartCount, 1);
    expect(service.watchAllCalls, 1);
  });

  test('repeating start with the identical implementation is a no-op',
      () async {
    final service = _FakeDownloadService();
    addTearDown(service.close);
    watcher.start(service);

    service.emit(_task(7));
    await pumpEventQueue();
    expect(watcher.debugStartedIds, contains(7));

    watcher.start(service);

    expect(watcher.debugStartCount, 1,
        reason: 'identical implementation must not resubscribe');
    expect(service.watchAllCalls, 1);
    expect(watcher.debugStartedIds, contains(7),
        reason: 'repeated start must not clear the started-id set');
  });

  test('start with a different implementation resubscribes and clears ids',
      () async {
    final first = _FakeDownloadService();
    final second = _FakeDownloadService();
    addTearDown(first.close);
    addTearDown(second.close);

    watcher.start(first);
    first.emit(_task(9));
    await pumpEventQueue();
    expect(watcher.debugStartedIds, contains(9));

    watcher.start(second);

    expect(watcher.debugStartCount, 2,
        reason: 'a different implementation must replace the subscription');
    expect(second.watchAllCalls, 1);
    expect(watcher.debugStartedIds, isEmpty,
        reason: 'rebinding to a new implementation resets notification state');
  });

  test('dispose cancels the subscription and allows a later start', () {
    final service = _FakeDownloadService();
    addTearDown(service.close);

    watcher.start(service);
    expect(watcher.debugStartCount, 1);

    watcher.dispose();
    watcher.start(service);

    expect(watcher.debugStartCount, 2,
        reason: 'after dispose a start must subscribe again');
    expect(service.watchAllCalls, 2);
  });

  // Ported from the deleted lazy wiring suite: the watcher's automatic install
  // is still meaningful production code, but after the Wave 6B cutover it must
  // always call `installTask` (there is no `installApk` fallback).
  test('completed installAfterDownload calls installTask and swallows errors',
      () async {
    final service = _FakeDownloadService();
    addTearDown(service.close);
    watcher.start(service);

    final install = _ThrowingInstallManager();
    ModuleManager.instance.bind<InstallManager>(install);
    addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

    final printed = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
      originalDebugPrint(message, wrapWidth: wrapWidth);
    };
    addTearDown(() => debugPrint = originalDebugPrint);

    service.emit(_task(
      9,
      status: DownloadStatusEnum.downloading,
      installAfterDownload: true,
    ));
    await pumpEventQueue();
    service.emit(_task(
      9,
      status: DownloadStatusEnum.completed,
      installAfterDownload: true,
    ));
    await pumpEventQueue();

    expect(install.installTaskCalls, 1,
        reason:
            'a completed installAfterDownload task always installs via core');
    expect(install.lastModuleTaskId, '9');
    expect(install.installApkCalls, 0,
        reason: 'the cutover removed the installApk fallback');
    expect(
      printed
          .any((m) => m.contains('核心自动安装失败') && m.contains('installTask boom')),
      isTrue,
      reason: 'the install error must be caught and reported, never unhandled',
    );
  });

  test('pending/installed 视为已消费：重启/重复 seed 不再自动安装', () async {
    final service = _FakeDownloadService();
    addTearDown(service.close);
    watcher.start(service);

    final install = _CountingInstallManager();
    ModuleManager.instance.bind<InstallManager>(install);
    addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

    DownloadTaskWatcher.installStatusProbeForTest = (_) async => 'pending';

    service.emit(_task(
      11,
      status: DownloadStatusEnum.downloading,
      installAfterDownload: true,
    ));
    await pumpEventQueue();
    service.emit(_task(
      11,
      status: DownloadStatusEnum.completed,
      installAfterDownload: true,
    ));
    await pumpEventQueue();

    expect(install.installTaskCalls, 0,
        reason: 'pending/installed 是已消费状态，不得重放');
    expect(install.consumeCalls, 0);
  });

  test('bare completed（重启 seed）不得重放自动安装', () async {
    final service = _FakeDownloadService();
    addTearDown(service.close);
    watcher.start(service);

    final install = _CountingInstallManager();
    ModuleManager.instance.bind<InstallManager>(install);
    addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

    DownloadTaskWatcher.installStatusProbeForTest = (_) async => 'failed';

    // 冷启动 seed 直接给出历史 completed，本进程从未见过活跃态。
    service.emit(_task(
      21,
      status: DownloadStatusEnum.completed,
      installAfterDownload: true,
    ));
    await pumpEventQueue();

    expect(install.installTaskCalls, 0,
        reason: 'seed 的 completed 不是本进程内的状态迁移，绝不能重装');
  });

  test('probe 返回 null 时 FAIL-CLOSED：不得安装', () async {
    final service = _FakeDownloadService();
    addTearDown(service.close);
    watcher.start(service);

    final install = _CountingInstallManager();
    ModuleManager.instance.bind<InstallManager>(install);
    addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

    DownloadTaskWatcher.installStatusProbeForTest = (_) async => null;

    service.emit(_task(
      22,
      status: DownloadStatusEnum.downloading,
      installAfterDownload: true,
    ));
    await pumpEventQueue();
    service.emit(_task(
      22,
      status: DownloadStatusEnum.completed,
      installAfterDownload: true,
    ));
    await pumpEventQueue();

    expect(install.installTaskCalls, 0, reason: '无法确认安装状态时必须保守跳过，不能猜测未消费');
  });

  test('probe 抛异常时 FAIL-CLOSED：不得安装', () async {
    final service = _FakeDownloadService();
    addTearDown(service.close);
    watcher.start(service);

    final install = _CountingInstallManager();
    ModuleManager.instance.bind<InstallManager>(install);
    addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

    DownloadTaskWatcher.installStatusProbeForTest =
        (_) async => throw StateError('probe boom');

    service.emit(_task(
      23,
      status: DownloadStatusEnum.downloading,
      installAfterDownload: true,
    ));
    await pumpEventQueue();
    service.emit(_task(
      23,
      status: DownloadStatusEnum.completed,
      installAfterDownload: true,
    ));
    await pumpEventQueue();

    expect(install.installTaskCalls, 0, reason: '探针异常同样属于无法确认，必须保守跳过');
  });

  test('forceRetry: true 无需prior active 也会安装', () async {
    final service = _FakeDownloadService();
    addTearDown(service.close);
    watcher.start(service);

    final install = _CountingInstallManager();
    ModuleManager.instance.bind<InstallManager>(install);
    addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

    DownloadTaskWatcher.installStatusProbeForTest = (_) async => 'failed';

    // 更新页用户显式点击：直接调 ensureAutoInstall(forceRetry: true)，
    // 不经过 watchAll 的活跃态门禁。
    final outcome = await watcher.ensureAutoInstall(
      _task(
        24,
        status: DownloadStatusEnum.completed,
        installAfterDownload: true,
      ),
      forceRetry: true,
    );

    expect(outcome, InstallOutcome.installed);
    expect(install.installTaskCalls, 1, reason: '显式重试必须绕过 _seenActive 门禁并真正安装');
    expect(install.lastModuleTaskId, '24');
  });

  test('failed 是可重试状态：completed 会再次尝试安装', () async {
    final service = _FakeDownloadService();
    addTearDown(service.close);
    watcher.start(service);

    final install = _CountingInstallManager();
    ModuleManager.instance.bind<InstallManager>(install);
    addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

    DownloadTaskWatcher.installStatusProbeForTest = (_) async => 'failed';

    service.emit(_task(
      13,
      status: DownloadStatusEnum.downloading,
      installAfterDownload: true,
    ));
    await pumpEventQueue();
    service.emit(_task(
      13,
      status: DownloadStatusEnum.completed,
      installAfterDownload: true,
    ));
    await pumpEventQueue();

    expect(install.installTaskCalls, 1, reason: 'failed 安装状态应允许用户重新下载后重试');
    expect(install.lastModuleTaskId, '13');
  });

  test('重新进入下载态后 completed 会再次尝试自动安装', () async {
    final service = _FakeDownloadService();
    addTearDown(service.close);
    watcher.start(service);

    final install = _CountingInstallManager();
    ModuleManager.instance.bind<InstallManager>(install);
    addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

    final completed = _task(
      14,
      status: DownloadStatusEnum.completed,
      installAfterDownload: true,
    );
    service.emit(_task(
      14,
      status: DownloadStatusEnum.downloading,
      installAfterDownload: true,
    ));
    await pumpEventQueue();
    service.emit(completed);
    await pumpEventQueue();
    expect(install.installTaskCalls, 1);

    service.emit(_task(
      14,
      status: DownloadStatusEnum.downloading,
      installAfterDownload: true,
    ));
    await pumpEventQueue();
    service.emit(completed);
    await pumpEventQueue();

    expect(install.installTaskCalls, 2, reason: '新一次下载应清除已消费标记并允许重试安装');
  });

  test('ensureAutoInstall 返回 installTask 的结果', () async {
    final service = _FakeDownloadService();
    addTearDown(service.close);
    watcher.start(service);

    final install = _CountingInstallManager();
    ModuleManager.instance.bind<InstallManager>(install);
    addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

    final outcome = await watcher.ensureAutoInstall(_task(
      15,
      status: DownloadStatusEnum.completed,
      installAfterDownload: true,
    ));

    expect(outcome, InstallOutcome.installed);
    expect(install.lastModuleTaskId, '15');
    expect(install.consumeCalls, 1);
  });

  test('同一进程内重复收到 completed 只触发一次自动安装', () async {
    final service = _FakeDownloadService();
    addTearDown(service.close);
    watcher.start(service);

    final install = _CountingInstallManager();
    ModuleManager.instance.bind<InstallManager>(install);
    addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

    final task = _task(
      12,
      status: DownloadStatusEnum.completed,
      installAfterDownload: true,
    );
    service.emit(_task(
      12,
      status: DownloadStatusEnum.downloading,
      installAfterDownload: true,
    ));
    await pumpEventQueue();
    service.emit(task);
    service.emit(task);
    await pumpEventQueue();

    expect(install.installTaskCalls, 1, reason: '同一次 seed/重复事件的自动安装只允许触发一次');
    expect(install.lastModuleTaskId, '12');
  });
}
