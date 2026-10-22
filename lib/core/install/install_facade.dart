/// Flag-free facade over the Rust `InstallApi`.
///
/// Tests install a fake [InstallBackend] through the constructor or
/// [backendOverride], so no native library is required. The `CoreFlags.install`
/// decision stays in the callers (`InstallManager` / `DownloadTaskWatcher`).
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Durable install record projected from `download_task`.
class InstallRecord {
  const InstallRecord({
    required this.moduleTaskId,
    required this.appId,
    required this.status,
    this.method,
    this.sessionId,
    this.error,
    this.installedAt,
    this.installedVersion,
    this.installAfterDownload = false,
  });

  final String moduleTaskId;
  final String appId;
  final String status;
  final String? method;
  final String? sessionId;
  final String? error;
  final int? installedAt;
  final String? installedVersion;
  final bool installAfterDownload;

  bool get isInstalled => status == 'installed';

  factory InstallRecord.fromRust(rust.InstallRecordDto dto) => InstallRecord(
        moduleTaskId: dto.moduleTaskId,
        appId: dto.appId,
        status: dto.status,
        method: dto.method,
        sessionId: dto.sessionId,
        error: dto.error,
        installedAt: dto.installedAt?.toInt(),
        installedVersion: dto.installedVersion,
        installAfterDownload: dto.installAfterDownload,
      );
}

/// Result of one install attempt (durable record plus optional event JSON).
class InstallAttempt {
  const InstallAttempt({required this.record, this.eventJson});

  final InstallRecord record;
  final String? eventJson;

  factory InstallAttempt.fromRust(rust.InstallAttemptDto dto) => InstallAttempt(
        record: InstallRecord.fromRust(dto.record),
        eventJson: dto.eventJson,
      );
}

/// Summary of one reconciliation sweep.
class InstallReconcile {
  const InstallReconcile({
    required this.checked,
    required this.resolved,
    required this.stillPending,
    required this.errors,
    required this.events,
  });

  final int checked;
  final int resolved;
  final int stillPending;
  final List<String> errors;
  final List<String> events;

  factory InstallReconcile.fromRust(rust.InstallReconcileDto dto) =>
      InstallReconcile(
        checked: dto.checked.toInt(),
        resolved: dto.resolved.toInt(),
        stillPending: dto.stillPending.toInt(),
        errors: dto.errors,
        events: dto.events,
      );
}

/// Injectable transport seam over `InstallApi`.
abstract class InstallBackend {
  Future<bool> canInstall();

  Future<InstallAttempt> install(String moduleTaskId);

  Future<InstallAttempt?> maybeInstallAfterDownload(String moduleTaskId);

  Future<InstallRecord?> get(String moduleTaskId);

  Future<void> uninstall(String packageName);

  Future<void> launch(String packageName);

  Future<List<InstallRecord>> listPending();

  Future<String?> onResult({
    required String sessionId,
    required String status,
    String? packageName,
    String? versionName,
    String? error,
  });

  Future<InstallReconcile> reconcile();
}

/// Production FRB backend. The `InstallApi` handle is created lazily.
class FrbInstallBackend implements InstallBackend {
  FrbInstallBackend({this.dataDir, this.filesDir, this.cacheDir});

  final String? dataDir;
  final String? filesDir;
  final String? cacheDir;

  rust.InstallApi? _api;
  Future<rust.InstallApi>? _pending;

  Future<rust.InstallApi> _ensureApi() {
    final existing = _api;
    if (existing != null) return Future.value(existing);
    return _pending ??= _create();
  }

  Future<rust.InstallApi> _create() async {
    try {
      await RustBridge.ensureInitialized();
      final dirs = await _resolveDirs();
      final api = await rust.InstallApi.init(
        dataDir: dirs.$1,
        filesDir: dirs.$2,
        cacheDir: dirs.$3,
      );
      _api = api;
      return api;
    } finally {
      _pending = null;
    }
  }

  Future<(String, String, String)> _resolveDirs() async {
    if (dataDir != null && filesDir != null && cacheDir != null) {
      return (dataDir!, filesDir!, cacheDir!);
    }
    final support = await getApplicationSupportDirectory();
    final root = '${support.path}/gstore_core';
    return ('$root/data', '$root/files', '$root/cache');
  }

  Future<T> _call<T>(Future<T> Function(rust.InstallApi api) action) async {
    final api = await _ensureApi();
    return action(api);
  }

  @override
  Future<bool> canInstall() => _call((api) => api.canInstall());

  @override
  Future<InstallAttempt> install(String moduleTaskId) => _call(
        (api) => api.install(moduleTaskId: moduleTaskId),
      ).then(InstallAttempt.fromRust);

  @override
  Future<InstallAttempt?> maybeInstallAfterDownload(String moduleTaskId) =>
      _call(
        (api) => api.maybeInstallAfterDownload(moduleTaskId: moduleTaskId),
      ).then((dto) => dto == null ? null : InstallAttempt.fromRust(dto));

  @override
  Future<InstallRecord?> get(String moduleTaskId) => _call(
        (api) => api.get_(moduleTaskId: moduleTaskId),
      ).then((dto) => dto == null ? null : InstallRecord.fromRust(dto));

  @override
  Future<void> uninstall(String packageName) =>
      _call((api) => api.uninstall(packageName: packageName));

  @override
  Future<void> launch(String packageName) =>
      _call((api) => api.launch(packageName: packageName));

  @override
  Future<List<InstallRecord>> listPending() =>
      _call((api) => api.listPending()).then(
        (records) =>
            records.map(InstallRecord.fromRust).toList(growable: false),
      );

  @override
  Future<String?> onResult({
    required String sessionId,
    required String status,
    String? packageName,
    String? versionName,
    String? error,
  }) =>
      _call(
        (api) => api.onResult(
          sessionId: sessionId,
          status: status,
          packageName: packageName,
          versionName: versionName,
          error: error,
        ),
      );

  @override
  Future<InstallReconcile> reconcile() =>
      _call((api) => api.reconcile()).then(InstallReconcile.fromRust);
}

/// Pass-through facade used by flag-gated install callers.
class InstallFacade {
  InstallFacade({
    InstallBackend? backend,
    InstallBackend Function()? backendFactory,
  })  : _backend = backend,
        _backendFactory = backendFactory ?? FrbInstallBackend.new;

  static InstallFacade instance = InstallFacade();

  @visibleForTesting
  static InstallBackend? backendOverride;

  final InstallBackend? _backend;
  final InstallBackend Function() _backendFactory;
  InstallBackend? _resolved;

  InstallBackend get _target =>
      backendOverride ?? _backend ?? (_resolved ??= _backendFactory());

  @visibleForTesting
  static void installBackendForTest(InstallBackend backend) {
    backendOverride = backend;
  }

  @visibleForTesting
  static void resetForTest() {
    backendOverride = null;
  }

  Future<bool> canInstall() => _target.canInstall();

  Future<InstallAttempt> install(String moduleTaskId) =>
      _target.install(moduleTaskId);

  Future<InstallAttempt?> maybeInstallAfterDownload(String moduleTaskId) =>
      _target.maybeInstallAfterDownload(moduleTaskId);

  Future<InstallRecord?> get(String moduleTaskId) =>
      _target.get(moduleTaskId);

  Future<void> uninstall(String packageName) => _target.uninstall(packageName);

  Future<void> launch(String packageName) => _target.launch(packageName);

  Future<List<InstallRecord>> listPending() => _target.listPending();

  Future<String?> onResult({
    required String sessionId,
    required String status,
    String? packageName,
    String? versionName,
    String? error,
  }) =>
      _target.onResult(
        sessionId: sessionId,
        status: status,
        packageName: packageName,
        versionName: versionName,
        error: error,
      );

  Future<InstallReconcile> reconcile() => _target.reconcile();
}
