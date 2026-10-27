/// Update transport backends: the FRB `UpdateApi` lane.
///
/// The legacy Dart engine lane was removed once the Rust core became
/// authoritative for `update`.
library;

import 'dart:convert';

import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_report.dart';

/// Optional capability: a transport that records the report of its last check.
///
/// The facade reads this seam directly (no concrete `FrbUpdateBackend` type
/// check), so the production `deriveCoreCheckLogs` path is driven by a real
/// report and a test fake can supply one. It is deliberately a separate,
/// opt-in interface rather than a member of [UpdateBackend]: adding a required
/// member to [UpdateBackend] would break every existing `implements
/// UpdateBackend` fake that is out of scope for this change.
abstract interface class UpdateReportSource {
  CoreCheckReport? get lastReport;
}

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
class FrbUpdateBackend implements UpdateBackend, UpdateReportSource {
  FrbUpdateBackend({this.dataDir, this.filesDir, this.cacheDir});

  final String? dataDir;
  final String? filesDir;
  final String? cacheDir;

  rust.UpdateApi? _api;
  Future<rust.UpdateApi>? _pending;

  /// The last report recorded by [check]/[run] (report-level data the plain
  /// `List<AppUpdateInfo>` return type cannot carry).
  @override
  CoreCheckReport? lastReport;

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
    try {
      final api = await _ensureApi();
      return await action(api);
    } catch (error) {
      // The raw FRB exception carries the Rust `CORE_E_*` prefix; keep it typed.
      throw CoreUpdateException.fromRaw(error);
    }
  }

  List<AppUpdateInfo> _record(rust.UpdateReport report) {
    final updates = decodeUpdateList(report.updatesJson);
    lastReport = CoreCheckReport(
      updates: updates,
      skipped: decodeUpdateSkips(report.skippedJson),
      checkedAt: DateTime.fromMillisecondsSinceEpoch(report.checkedAt.toInt()),
      total: report.total.toInt(),
      usedCache: report.usedCache,
    );
    return updates;
  }

  @override
  Future<List<AppUpdateInfo>> check({required bool force}) =>
      _call((api) => api.check(force: force)).then(_record);

  @override
  Future<List<AppUpdateInfo>> run() =>
      _call((api) => api.run()).then(_record);

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

