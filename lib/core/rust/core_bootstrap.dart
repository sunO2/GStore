/// Core bootstrap: one idempotent, non-fatal hand-off of platform facts and the
/// installed-app inventory to the Rust core.
///
/// Boundary (plan Decision 1/6): the core never queries the platform. The
/// Flutter app collects `PlatformFacts` + `InventorySnapshot` from the Android
/// side (`gstore/platform`, Todo 4) and pushes them in before any
/// `UpdateApi` / `InstallApi` use. This file owns that one-time push.
///
/// Why a separate file (plan Decision 10): the facades lazily create their own
/// `UpdateApi` / `InstallApi` handles, so the push must happen in the startup
/// sequence, not inside either facade. `lib/main.dart` awaits [start] right
/// after `WidgetsFlutterBinding.ensureInitialized()`; a failure is logged and
/// leaves [ready] `false` so the update/install UI can degrade instead of
/// crashing the app.
library;

import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/platform/platform_channel.dart';
import 'package:gstore/core/rust/CoreApiFacade.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Inventory/facts source identity pinned by the plan (`android_frontend`).
const String kCoreSourceId = 'android_frontend';

/// Narrow seam over the FRB `CoreApi` handle: init + the two pushes.
///
/// Tests inject a fake so the bootstrap needs no native library.
abstract class CoreBootstrapBackend {
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  });

  Future<void> pushPlatformFacts(rust.PlatformFactsDto facts);

  Future<rust.InventoryPushResultDto> pushInventory(
    rust.InventorySnapshotDto snapshot,
  );
}

/// Production backend over [CoreApiFacade] (which owns `RustLib.init` +
/// `LegacyWriteGuard` binding).
class FrbCoreBootstrapBackend implements CoreBootstrapBackend {
  rust.CoreApi? _api;

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {
    _api = await CoreApiFacade.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  }

  rust.CoreApi get _handle {
    final api = _api;
    if (api == null) {
      throw StateError('CoreBootstrapBackend.init must run before any push');
    }
    return api;
  }

  @override
  Future<void> pushPlatformFacts(rust.PlatformFactsDto facts) =>
      _handle.pushPlatformFacts(facts: facts);

  @override
  Future<rust.InventoryPushResultDto> pushInventory(
    rust.InventorySnapshotDto snapshot,
  ) =>
      _handle.pushInventory(snapshot: snapshot);
}

/// Platform probe seam: the two reads the bootstrap needs.
abstract class CorePlatformProbe {
  Future<Map<String, Object?>> deviceInfo();

  Future<List<Map<String, Object?>>> listInstalled();
}

/// Production probe over `gstore/platform` ([PlatformChannelClient]).
class ChannelCorePlatformProbe implements CorePlatformProbe {
  ChannelCorePlatformProbe({PlatformChannelClient? client})
      : _client = client ?? PlatformChannelClient();

  final PlatformChannelClient _client;

  @override
  Future<Map<String, Object?>> deviceInfo() => _client.deviceInfo();

  @override
  Future<List<Map<String, Object?>>> listInstalled() => _client.listInstalled();
}

/// One-shot core bootstrap.
///
/// * [start] is single-flight and idempotent: once [ready] is true it is a
///   no-op, and concurrent callers share the same run.
/// * A failure is **non-fatal**: it is logged and [ready] stays false, so the
///   app still starts with the legacy paths (flags stay false).
class CoreBootstrap {
  CoreBootstrap._();

  static bool _ready = false;
  static Future<void>? _pending;
  static int _lastSeq = 0;

  static CoreBootstrapBackend? _backendOverride;
  static CorePlatformProbe? _probeOverride;
  static int Function() _nowMillis = _defaultNowMillis;
  static String? _osOverride;
  static (String, String, String)? _dirsOverride;

  /// Whether the facts + inventory push completed successfully.
  static bool get ready => _ready;

  /// Runs the bootstrap once. Never throws.
  static Future<void> start() {
    if (_ready) return Future<void>.value();
    final pending = _pending;
    if (pending != null) return pending;
    final future = _run();
    _pending = future;
    return future;
  }

  /// Test-only: inject the backend/probe/clock (and the `os` label, which the
  /// host cannot infer off-device).
  @visibleForTesting
  static void debugConfigure({
    CoreBootstrapBackend? backend,
    CorePlatformProbe? probe,
    int Function()? nowMillis,
    String? os,
    (String, String, String)? dirs,
  }) {
    _backendOverride = backend;
    _probeOverride = probe;
    _nowMillis = nowMillis ?? _defaultNowMillis;
    _osOverride = os;
    _dirsOverride = dirs;
  }

  /// Test-only: clear readiness, the in-flight future and every injected seam.
  @visibleForTesting
  static void reset() {
    _ready = false;
    _pending = null;
    _lastSeq = 0;
    _backendOverride = null;
    _probeOverride = null;
    _nowMillis = _defaultNowMillis;
    _osOverride = null;
    _dirsOverride = null;
  }

  static Future<void> _run() async {
    try {
      final dirs = await _resolveDirs();
      final backend = _backendOverride ?? FrbCoreBootstrapBackend();
      final probe = _probeOverride ?? ChannelCorePlatformProbe();

      await backend.init(
        dataDir: dirs.$1,
        filesDir: dirs.$2,
        cacheDir: dirs.$3,
      );

      final device = await probe.deviceInfo();
      final apps = await probe.listInstalled();
      final capturedAt = _nowMillis();

      await backend.pushPlatformFacts(
        _buildFacts(dirs: dirs, device: device, capturedAt: capturedAt),
      );
      await backend.pushInventory(
        rust.InventorySnapshotDto(
          sourceId: kCoreSourceId,
          seq: _nextSeq(capturedAt),
          capturedAt: capturedAt,
          apps: <rust.InstalledAppDto>[
            for (final app in apps)
              if (_installedApp(app) case final dto?) dto,
          ],
        ),
      );
      _ready = true;
    } catch (error, stackTrace) {
      debugPrint('[CoreBootstrap] 核心自举失败（降级继续启动）: $error');
      if (kDebugMode) {
        debugPrint('[CoreBootstrap] stack: $stackTrace');
      }
    } finally {
      _pending = null;
    }
  }

  static rust.PlatformFactsDto _buildFacts({
    required (String, String, String) dirs,
    required Map<String, Object?> device,
    required int capturedAt,
  }) {
    final abis = _asStringList(device['abis']);
    return rust.PlatformFactsDto(
      sourceId: kCoreSourceId,
      os: _osOverride ??
          (Platform.isAndroid ? 'android' : Platform.operatingSystem),
      arch: _archFrom(abis),
      abis: abis,
      sdk: _asInt(device['sdk_int']) ?? 0,
      device: rust.DeviceFactsDto(
        model: _asString(device['model']) ?? '',
        manufacturer: _asString(device['manufacturer']) ?? '',
      ),
      paths: rust.CorePathsDto(
        data: dirs.$1,
        files: dirs.$2,
        cache: dirs.$3,
      ),
      // No existing core-scoped Keystore key: the webdav/debug secret stores are
      // unrelated domains, and inventing one here would be a new scheme.
      cryptoKey: null,
      // The crate clock is MILLISECONDS (facts::PlatformFacts::captured_at).
      capturedAt: capturedAt,
    );
  }

  /// Maps one `InventoryInspector.installedAppJson` entry; a payload without a
  /// package name is skipped (malformed input never crashes the bootstrap).
  static rust.InstalledAppDto? _installedApp(Map<String, Object?> app) {
    final packageName = _asString(app['package_name']);
    if (packageName == null) return null;
    return rust.InstalledAppDto(
      packageName: packageName,
      appName: _asString(app['app_name']),
      versionName: _asString(app['version_name']) ?? '',
      versionCode: _asInt(app['version_code']) ?? 0,
      signatureSha256: _asString(app['signature_sha256']),
      sourceDir: _asString(app['source_dir']),
      installer: _asString(app['installer']),
      isSystem: _asBool(app['is_system']),
      targetSdk: _asInt(app['target_sdk']) ?? 0,
      minSdk: _asInt(app['min_sdk']) ?? 0,
      abis: _asStringList(app['abis']),
    );
  }

  /// `seq` is a monotonic millisecond stamp: the plan allows persisted state or
  /// ms, and same-ms pushes would otherwise be dropped as `unchanged`.
  static int _nextSeq(int nowMs) {
    _lastSeq = nowMs > _lastSeq ? nowMs : _lastSeq + 1;
    return _lastSeq;
  }

  static Future<(String, String, String)> _resolveDirs() async {
    final override = _dirsOverride;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    final root = '${support.path}/gstore_core';
    return ('$root/data', '$root/files', '$root/cache');
  }

  static int _defaultNowMillis() => DateTime.now().millisecondsSinceEpoch;

  static String _archFrom(List<String> abis) {
    if (abis.isEmpty) return _platformFallbackArch();
    final first = abis.first;
    if (first.contains('arm64') && first.contains('v8a')) return 'arm64-v8a';
    if (first.contains('armeabi-v7a')) return 'armeabi-v7a';
    if (first.contains('x86_64')) return 'x86_64';
    if (first.contains('x86')) return 'x86';
    return first;
  }

  static String _platformFallbackArch() {
    switch (Platform.operatingSystem) {
      case 'android':
        return 'arm64-v8a';
      case 'macos':
        return 'macos';
      default:
        return 'x86_64';
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String? _asString(Object? value) {
    if (value is! String) return null;
    return value.isEmpty ? null : value;
  }

  static bool _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final text = value.trim().toLowerCase();
      return text == 'true' || text == '1';
    }
    return false;
  }

  static List<String> _asStringList(Object? value) {
    if (value is! List) return const <String>[];
    return <String>[
      for (final item in value)
        if (item is String) item,
    ];
  }
}
