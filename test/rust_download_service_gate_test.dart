import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/download/download_module_unavailable_exception.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/rust_download_service.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart' show RustModuleInstance;
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:gstore/core/rust/generated/event_bridge.dart' show ModuleEvent;
import 'package:mockito/mockito.dart';

/// Builds a host module event with the module's `emit_event` payload convention.
ModuleEvent _moduleEvent(String type, Map<String, dynamic> payload) =>
    ModuleEvent(
      moduleId: BigInt.one,
      instanceId: BigInt.one,
      eventType: type,
      data: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      timestampMs: 0,
    );

/// 伪造宿主模块句柄：只被 [ModuleBootstrap.debugConfigure] 的 `loadOverride`
/// 原样返回，从不调用其任何宿主方法（无 FFI）。
class _FakeModuleHandle extends Mock implements ModuleHandle {}

/// 伪造模块实例：`acquire('download')` 需要一个实例，但本测试从不调用它。
class _FakeRustModuleInstance extends Mock implements RustModuleInstance {}

/// Core task DTO with all the fields [DownloadTask] mapping reads.
rust.DownloadTaskDto _dto({
  int id = 7,
  String status = 'downloading',
  String destPath = '/tmp/app.apk',
}) =>
    rust.DownloadTaskDto(
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
      url: 'https://x/app.apk',
      destPath: destPath,
      status: status,
      bytesDone: 10,
      total: 100,
      speedBps: 2,
      etaSec: 5,
      segmentsJson: null,
      retries: 0,
      serverMeta: null,
      priority: 0,
      headersJson: null,
      expectedSha256: null,
      installAfterDownload: true,
      error: null,
      lastStartedAt: 7,
      createdAt: 100,
      updatedAt: 200,
    );

/// Fake transport for [DownloadFacade.backendOverride].
///
/// Records every call with its stringified id so the tests assert the exact
/// facade wiring instead of a module bus or a Floor fallback.
class _FakeDownloadBackend implements DownloadBackend {
  _FakeDownloadBackend({this.task});

  final List<String> calls = <String>[];

  /// Optional shared event log (records core calls in the same list as the
  /// module-ensure events) so tests can assert ordering, not just membership.
  List<String>? eventLog;

  final StreamController<rust.DownloadTaskDto> events =
      StreamController<rust.DownloadTaskDto>.broadcast();

  rust.DownloadTaskDto? task;
  rust.DownloadStartRequest? lastStart;
  Object? throwOn;
  bool listEmpty = false;
  int watchAllCalls = 0;

  void _record(String name) {
    calls.add(name);
    eventLog?.add(name);
  }

  void _maybeThrow() {
    final error = throwOn;
    if (error != null) throw error;
  }

  @override
  Future<int> start(rust.DownloadStartRequest request) async {
    _record('start');
    _maybeThrow();
    lastStart = request;
    return 7;
  }

  @override
  Future<List<rust.DownloadTaskDto>> list() async {
    _record('list');
    _maybeThrow();
    final current = listEmpty ? null : task;
    return current == null
        ? const <rust.DownloadTaskDto>[]
        : <rust.DownloadTaskDto>[current];
  }

  @override
  Future<rust.DownloadTaskDto?> get(String moduleTaskId) async {
    _record('get:$moduleTaskId');
    _maybeThrow();
    final current = task;
    if (current == null) return null;
    // Mirror the core: a cache-miss lookup for an id the fake was not seeded
    // with still returns that id's row (id must match the requested task).
    final requested = int.tryParse(moduleTaskId);
    if (requested != null && current.id != requested) {
      return _dto(id: requested);
    }
    return current;
  }

  @override
  Future<void> pause(String moduleTaskId) async {
    _record('pause:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Future<void> resume(String moduleTaskId) async {
    _record('resume:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Future<void> cancel(String moduleTaskId) async {
    _record('cancel:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Future<void> retry(String moduleTaskId) async {
    _record('retry:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Future<void> restart(String moduleTaskId) async {
    _record('restart:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Future<void> remove(String moduleTaskId) async {
    _record('remove:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Stream<rust.DownloadTaskDto> watchAll() {
    _record('watchAll');
    watchAllCalls++;
    return events.stream;
  }
}

/// 走绝对 saveFileName（短路 path_provider）的真实服务入口。
Future<DownloadTask> _startDownload() => RustDownloadService.instance.download(
      'com.example.app',
      '示例',
      '1.0.0',
      'https://x/app.apk',
      'app.apk',
      saveFileName: '/tmp/app.apk',
    );

/// Scans every Dart file under [root] for any of [needles].
///
/// Deliberately string/IO based (no imports of the symbols under test) so the
/// grep gates compile both before and after the legacy branches are deleted.
List<String> _scanDartTree(String root, List<String> needles) {
  final dir = Directory(root);
  if (!dir.existsSync()) return <String>[];
  final hits = <String>[];
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final content = entity.readAsStringSync();
    for (final needle in needles) {
      if (content.contains(needle)) {
        hits.add('${entity.path}: $needle');
      }
    }
  }
  return hits;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeDownloadBackend backend;

  /// Installs hermetic [ModuleBootstrap] seams so the new `download` module
  /// mount in [RustDownloadService._ensureCoreReady] never touches FFI/network.
  ///
  /// [ensureOverride] drives install+mount success; the fake handle/instance
  /// satisfy `acquire` without loading a real `.so`.
  void configureModuleSeams({
    required Future<bool> Function(
      String module, {
      required bool allowDownload,
      ModuleProgressCallback? onProgress,
    }) ensure,
  }) {
    ModuleBootstrap.instance.debugConfigure(
      ensureOverride: ensure,
      loadOverride: (String module) async => _FakeModuleHandle(),
      factoryOverride: (ModuleHandle handle) async => _FakeRustModuleInstance(),
      delayOverride: (Duration duration) async {},
    );
  }

  setUp(() {
    backend = _FakeDownloadBackend(task: _dto());
    DownloadFacade.backendOverride = backend;
    RustDownloadService.instance.resetCoreReadyForTest();
    RustDownloadService.debugResetPushSeams();
    ModuleBootstrap.instance.debugReset();
    // Default: the `download` module mounts successfully.
    configureModuleSeams(
      ensure: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) async =>
          true,
    );
  });

  tearDown(() async {
    DownloadFacade.backendOverride = null;
    RustDownloadService.instance.resetCoreReadyForTest();
    RustDownloadService.debugResetPushSeams();
    ModuleBootstrap.instance.debugReset();
    await backend.events.close();
  });

  group('B2 RustDownloadService is a DownloadFacade adapter', () {
    test('download() starts through the facade with the built request', () async {
      final task = await _startDownload();

      expect(task.id, 7, reason: 'the returned core task maps back');
      expect(backend.lastStart, isNotNull, reason: 'start must reach the backend');

      final req = backend.lastStart!;
      expect(req.appId, 'com.example.app');
      expect(req.appName, '示例');
      expect(req.version, '1.0.0');
      expect(req.fileName, 'app.apk');
      expect(req.url, 'https://x/app.apk');
      expect(req.destPath, '/tmp/app.apk');
      expect(req.kind, 'app');
      expect(req.resourceId, 'com.example.app');
      expect(req.resourceVersion, '1.0.0');
      expect(req.dedupKey, 'app:com.example.app:1.0.0:app.apk');
      expect(req.installAfterDownload, isTrue);
      expect(
        backend.calls,
        <String>['start', 'get:7'],
        reason: 'start then read-back, both through the facade',
      );
    });

    test('forceDownload restarts the newest row at the same destPath', () async {
      backend.task = _dto(id: 3, status: 'completed');

      final task = await RustDownloadService.instance.download(
        'com.example.app',
        '示例',
        '1.0.0',
        'https://x/app.apk',
        'app.apk',
        saveFileName: '/tmp/app.apk',
        forceDownload: true,
      );

      expect(task.id, 3);
      expect(backend.lastStart, isNull,
          reason: 'forceDownload must not start a second task');
      expect(backend.calls, contains('restart:3'));
      expect(
        backend.calls.any((c) => c == 'start'),
        isFalse,
        reason: 'the existing core row is restarted, not re-started',
      );
    });

    test('forceDownload without an existing row falls through to start',
        () async {
      backend.listEmpty = true;

      await RustDownloadService.instance.download(
        'com.example.app',
        '示例',
        '1.0.0',
        'https://x/app.apk',
        'app.apk',
        saveFileName: '/tmp/app.apk',
        forceDownload: true,
      );

      expect(backend.calls, contains('start'));
      expect(
        backend.calls.any((c) => c.startsWith('restart:')),
        isFalse,
        reason: 'nothing to restart when no row shares the destPath',
      );
    });

    test('downloadWithContext forwards request headers end-to-end', () async {
      final request = DownloadRequest(
        url: 'https://x/app.apk',
        savePath: '/tmp/app.apk',
        headers: const <String, String>{
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'GStore/1.0',
        },
      );

      await RustDownloadService.instance.downloadWithContext(
        request,
        'com.example.app',
        '示例',
        '1.0.0',
        'app.apk',
      );

      expect(backend.lastStart!.headers, <String, String>{
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'GStore/1.0',
      });
    });

    test('plain download() sends no headers', () async {
      await _startDownload();

      expect(backend.lastStart!.headers, isEmpty);
    });

    test('getTask/listTasks map the backend DTOs', () async {
      final one = await RustDownloadService.instance.getTask(7);
      final many = await RustDownloadService.instance.listTasks();

      expect(one?.id, 7);
      expect(one?.appId, 'com.example.app');
      expect(many.single.id, 7);
      expect(backend.calls, contains('get:7'));
      expect(backend.calls, contains('list'));
    });

    test('pause/resume/cancel/retry/restart/remove forward stringified ids',
        () async {
      final svc = RustDownloadService.instance;

      await svc.pause(7);
      await svc.resume(7);
      await svc.cancel(7);
      await svc.retry(7);
      await svc.restart(7);
      await svc.remove(7);

      expect(
        backend.calls,
        <String>[
          'pause:7',
          'resume:7',
          'cancel:7',
          'retry:7',
          'restart:7',
          'remove:7',
        ],
      );
    });

    test('watchAll is driven by the download module push lane', () async {
      final lane = StreamController<ModuleEvent>.broadcast();
      addTearDown(lane.close);
      RustDownloadService.downloadEventLaneOverride = () => lane.stream;

      final got = <DownloadTask>[];
      final sub = RustDownloadService.instance.watchAll().listen(got.add);
      await pumpEventQueue();

      // Seed: the authoritative core read supplies full metadata exactly once.
      expect(got.single.id, 7);

      lane.add(_moduleEvent('download.progress', {
        'taskId': 7,
        'status': DownloadStatusEnum.downloading.index,
        'total': 100,
        'received': 55,
        'speedBps': 2,
        'etaSec': 5,
      }));
      await pumpEventQueue();

      expect(got.last.received, 55);
      expect(got.last.status, DownloadStatusEnum.downloading);
      expect(
        backend.watchAllCalls,
        0,
        reason: 'the module push lane is the only live source; no facade poll',
      );
      await sub.cancel();
    });

    test('watch(id) filters the push lane by id', () async {
      final lane = StreamController<ModuleEvent>.broadcast();
      addTearDown(lane.close);
      RustDownloadService.downloadEventLaneOverride = () => lane.stream;

      final got = <DownloadTask>[];
      final sub = RustDownloadService.instance.watch(11).listen(got.add);
      await pumpEventQueue();

      lane.add(_moduleEvent('download.progress', {
        'taskId': 7,
        'status': DownloadStatusEnum.downloading.index,
        'total': 100,
        'received': 10,
      }));
      lane.add(_moduleEvent('download.progress', {
        'taskId': 11,
        'status': DownloadStatusEnum.downloading.index,
        'total': 100,
        'received': 10,
      }));
      await pumpEventQueue();

      expect(got, isNotEmpty);
      expect(got.map((task) => task.id), everyElement(11));
      expect(backend.watchAllCalls, 0);
      await sub.cancel();
    });
  });

  group('B2 typed unavailability at the facade boundary', () {
    test('backend CORE_E_DOWNLOAD_MODULE_UNAVAILABLE becomes typed', () async {
      backend.throwOn = Exception(
        'CORE_E_DOWNLOAD_MODULE_UNAVAILABLE: download module is not mounted',
      );

      await expectLater(
        _startDownload(),
        throwsA(isA<DownloadModuleUnavailableException>().having(
          (e) => '$e',
          'toString',
          contains('CORE_E_DOWNLOAD_MODULE_UNAVAILABLE'),
        )),
      );
    });

    test('an embedded code substring is not treated as unavailability',
        () async {
      final raw = Exception(
        'CORE_E_DOWNLOAD_INVALID_ARG: file name contains '
        'CORE_E_DOWNLOAD_MODULE_UNAVAILABLE',
      );
      backend.throwOn = raw;

      await expectLater(_startDownload(), throwsA(same(raw)));
    });

    test('other backend errors pass through unchanged', () async {
      final raw = StateError('boom');

      backend.throwOn = raw;

      await expectLater(_startDownload(), throwsA(same(raw)));
    });

    test('watchAll stream errors carrying the code become typed', () async {
      backend.throwOn = Exception(
        'CORE_E_DOWNLOAD_MODULE_UNAVAILABLE: not mounted',
      );
      final errors = <Object>[];
      final sub = RustDownloadService.instance
          .watchAll()
          .listen((_) {}, onError: errors.add);
      await pumpEventQueue();

      expect(errors.single, isA<DownloadModuleUnavailableException>());
      await sub.cancel();
    });
  });

  group('B2 legacy-removal grep gate', () {
    test('lib/ has no module-direct _invoke(\'download. call', () {
      final hits = _scanDartTree('lib', <String>["_invoke('download."]);
      expect(
        hits,
        isEmpty,
        reason: 'the module-direct download route must be deleted:\n'
            '${hits.join('\n')}',
      );
    });

    test('lib/core/download/ does not touch RustModuleManager', () {
      final hits = _scanDartTree(
        'lib/core/download',
        <String>['RustModuleManager'],
      );
      expect(
        hits,
        isEmpty,
        reason: 'the download layer must reach the module bus through the '
            'typed DownloadEventSource gateway, never RustModuleManager '
            'directly:\n${hits.join('\n')}',
      );
    });

    test('lib/core/download/ never opens the facade poll stream', () {
      // The 500 ms poll is gone: the only live source is the module push lane.
      // If a future edit re-adds `DownloadFacade.instance.watchAll()` here, the
      // per-subscription 500 ms native poll thread comes back.
      final hits = _scanDartTree(
        'lib/core/download',
        <String>['DownloadFacade.instance.watchAll'],
      );
      expect(
        hits,
        isEmpty,
        reason: 'the download layer must not open the 500 ms core poll:\n'
            '${hits.join('\n')}',
      );
    });

    test('lib/core/download/ does not read CoreFlags.download', () {
      final hits = _scanDartTree(
        'lib/core/download',
        <String>['CoreFlags.download'],
      );
      expect(
        hits,
        isEmpty,
        reason: 'the download layer must be flag-free after the cutover:\n'
            '${hits.join('\n')}',
      );
    });
  });

  group('download module ensure gate', () {
    late List<String> events;
    late List<String> ensureModules;

    setUp(() {
      events = <String>[];
      ensureModules = <String>[];
      backend.eventLog = events;
      configureModuleSeams(
        ensure: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          ensureModules.add(module);
          events.add('ensure:$module');
          return true;
        },
      );
    });

    tearDown(() {
      backend.eventLog = null;
    });

    test('mounts the download module before the first core call', () async {
      await _startDownload();

      expect(ensureModules, <String>['download'],
          reason: 'the download module must be ensured exactly once');
      expect(
        events,
        <String>['ensure:download', 'start', 'get:7'],
        reason: 'the mount must resolve BEFORE any core call (start/get)',
      );
    });

    test('the ensure is one-shot: memoized across every entry point', () async {
      await _startDownload();
      await RustDownloadService.instance.getTask(7);
      await RustDownloadService.instance.listTasks();

      expect(ensureModules, <String>['download'],
          reason: 'one-shot: the second/third entry points reuse the memo');
      expect(events.where((e) => e == 'ensure:download').length, 1);
    });

    test('a failed ensure surfaces the typed error and never calls the core',
        () async {
      configureModuleSeams(
        ensure: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async =>
            false,
      );

      await expectLater(
        _startDownload(),
        throwsA(isA<DownloadModuleUnavailableException>().having(
          (e) => '$e',
          'toString',
          contains('CORE_E_DOWNLOAD_MODULE_UNAVAILABLE'),
        )),
      );
      expect(
        backend.calls,
        isEmpty,
        reason: 'no core call and no Dart fallback when the module cannot mount',
      );
    });
  });
}
