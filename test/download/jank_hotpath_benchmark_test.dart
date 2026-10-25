/// Hermetic hot-path work benchmark for the download page (task 255).
///
/// The real jank is Dart-side periodic work driven by the page's watch wiring:
///   * each `service.watch(id)` subscribes the core's `watchAll` → ONE native
///     500 ms poll thread that runs a full `reconcile()` sweep per tick;
///   * each such thread re-emits every changed row across the FFI boundary into
///     the UI isolate, where the Dart `watch(id)` filter drops all but one.
///
/// This test models that boundary faithfully (each `watch(id)` listens to the
/// same list-level broadcast and filters by id) and counts, for a fixed
/// scenario (N tasks, M changed rows per tick, T ticks):
///   * `coreWatchSubs`  — native poll threads (== watchAll + per-id subs)
///   * `ffiDispatches`  — events crossing core→Dart into the UI isolate
///   * `stateEmissions` — download-list rebuilds
///
/// It is deterministic (counts, not wall-clock), so it is stable in CI.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/download/download_page_providers.dart';

class _BenchService implements IDownloadService {
  _BenchService(this.tasks);

  List<DownloadTask> tasks;
  int watchAllCalls = 0;
  final List<int> watchCalls = <int>[];
  int ffiDispatches = 0;
  int listTasksCalls = 0;

  final StreamController<DownloadTask> _watchAll =
      StreamController<DownloadTask>.broadcast();

  @override
  Future<List<DownloadTask>> listTasks() async {
    listTasksCalls++;
    return List<DownloadTask>.of(tasks);
  }

  @override
  Stream<DownloadTask> watchAll() {
    watchAllCalls++;
    return _watchAll.stream.map((t) {
      ffiDispatches++;
      return t;
    });
  }

  @override
  Stream<DownloadTask> watch(int id) {
    watchCalls.add(id);
    final out = StreamController<DownloadTask>.broadcast();
    // Mirrors the real RustDownloadService.watch(id): one subscription to the
    // list-level core stream per id, filtered client-side.
    _watchAll.stream.listen((t) {
      ffiDispatches++;
      if (t.id == id) out.add(t);
    });
    return out.stream;
  }

  void emit(DownloadTask task) {
    final i = tasks.indexWhere((t) => t.id == task.id);
    if (i >= 0) tasks[i] = task;
    _watchAll.add(task);
  }

  Future<void> dispose() => _watchAll.close();

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

DownloadTask _task(int id, {int received = 0}) => DownloadTask(
      id: id,
      appId: 'com.example.app',
      appName: '示例',
      version: '1.0.0',
      fileName: 'app.apk',
      url: 'https://example.test/app.apk',
      filePath: '/tmp/bench-$id.apk',
      total: 1000000,
      received: received,
      status: DownloadStatusEnum.downloading,
      speedBps: 0,
      etaSec: null,
      error: null,
      segments: null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

void main() {
  test('hot-path work for N tasks / M changed-per-tick / T ticks', () async {
    const n = 6;
    const m = 2;
    const t = 20;

    await ModuleManager.instance.clear();
    final service = _BenchService([for (var i = 1; i <= n; i++) _task(i)]);
    addTearDown(service.dispose);
    ModuleManager.instance.bind<IDownloadService>(service);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(downloadManagerProvider.notifier);

    var emissions = 0;
    final sub =
        container.listen(downloadManagerProvider, (_, __) => emissions++);
    addTearDown(sub.close);

    await notifier.load();
    await pumpEventQueue();

    // Baseline captured AFTER the initial load so we measure the steady state.
    final baseFfi = service.ffiDispatches;
    final baseEm = emissions;
    final baseList = service.listTasksCalls;

    // T ticks; each tick M tasks change (like 500 ms of live progress).
    for (var tick = 0; tick < t; tick++) {
      for (var k = 1; k <= m; k++) {
        service.emit(_task(k, received: (tick + 1) * 1000));
      }
      await pumpEventQueue();
    }

    final coreWatchSubs = service.watchAllCalls + service.watchCalls.length;
    final ffiDispatches = service.ffiDispatches - baseFfi;
    final stateEmissions = emissions - baseEm;
    final listTasksCalls = service.listTasksCalls - baseList;

    // ignore: avoid_print
    print(
      'JANKBENCH tasks=$n changedPerTick=$m ticks=$t '
      'coreWatchSubs=$coreWatchSubs '
      'ffiDispatches=$ffiDispatches '
      'stateEmissions=$stateEmissions '
      'listTasksCalls=$listTasksCalls',
    );

    // Structural invariants (hold on the fixed code; fail pre-fix).
    expect(service.watchCalls, isEmpty,
        reason: 'no per-task subscriptions on the fixed code');
    expect(service.watchAllCalls, 1,
        reason: 'exactly one list-level subscription');
  });
}
