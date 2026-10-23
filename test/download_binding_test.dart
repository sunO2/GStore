import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/download/download_module_unavailable_exception.dart';
import 'package:gstore/core/download/download_task_watcher.dart';
import 'package:gstore/core/download/manager/download_manager.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/rust_download_service.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Wave 6B-B1 binding contract.
///
/// This file is deliberately written against the *public* surface only: the
/// typed exception is asserted by its observable code string (and runtime type
/// name) so the failing-first run against the lazy router is a real assertion
/// failure, not a compile break caused by importing a not-yet-created class.

/// Minimal module used to satisfy `DownloadModule.dependencies`.
class _NoopModule extends AppModule {
  _NoopModule(this.moduleName);

  @override
  final String moduleName;
}

/// The Dart fallback that must never be reached or bound after B1.
///
/// It claims to be a [DownloadManager] so the pre-change wiring (which did
/// `require<DownloadManager>()`) can resolve it; `download` would silently
/// succeed, which is exactly the degradation B1 removes.
class _FakeDartDownloadManager implements DownloadManager {
  int downloadCalls = 0;

  @override
  Future<DownloadTask> download(
    String appid,
    String appName,
    String version,
    String url,
    String fileName, {
    int? downloadSize,
    bool breakPoint = true,
    String? saveFileName,
    bool forceDownload = false,
    bool installAfterDownload = true,
  }) async {
    downloadCalls++;
    return _task(1);
  }

  @override
  Stream<DownloadTask> watchAll() => const Stream<DownloadTask>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Silent backend for binding-only tests: module registration subscribes the
/// watcher, and a real FRB backend would try to load the native bridge.
class _InertDownloadBackend implements DownloadBackend {
  @override
  Stream<rust.DownloadTaskDto> watchAll() =>
      const Stream<rust.DownloadTaskDto>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Backend whose only failure mode is "the Rust download module is not
/// mounted", mirroring the production FRB error text.
class _UnavailableDownloadBackend implements DownloadBackend {
  @override
  Future<int> start(rust.DownloadStartRequest request) async {
    throw Exception(
      'CORE_E_DOWNLOAD_MODULE_UNAVAILABLE: download module is not mounted',
    );
  }

  /// The watcher subscribes on module registration; an unmounted core simply
  /// has no events to relay.
  @override
  Stream<rust.DownloadTaskDto> watchAll() =>
      const Stream<rust.DownloadTaskDto>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// All-flags-off backend: keeps `CoreFlags.refresh()` hermetic (no FFI) without
/// changing any flag value.
class _DisabledFlagsBackend implements CoreFlagsBackend {
  @override
  Future<CoreFlagsSnapshot> read() async => CoreFlagsSnapshot.disabled;

  @override
  Future<void> write(CoreFlagsPatch patch) async {}
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
      status: DownloadStatusEnum.queued,
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

  final manager = ModuleManager.instance;

  setUp(() async {
    await manager.clear();
    manager.injectContext(ModuleContext(
      config: null,
      bindService: (type, impl) => manager.bindByType(type, impl),
      unbindService: (type) => manager.unbindByType(type),
      manager: manager,
    ));
    DownloadTaskWatcher.instance.dispose();
    DownloadTaskWatcher.instance.debugStartCount = 0;
    CoreFlags.installBackend(_DisabledFlagsBackend());
    DownloadFacade.backendOverride = null;
    RustDownloadService.instance.resetCoreReadyForTest();
  });

  tearDown(() async {
    DownloadTaskWatcher.instance.dispose();
    DownloadTaskWatcher.instance.debugStartCount = 0;
    CoreFlags.resetBackend();
    DownloadFacade.backendOverride = null;
    RustDownloadService.instance.resetCoreReadyForTest();
    manager.injectContext(null);
    await manager.clear();
  });

  /// Drives the real `ModuleManager` registration path:
  /// register (no-op deps) -> initializeModule -> onInit/onRegister.
  Future<IDownloadService> registerDownloadModule() async {
    // Registration subscribes DownloadTaskWatcher to the real service; keep
    // that stream inert so no FFI/network is touched.
    DownloadFacade.backendOverride = _InertDownloadBackend();
    // Pre-change wiring needs a Dart implementation to resolve; post-change it
    // must be ignored. Keeping it bound also proves it is not what gets bound.
    manager.bind<DownloadManager>(_FakeDartDownloadManager());
    await manager.registerModule(_NoopModule('channel'));
    await manager.registerModule(_NoopModule('config'));
    await manager.registerModule(DownloadModule());
    await manager.initializeModule('download');
    return manager.require<IDownloadService>();
  }

  group('B1 download binding', () {
    test('real ModuleManager registration binds RustDownloadService.instance',
        () async {
      final bound = await registerDownloadModule();

      expect(
        identical(bound, RustDownloadService.instance),
        isTrue,
        reason: 'DownloadModule.onRegister must bind RustDownloadService.instance '
            'directly, got ${bound.runtimeType}',
      );
      expect(
        bound.runtimeType.toString(),
        isNot(contains('Lazy')),
        reason: 'the lazy router must not survive the direct binding',
      );
      expect(manager.get<IDownloadService>(), same(bound));
    });

    test(
        'module unavailable fails typed with CORE_E_DOWNLOAD_MODULE_UNAVAILABLE '
        'and no Dart fallback', () async {
      final bound = await registerDownloadModule();
      final dartFallback = manager.get<DownloadManager>();

      // The facade backend is the only FFI boundary: make it report the core
      // module as unmounted, exactly like the Rust error code would.
      DownloadFacade.backendOverride = _UnavailableDownloadBackend();

      Object? thrown;
      try {
        await bound.download(
          'com.example.app',
          'App',
          '1.0.0',
          'https://example.com/app.apk',
          'app.apk',
          saveFileName: '/tmp/app.apk',
        );
      } catch (error) {
        thrown = error;
      }

      expect(
        thrown,
        isNotNull,
        reason: 'module-unavailable must not silently succeed or fall back',
      );
      expect(
        thrown,
        isA<DownloadModuleUnavailableException>(),
        reason: 'the facade must map the core code onto the typed exception',
      );
      expect(
        '$thrown',
        contains('CORE_E_DOWNLOAD_MODULE_UNAVAILABLE'),
        reason: 'the Dart-observable error code must reach the caller',
      );
      expect(
        thrown.runtimeType.toString(),
        'DownloadModuleUnavailableException',
        reason: 'the failure must be the typed download-layer exception',
      );

      // No fallback binding: the interface still points at the Rust service,
      // never at the Dart implementation.
      expect(
        identical(manager.get<IDownloadService>(), RustDownloadService.instance),
        isTrue,
        reason: 'a failed acquire must not rebind a Dart implementation',
      );
      expect(
        identical(manager.get<IDownloadService>(), dartFallback),
        isFalse,
        reason: 'the Dart DownloadManager must never be the bound fallback',
      );
      expect(dartFallback, isA<DownloadManager>());
    });

    test('typed exception exposes a non-empty userMessage containing the code',
        () {
      final error = DownloadModuleUnavailableException(StateError('boom'));

      expect(error.userMessage, isNotEmpty);
      expect(
        error.userMessage,
        contains(DownloadModuleUnavailableException.code),
      );
      expect(
        DownloadModuleUnavailableException.code,
        'CORE_E_DOWNLOAD_MODULE_UNAVAILABLE',
      );
    });

    test('source gate: lazy router, its config class and key are gone from lib/',
        () {
      const needles = <String>[
        'DownloadCoreConfig',
        'LazyDownloadService',
        'download.core',
      ];
      final hits = <String>[];
      final root = Directory('lib');
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart') && !entity.path.endsWith('.md')) {
          continue;
        }
        final content = entity.readAsStringSync();
        for (final needle in needles) {
          if (content.contains(needle)) {
            hits.add('${entity.path}: $needle');
          }
        }
      }
      expect(
        hits,
        isEmpty,
        reason: 'the lazy router and its config key must be deleted:\n'
            '${hits.join('\n')}',
      );
    });
  });
}
