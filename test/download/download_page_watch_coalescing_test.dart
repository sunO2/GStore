/// Structural regression tests for the download-page watch/reload hot paths.
///
/// BUG (reported): "为什么操作会一卡一卡的" — the download page stutters.
///
/// Root cause (see `lib/page/download/download_page_providers.dart`):
///   1. `_resubscribeWatches` created ONE `service.watch(id)` subscription PER
///      TASK. The core's `watchAll` is a per-subscription 500 ms poll thread that
///      runs a full `reconcile()` sweep each tick
///      (`rust/gstore_host/src/bridge.rs` `DownloadApi::watch_all`,
///      `download_host.rs` `refresh_and_list`). N tasks → N poll threads, each
///      re-emitting every changed row into the UI isolate → N×M state replaces
///      per tick → the whole list rebuilt continuously.
///   2. `loadTasks()` replaced `state` wholesale even when nothing changed, so
///      every reload rebuilt the list.
///   3. `_refreshMissingFiles` ran a `File.exists` per completed task on EVERY
///      load.
///
/// These tests fail on the pre-fix code:
///   - pre-fix `watchAllCalls` was 0 and `watchCalls` grew with the task count;
///   - pre-fix an unchanged reload still replaced `state` (an extra emission).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/download/download_page_providers.dart';

/// In-memory fake: `listTasks` is the data source, `watchAll` is the single
/// list-level stream the page must subscribe to, `watch(id)` is counted to prove
/// the page no longer subscribes per task.
class _FakeService implements IDownloadService {
  _FakeService(this.tasks);

  List<DownloadTask> tasks;
  int watchAllCalls = 0;
  final List<int> watchCalls = <int>[];
  final StreamController<DownloadTask> _watchAll =
      StreamController<DownloadTask>.broadcast();

  void emit(DownloadTask task) {
    final id = task.id;
    if (id != null) {
      final i = tasks.indexWhere((t) => t.id == id);
      if (i >= 0) tasks[i] = task;
    }
    _watchAll.add(task);
  }

  Future<void> dispose() => _watchAll.close();

  @override
  Future<List<DownloadTask>> listTasks() async => List<DownloadTask>.of(tasks);

  @override
  Stream<DownloadTask> watchAll() {
    watchAllCalls++;
    return _watchAll.stream;
  }

  @override
  Stream<DownloadTask> watch(int id) {
    watchCalls.add(id);
    return const Stream<DownloadTask>.empty();
  }

  @override
  Future<void> remove(int id) async {
    tasks.removeWhere((t) => t.id == id);
  }

  @override
  Future<void> retry(int id) async {}
  @override
  Future<void> restart(int id) async {}
  @override
  Future<void> pause(int id) async {}
  @override
  Future<void> resume(int id) async {}
  @override
  Future<void> cancel(int id) async {}
  @override
  Future<DownloadTask?> getTask(int id) async =>
      tasks.where((t) => t.id == id).firstOrNull;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadTask _task(
  int id, {
  DownloadStatusEnum status = DownloadStatusEnum.downloading,
  String appId = 'com.example.app',
  String filePath = '/tmp/does-not-exist/app.apk',
  int received = 0,
}) {
  return DownloadTask(
    id: id,
    appId: appId,
    appName: '示例',
    version: '1.0.0',
    fileName: 'app.apk',
    url: 'https://example.test/app.apk',
    filePath: filePath,
    total: 1000,
    received: received,
    status: status,
    speedBps: 0,
    etaSec: null,
    error: null,
    segments: null,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
  );
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Future<Set<int>> Function(List<(int, String)>) originalScanner;

  setUp(() async {
    await ModuleManager.instance.clear();
    originalScanner = DownloadManagerNotifier.scanMissingFiles;
    // Inject a synchronous scanner: the test only cares about the SKIP/rescan
    // semantics, not the isolate scheduling, so drop the compute() hop here.
    DownloadManagerNotifier.scanMissingFiles = (entries) async {
      final missing = <int>{};
      for (final (id, path) in entries) {
        if (!await File(path).exists()) missing.add(id);
      }
      return missing;
    };
  });

  tearDown(() async {
    DownloadManagerNotifier.scanMissingFiles = originalScanner;
    await ModuleManager.instance.clear();
  });

  ProviderContainer containerFor(_FakeService service) {
    ModuleManager.instance.bind<IDownloadService>(service);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test('N tasks subscribe the list-level watch ONCE, never per task', () async {
    final service = _FakeService([
      _task(1),
      _task(2, filePath: '/tmp/does-not-exist/b.apk'),
      _task(3, filePath: '/tmp/does-not-exist/c.apk'),
    ]);
    addTearDown(service.dispose);
    final container = containerFor(service);
    final notifier = container.read(downloadManagerProvider.notifier);

    await notifier.load();

    final groups = container.read(downloadManagerProvider).groups;
    expect(groups.expand((g) => g), hasLength(3));
    expect(service.watchAllCalls, 1,
        reason: '3 tasks must create exactly ONE core watch poll, not 3');
    expect(service.watchCalls, isEmpty,
        reason: 'the page must not call service.watch(id) at all');
  });

  test('repeated loadTasks does not stack more watch subscriptions', () async {
    final service = _FakeService([_task(1), _task(2)]);
    addTearDown(service.dispose);
    final container = containerFor(service);
    final notifier = container.read(downloadManagerProvider.notifier);

    await notifier.load();
    await notifier.loadTasks();
    await notifier.loadTasks();

    expect(service.watchAllCalls, 1,
        reason: 'the list-level watch is idempotent across reloads');
    expect(service.watchCalls, isEmpty);
  });

  test('an unchanged reload does NOT replace state (no list rebuild)', () async {
    final service = _FakeService([_task(1), _task(2)]);
    addTearDown(service.dispose);
    final container = containerFor(service);
    final notifier = container.read(downloadManagerProvider.notifier);

    await notifier.load();
    // let the first load's async tails (prefetch / missing-file scan) settle
    await pumpEventQueue();

    var emissions = 0;
    final sub =
        container.listen(downloadManagerProvider, (_, __) => emissions++);
    addTearDown(sub.close);

    // Same tasks, same data → must not re-publish state.
    await notifier.loadTasks();
    await pumpEventQueue();

    expect(emissions, 0,
        reason: 'an identical reload must not trigger a list rebuild');
  });

  test('live progress still flows through the single watchAll stream', () async {
    final service = _FakeService([_task(1, received: 100)]);
    addTearDown(service.dispose);
    final container = containerFor(service);
    final notifier = container.read(downloadManagerProvider.notifier);

    await notifier.load();
    await pumpEventQueue();
    expect(container.read(downloadManagerProvider).groups.first.first.received,
        100);

    service.emit(_task(1, received: 400));
    await _waitUntil(
        () => container.read(downloadManagerProvider).groups.first.first.received == 400);

    expect(container.read(downloadManagerProvider).groups.first.first.received,
        400);
  });

  test(
      '_refreshMissingFiles rescans on mount but skips an unchanged reload '
      '(forced rescan still updates)', () async {
    final dir = await Directory.systemTemp.createTemp('jank_scan_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/done.apk')..writeAsStringSync('x');
    final completed = _task(1,
        status: DownloadStatusEnum.completed, filePath: file.path);

    final service = _FakeService([completed]);
    addTearDown(service.dispose);
    final container = containerFor(service);
    final notifier = container.read(downloadManagerProvider.notifier);

    await notifier.load();
    // First scan: the file exists → nothing missing.
    await _waitUntil(
        () => !container.read(downloadManagerProvider).missingFileIds.contains(1),
        timeout: const Duration(seconds: 5));

    // Delete the file externally but keep the completed set identical.
    await file.delete();
    await notifier.loadTasks();
    await pumpEventQueue();

    // The unchanged reload must have skipped the disk scan → stale (still 0).
    expect(container.read(downloadManagerProvider).missingFileIds, isEmpty,
        reason: 'an unchanged completed set must skip the per-load disk scan');

    // A forced rescan (page re-mount) must still detect the deletion.
    await notifier.load();
    await _waitUntil(
        () => container.read(downloadManagerProvider).missingFileIds.contains(1));

    expect(container.read(downloadManagerProvider).missingFileIds, contains(1));
  });
}
