import 'dart:async';
import 'dart:io';

// fake_async 是 flutter_test 的传递依赖（未直接列入 pubspec，故忽略该 lint）。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/download/download_task_watcher.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/rust_download_service.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart' show ModuleManager;
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/service/download_notification_service.dart';
import 'package:gstore/core/service/install_manager.dart';

class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsSnapshot flags) async {
    snapshot = flags;
  }
}

Future<void> _setFlags({bool download = false, bool install = false}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(
      CoreFlagsSnapshot(download: download, install: install),
    ),
  );
  await CoreFlags.refresh();
}

rust.DownloadTaskDto _dto({
  int id = 7,
  String moduleTaskId = '7',
  String status = 'completed',
  String? error,
  int? lastStartedAt = 7,
  int createdAt = 100,
  int updatedAt = 200,
  String? segmentsJson,
  String? headersJson,
  String destPath = '/tmp/example.apk',
}) =>
    rust.DownloadTaskDto(
      id: id,
      moduleTaskId: moduleTaskId,
      dedupKey: 'dedup:$id',
      appId: 'com.example.app',
      appName: 'Example',
      version: '1.2.3',
      fileName: 'example.apk',
      kind: 'app',
      resourceId: 'com.example.app',
      resourceVersion: '1.2.3',
      url: 'https://example.test/example.apk',
      destPath: destPath,
      status: status,
      bytesDone: 10,
      total: 100,
      speedBps: 2,
      etaSec: 5,
      segmentsJson: segmentsJson,
      retries: 0,
      serverMeta: null,
      priority: 0,
      headersJson: headersJson,
      expectedSha256: null,
      installAfterDownload: true,
      error: error,
      lastStartedAt: lastStartedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

class _FakeDownloadBackend implements DownloadBackend {
  final List<String> calls = <String>[];
  final List<rust.DownloadTaskDto> streamed = <rust.DownloadTaskDto>[];
  rust.DownloadTaskDto? task = _dto();

  @override
  Future<int> start(rust.DownloadStartRequest request) async {
    calls.add('start:${request.destPath}');
    return 7;
  }

  @override
  Future<List<rust.DownloadTaskDto>> list() async {
    calls.add('list');
    final current = task;
    return current == null
        ? const <rust.DownloadTaskDto>[]
        : <rust.DownloadTaskDto>[current];
  }

  @override
  Future<rust.DownloadTaskDto?> get(String moduleTaskId) async {
    calls.add('get:$moduleTaskId');
    return task;
  }

  @override
  Future<void> pause(String moduleTaskId) async =>
      calls.add('pause:$moduleTaskId');

  @override
  Future<void> resume(String moduleTaskId) async =>
      calls.add('resume:$moduleTaskId');

  @override
  Future<void> cancel(String moduleTaskId) async =>
      calls.add('cancel:$moduleTaskId');

  @override
  Future<void> retry(String moduleTaskId) async =>
      calls.add('retry:$moduleTaskId');

  @override
  Future<void> restart(String moduleTaskId) async =>
      calls.add('restart:$moduleTaskId');

  @override
  Future<void> remove(String moduleTaskId) async =>
      calls.add('remove:$moduleTaskId');

  @override
  Stream<rust.DownloadTaskDto> watchAll() async* {
    calls.add('watchAll');
    yield* Stream<rust.DownloadTaskDto>.fromIterable(streamed);
  }
}

/// Fake backend that also exposes the legacy-import capability, recording the
/// exact order of import vs. core reads/mutations.
class _LegacyRecordingDownloadBackend extends _FakeDownloadBackend
    implements DownloadLegacyImport {
  final List<String> events = <String>[];
  int importCalls = 0;

  @override
  Future<void> importLegacyOnce(
      {String? floorDbPath, String? moduleDbPath}) async {
    importCalls++;
    events.add('import');
  }

  @override
  Future<List<rust.DownloadTaskDto>> list() async {
    events.add('list');
    return super.list();
  }

  @override
  Future<rust.DownloadTaskDto?> get(String moduleTaskId) async {
    events.add('get');
    return super.get(moduleTaskId);
  }

  @override
  Future<void> pause(String moduleTaskId) async {
    events.add('pause');
    return super.pause(moduleTaskId);
  }
}

class _FakeInstallBackend implements InstallBackend {
  final List<String> calls = <String>[];
  InstallRecord record = const InstallRecord(
    moduleTaskId: 'task-1',
    appId: 'com.example.app',
    status: 'installed',
    method: 'shizuku',
  );

  /// Request returned by [install]; null = the core settled the row.
  InstallRequest? request;

  @override
  Future<InstallStart> install(String moduleTaskId) async {
    calls.add('install:$moduleTaskId');
    return InstallStart(record: record, request: request);
  }

  @override
  Future<List<InstallStart>> pendingRequests() async {
    calls.add('pendingRequests');
    return const <InstallStart>[];
  }

  @override
  Future<InstallResultAck> reportResult(InstallReport report) async {
    calls.add('reportResult:${report.status}');
    return InstallResultAck(
      sessionId: report.sessionId,
      status: report.status,
      changed: true,
    );
  }

  @override
  Future<List<String>> takeEvents() async {
    calls.add('takeEvents');
    return const <String>[];
  }

  @override
  Future<InstallRecord?> get(String moduleTaskId) async {
    calls.add('get:$moduleTaskId');
    return record;
  }

  @override
  Future<void> uninstall(String packageName) async =>
      calls.add('uninstall:$packageName');

  @override
  Future<void> launch(String packageName) async =>
      calls.add('launch:$packageName');
}

/// Pending on install, then terminal on the second `get`.
class _PollingInstallBackend extends _FakeInstallBackend {
  static const InstallRecord _pending = InstallRecord(
    moduleTaskId: '7',
    appId: 'com.example.app',
    status: 'pending',
    method: 'package_installer',
  );
  static const InstallRecord _installed = InstallRecord(
    moduleTaskId: '7',
    appId: 'com.example.app',
    status: 'installed',
    method: 'package_installer',
  );

  int getCalls = 0;
  int pendingRequestsCalls = 0;

  @override
  Future<InstallStart> install(String moduleTaskId) async {
    calls.add('install:$moduleTaskId');
    return const InstallStart(record: _pending);
  }

  @override
  Future<List<InstallStart>> pendingRequests() async {
    pendingRequestsCalls++;
    calls.add('pendingRequests');
    return const <InstallStart>[];
  }

  @override
  Future<InstallRecord?> get(String moduleTaskId) async {
    getCalls++;
    calls.add('get:$moduleTaskId');
    return getCalls >= 2 ? _installed : _pending;
  }
}

class _RecordingInstallManager implements InstallManager {
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
    return (true, InstallMethod.shizuku);
  }

  @override
  Future<(bool, InstallMethod)> installApk(
    String filePath, {
    bool moduleInstall = false,
  }) async {
    installApkCalls++;
    return (true, InstallMethod.system);
  }

  @override
  Future<int> consumeInstallRequests() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDownloadService implements IDownloadService {
  final StreamController<DownloadTask> controller =
      StreamController<DownloadTask>.broadcast();

  @override
  Stream<DownloadTask> watchAll() => controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadTask _task(int id, {bool installAfterDownload = true}) => DownloadTask(
      id: id,
      appId: 'com.example.app',
      appName: 'Example',
      version: '1.2.3',
      fileName: 'example.apk',
      url: 'https://example.test/example.apk',
      filePath: '/tmp/example.apk',
      total: 100,
      received: 100,
      status: DownloadStatusEnum.completed,
      speedBps: 0,
      etaSec: null,
      error: null,
      segments: null,
      installAfterDownload: installAfterDownload,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late File apk;

  setUp(() {
    InstallManager.resetForTest();
    InstallFacade.resetForTest();
    DownloadFacade.backendOverride = null;
    RustDownloadService.instance.resetCoreReadyForTest();
    temp = Directory.systemTemp.createTempSync('gstore_install_api_');
    apk = File('${temp.path}/app.apk')..writeAsBytesSync(<int>[0x50, 0x4B]);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
    InstallManager.resetForTest();
    InstallFacade.resetForTest();
    DownloadFacade.backendOverride = null;
    RustDownloadService.instance.resetCoreReadyForTest();
    CoreFlags.resetBackend();
  });

  group('install flag off keeps the legacy path', () {
    test('installTask delegates to installApk and never touches InstallFacade',
        () async {
      final install = _FakeInstallBackend();
      InstallFacade.installBackendForTest(install);
      InstallManager.commandRunnerForTest = (_) async => 'Success';
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      final result = await manager.installTask('task-1', apk.path);

      expect(result, (true, InstallMethod.shizuku));
      expect(install.calls, isEmpty, reason: 'flag off must not use core');
    });

    test('managePackage(uninstall) keeps the Shizuku runner', () async {
      final install = _FakeInstallBackend();
      InstallFacade.installBackendForTest(install);
      var commands = 0;
      InstallManager.commandRunnerForTest = (_) async {
        commands++;
        return 'Success';
      };
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      final ok = await manager.managePackage('com.example.app', 'uninstall');

      expect(ok, isTrue);
      expect(commands, 1);
      expect(install.calls, isEmpty);
    });
  });

  group('install flag on routes through InstallFacade only', () {
    test('installTask and managePackage never touch Shizuku/AppInstaller',
        () async {
      await _setFlags(install: true);
      final install = _FakeInstallBackend();
      InstallFacade.installBackendForTest(install);
      var commands = 0;
      InstallManager.commandRunnerForTest = (_) async {
        commands++;
        return 'Success';
      };
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      final result = await manager.installTask('task-1', apk.path);
      final uninstalled =
          await manager.managePackage('com.example.app', 'uninstall');

      expect(result, (true, InstallMethod.shizuku));
      expect(uninstalled, isTrue);
      expect(install.calls, <String>[
        'pendingRequests',
        'install:task-1',
        'uninstall:com.example.app',
      ]);
      expect(commands, 0, reason: 'core branch must not run Shizuku commands');
    });

    test('installApk resolves a core download by dest_path', () async {
      await _setFlags(install: true);
      final install = _FakeInstallBackend();
      InstallFacade.installBackendForTest(install);
      final downloads = _FakeDownloadBackend();
      DownloadFacade.backendOverride = downloads;
      var commands = 0;
      InstallManager.commandRunnerForTest = (_) async {
        commands++;
        return 'Success';
      };
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      final result = await manager.installApk('/tmp/example.apk');

      expect(result.$1, isTrue);
      expect(downloads.calls, contains('list'));
      expect(install.calls, <String>['pendingRequests', 'install:7']);
      expect(commands, 0);
    });

    test('missing core task never falls back to Shizuku/AppInstaller', () async {
      await _setFlags(install: true);
      final install = _FakeInstallBackend();
      InstallFacade.installBackendForTest(install);
      final downloads = _FakeDownloadBackend();
      downloads.task = _dto(destPath: '/tmp/somewhere-else.apk');
      DownloadFacade.backendOverride = downloads;
      var commands = 0;
      InstallManager.commandRunnerForTest = (_) async {
        commands++;
        return 'Success';
      };
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      final result = await manager.installApk('/tmp/example.apk');

      expect(result, (false, InstallMethod.system));
      expect(commands, 0, reason: 'flag-on app install has no legacy fallback');
      expect(install.calls, isEmpty);
      debugPrint('flag-on missing core task result=$result commands=$commands');
    });

    test('explicit module APK keeps the module legacy path', () async {
      await _setFlags(install: true);
      final install = _FakeInstallBackend();
      InstallFacade.installBackendForTest(install);
      final downloads = _FakeDownloadBackend();
      downloads.task = _dto(destPath: '/tmp/somewhere-else.apk');
      DownloadFacade.backendOverride = downloads;
      var commands = 0;
      InstallManager.commandRunnerForTest = (_) async {
        commands++;
        return 'Success';
      };
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      final result =
          await manager.installApk(apk.path, moduleInstall: true);

      expect(result, (true, InstallMethod.shizuku));
      expect(commands, 1);
      expect(install.calls, isEmpty);
      debugPrint('module APK result=$result commands=$commands');
    });

    test('installApk imports legacy before the first core list', () async {
      await _setFlags(install: true);
      final install = _FakeInstallBackend();
      InstallFacade.installBackendForTest(install);
      final downloads = _LegacyRecordingDownloadBackend();
      DownloadFacade.backendOverride = downloads;
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      await manager.installApk('/tmp/example.apk');

      expect(downloads.events.take(2), <String>['import', 'list']);
      expect(downloads.importCalls, 1);
      debugPrint('install import order: ${downloads.events}');
    });

    test('pending core install pumps reconcile+get until terminal', () async {
      await _setFlags(install: true);
      final install = _PollingInstallBackend();
      InstallFacade.installBackendForTest(install);
      DownloadFacade.backendOverride = _FakeDownloadBackend();
      InstallManager.installPollInterval = const Duration(milliseconds: 10);
      InstallManager.installPollTimeout = const Duration(seconds: 1);
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      late (bool, InstallMethod) result;
      fakeAsync((async) {
        manager.installApk('/tmp/example.apk').then((value) => result = value);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 100));
      });

      expect(result, (false, InstallMethod.packageInstaller));
      expect(install.getCalls, 2, reason: 'pending then terminal ends the pump');
      expect(install.pendingRequestsCalls, 3,
          reason: 'one recovery sweep plus one sweep per poll');
      expect(
        install.calls.where((call) => call.startsWith('get:')),
        <String>['get:7', 'get:7'],
      );
      debugPrint('install pump calls: ${install.calls}');
    });

    test('terminal core record starts no poller', () async {
      await _setFlags(install: true);
      final install = _FakeInstallBackend();
      InstallFacade.installBackendForTest(install);
      DownloadFacade.backendOverride = _FakeDownloadBackend();
      InstallManager.installPollInterval = const Duration(milliseconds: 10);
      InstallManager.installPollTimeout = const Duration(seconds: 1);
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      late (bool, InstallMethod) result;
      fakeAsync((async) {
        manager.installApk('/tmp/example.apk').then((value) => result = value);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 100));
      });

      expect(result, (true, InstallMethod.shizuku));
      expect(install.calls.where((call) => call.startsWith('get:')), isEmpty);
      expect(
        install.calls.where((call) => call == 'pendingRequests'),
        hasLength(1),
        reason: 'only the pre-install recovery sweep runs',
      );
      debugPrint('terminal install calls: ${install.calls}');
    });
  });

  group('download flag on routes through DownloadFacade', () {
    test('download/get/pause all use the core facade', () async {
      await _setFlags(download: true);
      final backend = _FakeDownloadBackend();
      DownloadFacade.backendOverride = backend;
      final service = RustDownloadService.instance;
      final started = await service.download(
        'com.example.app',
        'Example',
        '1.2.3',
        'https://example.test/example.apk',
        'example.apk',
        saveFileName: '${temp.path}/example.apk',
      );
      await service.pause(7);
      final fetched = await service.getTask(7);

      expect(started.status, DownloadStatusEnum.completed);
      expect(fetched?.id, 7);
      expect(
        backend.calls,
        <String>[
          'start:${temp.path}/example.apk',
          'get:7',
          'pause:7',
          'get:7',
        ],
      );
    });
  });

  group('legacy import gates every core read', () {
    test('import resolves before list/get/pause and is memoized', () async {
      await _setFlags(download: true);
      final backend = _LegacyRecordingDownloadBackend();
      DownloadFacade.backendOverride = backend;
      final service = RustDownloadService.instance;

      final tasks = await service.listTasks();
      expect(tasks, hasLength(1));
      expect(backend.events, <String>['import', 'list'],
          reason: 'the import must resolve before the core list read');
      expect(backend.importCalls, 1);
      debugPrint('legacy gate after listTasks: ${backend.events} '
          '(imports=${backend.importCalls})');

      await service.pause(7);
      expect(backend.events, <String>['import', 'list', 'pause'],
          reason: 'the import must resolve before a core mutation');
      expect(backend.importCalls, 1,
          reason: 'the import gate is memoized across flag-on calls');
      debugPrint('legacy gate after pause: ${backend.events} '
          '(imports=${backend.importCalls})');

      final fetched = await service.getTask(7);
      expect(fetched?.id, 7);
      expect(backend.events, <String>['import', 'list', 'pause', 'get']);
      expect(backend.importCalls, 1);
      debugPrint('legacy gate after getTask: ${backend.events} '
          '(imports=${backend.importCalls})');

      // Flag-off legacy streams are lazy and must not touch the core backend
      // or re-run the import.
      await _setFlags(download: false);
      backend.events.clear();
      final legacyStream = service.watchAll();
      expect(legacyStream, isA<Stream<DownloadTask>>());
      final legacyWatch = service.watch(7);
      expect(legacyWatch, isA<Stream<DownloadTask>>());
      expect(backend.events, isEmpty,
          reason: 'flag-off must make zero core calls');
      expect(backend.importCalls, 1,
          reason: 'flag-off must not trigger another import');
      debugPrint('legacy gate flag-off: core_calls=${backend.events} '
          '(imports=${backend.importCalls})');
    });
  });

  group('watcher flag on uses installTask', () {
    test('completed task calls installTask and never installApk', () async {
      await _setFlags(install: true);
      final manager = _RecordingInstallManager();
      ModuleManager.instance.bind<InstallManager>(manager);
      addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

      final download = _FakeDownloadService();
      final watcher = DownloadTaskWatcher.debug()..start(download);
      addTearDown(watcher.dispose);

      download.controller.add(_task(9));
      await pumpEventQueue();

      expect(manager.installTaskCalls, 1);
      expect(manager.lastModuleTaskId, '9');
      expect(manager.installApkCalls, 0);
    });
  });

  group('notification flag on posts nothing', () {
    test('all posting entry points keep debugPostCount at zero', () async {
      await _setFlags(download: true);
      DownloadNotificationService.debugResetCallCount();
      final service = DownloadNotificationService.instance;

      service.onDownloadStart(1, 'Example', 'example.apk');
      service.onDownloadProgress(1, 'Example', 'example.apk', 10, 100);
      service.onDownloadComplete(1);
      service.onDownloadError(2, 'Example');
      service.onDownloadCancel(3);
      await service.startForegroundService();
      await service.init();

      expect(DownloadNotificationService.debugCallCount, 5);
      expect(DownloadNotificationService.debugPostCount, 0);
    });
  });

  group('DownloadTaskDto mapping', () {
    test('needs_restart becomes paused and keeps the raw status', () {
      final task = toDownloadTask(_dto(status: 'needs_restart'));

      expect(task.status, DownloadStatusEnum.paused);
      expect(task.error, 'needs_restart');
    });

    test('id prefers module_task_id and falls back to the core id', () {
      expect(toDownloadTask(_dto(moduleTaskId: '42')).id, 42);
      expect(toDownloadTask(_dto(moduleTaskId: 'not-a-number', id: 5)).id, 5);
    });

    test('epoch seconds are normalized but milliseconds are preserved', () {
      final task = toDownloadTask(
        _dto(lastStartedAt: 7, createdAt: 100, updatedAt: 1700000000000),
      );

      expect(task.lastStartedAt, 7000);
      expect(task.createdAt.millisecondsSinceEpoch, 100000);
      expect(task.updatedAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('malformed segments/headers json is empty, valid json is parsed', () {
      final malformed = toDownloadTask(
        _dto(segmentsJson: '{bad', headersJson: 'not-json'),
      );
      expect(malformed.segments, isEmpty);
      expect(malformed.headers, isEmpty);

      final valid = toDownloadTask(
        _dto(
          segmentsJson: '[{"index":0,"startByte":0,"endByte":10,"received":5}]',
          headersJson: '{"Authorization":"token"}',
        ),
      );
      expect(valid.segments, hasLength(1));
      expect(valid.segments!.single.received, 5);
      expect(valid.headers['Authorization'], 'token');
    });
  });
}
