import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/download_task_watcher.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

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

DownloadTask _task(int id) => DownloadTask(
      id: id,
      appId: 'app$id',
      appName: 'App $id',
      version: '1.0.0',
      fileName: 'file$id.apk',
      url: 'https://example.com/file$id.apk',
      filePath: '/tmp/file$id.apk',
      total: 100,
      received: 0,
      status: DownloadStatusEnum.downloading,
      speedBps: 0,
      etaSec: null,
      error: null,
      segments: null,
      installAfterDownload: false,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

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
}
