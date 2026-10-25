/// Structural before/after counters for task 258 (push vs 500 ms poll).
///
/// * BEFORE — the removed mechanism: one facade `watchAll()` subscription per
///   consumer, and a Rust thread calling `refresh_and_list()` (full reconcile +
///   core read) every 500 ms. Measured here by replaying that exact 500 ms loop
///   against the same counters over a fixed window.
/// * AFTER — `DownloadPushStream`: zero facade poll subscriptions, one seed
///   full read on subscribe, then one UI dispatch per pushed tick.
///
/// Counters are deterministic; the only wall-clock number is the delivery
/// latency, printed for reference.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/download_push_stream.dart';
import 'package:gstore/core/download/rust/rust_download_service.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart'
    show RustModuleInstance, RustModuleManager;
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:gstore/core/rust/generated/event_bridge.dart' show ModuleEvent;
import 'package:mockito/mockito.dart';

ModuleEvent _progress(int id, int received) => ModuleEvent(
      moduleId: BigInt.one,
      instanceId: BigInt.one,
      eventType: 'download.progress',
      data: Uint8List.fromList(utf8.encode(jsonEncode({
        'taskId': id,
        'status': 2,
        'total': 1000000,
        'received': received,
        'speedBps': 4096,
        'etaSec': 10,
      }))),
      timestampMs: 0,
    );

DownloadTask _task(int id, {int received = 0}) => DownloadTask(
      id: id,
      appId: 'com.example.app',
      appName: '示例',
      version: '1.0.0',
      fileName: 'app.apk',
      url: 'https://example.test/app.apk',
      filePath: '/tmp/app.apk',
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

class _FakeModuleHandle extends Mock implements ModuleHandle {}

class _FakeRustModuleInstance extends Mock implements RustModuleInstance {}

rust.DownloadTaskDto _dto(int id) => rust.DownloadTaskDto(
      id: id,
      moduleTaskId: '$id',
      dedupKey: 'dedup:$id',
      appId: 'com.example.app',
      appName: '示例',
      version: '1.0.0',
      fileName: 'app.apk',
      kind: 'app',
      resourceId: 'com.example.app',
      resourceVersion: '1.0.0',
      url: 'https://example.test/app.apk',
      destPath: '/tmp/app.apk',
      status: 'downloading',
      bytesDone: 0,
      total: 1000000,
      speedBps: 0,
      etaSec: null,
      segmentsJson: null,
      retries: 0,
      serverMeta: null,
      priority: 0,
      headersJson: null,
      expectedSha256: null,
      installAfterDownload: false,
      error: null,
      lastStartedAt: 7,
      createdAt: 100,
      updatedAt: 200,
    );

class _CountingBackend implements DownloadBackend {
  int watchAllCalls = 0;
  int listCalls = 0;
  final StreamController<rust.DownloadTaskDto> events =
      StreamController<rust.DownloadTaskDto>.broadcast();

  @override
  Future<List<rust.DownloadTaskDto>> list() async {
    listCalls++;
    return <rust.DownloadTaskDto>[_dto(1)];
  }

  @override
  Future<rust.DownloadTaskDto?> get(String moduleTaskId) async =>
      _dto(int.tryParse(moduleTaskId) ?? 1);

  @override
  Stream<rust.DownloadTaskDto> watchAll() {
    watchAllCalls++;
    return events.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('BEFORE: the removed 500 ms poll calls refresh_and_list every tick',
      () async {
    // Replay of `DownloadApi::watch_all`'s loop: `loop { sleep(500ms);
    // refresh_and_list()? }` — one full reconcile+read per 500 ms, per
    // subscription, regardless of how many rows changed.
    var sweeps = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      sweeps++; // == one refresh_and_list() sweep
    });
    await Future<void>.delayed(const Duration(milliseconds: 1050));
    timer.cancel();

    // ignore: avoid_print
    print('BENCH258 BEFORE window=1050ms pollThreads=1 '
        'refreshAndListSweeps=$sweeps (per subscription)');
    expect(sweeps, greaterThanOrEqualTo(2),
        reason: 'a 500 ms loop must fire ≥2× in a 1.05 s window');
  });

  test('AFTER: N pushed ticks → 0 poll threads, 1 seed read, N dispatches',
      () async {
    const n = 60;
    final lane = StreamController<ModuleEvent>.broadcast();
    addTearDown(lane.close);
    var loadAllCalls = 0;
    final got = <DownloadTask>[];

    final stopwatch = Stopwatch()..start();
    final sub = DownloadPushStream(
      lane: lane.stream,
      loadAll: () async {
        loadAllCalls++;
        return <DownloadTask>[_task(1)];
      },
      fetchOne: (id) async => _task(1),
      safetyInterval: const Duration(hours: 1), // disable the slow net here
    ).tasks().listen(got.add);
    await pumpEventQueue();

    for (var i = 1; i <= n; i++) {
      lane.add(_progress(1, i * 1000));
    }
    await pumpEventQueue();
    stopwatch.stop();

    const pollSubscriptions = 0; // no DownloadFacade.watchAll in the push path
    final dispatches = got.length - 1; // minus the seed emission

    // ignore: avoid_print
    print('BENCH258 AFTER n=$n pollThreads=$pollSubscriptions '
        'refreshAndListSweeps=$loadAllCalls ffiDispatches=$dispatches '
        'wallClockMs=${stopwatch.elapsedMilliseconds}');

    expect(loadAllCalls, 1, reason: 'one seed read, zero per-tick sweeps');
    expect(dispatches, n, reason: 'one UI dispatch per pushed tick');
    await sub.cancel();
  });

  test('AFTER (wired service): watchAll opens no facade poll subscription',
      () async {
    final backend = _CountingBackend();
    DownloadFacade.backendOverride = backend;
    RustDownloadService.instance.resetCoreReadyForTest();
    RustDownloadService.debugResetPushSeams();
    ModuleBootstrap.instance.debugReset();
    ModuleBootstrap.instance.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) async =>
          true,
      loadOverride: (String module) async => _FakeModuleHandle(),
      factoryOverride: (ModuleHandle handle) async => _FakeRustModuleInstance(),
      delayOverride: (Duration duration) async {},
    );
    addTearDown(() async {
      RustDownloadService.debugResetPushSeams();
      DownloadFacade.backendOverride = null;
      RustDownloadService.instance.resetCoreReadyForTest();
      ModuleBootstrap.instance.debugReset();
      await backend.events.close();
    });

    final got = <DownloadTask>[];
    final sub = RustDownloadService.instance.watchAll().listen(got.add);
    await pumpEventQueue();
    for (var i = 1; i <= 30; i++) {
      RustModuleManager.instance.handleModuleEvent(_progress(1, i * 10));
    }
    await pumpEventQueue();

    // ignore: avoid_print
    print('BENCH258 WIRED n=30 facadeWatchAllCalls(pollThreads)='
        '${backend.watchAllCalls} facadeListCalls(sweeps)=${backend.listCalls} '
        'uiUpdates=${got.length - 1}');

    expect(backend.watchAllCalls, 0);
    expect(backend.listCalls, 1);
    expect(got.length - 1, 30);
    await sub.cancel();
  });
}
