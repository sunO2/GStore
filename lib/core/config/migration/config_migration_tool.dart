/// Standalone legacy → Rust config migration (plan Todo 21, corrections
/// C9/C15).
///
/// The migration is deliberately **standalone**: it does not use
/// legacy config stores / `ConfigStore` / `ConfigService` (those become a thin Rust
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
import 'legacy_config_mapping.dart';

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

class _PendingEntry {
  const _PendingEntry(this.storageKey, this.entry);

  final String storageKey;
  final MigrationEntry entry;
}

/// Standalone legacy-config migration (see the library docs).
class ConfigMigrationTool {
  ConfigMigrationTool._();

  /// Storage-key table and decoders live in the pure mapping helper so the
  /// on-device tool (Todo 21) and the offline CLI (Todo 22) share one source
  /// of truth and cannot drift.
  static Map<String, List<String>> get storageKeyToWireKeys =>
      kLegacyStorageKeyToWireKeys;

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

      // One pure mapping pass shared with the offline CLI (Todo 22): the
      // storage-key table and decoders live in `legacy_config_mapping.dart`,
      // so the on-device tool and `tool/migrate_config.dart` cannot drift.
      final mapping = mapLegacyConfig(prefs: prefs, secure: secure);
      final total = mapping.totalStorageKeys;
      onProgress?.call(0, total);
      for (var index = 0; index < total; index++) {
        onProgress?.call(index + 1, total);
      }

      final keyReports = <MigrationKeyReport>[
        for (final report in mapping.reports)
          MigrationKeyReport(
            storageKey: report.storageKey,
            wireKey: report.wireKey,
            status: report.status,
            code: report.code,
          ),
      ];
      final pending = <_PendingEntry>[
        for (final entry in mapping.pending)
          _PendingEntry(
            entry.storageKey,
            MigrationEntry(wireKey: entry.wireKey, value: entry.value),
          ),
      ];

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
        final decoded = decodeLegacyJsonLenient(value);
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
      isLegacyAgentModelsKey(key);

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
    final decoded = decodeLegacyJsonLenient(raw);
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
