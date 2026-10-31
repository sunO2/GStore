/// Standalone legacy → Rust config migration (plan Todo 21, corrections
/// C9/C15).
///
/// The migration is deliberately **standalone**: it does not use
/// `ConfigManager` / `ConfigStore` / `ConfigService` (those become a thin Rust
/// facade), and it never edits the boot sequence. It reads the *real* legacy
/// storage keys (SharedPreferences `config_*` keys + secure `webdav_*` /
/// `secure_config_webdav_*` keys), maps them to the grouped Rust wire keys
/// (`module.key`) through an explicit table, imports them through the Rust
/// `ConfigApi.import`, reads them back with `ConfigApi.verify`, and finally
/// writes the `config.migrated.v1` marker through `ConfigApi.meta_set`.
///
/// Guarantees:
///
/// * **One-time** — after a complete pass `config.migrated.v1` holds a JSON
///   report. A second call returns `alreadyDone` and touches nothing.
/// * **Per-key isolation** — a corrupt legacy JSON payload is reported and
///   skipped; the remaining keys still migrate. The marker stays absent while
///   any key failed so the next launch retries.
/// * **Read-back verified** — the marker is written only when `verify` reports
///   zero mismatches.
/// * **Never destructive** — old keys are never deleted (on failure *or*
///   success), so rollback to the old app always remains possible.
/// * **Secret-safe backup** — the optional plaintext backup omits WebDAV
///   passwords and masks agent API keys; a post-write secret scan covers both
///   the backup artifact and the `config_meta` marker payload.
/// * **No values in reports** — reports carry `storageKey` / `wireKey` /
///   `status` / stable `code` only.
///
/// Production callers (Todo 23) must invoke this **after**
/// `CoreBootstrap.start` / `CoreApi.init`. The production API factory simply
/// lets the Rust call fail with `CORE_E_NOT_INITIALIZED`; the tool then returns
/// a non-fatal `core_not_initialized` report without writing the marker.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../rust/generated/bridge.dart' as generated;
import '../../rust/generated/config_api.dart' as generated;

/// `config_meta` marker written after a fully verified pass.
const String kConfigMigrationMarkerKey = 'config.migrated.v1';

/// Stable `source` code passed to `ConfigApi.import`.
const String kConfigMigrationSource = 'migration';

/// Backup file prefix (companion artifacts live next to the core DB).
const String kConfigMigrationBackupPrefix = 'config_migration_backup_';

/// Progress callback: `done` of `total` legacy storage keys handled.
typedef ConfigMigrationProgress = void Function(int done, int total);

/// One (already mapped) grouped config entry handed to the Rust import.
class MigrationEntry {
  const MigrationEntry({required this.wireKey, required this.value});

  /// Grouped wire key (`module.key`, e.g. `download.max_concurrent`).
  final String wireKey;

  /// Typed value; encoded to JSON right before crossing the FFI seam.
  final Object? value;

  String get module => wireKey.substring(0, wireKey.indexOf('.'));

  String get key => wireKey.substring(wireKey.indexOf('.') + 1);

  String get valueJson => jsonEncode(value);
}

/// Result of one bulk import (mirrors `ConfigImportReportDto`).
class MigrationImportResult {
  const MigrationImportResult({
    this.total = 0,
    this.applied = 0,
    this.unchanged = 0,
    this.eventsPublished = 0,
    this.failed = const <String, String>{},
  });

  final int total;
  final int applied;
  final int unchanged;
  final int eventsPublished;

  /// Wire key → stable failure code. Never a value.
  final Map<String, String> failed;
}

/// Result of one read-back verification (mirrors `ConfigVerifyReportDto`).
class MigrationVerifyResult {
  const MigrationVerifyResult({
    this.total = 0,
    this.matched = 0,
    this.failed = const <String, String>{},
  });

  final int total;
  final int matched;

  /// Wire key → mismatch/rejection status/code. Never a value.
  final Map<String, String> failed;

  bool get allMatched => failed.isEmpty && matched == total;
}

/// Narrow seam over the generated FRB `ConfigApi`. Production delegates to
/// Rust; tests inject an in-memory fake (no native library required).
abstract class ConfigMigrationApi {
  Future<MigrationImportResult> importEntries(
    List<MigrationEntry> entries, {
    required String source,
  });

  Future<MigrationVerifyResult> verifyEntries(List<MigrationEntry> entries);

  Future<String?> getMeta(String key);

  Future<void> setMeta(String key, String valueJson);
}

/// Production adapter: `ConfigApi.import_` / `verify` / `meta_get` /
/// `meta_set`. `create()` fails when `CoreApi` is not initialized.
class GeneratedConfigMigrationApi implements ConfigMigrationApi {
  GeneratedConfigMigrationApi(this._api);

  final generated.ConfigApi _api;

  static Future<ConfigMigrationApi> create() async {
    return GeneratedConfigMigrationApi(await generated.ConfigApi.init());
  }

  @override
  Future<MigrationImportResult> importEntries(
    List<MigrationEntry> entries, {
    required String source,
  }) async {
    final report = await _api.import_(
      entries: <generated.ConfigImportEntryDto>[
        for (final entry in entries)
          generated.ConfigImportEntryDto(
            module: entry.module,
            key: entry.key,
            valueJson: entry.valueJson,
          ),
      ],
      source: source,
    );
    return MigrationImportResult(
      total: report.total,
      applied: report.applied,
      unchanged: report.unchanged,
      eventsPublished: report.eventsPublished,
      failed: <String, String>{
        for (final failure in report.failed)
          '${failure.module}.${failure.key}': failure.code,
      },
    );
  }

  @override
  Future<MigrationVerifyResult> verifyEntries(
    List<MigrationEntry> entries,
  ) async {
    final report = await _api.verify(
      entries: <generated.ConfigVerifyEntryDto>[
        for (final entry in entries)
          generated.ConfigVerifyEntryDto(
            module: entry.module,
            key: entry.key,
            valueJson: entry.valueJson,
          ),
      ],
    );
    final failed = <String, String>{};
    for (final result in report.results) {
      if (result.status != 'match') {
        failed['${result.module}.${result.key}'] =
            result.code ?? result.status;
      }
    }
    return MigrationVerifyResult(
      total: report.total,
      matched: report.matched,
      failed: failed,
    );
  }

  @override
  Future<String?> getMeta(String key) => _api.metaGet(key: key);

  @override
  Future<void> setMeta(String key, String valueJson) =>
      _api.metaSet(key: key, valueJson: valueJson);
}

/// Seam over the legacy stores. Production reads SharedPreferences +
/// FlutterSecureStorage once; tests pass a plain map snapshot.
abstract class LegacyConfigSource {
  Future<Map<String, Object?>> readPrefs();

  Future<Map<String, String?>> readSecure();
}

/// Real legacy stores (read-only snapshot).
class DefaultLegacyConfigSource implements LegacyConfigSource {
  DefaultLegacyConfigSource._(this._prefs, this._secure);

  final Map<String, Object?> _prefs;
  final Map<String, String?> _secure;

  static Future<LegacyConfigSource> create() async {
    final prefs = await SharedPreferences.getInstance();
    final prefsSnapshot = <String, Object?>{
      for (final key in prefs.getKeys()) key: prefs.get(key),
    };
    const secureStore = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    var secureSnapshot = <String, String?>{};
    try {
      secureSnapshot = Map<String, String?>.from(await secureStore.readAll());
    } catch (_) {
      // Secure storage unavailable (e.g. host test): behave as "empty".
      secureSnapshot = <String, String?>{};
    }
    return DefaultLegacyConfigSource._(prefsSnapshot, secureSnapshot);
  }

  @override
  Future<Map<String, Object?>> readPrefs() async => _prefs;

  @override
  Future<Map<String, String?>> readSecure() async => _secure;
}

/// Per-key outcome. **No values.**
class MigrationKeyReport {
  const MigrationKeyReport({
    required this.storageKey,
    required this.wireKey,
    required this.status,
    this.code,
  });

  final String storageKey;
  final String wireKey;

  /// `applied` / `failed` / `superseded`.
  final String status;

  /// Stable failure code (`config_invalid_json`, `config_invalid_enum`, …).
  final String? code;

  Map<String, Object?> toJson() => <String, Object?>{
        'storageKey': storageKey,
        'wireKey': wireKey,
        'status': status,
        if (code != null) 'code': code,
      };

  @override
  String toString() =>
      'MigrationKeyReport($storageKey → $wireKey: $status'
      '${code == null ? '' : ', $code'})';
}

/// Outcome of one [ConfigMigrationTool.run] pass.
class ConfigMigrationReport {
  const ConfigMigrationReport({
    this.alreadyDone = false,
    this.coreReady = true,
    this.totalStorageKeys = 0,
    this.applied = 0,
    this.unchanged = 0,
    this.failed = 0,
    this.verifyFailures = 0,
    this.markerWritten = false,
    this.backupPath,
    this.secretScanClean = true,
    this.errorCode,
    this.keys = const <MigrationKeyReport>[],
  });

  final bool alreadyDone;
  final bool coreReady;
  final int totalStorageKeys;
  final int applied;
  final int unchanged;
  final int failed;
  final int verifyFailures;
  final bool markerWritten;
  final String? backupPath;
  final bool secretScanClean;
  final String? errorCode;
  final List<MigrationKeyReport> keys;

  bool get success =>
      coreReady &&
      failed == 0 &&
      verifyFailures == 0 &&
      secretScanClean &&
      errorCode == null;

  int get distinctWireKeys => keys
      .where((report) => report.status == 'applied')
      .map((report) => report.wireKey)
      .toSet()
      .length;

  /// Marker / test projection — **key/status only, never values**.
  Map<String, Object?> toJson() => <String, Object?>{
        'version': 1,
        'markerKey': kConfigMigrationMarkerKey,
        'source': kConfigMigrationSource,
        'alreadyDone': alreadyDone,
        'coreReady': coreReady,
        'totalStorageKeys': totalStorageKeys,
        'applied': applied,
        'unchanged': unchanged,
        'failed': failed,
        'verifyFailures': verifyFailures,
        'markerWritten': markerWritten,
        'secretScanClean': secretScanClean,
        'backupFile': backupPath == null ? null : p.basename(backupPath!),
        if (errorCode != null) 'errorCode': errorCode,
        'keys': <Map<String, Object?>>[
          for (final key in keys) key.toJson(),
        ],
      };

  @override
  String toString() => 'ConfigMigrationReport(alreadyDone: $alreadyDone, '
      'coreReady: $coreReady, total: $totalStorageKeys, applied: $applied, '
      'unchanged: $unchanged, failed: $failed, '
      'verifyFailures: $verifyFailures, marker: $markerWritten, '
      'secretScanClean: $secretScanClean, error: $errorCode)';
}

enum _Shape { boolean, integer, string, jsonMap, jsonList, stringList }

class _DecodeException implements Exception {
  const _DecodeException(this.code);

  final String code;
}

class _DecodedBatch {
  _DecodedBatch(this.storageKey, {List<MigrationEntry>? entries, Map<String, String>? failures})
      : entries = entries ?? <MigrationEntry>[],
        failures = failures ?? <String, String>{};

  final String storageKey;
  final List<MigrationEntry> entries;

  /// Wire key → stable code for fields that could not be decoded.
  final Map<String, String> failures;
}

class _PendingEntry {
  const _PendingEntry(this.storageKey, this.entry);

  final String storageKey;
  final MigrationEntry entry;
}

/// Standalone legacy-config migration (see the library docs).
class ConfigMigrationTool {
  ConfigMigrationTool._();

  /// Explicit **storage key → grouped wire key(s)** table (C15).
  ///
  /// These are the real on-disk keys, not logical object names. There is no
  /// single `download_config` / `webdav_config` value on disk: download is
  /// stored per field, WebDAV per field, and `config_update_config` is the
  /// only aggregated JSON whose fields are split **after** parsing.
  static const Map<String, List<String>> storageKeyToWireKeys =
      <String, List<String>>{
    // ---- download (per-field storage, no `config_download_config`) ----
    'config_download_multi_segment': <String>[
      'download.multi_segment.enabled',
    ],
    'config_download_max_concurrent': <String>['download.max_concurrent'],
    'config_download_wifi_only': <String>['download.wifi_only'],
    'config_download_max_retry': <String>['download.max_retries'],
    // ---- update (aggregated JSON, split after parsing) ----
    'config_update_config': <String>[
      'update.channel',
      'update.auto_update_policy',
      'update.ignore_prerelease',
      'update.silent_update',
      'update.check_interval_hours',
      'update.last_check_time',
      'update.last_updated_version',
    ],
    // ---- theme ----
    'config_theme_config': <String>['theme.config'],
    'config_theme_mode': <String>['theme.mode'],
    // ---- perf ----
    'config_perf.profiles': <String>['perf.profiles'],
    'config_perf.profiles.enabled': <String>['perf.profiles.enabled'],
    'config_perf.history.enabled': <String>['perf.history.enabled'],
    // ---- agent (JSON split after parsing; sensitivity preserved by Rust) ----
    'config_agent_models': <String>['agent.models'],
    'config_agent_selected_model_id': <String>['agent.selected_model_id'],
    'config_agent_model_catalog': <String>['agent.model_catalog'],
    // ---- fdroid / discovery / network ----
    'config_fdroid_sources': <String>['fdroid.sources'],
    'config_last_source_id': <String>['fdroid.last_source_id'],
    'config_selected_channels': <String>['discovery.selected_channels'],
    'config_proxy_url': <String>['network.proxy_url'],
    'config_catalog_url': <String>['catalog.source_url'],
    // ---- all 11 proxy page keys ----
    'config_proxy_engine_stack': <String>['proxy.engine_stack'],
    'config_proxy_engine_mtu': <String>['proxy.engine_mtu'],
    'config_proxy_routing_mode': <String>['proxy.routing_mode'],
    'config_proxy_run_mode': <String>['proxy.run_mode'],
    'config_proxy_active_node_label': <String>['proxy.active_node_label'],
    'config_proxy_active_profile_id': <String>['proxy.active_profile_id'],
    'config_proxy_sheet_view_mode': <String>['proxy.sheet_view_mode'],
    'config_proxy_split_mode': <String>['proxy.split_mode'],
    'config_proxy_split_apps': <String>['proxy.split_apps'],
    'config_proxy_always_on_intent': <String>['proxy.always_on_intent'],
    'config_proxy_log_level': <String>['proxy.log_level'],
    // ---- all 11 module toggles ----
    'config_module.channel.enabled': <String>['module.channel.enabled'],
    'config_module.download.enabled': <String>['module.download.enabled'],
    'config_module.backup.enabled': <String>['module.backup.enabled'],
    'config_module.webdav.enabled': <String>['module.webdav.enabled'],
    'config_module.fdroid.enabled': <String>['module.fdroid.enabled'],
    'config_module.theme.enabled': <String>['module.theme.enabled'],
    'config_module.install.enabled': <String>['module.install.enabled'],
    'config_module.aggregate.enabled': <String>['module.aggregate.enabled'],
    'config_module.agent_tools.enabled': <String>['module.agent_tools.enabled'],
    'config_module.update.enabled': <String>['module.update.enabled'],
    'config_module.badge.enabled': <String>['module.badge.enabled'],
    // ---- bare legacy keys (older ConfigRegistry / backup imports) ----
    'fdroid_sources': <String>['fdroid.sources'],
    'last_source_id': <String>['fdroid.last_source_id'],
    'selected_channels': <String>['discovery.selected_channels'],
    'agent_models': <String>['agent.models'],
    'agent_selected_model_id': <String>['agent.selected_model_id'],
    // ---- WebDAV bare manager copy (wins) ----
    'webdav_url': <String>['webdav.url'],
    'webdav_username': <String>['webdav.username'],
    'webdav_password': <String>['webdav.password'],
    'webdav_backup_path': <String>['webdav.backup_path'],
    'webdav_enable_https': <String>['webdav.enable_https'],
    // ---- stale `SecureConfigStorage` provider copy (loses) ----
    'secure_config_webdav_url': <String>['webdav.url'],
    'secure_config_webdav_username': <String>['webdav.username'],
    'secure_config_webdav_password': <String>['webdav.password'],
    'secure_config_webdav_backup_path': <String>['webdav.backup_path'],
    'secure_config_webdav_enable_https': <String>['webdav.enable_https'],
  };

  static const Set<String> _bareLegacyStorageKeys = <String>{
    'fdroid_sources',
    'last_source_id',
    'selected_channels',
    'agent_models',
    'agent_selected_model_id',
  };

  static const Set<String> _agentModelsStorageKeys = <String>{
    'config_agent_models',
    'agent_models',
    'secure_config_agent_models',
  };

  static const Map<String, _Shape> _shapeByWireKey = <String, _Shape>{
    'download.multi_segment.enabled': _Shape.boolean,
    'download.max_concurrent': _Shape.integer,
    'download.wifi_only': _Shape.boolean,
    'download.max_retries': _Shape.integer,
    'theme.config': _Shape.jsonMap,
    'theme.mode': _Shape.integer,
    'perf.profiles': _Shape.jsonMap,
    'perf.profiles.enabled': _Shape.boolean,
    'perf.history.enabled': _Shape.boolean,
    'agent.models': _Shape.jsonList,
    'agent.selected_model_id': _Shape.string,
    'agent.model_catalog': _Shape.jsonMap,
    'fdroid.sources': _Shape.jsonList,
    'fdroid.last_source_id': _Shape.string,
    'discovery.selected_channels': _Shape.stringList,
    'network.proxy_url': _Shape.string,
    'catalog.source_url': _Shape.string,
    'proxy.engine_stack': _Shape.string,
    'proxy.engine_mtu': _Shape.integer,
    'proxy.routing_mode': _Shape.string,
    'proxy.run_mode': _Shape.string,
    // Rust registry: `proxy.active_node_label` is ConfigValueType::Json (object),
    // NOT String. The legacy store holds a JSON *string*; it must be parsed to
    // a Map before crossing the FFI seam (otherwise file-level import fails
    // with config_type_mismatch).
    'proxy.active_node_label': _Shape.jsonMap,
    'proxy.active_profile_id': _Shape.string,
    'proxy.sheet_view_mode': _Shape.string,
    'proxy.split_mode': _Shape.string,
    'proxy.split_apps': _Shape.stringList,
    'proxy.always_on_intent': _Shape.boolean,
    'proxy.log_level': _Shape.string,
    'webdav.url': _Shape.string,
    'webdav.username': _Shape.string,
    'webdav.password': _Shape.string,
    'webdav.backup_path': _Shape.string,
    'webdav.enable_https': _Shape.boolean,
  };

  /// All storage keys in the explicit table (test/static guard helper).
  static Set<String> get allStorageKeys =>
      storageKeyToWireKeys.keys.toSet();

  /// Runs the one-time migration. Never throws.
  ///
  /// [api] and [source] are test seams; production leaves them `null`.
  static Future<ConfigMigrationReport> run({
    ConfigMigrationProgress? onProgress,
    String? backupDir,
    ConfigMigrationApi? api,
    LegacyConfigSource? source,
  }) async {
    ConfigMigrationApi migrationApi;
    if (api != null) {
      migrationApi = api;
    } else {
      try {
        migrationApi = await GeneratedConfigMigrationApi.create();
      } catch (_) {
        return const ConfigMigrationReport(
          coreReady: false,
          errorCode: 'core_not_initialized',
        );
      }
    }

    try {
      final existingMarker = await migrationApi.getMeta(kConfigMigrationMarkerKey);
      if (existingMarker != null) {
        return const ConfigMigrationReport(
          alreadyDone: true,
          coreReady: true,
        );
      }
    } catch (_) {
      return const ConfigMigrationReport(
        coreReady: false,
        errorCode: 'core_not_initialized',
      );
    }

    try {
      final legacySource = source ?? await DefaultLegacyConfigSource.create();
      final prefs = await legacySource.readPrefs();
      final secure = await legacySource.readSecure();

      final orderedKeys = _orderedStorageKeys();
      final presentKeys = <String>[
        for (final key in orderedKeys)
          if (_rawValueOf(key, prefs, secure) != null) key,
      ];
      final total = presentKeys.length;
      onProgress?.call(0, total);

      final batches = <_DecodedBatch>[];
      for (var index = 0; index < presentKeys.length; index++) {
        final storageKey = presentKeys[index];
        batches.add(
          _decodeStorageKey(storageKey, _rawValueOf(storageKey, prefs, secure)),
        );
        onProgress?.call(index + 1, total);
      }

      // Merge by wire key: keys are visited low → high priority, so a later
      // (higher-priority) value overwrites the stale copy. WebDAV therefore
      // resolves as bare `WebDavConfigManager` > `secure_config_` provider copy.
      final winner = <String, MigrationEntry>{};
      for (final batch in batches) {
        for (final entry in batch.entries) {
          winner[entry.wireKey] = entry;
        }
        for (final wireKey in batch.failures.keys) {
          winner.remove(wireKey);
        }
      }

      final keyReports = <MigrationKeyReport>[];
      final pending = <_PendingEntry>[];
      for (final batch in batches) {
        for (final entry in batch.entries) {
          if (identical(winner[entry.wireKey], entry)) {
            pending.add(_PendingEntry(batch.storageKey, entry));
          } else {
            keyReports.add(
              MigrationKeyReport(
                storageKey: batch.storageKey,
                wireKey: entry.wireKey,
                status: 'superseded',
              ),
            );
          }
        }
        batch.failures.forEach((wireKey, code) {
          keyReports.add(
            MigrationKeyReport(
              storageKey: batch.storageKey,
              wireKey: wireKey,
              status: winner.containsKey(wireKey) ? 'superseded' : 'failed',
              code: winner.containsKey(wireKey) ? null : code,
            ),
          );
        });
      }

      var importResult = const MigrationImportResult();
      final verifyFailures = <String, String>{};
      var verifyAllMatched = true;
      if (pending.isNotEmpty) {
        final entries = <MigrationEntry>[
          for (final item in pending) item.entry,
        ];
        importResult = await migrationApi.importEntries(
          entries,
          source: kConfigMigrationSource,
        );
        final verifyResult = await migrationApi.verifyEntries(entries);
        verifyFailures.addAll(verifyResult.failed);
        // Marker decision uses the report's own contract, not just the failure
        // map: matched == total AND no non-match results.
        verifyAllMatched = verifyResult.allMatched;

        for (final item in pending) {
          final importCode = importResult.failed[item.entry.wireKey];
          final verifyCode = verifyFailures[item.entry.wireKey];
          if (importCode != null) {
            keyReports.add(
              MigrationKeyReport(
                storageKey: item.storageKey,
                wireKey: item.entry.wireKey,
                status: 'failed',
                code: importCode,
              ),
            );
          } else if (verifyCode != null) {
            keyReports.add(
              MigrationKeyReport(
                storageKey: item.storageKey,
                wireKey: item.entry.wireKey,
                status: 'failed',
                code: verifyCode,
              ),
            );
          } else {
            keyReports.add(
              MigrationKeyReport(
                storageKey: item.storageKey,
                wireKey: item.entry.wireKey,
                status: 'applied',
              ),
            );
          }
        }
      }

      final secrets = _collectSecrets(prefs, secure);
      final backupContent = _buildBackupContent(prefs, secure);
      String? backupPath;
      if (backupDir != null) {
        try {
          backupPath = await _writeBackup(backupDir, backupContent);
        } catch (_) {
          backupPath = null;
        }
      }

      final failedCount =
          keyReports.where((report) => report.status == 'failed').length;
      // Structured exact-value scan: parse the backup/marker JSON and compare
      // each string scalar to the collected secrets. Exact equality avoids
      // false positives on ordinary tokens such as `config` / `prefs` /
      // `migration` / `applied`, while still catching a raw password/API key
      // (which is stored as its own JSON string value if sanitising regressed).
      var secretScanClean =
          !containsAnySecretValue(jsonDecode(backupContent), secrets);

      final markerPayload = <String, Object?>{
        'version': 1,
        'markerKey': kConfigMigrationMarkerKey,
        'source': kConfigMigrationSource,
        'alreadyDone': false,
        'totalStorageKeys': total,
        'applied': importResult.applied,
        'unchanged': importResult.unchanged,
        'failed': failedCount,
        'verifyFailures': verifyFailures.length,
        'secretScanClean': secretScanClean,
        'backupFile': backupPath == null ? null : p.basename(backupPath),
        'keys': <Map<String, Object?>>[
          for (final report in keyReports) report.toJson(),
        ],
      };
      final markerJson = jsonEncode(markerPayload);
      // `config_meta` participates in the secret scan (C15), but *structurally*,
      // not by exact-value comparison against user secrets. The marker is built
      // exclusively from identifiers/statuses, so a password that happens to be
      // "migration" or "applied" must not false-positive against
      // `"source":"migration"` / `"status":"applied"`. Instead we assert the
      // marker owns only the known structural vocabulary; a user value (or an
      // unknown field) in the marker fails the scan.
      secretScanClean = secretScanClean &&
          markerHasOnlyStructuralFields(jsonDecode(markerJson));

      final blocked =
          failedCount > 0 || !verifyAllMatched || !secretScanClean;
      var markerWritten = false;
      String? errorCode;
      if (!blocked) {
        try {
          await migrationApi.setMeta(kConfigMigrationMarkerKey, markerJson);
          markerWritten = true;
        } catch (_) {
          errorCode = 'marker_write_failed';
        }
      } else if (failedCount > 0 || !verifyAllMatched) {
        errorCode = 'migration_incomplete';
      } else {
        errorCode = 'secret_leak';
      }

      return ConfigMigrationReport(
        coreReady: true,
        totalStorageKeys: total,
        applied: importResult.applied,
        unchanged: importResult.unchanged,
        failed: failedCount,
        verifyFailures: verifyFailures.length,
        markerWritten: markerWritten,
        backupPath: backupPath,
        secretScanClean: secretScanClean,
        errorCode: errorCode,
        keys: List<MigrationKeyReport>.unmodifiable(keyReports),
      );
    } catch (_) {
      // Non-fatal: marker is not written, the next launch retries. Old keys
      // are untouched because this tool never deletes anything.
      return const ConfigMigrationReport(
        coreReady: true,
        errorCode: 'migration_failed',
      );
    }
  }

  /// Low → high precedence order (stable within a priority band).
  static List<String> _orderedStorageKeys() {
    final ordered = <String>[];
    for (var priority = 0; priority <= 3; priority++) {
      for (final key in storageKeyToWireKeys.keys) {
        if (_priorityOf(key) == priority) ordered.add(key);
      }
    }
    return ordered;
  }

  static int _priorityOf(String storageKey) {
    if (storageKey.startsWith('secure_config_')) return 0;
    if (storageKey.startsWith('webdav_')) return 1;
    if (_bareLegacyStorageKeys.contains(storageKey)) return 2;
    return 3;
  }

  static Object? _rawValueOf(
    String storageKey,
    Map<String, Object?> prefs,
    Map<String, String?> secure,
  ) {
    if (storageKey.startsWith('webdav_') ||
        storageKey.startsWith('secure_config_')) {
      if (secure.containsKey(storageKey)) return secure[storageKey];
      return prefs[storageKey];
    }
    if (prefs.containsKey(storageKey)) return prefs[storageKey];
    return secure[storageKey];
  }

  static _DecodedBatch _decodeStorageKey(String storageKey, Object? raw) {
    final wireKeys = storageKeyToWireKeys[storageKey]!;
    if (storageKey == 'config_update_config') {
      return _decodeUpdateConfig(storageKey, raw);
    }
    final wireKey = wireKeys.single;
    final shape = wireKey.startsWith('module.') &&
            wireKey.endsWith('.enabled')
        ? _Shape.boolean
        : (_shapeByWireKey[wireKey] ?? _Shape.string);
    try {
      final value = _decodeScalar(shape, raw);
      return _DecodedBatch(
        storageKey,
        entries: <MigrationEntry>[
          MigrationEntry(wireKey: wireKey, value: value),
        ],
      );
    } on _DecodeException catch (error) {
      return _DecodedBatch(
        storageKey,
        failures: <String, String>{wireKey: error.code},
      );
    }
  }

  static _DecodedBatch _decodeUpdateConfig(String storageKey, Object? raw) {
    final decoded = _decodeJsonLenient(raw);
    if (decoded is! Map) {
      return _DecodedBatch(
        storageKey,
        failures: <String, String>{
          for (final wireKey in storageKeyToWireKeys[storageKey]!)
            wireKey: 'config_invalid_json',
        },
      );
    }
    final json = <String, Object?>{
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
    };
    final batch = _DecodedBatch(storageKey);

    void put(String wireKey, Object? value) {
      batch.entries.add(MigrationEntry(wireKey: wireKey, value: value));
    }

    void fail(String wireKey, String code) {
      batch.failures[wireKey] = code;
    }

    final channel = _encodeUpdateChannel(json['channel']);
    if (json['channel'] != null) {
      if (channel == null) {
        fail('update.channel', 'config_invalid_enum');
      } else {
        put('update.channel', channel);
      }
    }

    final policy = _encodeUpdatePolicy(json['autoUpdatePolicy']);
    if (json['autoUpdatePolicy'] != null) {
      if (policy == null) {
        fail('update.auto_update_policy', 'config_invalid_enum');
      } else {
        put('update.auto_update_policy', policy);
      }
    }

    for (final field in const <String>[
      'ignorePrerelease',
      'silentUpdate',
    ]) {
      final value = json[field];
      if (value == null) continue;
      try {
        put(
          field == 'ignorePrerelease'
              ? 'update.ignore_prerelease'
              : 'update.silent_update',
          _asBool(value),
        );
      } on _DecodeException catch (error) {
        fail(
          field == 'ignorePrerelease'
              ? 'update.ignore_prerelease'
              : 'update.silent_update',
          error.code,
        );
      }
    }

    final interval = json['checkIntervalHours'];
    if (interval != null) {
      try {
        put('update.check_interval_hours', _asInt(interval));
      } on _DecodeException catch (error) {
        fail('update.check_interval_hours', error.code);
      }
    }

    final lastCheckTime = json['lastCheckTime'];
    if (lastCheckTime != null) {
      try {
        put('update.last_check_time', _asString(lastCheckTime));
      } on _DecodeException catch (error) {
        fail('update.last_check_time', error.code);
      }
    }

    final lastVersion = json['lastUpdatedVersion'];
    if (lastVersion != null) {
      try {
        put('update.last_updated_version', _asString(lastVersion));
      } on _DecodeException catch (error) {
        fail('update.last_updated_version', error.code);
      }
    }

    return batch;
  }

  static String? _encodeUpdateChannel(Object? raw) {
    if (raw is int) {
      const values = <String>['stable', 'beta', 'dev'];
      return raw >= 0 && raw < values.length ? values[raw] : null;
    }
    if (raw is String) {
      final text = raw.trim();
      final name = text.contains('.') ? text.split('.').last : text;
      return switch (name.toLowerCase()) {
        'stable' => 'stable',
        'beta' => 'beta',
        'dev' => 'dev',
        _ => null,
      };
    }
    return null;
  }

  static String? _encodeUpdatePolicy(Object? raw) {
    if (raw is int) {
      const values = <String>['never', 'wifi_only', 'always'];
      return raw >= 0 && raw < values.length ? values[raw] : null;
    }
    if (raw is String) {
      final text = raw.trim();
      final name = text.contains('.') ? text.split('.').last : text;
      return switch (name.toLowerCase()) {
        'never' => 'never',
        'wifionly' || 'wifi_only' => 'wifi_only',
        'always' => 'always',
        _ => null,
      };
    }
    return null;
  }

  static Object? _decodeScalar(_Shape shape, Object? raw) {
    return switch (shape) {
      _Shape.boolean => _asBool(raw),
      _Shape.integer => _asInt(raw),
      _Shape.string => _asString(raw),
      _Shape.jsonMap => _asJsonMap(raw),
      _Shape.jsonList => _asJsonList(raw),
      _Shape.stringList => _asStringList(raw),
    };
  }

  static bool _asBool(Object? raw) {
    if (raw is bool) return raw;
    if (raw is int) return raw != 0;
    if (raw is String) {
      final text = raw.trim().toLowerCase();
      if (text == 'true' || text == '1') return true;
      if (text == 'false' || text == '0') return false;
    }
    throw const _DecodeException('config_invalid_bool');
  }

  static int _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num && raw == raw.roundToDouble()) return raw.toInt();
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null) return parsed;
      final asDouble = double.tryParse(raw.trim());
      if (asDouble != null && asDouble == asDouble.roundToDouble()) {
        return asDouble.toInt();
      }
    }
    throw const _DecodeException('config_invalid_int');
  }

  static String _asString(Object? raw) {
    if (raw is String) return raw;
    if (raw is Map || raw is List) return jsonEncode(raw);
    if (raw is num || raw is bool) return raw.toString();
    throw const _DecodeException('config_invalid_string');
  }

  static Map<String, Object?> _asJsonMap(Object? raw) {
    final decoded = _decodeJsonLenient(raw);
    if (decoded is Map) {
      return <String, Object?>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      };
    }
    throw const _DecodeException('config_invalid_json');
  }

  static List<Object?> _asJsonList(Object? raw) {
    final decoded = _decodeJsonLenient(raw);
    if (decoded is List) return List<Object?>.from(decoded);
    throw const _DecodeException('config_invalid_json');
  }

  static List<String> _asStringList(Object? raw) {
    if (raw is List) {
      return <String>[for (final item in raw) item.toString()];
    }
    if (raw is String) {
      final text = raw.trim();
      if (text.isEmpty) return const <String>[];
      if (text.startsWith('[')) {
        final decoded = _decodeJsonLenient(text);
        if (decoded is List) {
          return <String>[for (final item in decoded) item.toString()];
        }
        throw const _DecodeException('config_invalid_json');
      }
      return <String>[
        for (final part in text.split(','))
          if (part.trim().isNotEmpty) part.trim(),
      ];
    }
    throw const _DecodeException('config_invalid_string_list');
  }

  /// Decodes 0–2 layers of JSON strings (historical double encoding, C6).
  static Object? _decodeJsonLenient(Object? raw) {
    var value = raw;
    for (var depth = 0; depth < 2 && value is String; depth++) {
      final text = value.trim();
      if (text.isEmpty) return null;
      final looksJson = text.startsWith('{') ||
          text.startsWith('[') ||
          text.startsWith('"');
      if (!looksJson) return null;
      try {
        value = jsonDecode(text);
      } catch (_) {
        return null;
      }
    }
    return value;
  }

  static Set<String> _collectSecrets(
    Map<String, Object?> prefs,
    Map<String, String?> secure,
  ) {
    final secrets = <String>{};
    void collect(String key, Object? value) {
      if (value == null) return;
      if (_isPasswordKey(key)) {
        final text = value.toString();
        if (text.isNotEmpty) secrets.add(text);
      }
      if (isAgentModelsKey(key)) {
        final decoded = _decodeJsonLenient(value);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              for (final field in const <String>['apiKey', 'api_key']) {
                final apiKey = item[field];
                if (apiKey is String && apiKey.isNotEmpty) {
                  secrets.add(apiKey);
                }
              }
            }
          }
        }
      }
    }

    prefs.forEach(collect);
    secure.forEach(collect);
    return secrets;
  }

  static bool _isPasswordKey(String key) =>
      key == 'webdav_password' ||
      key == 'secure_config_webdav_password' ||
      key.toLowerCase().contains('password');

  /// Agent model lists carry API keys; exposed for the backup redactor/tests.
  @visibleForTesting
  static bool isAgentModelsKey(String key) =>
      _agentModelsStorageKeys.contains(key);

  static String _buildBackupContent(
    Map<String, Object?> prefs,
    Map<String, String?> secure,
  ) {
    final payload = <String, Object?>{
      'version': 1,
      'kind': 'config_migration_backup',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'markerKey': kConfigMigrationMarkerKey,
      'note': 'Secrets are omitted or masked; old keys are never deleted.',
      'prefs': _sanitizeForBackup(prefs),
      'secure': _sanitizeForBackup(<String, Object?>{
        for (final entry in secure.entries) entry.key: entry.value,
      }),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  static Map<String, Object?> _sanitizeForBackup(Map<String, Object?> values) {
    final sanitized = <String, Object?>{};
    values.forEach((key, value) {
      if (_isPasswordKey(key)) return; // omit raw passwords entirely
      if (isAgentModelsKey(key)) {
        final masked = _maskAgentModels(value);
        if (masked != null) sanitized[key] = masked;
        return;
      }
      sanitized[key] = value;
    });
    return sanitized;
  }

  static Object? _maskAgentModels(Object? raw) {
    final decoded = _decodeJsonLenient(raw);
    if (decoded is! List) return null; // unparseable: omit rather than leak
    return <Object?>[
      for (final item in decoded)
        if (item is Map)
          <String, Object?>{
            for (final entry in item.entries)
              entry.key.toString(): _isAgentSecretField(entry.key.toString())
                  ? '<redacted>'
                  : entry.value,
          }
        else
          '<redacted>',
    ];
  }

  static bool _isAgentSecretField(String key) =>
      key == 'apiKey' || key == 'api_key' || key == 'key';

  /// Whether any string scalar in [decoded] is exactly one of [secrets].
  ///
  /// Structured, exact-value scan (not a whole-document substring search):
  /// ordinary tokens such as `config` / `prefs` / `migration` / `applied`
  /// cannot trigger a false positive, while a raw secret that survived
  /// sanitisation is a distinct JSON string value and is caught. Exposed so
  /// the mutation regression test can prove the scanner still detects a leak.
  @visibleForTesting
  static bool containsAnySecretValue(
    Object? decoded,
    Iterable<String> secrets,
  ) {
    final values = <String>{
      for (final secret in secrets)
        if (secret.isNotEmpty) secret,
    };
    if (values.isEmpty) return false;

    bool walk(Object? node) {
      if (node is String) return values.contains(node);
      if (node is Map) return node.values.any(walk);
      if (node is List) return node.any(walk);
      return false;
    }

    return walk(decoded);
  }

  static const Set<String> _markerTopLevelFields = <String>{
    'version',
    'markerKey',
    'source',
    'alreadyDone',
    'coreReady',
    'totalStorageKeys',
    'applied',
    'unchanged',
    'failed',
    'verifyFailures',
    'markerWritten',
    'secretScanClean',
    'backupFile',
    'errorCode',
    'keys',
  };

  static const Set<String> _markerKeyEntryFields = <String>{
    'storageKey',
    'wireKey',
    'status',
    'code',
  };

  static const Set<String> _markerStatuses = <String>{
    'applied',
    'superseded',
    'failed',
  };

  /// Structural ownership check for the `config_meta` marker payload (C15).
  ///
  /// The marker is built only from the tool's own vocabulary: fixed top-level
  /// fields, `storageKey`s from the migration table, grouped `wireKey`s from
  /// the same table, statuses, and stable codes. It can therefore never carry
  /// a user value. This check proves that shape directly instead of comparing
  /// marker strings against user secrets — which would false-positive when a
  /// WebDAV password is literally `migration` or `applied` (those are marker
  /// structural vocabulary, not leaked data).
  ///
  /// Exposed so the regression test can assert the real marker passes and a
  /// mutated marker carrying a user value / unknown field fails.
  @visibleForTesting
  static bool markerHasOnlyStructuralFields(Object? decoded) {
    if (decoded is! Map) return false;
    if (decoded['markerKey'] != kConfigMigrationMarkerKey) return false;
    if (decoded['source'] != kConfigMigrationSource) return false;
    if (decoded['version'] is! int) return false;
    for (final field in decoded.keys) {
      if (!_markerTopLevelFields.contains(field.toString())) return false;
    }

    final keys = decoded['keys'];
    if (keys is! List) return false;
    final knownWireKeys =
        storageKeyToWireKeys.values.expand((wires) => wires).toSet();
    for (final entry in keys) {
      if (entry is! Map) return false;
      for (final field in entry.keys) {
        if (!_markerKeyEntryFields.contains(field.toString())) return false;
      }
      final storageKey = entry['storageKey'];
      final wireKey = entry['wireKey'];
      final status = entry['status'];
      final code = entry['code'];
      if (storageKey is! String || !allStorageKeys.contains(storageKey)) {
        return false;
      }
      if (wireKey is! String || !knownWireKeys.contains(wireKey)) return false;
      if (status is! String || !_markerStatuses.contains(status)) return false;
      if (code != null && code is! String) return false;
    }
    return true;
  }

  static Future<String> _writeBackup(String backupDir, String content) async {
    final directory = Directory(backupDir);
    await directory.create(recursive: true);
    final name =
        '$kConfigMigrationBackupPrefix${DateTime.now().toUtc().millisecondsSinceEpoch}.json';
    final file = File(p.join(directory.path, name));
    await file.writeAsString(content, flush: true);
    // Defense in depth: the file is already secret-free, but keep it owner-only.
    try {
      await Process.run('chmod', <String>['600', file.path]);
    } catch (_) {
      // Best effort (non-POSIX hosts).
    }
    return file.path;
  }
}
