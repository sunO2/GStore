/// Flag-free facade over the Rust `InstallApi`.
///
/// Boundary (plan Decision 6): the core owns the durable install request and
/// the reported outcome, the frontend owns the effect. `install()` returns an
/// [InstallStart] — exactly one of `record.status == 'installed'` or a non-null
/// [InstallStart.request] is set — and the frontend reports the terminal status
/// back through [InstallFacade.reportResult].
///
/// Effects that used to live in the core (`uninstall`, `launch`, `canInstall`)
/// are local again: `uninstall`/`launch` go through the existing system-intent
/// and `installed_apps` seams, `canInstall` is a frontend predicate.
///
/// Tests install a fake [InstallBackend] through the constructor or
/// [backendOverride], so no native library is required. After the Wave 6B
/// cutover the install domain is core-owned, so callers
/// (`InstallManager` / `DownloadTaskWatcher`) no longer read a flag.
library;

import 'dart:convert' show jsonDecode;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:installed_apps/installed_apps.dart';
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/shell/rust_shizuku_runner.dart';

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

/// Download variant the core picked for one install request.
class InstallVariant {
  const InstallVariant({
    required this.abi,
    required this.url,
    this.fallbackChain = const <String>[],
  });

  final String abi;
  final String url;
  final List<String> fallbackChain;

  factory InstallVariant.fromRust(rust.VariantChoiceDto dto) => InstallVariant(
        abi: dto.abi,
        url: dto.url,
        fallbackChain: dto.fallbackChain,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'abi': abi,
        'url': url,
        'fallback_chain': fallbackChain,
      };
}

/// The request the frontend must execute (plan Decision 7).
class InstallRequest {
  const InstallRequest({
    required this.moduleTaskId,
    required this.sessionId,
    required this.packageName,
    required this.versionName,
    required this.apkPath,
    required this.method,
    required this.variant,
  });

  final String moduleTaskId;
  final String sessionId;
  final String packageName;
  final String versionName;
  final String apkPath;

  /// `shizuku` | `package_installer` | `intent` | `platform`.
  final String method;

  final InstallVariant variant;

  factory InstallRequest.fromRust(rust.InstallRequestDto dto) => InstallRequest(
        moduleTaskId: dto.moduleTaskId,
        sessionId: dto.sessionId,
        packageName: dto.packageName,
        versionName: dto.versionName,
        apkPath: dto.apkPath,
        method: dto.method,
        variant: InstallVariant.fromRust(dto.variant),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'module_task_id': moduleTaskId,
        'session_id': sessionId,
        'package_name': packageName,
        'version_name': versionName,
        'apk_path': apkPath,
        'method': method,
        'variant': variant.toJson(),
      };
}

/// One `InstallApi.install` result: a settled record and/or a request.
class InstallStart {
  const InstallStart({required this.record, this.request});

  final InstallRecord record;
  final InstallRequest? request;

  bool get hasRequest => request != null;

  factory InstallStart.fromRust(rust.InstallStartDto dto) => InstallStart(
        record: InstallRecord.fromRust(dto.record),
        request:
            dto.request == null ? null : InstallRequest.fromRust(dto.request!),
      );
}

/// Terminal report statuses (plan Decision 12), 1:1 with the core enum.
abstract final class InstallReportStatus {
  static const String installed = 'installed';
  static const String failed = 'failed';
  static const String denied = 'denied';
  static const String timeout = 'timeout';

  static const Set<String> all = <String>{installed, failed, denied, timeout};
}

/// One frontend-observed install attempt outcome (distinct from the core's
/// durable `install_status`).
///
/// The platform branch only *launches* the system installer intent; the real
/// terminal result arrives asynchronously through `install_events` (or the
/// frontend deadline). Reporting `installed` at launch time is therefore a
/// lie — [launched] is the honest value and keeps the core row `pending` so a
/// later tap re-executes instead of silently no-op'ing on a bogus `installed`.
enum InstallOutcome {
  /// The core row was already `installed`: idempotent hit, no effect ran.
  alreadyInstalled,

  /// A synchronous install completed (Shizuku `pm install` → `Success`).
  installed,

  /// The system installer intent was launched; the terminal result is pending.
  launched,

  /// Failed / user-denied / timed out before a launch could be confirmed.
  failed;

  /// Whether the install is confirmed (idempotent hit or synchronous success).
  bool get isInstalled => this == alreadyInstalled || this == installed;
}

/// One terminal report sent back to the core.
class InstallReport {
  const InstallReport({
    required this.sessionId,
    required this.status,
    required this.method,
    this.installedVersion,
    this.error,
    required this.reportedAt,
  });

  final String sessionId;
  final String status;
  final String method;
  final String? installedVersion;
  final String? error;
  final int reportedAt;

  rust.InstallReportDto toRust() => rust.InstallReportDto(
        sessionId: sessionId,
        status: status,
        method: method,
        installedVersion: installedVersion,
        error: error,
        reportedAt: reportedAt,
      );
}

/// Acknowledgement of one report; `changed == false` means the row was already
/// terminal (idempotent duplicate).
class InstallResultAck {
  const InstallResultAck({
    required this.sessionId,
    required this.status,
    required this.changed,
  });

  final String sessionId;
  final String status;
  final bool changed;

  factory InstallResultAck.fromRust(rust.InstallResultAckDto dto) =>
      InstallResultAck(
        sessionId: dto.sessionId,
        status: dto.status,
        changed: dto.changed,
      );
}

/// Normalised typed error crossing the facade.
///
/// The FRB codec throws the raw host error string for `Result<_, String>`; the
/// host prefixes stable codes such as `CORE_E_INSTALL_SESSION`, so the facade
/// re-throws a typed exception with that code extracted.
class InstallCoreException implements Exception {
  const InstallCoreException(this.code, this.message);

  final String code;
  final String message;

  factory InstallCoreException.from(Object error) {
    final text = error.toString();
    final match = RegExp(r'CORE_E_[A-Z0-9_]+').firstMatch(text);
    return InstallCoreException(
      match?.group(0) ?? 'CORE_E_INSTALL',
      text,
    );
  }

  @override
  String toString() => 'InstallCoreException($code): $message';
}

/// Parses one `install.requested` event payload.
///
/// Returns null for malformed JSON, a different event, or an incomplete
/// request — the auto-install path must never crash on a bad event.
InstallRequest? parseInstallRequestEvent(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded['event']?.toString() != 'install.requested') return null;
  final payload = decoded['payload'];
  if (payload is! Map) return null;
  final request = payload['request'];
  if (request is! Map) return null;

  final moduleTaskId = _requiredString(request['module_task_id']);
  final sessionId = _requiredString(request['session_id']);
  final packageName = _requiredString(request['package_name']);
  final versionName = _requiredString(request['version_name']);
  final apkPath = _requiredString(request['apk_path']);
  final method = _requiredString(request['method']);
  if (moduleTaskId == null ||
      sessionId == null ||
      packageName == null ||
      versionName == null ||
      apkPath == null ||
      method == null) {
    return null;
  }

  final variant = request['variant'];
  final variantMap = variant is Map ? variant : const <Object?, Object?>{};
  return InstallRequest(
    moduleTaskId: moduleTaskId,
    sessionId: sessionId,
    packageName: packageName,
    versionName: versionName,
    apkPath: apkPath,
    method: method,
    variant: InstallVariant(
      abi: variantMap['abi']?.toString() ?? '',
      url: variantMap['url']?.toString() ?? '',
      fallbackChain: _stringList(variantMap['fallback_chain']),
    ),
  );
}

String? _requiredString(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return value;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return <String>[
    for (final item in value)
      if (item is String) item,
  ];
}

/// Injectable transport seam over `InstallApi`.
abstract class InstallBackend {
  Future<InstallStart> install(String moduleTaskId);

  Future<List<InstallStart>> pendingRequests();

  Future<InstallResultAck> reportResult(InstallReport report);

  Future<List<String>> takeEvents();

  Future<InstallRecord?> get(String moduleTaskId);

  Future<void> uninstall(String packageName);

  Future<void> launch(String packageName);
}

/// Builds the opaque `InstallApi` handle (overridable in tests).
typedef InstallApiFactory = Future<rust.InstallApi> Function(
  String dataDir,
  String filesDir,
  String cacheDir,
);

/// Production backend. The `InstallApi` handle is created lazily.
///
/// The core no longer performs platform effects, so the two effect methods
/// (`uninstall` / `launch`) use the existing Dart-side seams.
class FrbInstallBackend implements InstallBackend {
  FrbInstallBackend({
    this.dataDir,
    this.filesDir,
    this.cacheDir,
    InstallApiFactory? apiFactory,
  }) : _apiFactory = apiFactory ?? _defaultApiFactory;

  final String? dataDir;
  final String? filesDir;
  final String? cacheDir;
  final InstallApiFactory _apiFactory;

  static const MethodChannel _systemIntentChannel =
      MethodChannel('gstore/system_intent');

  rust.InstallApi? _api;
  Future<rust.InstallApi>? _pending;

  static Future<rust.InstallApi> _defaultApiFactory(
    String dataDir,
    String filesDir,
    String cacheDir,
  ) async {
    await RustBridge.ensureInitialized();
    return rust.InstallApi.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  }

  Future<rust.InstallApi> _ensureApi() {
    final existing = _api;
    if (existing != null) return Future.value(existing);
    return _pending ??= _create();
  }

  Future<rust.InstallApi> _create() async {
    try {
      final dirs = await _resolveDirs();
      final api = await _apiFactory(dirs.$1, dirs.$2, dirs.$3);
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
    try {
      return await action(api);
    } on InstallCoreException {
      rethrow;
    } on Object catch (error) {
      throw InstallCoreException.from(error);
    }
  }

  @override
  Future<InstallStart> install(String moduleTaskId) =>
      _call((api) => api.install(moduleTaskId: moduleTaskId))
          .then(InstallStart.fromRust);

  @override
  Future<List<InstallStart>> pendingRequests() =>
      _call((api) => api.pendingRequests()).then(
        (starts) => starts.map(InstallStart.fromRust).toList(growable: false),
      );

  @override
  Future<InstallResultAck> reportResult(InstallReport report) =>
      _call((api) => api.reportResult(report: report.toRust()))
          .then(InstallResultAck.fromRust);

  @override
  Future<List<String>> takeEvents() => _call((api) => api.takeEvents());

  @override
  Future<InstallRecord?> get(String moduleTaskId) =>
      _call((api) => api.get_(moduleTaskId: moduleTaskId))
          .then((dto) => dto == null ? null : InstallRecord.fromRust(dto));

  @override
  Future<void> uninstall(String packageName) async {
    try {
      final handled = await _systemIntentChannel.invokeMethod<bool>(
        'openUninstall',
        <String, Object?>{'packageName': packageName},
      );
      if (handled != true) {
        throw const InstallCoreException(
          'CORE_E_INSTALL_INTENT',
          'the system uninstall dialog was not opened',
        );
      }
    } on PlatformException catch (error) {
      throw InstallCoreException(
        error.code.isEmpty ? 'CORE_E_INSTALL_INTENT' : error.code,
        error.message ?? 'openUninstall failed',
      );
    }
  }

  @override
  Future<void> launch(String packageName) async {
    final started = await InstalledApps.startApp(packageName);
    if (started != true) {
      throw InstallCoreException(
        'CORE_E_INSTALL_LAUNCH',
        'could not launch $packageName',
      );
    }
  }
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

  /// Test seam for the local [canInstall] predicate.
  @visibleForTesting
  static Future<bool> Function()? shizukuAvailableOverride;

  /// Test seam for the local [canInstall] predicate.
  @visibleForTesting
  static bool? appInstallerAvailableOverride;

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
    shizukuAvailableOverride = null;
    appInstallerAvailableOverride = null;
  }

  /// Local frontend predicate (plan Decision 6): never calls the core.
  ///
  /// Shizuku enables silent install; otherwise Android's own package installer
  /// handles the intent. The only user gate (`install unknown apps`) is surfaced
  /// by the system UI, so there is nothing else to query here.
  Future<bool> canInstall() async {
    if (!Platform.isAndroid) return false;
    final shizuku = await (shizukuAvailableOverride ?? rustShizukuAvailable)();
    final appInstaller = appInstallerAvailableOverride ?? Platform.isAndroid;
    return shizuku || appInstaller;
  }

  Future<InstallStart> install(String moduleTaskId) =>
      _target.install(moduleTaskId);

  Future<List<InstallStart>> pendingRequests() => _target.pendingRequests();

  Future<InstallResultAck> reportResult(InstallReport report) =>
      _target.reportResult(report);

  Future<List<String>> takeEvents() => _target.takeEvents();

  Future<InstallRecord?> get(String moduleTaskId) => _target.get(moduleTaskId);

  Future<void> uninstall(String packageName) => _target.uninstall(packageName);

  Future<void> launch(String packageName) => _target.launch(packageName);
}
