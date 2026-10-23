import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/download_task_watcher.dart';
import 'package:gstore/core/download/model/download_task.dart';
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
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
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
  Future<(bool, InstallMethod)> installTask(
    String moduleTaskId,
    String filePath,
  ) async {
    installTaskCalls++;
    lastModuleTaskId = moduleTaskId;
    throw StateError('installTask boom: $moduleTaskId');
  }

  @override
  Future<(bool, InstallMethod)> installApk(
    String filePath, {
    bool moduleInstall = false,
  }) async {
    installApkCalls++;
    throw StateError('installApk must not be used after the cutover');
  }

  @override
  Future<int> consumeInstallRequests() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DownloadTaskWatcher watcher;

  setUp(() {
    watcher = DownloadTaskWatcher.debug();
  });

  tearDown(() {
    watcher.dispose();
  });

  test('start subscribes exactly once', () {
    final service = _FakeDownloadService();
    addTearDown(service.close);

    watcher.start(service);

    expect(watcher.debugStartCount, 1);
    expect(service.watchAllCalls, 1);
  });

  test('repeating start with the identical implementation is a no-op', () async {
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
      status: DownloadStatusEnum.completed,
      installAfterDownload: true,
    ));
    await pumpEventQueue();

    expect(install.installTaskCalls, 1,
        reason: 'a completed installAfterDownload task always installs via core');
    expect(install.lastModuleTaskId, '9');
    expect(install.installApkCalls, 0,
        reason: 'the cutover removed the installApk fallback');
    expect(
      printed.any((m) =>
          m.contains('核心自动安装失败') && m.contains('installTask boom')),
      isTrue,
      reason: 'the install error must be caught and reported, never unhandled',
    );
  });
}
