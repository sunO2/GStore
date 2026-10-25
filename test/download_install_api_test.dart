import 'dart:async';
import 'dart:io';

// fake_async 是 flutter_test 的传递依赖（未直接列入 pubspec，故忽略该 lint）。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/download/download_task_watcher.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/rust_download_service.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart' show ModuleManager;
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart' show RustModuleInstance;
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:mockito/mockito.dart';
import 'package:gstore/core/service/download_notification_service.dart';
import 'package:gstore/core/service/install_manager.dart';
import 'package:gstore/page/download/download_page_providers.dart';

/// 伪造宿主模块句柄：只被 [ModuleBootstrap.debugConfigure] 的 `loadOverride`
/// 原样返回（无 FFI）。
class _FakeModuleHandle extends Mock implements rust.ModuleHandle {}

/// 伪造模块实例：满足 `acquire('download')` 的实例创建（从不调用其方法）。
class _FakeRustModuleInstance extends Mock implements RustModuleInstance {}

class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    snapshot = CoreFlagsSnapshot(
      channels: patch.channel ?? snapshot.channels,
      catalog: patch.catalog ?? snapshot.catalog,
      update: patch.update ?? snapshot.update,
      download: patch.download ?? snapshot.download,
      install: patch.install ?? snapshot.install,
      jsChannel: patch.jsChannel ?? snapshot.jsChannel,
      coreWrites: snapshot.coreWrites,
    );
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
  String? lastInstallApkPath;

  /// [installApk] 的返回值（默认：仅发起系统安装器，未确认安装）。
  (InstallOutcome, InstallMethod) installApkResult =
      (InstallOutcome.launched, InstallMethod.system);

  /// 非空时 [installApk] 抛出该异常（用于模拟核心类型化失败）。
  Object? installApkError;

  @override
  Future<(InstallOutcome, InstallMethod)> installTask(
    String moduleTaskId,
    String filePath,
  ) async {
    installTaskCalls++;
    lastModuleTaskId = moduleTaskId;
    return (InstallOutcome.installed, InstallMethod.shizuku);
  }

  @override
  Future<(InstallOutcome, InstallMethod)> installApk(
    String filePath, {
    bool moduleInstall = false,
  }) async {
    installApkCalls++;
    lastInstallApkPath = filePath;
    final error = installApkError;
    if (error != null) throw error;
    return installApkResult;
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

DownloadTask _task(
  int id, {
  bool installAfterDownload = true,
  String fileName = 'example.apk',
}) =>
    DownloadTask(
      id: id,
      appId: 'com.example.app',
      appName: 'Example',
      version: '1.2.3',
      fileName: fileName,
      url: 'https://example.test/$fileName',
      filePath: '/tmp/$fileName',
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
    // Hermetic `download` module mount: `RustDownloadService` acquires the
    // module before its first core call; keep it off FFI/network here.
    ModuleBootstrap.instance.debugReset();
    ModuleBootstrap.instance.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) async =>
          true,
      loadOverride: (String module) async => _FakeModuleHandle(),
      factoryOverride: (rust.ModuleHandle handle) async =>
          _FakeRustModuleInstance(),
      delayOverride: (Duration duration) async {},
    );
    temp = Directory.systemTemp.createTempSync('gstore_install_api_');
    apk = File('${temp.path}/app.apk')..writeAsBytesSync(<int>[0x50, 0x4B]);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
    InstallManager.resetForTest();
    InstallFacade.resetForTest();
    DownloadFacade.backendOverride = null;
    RustDownloadService.instance.resetCoreReadyForTest();
    ModuleBootstrap.instance.debugReset();
    CoreFlags.resetBackend();
  });

  group('installTask is core-only regardless of the flag mirror', () {
    test('installTask always routes through InstallFacade', () async {
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

      expect(result, (InstallOutcome.alreadyInstalled, InstallMethod.shizuku));
      expect(install.calls, <String>['pendingRequests', 'install:task-1']);
      expect(commands, 0, reason: 'installTask has no legacy Shizuku path');
    });

    test('managePackage(uninstall) always uses the core facade', () async {
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
      expect(install.calls, <String>['uninstall:com.example.app']);
      expect(commands, 0);
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

      expect(result, (InstallOutcome.alreadyInstalled, InstallMethod.shizuku));
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

      expect(result.$1, InstallOutcome.alreadyInstalled);
      expect(downloads.calls, contains('list'));
      expect(install.calls, <String>['pendingRequests', 'install:7']);
      expect(commands, 0);
    });

    test('missing core task installs directly without core state', () async {
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

      final result = await manager.installApk(apk.path);

      expect(result, (InstallOutcome.installed, InstallMethod.shizuku));
      expect(commands, 1, reason: 'no mirrored row means the direct APK path');
      expect(install.calls, isEmpty);
      debugPrint('missing core task direct install result=$result '
          'commands=$commands');
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

      expect(result, (InstallOutcome.installed, InstallMethod.shizuku));
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

      late (InstallOutcome, InstallMethod) result;
      fakeAsync((async) {
        manager.installApk('/tmp/example.apk').then((value) => result = value);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 100));
      });

      expect(result, (InstallOutcome.failed, InstallMethod.packageInstaller));
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

      late (InstallOutcome, InstallMethod) result;
      fakeAsync((async) {
        manager.installApk('/tmp/example.apk').then((value) => result = value);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 100));
      });

      expect(result, (InstallOutcome.alreadyInstalled, InstallMethod.shizuku));
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

      // The cutover made routing flag-free: a mirror that reports download
      // false must NOT change where a call is dispatched. The one-shot legacy
      // import gate is still memoized across that mirror change.
      await _setFlags(download: false);
      backend.events.clear();
      await service.pause(8);
      expect(backend.events, <String>['pause'],
          reason: 'the flag mirror must not gate a core mutation');
      expect(backend.importCalls, 1,
          reason: 'the import gate is memoized across mirror changes');

      await service.watchAll().toList();
      expect(backend.calls, contains('watchAll'),
          reason: 'watchAll always reads the core stream, mirror-off included');
      expect(backend.importCalls, 1,
          reason: 'watchAll must not re-run the memoized import');
      debugPrint('legacy gate mirror-off: core_calls=${backend.events} '
          'calls=${backend.calls} (imports=${backend.importCalls})');
    });
  });

  group('watcher always uses installTask', () {
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

    test('download_completion_always_uses_core', () async {
      // No flag mirror at all: the watcher must still route to the core.
      final manager = _RecordingInstallManager();
      ModuleManager.instance.bind<InstallManager>(manager);
      addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

      final download = _FakeDownloadService();
      final watcher = DownloadTaskWatcher.debug()..start(download);
      addTearDown(watcher.dispose);

      download.controller.add(_task(10));
      await pumpEventQueue();

      expect(manager.installTaskCalls, 1);
      expect(manager.lastModuleTaskId, '10');
      expect(manager.installApkCalls, 0);
    });
  });

  group('download notifications stay enabled after the cutover', () {
    test('init before on* posts, including a progress post', () async {
      await _setFlags(download: true);
      DownloadNotificationService.debugResetCallCount();
      final service = DownloadNotificationService.instance;

      // `init()` MUST run before the `on*` callbacks: otherwise the service's
      // `_initialized` early-return drops every post.
      await service.init();

      service.onDownloadStart(1, 'Example', 'example.apk');
      final afterStart = DownloadNotificationService.debugPostCount;
      expect(afterStart, greaterThan(0),
          reason: 'start must post a notification even with the flag on');

      service.onDownloadProgress(1, 'Example', 'example.apk', 10, 100);
      expect(
        DownloadNotificationService.debugPostCount,
        greaterThan(afterStart),
        reason: 'progress must post a notification after init',
      );

      service.onDownloadComplete(1);
      service.onDownloadError(2, 'Example');
      service.onDownloadCancel(3);

      expect(DownloadNotificationService.debugCallCount, 5);
      expect(DownloadNotificationService.debugPostCount, greaterThan(0),
          reason: 'the Dart notification path must not be suppressed');
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
      expect(valid.segments!.single.index, 0);
      expect(valid.segments!.single.startByte, 0);
      expect(valid.segments!.single.endByte, 10);
      expect(valid.segments!.single.received, 5);
      expect(valid.headers['Authorization'], 'token');
    });
  });

  group('installApp surfaces every install outcome to the user', () {
    /// AppDialogs snackbar 需要挂载了 scaffoldMessengerKey 的 MaterialApp。
    Future<void> pumpHost(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const Scaffold(body: SizedBox()),
      ));
    }

    Future<DownloadManagerNotifier> notifierFor() async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      return container.read(downloadManagerProvider.notifier);
    }

    Future<void> bindFake(_RecordingInstallManager manager) async {
      ModuleManager.instance.bind<InstallManager>(manager);
      addTearDown(() => ModuleManager.instance.unbind<InstallManager>());
    }

    setUp(() {
      // 主机是 Linux：把平台判定接到 Android 分支，才能驱动真实 installApk 调用。
      DownloadManagerNotifier.isAndroidPlatform = () => true;
    });

    tearDown(() {
      DownloadManagerNotifier.isAndroidPlatform = () => Platform.isAndroid;
    });

    testWidgets('failed core install (false) yields a visible typed error',
        (tester) async {
      final manager = _RecordingInstallManager()
        ..installApkResult = (InstallOutcome.failed, InstallMethod.system);
      await bindFake(manager);
      await pumpHost(tester);
      final notifier = await notifierFor();

      await notifier.installApp(_task(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(manager.installApkCalls, 1,
          reason: 'the real installApp must reach installApk');
      expect(manager.lastInstallApkPath, '/tmp/example.apk');
      expect(find.textContaining('安装失败'), findsWidgets,
          reason: 'a false result must be surfaced, not swallowed');
      expect(tester.takeException(), isNull);
    });

    testWidgets('InstallCoreException surfaces its typed code', (tester) async {
      final manager = _RecordingInstallManager()
        ..installApkError = const InstallCoreException(
          'CORE_E_INSTALL_APK_MISSING',
          'CORE_E_INSTALL_INVALID_ARG: '
              'CORE_E_INSTALL_APK_MISSING: /tmp/example.apk',
        );
      await bindFake(manager);
      await pumpHost(tester);
      final notifier = await notifierFor();

      await notifier.installApp(_task(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(manager.installApkCalls, 1);
      expect(find.textContaining('CORE_E_INSTALL_APK_MISSING'), findsWidgets,
          reason: 'the typed core code must reach the user');
      expect(tester.takeException(), isNull,
          reason: 'the typed exception must not escape unhandled');
    });

    testWidgets('successful install reports success', (tester) async {
      final manager = _RecordingInstallManager()
        ..installApkResult = (InstallOutcome.installed, InstallMethod.shizuku);
      await bindFake(manager);
      await pumpHost(tester);
      final notifier = await notifierFor();

      await notifier.installApp(_task(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(manager.installApkCalls, 1);
      expect(find.textContaining('安装完成'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'launching the system installer reports a truthful pending message',
        (tester) async {
      final manager = _RecordingInstallManager()
        ..installApkResult = (InstallOutcome.launched, InstallMethod.platform);
      await bindFake(manager);
      await pumpHost(tester);
      final notifier = await notifierFor();

      await notifier.installApp(_task(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(manager.installApkCalls, 1);
      expect(find.textContaining('已发起安装，等待系统确认'), findsWidgets,
          reason: 'an intent launch must report the truthful pending message');
      expect(find.textContaining('安装完成'), findsNothing,
          reason: 'an intent launch is NOT a completed install');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an already-installed row reports 已安装, not 安装完成',
        (tester) async {
      final manager = _RecordingInstallManager()
        ..installApkResult =
            (InstallOutcome.alreadyInstalled, InstallMethod.platform);
      await bindFake(manager);
      await pumpHost(tester);
      final notifier = await notifierFor();

      await notifier.installApp(_task(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('已安装'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'non-APK file yields an explicit message and never calls installApk',
        (tester) async {
      final manager = _RecordingInstallManager();
      await bindFake(manager);
      await pumpHost(tester);
      final notifier = await notifierFor();

      await notifier.installApp(_task(1, fileName: 'payload.bin'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(manager.installApkCalls, 0,
          reason: 'a non-APK must not silently no-op nor attempt an install');
      expect(find.textContaining('不是可安装的 APK'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('non-Android platform yields an explicit message',
        (tester) async {
      DownloadManagerNotifier.isAndroidPlatform = () => false;
      final manager = _RecordingInstallManager();
      await bindFake(manager);
      await pumpHost(tester);
      final notifier = await notifierFor();

      await notifier.installApp(_task(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(manager.installApkCalls, 0);
      expect(find.textContaining('当前平台不支持安装 APK'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
