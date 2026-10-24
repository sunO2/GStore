/// Flag-gated facade over update checking.
///
/// `CoreFlags.update == false` routes to the legacy Dart
/// `UpdateManagerService`; `true` routes to the FRB `UpdateApi`.
///
/// The facade also owns the shared reactive state surface (results, logs,
/// progress, last-check time). On the legacy lane the service writes that
/// state itself; on the core lane the facade mirrors the core result into the
/// same state holder so the update page, the app list, the badge and the agent
/// keep a single subscription contract. The legacy check engine is never run
/// while `update` is authoritative.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/core_bootstrap.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_backends.dart';
import 'package:gstore/core/update/update_log.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/core/update/update_report.dart';

export 'package:gstore/core/update/update_backends.dart';
export 'package:gstore/core/update/update_report.dart';

/// Flag-gated update facade.
class UpdateFacade {
  UpdateFacade({UpdateBackend? legacy, UpdateBackend? frb})
      : _legacy = legacy ?? LegacyUpdateBackend(),
        _frb = frb ?? FrbUpdateBackend(),
        _frbInjected = frb != null;

  static UpdateFacade instance = UpdateFacade();

  /// Test seam: replaces the FRB backend.
  @visibleForTesting
  static UpdateBackend? backendOverride;

  /// Test seam: replaces the legacy backend.
  @visibleForTesting
  static UpdateBackend? legacyBackendOverride;

  final UpdateBackend _legacy;
  final UpdateBackend _frb;

  /// An injected FRB backend is a test seam; only the default production wiring
  /// enforces the bootstrap/catalog ordering gate.
  final bool _frbInjected;

  /// The shared reactive state holder. The legacy engine writes it when
  /// `update` is off; the facade mirrors the core result into it when on.
  UpdateManagerService get _state => UpdateManagerService.instance;

  Future<bool> _enabled() async {
    try {
      await CoreFlags.refresh();
    } catch (_) {
      // Keep the last mirror; an unavailable flag backend must not arm a flag.
    }
    return CoreFlags.update;
  }

  /// The cutover is only legal after the Rust core is authoritative for
  /// `catalog` and the bootstrap has pushed platform facts + inventory.
  void _assertCutoverOrder() {
    if (!CoreFlags.catalog) {
      throw const CoreUpdateException(
        CoreUpdateException.cutoverOrder,
        'update cutover requires catalog authoritative (catalog -> update order)',
      );
    }
    if (!CoreBootstrap.ready) {
      throw const CoreUpdateException(
        CoreUpdateException.factsMissing,
        'CoreBootstrap has not pushed platform facts + inventory',
      );
    }
  }

  UpdateBackend _coreBackend() {
    final override = backendOverride;
    if (override != null) return override;
    if (!_frbInjected) _assertCutoverOrder();
    return _frb;
  }

  Future<UpdateBackend> _backend() async {
    if (!await _enabled()) {
      return legacyBackendOverride ?? _legacy;
    }
    return _coreBackend();
  }

  // ===== Shared reactive state (same surface for both lanes) =====

  List<AppUpdateInfo> get updateList => _state.updateList;

  List<AppUpdateInfo> get updatableApps => _state.updatableApps;

  int get updateCount => _state.updateCount;

  AppUpdateInfo? cachedUpdate(String appId) => _state.getByAppId(appId);

  bool cachedHasUpdate(String appId) => _state.hasUpdate(appId);

  DateTime? get lastCheckedAt => _state.lastCheckedAt;

  bool get isChecking => _state.isChecking;

  List<CheckLogEntry> get checkLog => _state.checkLog;

  UpdateCheckProgress? get currentProgress => _state.currentProgress;

  Stream<List<AppUpdateInfo>> get updateListStream => _state.updateListStream;

  Stream<List<CheckLogEntry>> get checkLogStream => _state.checkLogStream;

  Stream<bool> get isCheckingStream => _state.isCheckingStream;

  Stream<DateTime?> get lastCheckedAtStream => _state.lastCheckedAtStream;

  Stream<List<String>> get checkListStream => _state.checkListStream;

  Stream<int> get checkedCountStream => _state.checkedCountStream;

  Stream<int> get totalCountStream => _state.totalCountStream;

  Stream<String> get checkingAppNameStream => _state.checkingAppNameStream;

  Stream<String?> get checkingIconUrlStream => _state.checkingIconUrlStream;

  Stream<UpdateCheckProgress?> get currentProgressStream =>
      _state.currentProgressStream;

  List<String> get checkList => _state.checkList;

  int get checkedCount => _state.checkedCount;

  int get totalCount => _state.totalCount;

  String get checkingAppName => _state.checkingAppName;

  String? get checkingIconUrl => _state.checkingIconUrl;

  /// Restores the persisted result/log cache into the shared state.
  Future<void> get cacheRestored => _state.cacheRestored;

  void restoreCacheInBackground() => _state.restoreCacheInBackground();

  /// Startup/background lazy check (lock + one-hour window), routed by flag.
  Future<void> ensureChecked({bool force = false}) async {
    if (_state.isChecking) return;
    if (!force && _state.updateList.isNotEmpty && await cacheValid()) return;
    await checkUpdates(force: true);
  }

  /// Runs one check on the flag-selected lane and mirrors the result.
  ///
  /// Core failures surface as [CoreUpdateException] (typed `CORE_E_*`); the
  /// facade never falls back to the legacy engine once `update` is on.
  Future<void> checkUpdates({
    bool force = false,
    void Function(UpdateCheckProgress progress)? onProgress,
    void Function(CheckLogLevel level, String message)? onLog,
    void Function(List<String> appNames)? onCheckList,
  }) async {
    final enabled = await _enabled();
    if (!enabled) {
      final backend = legacyBackendOverride ?? _legacy;
      if (backend is LegacyUpdateBackend) {
        await backend.runCheck(
          force: force,
          onProgress: onProgress,
          onLog: onLog,
          onCheckList: onCheckList,
        );
        return;
      }
      _state.beginFacadeCheck();
      try {
        final updates = await backend.check(force: force);
        _adopt(updates, onLog: onLog, onCheckList: onCheckList);
      } catch (error) {
        _state.failFacadeCheck(error.toString());
        rethrow;
      }
      return;
    }

    final backend = _coreBackend();
    _state.beginFacadeCheck();
    try {
      final updates = await backend.check(force: force);
      final report = backend is FrbUpdateBackend ? backend.lastReport : null;
      if (report != null) {
        final logs = deriveCoreCheckLogs(report);
        for (final entry in logs) {
          onLog?.call(entry.level, entry.text);
        }
        final names = <String>[
          for (final update in report.updates) update.appName,
        ];
        onCheckList?.call(names);
        _state.adoptFacadeCheck(
          updates: report.updates,
          logs: logs,
          checkedAt: report.checkedAt,
          total: report.total,
          checkList: names,
        );
      } else {
        _adopt(updates, onLog: onLog, onCheckList: onCheckList);
      }
    } on CoreUpdateException catch (error) {
      _state.failFacadeCheck(error.toString());
      rethrow;
    } catch (error) {
      final typed = CoreUpdateException.fromRaw(error);
      _state.failFacadeCheck(typed.toString());
      throw typed;
    }
  }

  void _adopt(
    List<AppUpdateInfo> updates, {
    void Function(CheckLogLevel level, String message)? onLog,
    void Function(List<String> appNames)? onCheckList,
  }) {
    final checkedAt =
        updates.isNotEmpty ? updates.first.checkedAt : DateTime.now();
    final report = CoreCheckReport(
      updates: updates,
      skipped: const <UpdateSkip>[],
      checkedAt: checkedAt,
      total: updates.length,
      usedCache: false,
    );
    final logs = deriveCoreCheckLogs(report);
    for (final entry in logs) {
      onLog?.call(entry.level, entry.text);
    }
    final names = <String>[for (final update in updates) update.appName];
    onCheckList?.call(names);
    _state.adoptFacadeCheck(
      updates: updates,
      logs: logs,
      checkedAt: checkedAt,
      total: updates.length,
      checkList: names,
    );
  }

  // ===== Operations =====

  Future<List<AppUpdateInfo>> check({required bool force}) async =>
      (await _backend()).check(force: force);

  Future<List<AppUpdateInfo>> run() async => (await _backend()).run();

  Future<List<AppUpdateInfo>> list() async => (await _backend()).list();

  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode}) async =>
      (await _backend()).checkApp(appId, channelCode: channelCode);

  Future<bool> markUpdated(String appId) async {
    final removed = (await _backend()).markUpdated(appId);
    final result = await removed;
    if (result) _state.removeFacadeUpdated(appId);
    return result;
  }

  Future<bool> hasUpdate(String appId) async =>
      (await _backend()).hasUpdate(appId);

  Future<int> count() async => (await _backend()).count();

  Future<bool> cacheValid() async => (await _backend()).cacheValid();
}
