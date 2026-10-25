/// Failing-first proof for task 258: the download service's live update source
/// must be the download module's push lane, not a facade poll stream.
///
/// On the pre-change code, `RustDownloadService.watchAll()` subscribed the
/// facade's `watchAll()` (one native 500 ms poll thread) and never observed the
/// module event bus — so `backend.watchAllCalls` was 1 and a pushed tick reached
/// the UI 0 times. This file uses only APIs that exist before the change, so it
/// compiles on both revisions and fails on the old one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/rust_download_service.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart'
    show RustModuleInstance, RustModuleManager;
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:gstore/core/rust/generated/event_bridge.dart' show ModuleEvent;
import 'package:mockito/mockito.dart';

ModuleEvent _evt(String type, Map<String, dynamic> payload) => ModuleEvent(
      moduleId: BigInt.one,
      instanceId: BigInt.one,
      eventType: type,
      data: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      timestampMs: 0,
    );

ModuleEvent _progress(int id, int received, {int total = 1000}) =>
    _evt('download.progress', {
      'taskId': id,
      'status': 2,
      'total': total,
      'received': received,
      'speedBps': 2048,
      'etaSec': 5,
    });

ModuleEvent _done(int id, int status) => _evt('download.done', {
      'id': id,
      'status': status,
      'total': 1000,
      'received': 1000,
      'speedBps': 0,
      'etaSec': null,
      'error': null,
      'segments': const <Map<String, dynamic>>[],
    });

class _FakeModuleHandle extends Mock implements ModuleHandle {}

class _FakeRustModuleInstance extends Mock implements RustModuleInstance {}

rust.DownloadTaskDto _dto(int id, {int received = 0}) => rust.DownloadTaskDto(
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
      bytesDone: received,
      total: 1000,
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

  late _CountingBackend backend;

  setUp(() {
    backend = _CountingBackend();
    DownloadFacade.backendOverride = backend;
    RustDownloadService.instance.resetCoreReadyForTest();
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
  });

  tearDown(() async {
    DownloadFacade.backendOverride = null;
    RustDownloadService.instance.resetCoreReadyForTest();
    ModuleBootstrap.instance.debugReset();
    await backend.events.close();
  });

  test(
      'a downloading task: N pushed ticks → 0 poll subscriptions, 1 seed read, N updates',
      () async {
    const n = 40;
    final got = <DownloadTask>[];
    final sub = RustDownloadService.instance.watchAll().listen(got.add);
    await pumpEventQueue();

    // The authoritative seed comes from the core read, not a poll stream.
    expect(backend.listCalls, 1);
    expect(backend.watchAllCalls, 0,
        reason: 'no facade watchAll → no native 500 ms poll thread');
    expect(got, hasLength(1));

    for (var i = 1; i <= n; i++) {
      RustModuleManager.instance.handleModuleEvent(_progress(1, i * 10));
    }
    await pumpEventQueue();

    expect(got, hasLength(1 + n),
        reason: 'the UI must still receive every pushed tick');
    expect(got.last.received, n * 10);
    expect(backend.watchAllCalls, 0,
        reason: 'still zero poll subscriptions over N ticks');
    expect(backend.listCalls, 1,
        reason: 'zero full-list refreshes per tick (seed only)');

    await sub.cancel();
  });

  test('a terminal pushed event marks the task terminal', () async {
    final got = <DownloadTask>[];
    final sub = RustDownloadService.instance.watchAll().listen(got.add);
    await pumpEventQueue();

    RustModuleManager.instance
        .handleModuleEvent(_done(1, DownloadStatusEnum.completed.index));
    await pumpEventQueue();

    expect(got.last.status, DownloadStatusEnum.completed);
    await sub.cancel();
  });
}
