/// Flag-gated facade over update checking.
///
/// `CoreFlags.update == false` routes to the legacy Dart
/// `UpdateManagerService`; `true` routes to the FRB `UpdateApi`.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_manager.dart';

/// Injectable update transport seam.
abstract class UpdateBackend {
  /// Checks updates, honoring the cache unless [force].
  Future<List<AppUpdateInfo>> check({required bool force});

  /// Forces a full check.
  Future<List<AppUpdateInfo>> run();

  Future<List<AppUpdateInfo>> list();

  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode});

  Future<bool> markUpdated(String appId);

  Future<bool> hasUpdate(String appId);

  Future<int> count();

  Future<bool> cacheValid();
}

/// Production FRB backend.
class FrbUpdateBackend implements UpdateBackend {
  FrbUpdateBackend({this.dataDir, this.filesDir, this.cacheDir});

  final String? dataDir;
  final String? filesDir;
  final String? cacheDir;

  rust.UpdateApi? _api;
  Future<rust.UpdateApi>? _pending;

  Future<rust.UpdateApi> _ensureApi() {
    final existing = _api;
    if (existing != null) return Future.value(existing);
    return _pending ??= _create();
  }

  Future<rust.UpdateApi> _create() async {
    try {
      await RustBridge.ensureInitialized();
      final dirs = await _resolveDirs();
      final api = await rust.UpdateApi.init(
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

  Future<T> _call<T>(Future<T> Function(rust.UpdateApi api) action) async {
    final api = await _ensureApi();
    return action(api);
  }

  @override
  Future<List<AppUpdateInfo>> check({required bool force}) =>
      _call((api) => api.check(force: force)).then(
        (report) => decodeUpdateList(report.updatesJson),
      );

  @override
  Future<List<AppUpdateInfo>> run() => _call((api) => api.run()).then(
        (report) => decodeUpdateList(report.updatesJson),
      );

  @override
  Future<List<AppUpdateInfo>> list() =>
      _call((api) => api.list()).then(decodeUpdateList);

  @override
  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode}) =>
      _call((api) => api.checkApp(appId: appId, channelCode: channelCode))
          .then((raw) => raw == null ? null : decodeUpdate(raw));

  @override
  Future<bool> markUpdated(String appId) =>
      _call((api) => api.markUpdated(appId: appId));

  @override
  Future<bool> hasUpdate(String appId) =>
      _call((api) => api.hasUpdate(appId: appId));

  @override
  Future<int> count() =>
      _call((api) => api.count()).then((value) => value.toInt());

  @override
  Future<bool> cacheValid() => _call((api) => api.cacheValid());
}

/// Decodes one serialized `AppUpdateInfo`.
AppUpdateInfo decodeUpdate(String raw) => AppUpdateInfo.fromCacheJson(
    Map<String, dynamic>.from(jsonDecode(raw) as Map));

/// Decodes a serialized `AppUpdateInfo` array.
List<AppUpdateInfo> decodeUpdateList(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) return <AppUpdateInfo>[];
  return decoded
      .whereType<Map>()
      .map((item) =>
          AppUpdateInfo.fromCacheJson(Map<String, dynamic>.from(item)))
      .toList(growable: false);
}

/// Legacy backend over `UpdateManagerService`.
class LegacyUpdateBackend implements UpdateBackend {
  LegacyUpdateBackend({UpdateManagerService? service})
      : _service = service ?? UpdateManagerService.instance;

  final UpdateManagerService _service;

  @override
  Future<List<AppUpdateInfo>> check({required bool force}) async {
    await _service.checkUpdates(force: force);
    return List<AppUpdateInfo>.of(_service.updateList);
  }

  @override
  Future<List<AppUpdateInfo>> run() => check(force: true);

  @override
  Future<List<AppUpdateInfo>> list() async =>
      List<AppUpdateInfo>.of(_service.updateList);

  @override
  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode}) async =>
      _service.getByAppId(appId);

  @override
  Future<bool> markUpdated(String appId) async {
    final existed = _service.hasUpdate(appId);
    await _service.markUpdated(appId);
    return existed && !_service.hasUpdate(appId);
  }

  @override
  Future<bool> hasUpdate(String appId) async => _service.hasUpdate(appId);

  @override
  Future<int> count() async => _service.updateCount;

  @override
  Future<bool> cacheValid() async {
    if (_service.updateList.isEmpty) return false;
    final last = _service.lastCheckedAt;
    if (last == null) return false;
    return DateTime.now().difference(last).inHours < 1;
  }
}

/// Flag-gated update facade.
class UpdateFacade {
  UpdateFacade({UpdateBackend? legacy, UpdateBackend? frb})
      : _legacy = legacy ?? LegacyUpdateBackend(),
        _frb = frb ?? FrbUpdateBackend();

  static UpdateFacade instance = UpdateFacade();

  /// Test seam: replaces the FRB backend.
  @visibleForTesting
  static UpdateBackend? backendOverride;

  /// Test seam: replaces the legacy backend.
  @visibleForTesting
  static UpdateBackend? legacyBackendOverride;

  final UpdateBackend _legacy;
  final UpdateBackend _frb;

  Future<bool> _enabled() async {
    try {
      await CoreFlags.refresh();
    } catch (_) {
      // Keep the last mirror; an unavailable flag backend must not arm a flag.
    }
    return CoreFlags.update;
  }

  Future<UpdateBackend> _backend() async => await _enabled()
      ? (backendOverride ?? _frb)
      : (legacyBackendOverride ?? _legacy);

  Future<List<AppUpdateInfo>> check({required bool force}) async =>
      (await _backend()).check(force: force);

  Future<List<AppUpdateInfo>> run() async => (await _backend()).run();

  Future<List<AppUpdateInfo>> list() async => (await _backend()).list();

  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode}) async =>
      (await _backend()).checkApp(appId, channelCode: channelCode);

  Future<bool> markUpdated(String appId) async =>
      (await _backend()).markUpdated(appId);

  Future<bool> hasUpdate(String appId) async =>
      (await _backend()).hasUpdate(appId);

  Future<int> count() async => (await _backend()).count();

  Future<bool> cacheValid() async => (await _backend()).cacheValid();
}
