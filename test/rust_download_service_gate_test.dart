import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/download/download_module_unavailable_exception.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/rust_download_service.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

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
  final StreamController<rust.DownloadTaskDto> events =
      StreamController<rust.DownloadTaskDto>.broadcast();

  rust.DownloadTaskDto? task;
  rust.DownloadStartRequest? lastStart;
  Object? throwOn;
  bool listEmpty = false;
  int watchAllCalls = 0;

  void _maybeThrow() {
    final error = throwOn;
    if (error != null) throw error;
  }

  @override
  Future<int> start(rust.DownloadStartRequest request) async {
    calls.add('start');
    _maybeThrow();
    lastStart = request;
    return 7;
  }

  @override
  Future<List<rust.DownloadTaskDto>> list() async {
    calls.add('list');
    _maybeThrow();
    final current = listEmpty ? null : task;
    return current == null
        ? const <rust.DownloadTaskDto>[]
        : <rust.DownloadTaskDto>[current];
  }

  @override
  Future<rust.DownloadTaskDto?> get(String moduleTaskId) async {
    calls.add('get:$moduleTaskId');
    _maybeThrow();
    return task;
  }

  @override
  Future<void> pause(String moduleTaskId) async {
    calls.add('pause:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Future<void> resume(String moduleTaskId) async {
    calls.add('resume:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Future<void> cancel(String moduleTaskId) async {
    calls.add('cancel:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Future<void> retry(String moduleTaskId) async {
    calls.add('retry:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Future<void> restart(String moduleTaskId) async {
    calls.add('restart:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Future<void> remove(String moduleTaskId) async {
    calls.add('remove:$moduleTaskId');
    _maybeThrow();
  }

  @override
  Stream<rust.DownloadTaskDto> watchAll() {
    calls.add('watchAll');
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

  setUp(() {
    backend = _FakeDownloadBackend(task: _dto());
    DownloadFacade.backendOverride = backend;
    RustDownloadService.instance.resetCoreReadyForTest();
  });

  tearDown(() async {
    DownloadFacade.backendOverride = null;
    RustDownloadService.instance.resetCoreReadyForTest();
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

    test('watchAll relays the single backend stream as DownloadTask', () async {
      final future = RustDownloadService.instance.watchAll().take(1).toList();
      await pumpEventQueue();

      backend.events.add(_dto(id: 9));
      final tasks = await future;

      expect(tasks.single.id, 9);
      expect(tasks.single.status, DownloadStatusEnum.downloading);
      expect(
        backend.watchAllCalls,
        1,
        reason: 'exactly one backend stream, no Dart/module event merge',
      );
    });

    test('watch(id) filters the same backend stream by id', () async {
      final future = RustDownloadService.instance.watch(11).take(1).toList();
      await pumpEventQueue();

      backend.events.add(_dto(id: 7));
      backend.events.add(_dto(id: 11));
      final tasks = await future;

      expect(tasks.single.id, 11);
      expect(backend.watchAllCalls, 1);
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
      final errors = <Object>[];
      final sub = RustDownloadService.instance
          .watchAll()
          .listen((_) {}, onError: errors.add);
      await pumpEventQueue();

      backend.events.addError(
        Exception('CORE_E_DOWNLOAD_MODULE_UNAVAILABLE: not mounted'),
      );
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
        reason: 'the download layer must not read the module event bus:\n'
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
}
