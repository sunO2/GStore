/// Backup config restore adapter (plan Todo 27, corrections C9/C16).
///
/// Restores configuration from **both** archive locations a backup can carry:
///
/// * `apps.json` → `appConfig` (the payload embedded in `BackupData`), and
/// * `app_config.json` (the standalone bundle written by the new exporter).
///
/// Both locations are `ConfigBackupData`-shaped (`version` / `timestamp` /
/// `configs`) in new backups, but old backups are accepted too:
///
/// * a `configs` map holding the **real legacy storage keys**
///   (`config_download_max_concurrent`, bare `webdav_*`, …),
/// * a `configs` map holding the **legacy aggregate keys**
///   (`download_config`, `update_config`, `theme_config`, `agent_models`,
///   `webdav_config`),
/// * a flat map with no `configs` wrapper at all (defensive), and
/// * a mixture of grouped (`module.key`) and legacy keys in one payload.
///
/// Detection is shape-based, never only on `config_format`:
///
/// * a key with a known legacy storage name (or a bare legacy alias) is mapped
///   through the single real table in `legacy_config_mapping.dart`;
/// * a `module.key` key is a grouped wire key and is imported as-is;
/// * when both a grouped key and a legacy alias target the same wire key,
///   **the grouped key wins**;
/// * top-level `proxy_url` / `webdav_config` mirrors are lowest priority, so
///   grouped/legacy config values override them.
///
/// The adapter never uses the deleted legacy import path. It goes straight to the
/// Rust batch import seam (`ConfigApi.import_(entries, source)` through
/// [GeneratedConfigMigrationApi]) and returns a per-key report. One rejected or
/// malformed key is reported and never aborts the remaining restore.
///
/// Reports carry stable codes only — never values — so passwords/API keys
/// cannot leak through logging.
library;

import 'config_migration_tool.dart';
import 'legacy_config_mapping.dart';
import '../../config/config_registry.dart';

/// Stable `source` code passed to `ConfigApi.import`.
const String kConfigRestoreSource = 'backup_restore';

/// Source label for the payload embedded in `apps.json`.
const String kConfigRestoreAppsSource = 'apps.json.appConfig';

/// Source label for the standalone `app_config.json` bundle.
const String kConfigRestoreFileSource = 'app_config.json';

/// Metadata keys that belong to the `ConfigBackupData` envelope, not to the
/// config map. They are ignored when a payload is treated as a flat map.
const Set<String> _envelopeKeys = <String>{
  'version',
  'timestamp',
  'appVersion',
  'config_format',
};

/// Legacy aggregate keys that must be split into several grouped wire keys.
const Set<String> _aggregateLegacyKeys = <String>{
  LegacyConfigKeys.downloadConfig,
  LegacyConfigKeys.updateConfig,
  LegacyConfigKeys.themeConfig,
  LegacyConfigKeys.webdavConfig,
};

/// Bare legacy aliases whose names differ from their real storage key.
///
/// Everything else (`agent_models`, `fdroid_sources`, bare `webdav_*`, …) is
/// already a real storage key in [kLegacyStorageKeyToWireKeys].
const Map<String, String> _legacyAliasToStorageKey = <String, String>{
  LegacyConfigKeys.themeMode: 'config_theme_mode',
  LegacyConfigKeys.proxyUrl: 'config_proxy_url',
  LegacyConfigKeys.catalogUrl: 'config_catalog_url',
  LegacyConfigKeys.agentModelCatalog: 'config_agent_model_catalog',
};

/// One per-key restore outcome. Values are intentionally absent.
class ConfigRestoreEntryResult {
  const ConfigRestoreEntryResult({
    required this.source,
    required this.wireKey,
    required this.status,
    this.originalKey,
    this.code,
  });

  /// `apps.json.appConfig` or `app_config.json`.
  final String source;

  /// Grouped wire key that was restored, or the offending legacy key.
  final String wireKey;

  /// Key as it appeared in the backup (legacy storage/aggregate key), when it
  /// differs from [wireKey].
  final String? originalKey;

  /// `restored` / `failed` / `superseded`.
  final String status;

  /// Stable failure code (`config_invalid_json`, `config_unregistered_key`, …).
  final String? code;

  bool get isFailure => status == 'failed';
}

/// Result of one restore pass across both archive locations.
class ConfigRestoreReport {
  const ConfigRestoreReport({
    required this.total,
    required this.restored,
    required this.superseded,
    required this.failures,
    required this.entries,
  });

  /// Distinct keys attempted (restored + failed, excluding duplicates that were
  /// superseded before the import).
  final int total;

  /// Keys whose import was accepted by Rust.
  final int restored;

  /// Lower-priority duplicates that lost to a grouped/top-level winner.
  final int superseded;

  /// Wire key → stable failure code. Never a value.
  final Map<String, String> failures;

  /// Full per-key matrix (including superseded duplicates).
  final List<ConfigRestoreEntryResult> entries;

  bool get success => failures.isEmpty;

  int get failedCount => failures.length;

  static const ConfigRestoreReport empty = ConfigRestoreReport(
    total: 0,
    restored: 0,
    superseded: 0,
    failures: <String, String>{},
    entries: <ConfigRestoreEntryResult>[],
  );
}

/// Restores legacy and grouped backup config through the Rust import seam.
class ConfigRestoreAdapter {
  ConfigRestoreAdapter({
    ConfigMigrationApi? api,
    this.source = kConfigRestoreSource,
  }) : _api = api;

  /// Production factory: lazily creates the generated `ConfigApi` seam.
  static Future<ConfigRestoreAdapter> create({String source = kConfigRestoreSource}) async {
    return ConfigRestoreAdapter(api: await GeneratedConfigMigrationApi.create(), source: source);
  }

  final String source;
  ConfigMigrationApi? _api;

  Future<ConfigMigrationApi> _requireApi() async {
    final existing = _api;
    if (existing != null) return existing;
    final created = await GeneratedConfigMigrationApi.create();
    _api = created;
    return created;
  }

  /// Restores config from the given archive locations.
  ///
  /// [appsJson] is the parsed `apps.json`; its `appConfig` field is used. When
  /// the caller already has a `BackupData` (or a bare `appConfig` map) it can
  /// pass [embeddedAppConfig] instead. [appConfigJson] is the parsed
  /// `app_config.json` payload.
  Future<ConfigRestoreReport> restore({
    Map<String, dynamic>? appsJson,
    Map<String, dynamic>? appConfigJson,
    Map<String, dynamic>? embeddedAppConfig,
  }) async {
    final payloads = <({String source, Map<String, dynamic> payload})>[];
    final embedded = embeddedAppConfig ??
        _asStringMap(appsJson?['appConfig']);
    if (embedded != null) {
      payloads.add((source: kConfigRestoreAppsSource, payload: embedded));
    }
    if (appConfigJson != null) {
      payloads.add((source: kConfigRestoreFileSource, payload: appConfigJson));
    }
    if (payloads.isEmpty) return ConfigRestoreReport.empty;

    final planner = _RestorePlanner();
    for (final payload in payloads) {
      planner.addPayload(payload.payload, payload.source);
    }
    return planner.importWith(await _requireApi(), source: source);
  }
}

/// Builds the winning candidate set and merges the mapping/import reports.
class _RestorePlanner {
  final Map<String, _Candidate> _chosen = <String, _Candidate>{};
  final List<ConfigRestoreEntryResult> _mappingFailures =
      <ConfigRestoreEntryResult>[];
  final List<ConfigRestoreEntryResult> _mappingSuperseded =
      <ConfigRestoreEntryResult>[];

  void addPayload(Map<String, dynamic> payload, String source) {
    final configs = _configsOf(payload);
    final legacy = <String, Object?>{};

    for (final entry in configs.entries) {
      final key = entry.key;
      final value = entry.value;
      if (_isGroupedKey(key)) {
        _offer(_Candidate(
          wireKey: key,
          value: value,
          originalKey: key,
          source: source,
          priority: _Priority.grouped,
        ));
      } else if (_isKnownLegacyKey(key)) {
        legacy[key] = value;
      } else {
        _mappingFailures.add(ConfigRestoreEntryResult(
          source: source,
          wireKey: key,
          originalKey: key,
          status: 'failed',
          code: 'config_unrecognized_key',
        ));
      }
    }

    _offerLegacy(legacy, source, _Priority.legacyConfig);

    // Top-level mirrors from the same payload are the lowest-priority source.
    _offerLegacy(
      <String, Object?>{
        if (payload.containsKey(LegacyConfigKeys.proxyUrl))
          LegacyConfigKeys.proxyUrl: payload[LegacyConfigKeys.proxyUrl],
        if (payload.containsKey(LegacyConfigKeys.webdavConfig))
          LegacyConfigKeys.webdavConfig: payload[LegacyConfigKeys.webdavConfig],
      },
      source,
      _Priority.topLevel,
    );
  }

  void _offerLegacy(
    Map<String, Object?> legacy,
    String source,
    int priority,
  ) {
    if (legacy.isEmpty) return;

    final prefs = <String, Object?>{};
    legacy.forEach((key, value) {
      if (kLegacyStorageKeyToWireKeys.containsKey(key)) {
        prefs[key] = value;
        return;
      }
      if (key == LegacyConfigKeys.updateConfig) {
        prefs['config_update_config'] = value;
        return;
      }
      if (key == LegacyConfigKeys.themeConfig) {
        prefs['config_theme_config'] = value;
        return;
      }
      if (key == LegacyConfigKeys.downloadConfig) {
        final split = _splitDownloadConfig(value);
        if (split == null) {
          _mappingFailures.add(ConfigRestoreEntryResult(
            source: source,
            wireKey: key,
            originalKey: key,
            status: 'failed',
            code: 'config_invalid_json',
          ));
        } else {
          prefs.addAll(split);
        }
        return;
      }
      if (key == LegacyConfigKeys.webdavConfig) {
        final split = _splitWebdavConfig(value);
        if (split == null) {
          _mappingFailures.add(ConfigRestoreEntryResult(
            source: source,
            wireKey: key,
            originalKey: key,
            status: 'failed',
            code: 'config_invalid_json',
          ));
        } else {
          prefs.addAll(split);
        }
        return;
      }
      final storageKey = _legacyAliasToStorageKey[key];
      if (storageKey != null) {
        prefs[storageKey] = value;
        return;
      }
      _mappingFailures.add(ConfigRestoreEntryResult(
        source: source,
        wireKey: key,
        originalKey: key,
        status: 'failed',
        code: 'config_unrecognized_key',
      ));
    });

    if (prefs.isEmpty) return;
    final mapped = mapLegacyConfig(prefs: prefs, secure: <String, String?>{});
    for (final report in mapped.reports) {
      if (report.status == 'superseded') {
        _mappingSuperseded.add(ConfigRestoreEntryResult(
          source: source,
          wireKey: report.wireKey,
          originalKey: report.storageKey,
          status: 'superseded',
        ));
      } else {
        _mappingFailures.add(ConfigRestoreEntryResult(
          source: source,
          wireKey: report.wireKey,
          originalKey: report.storageKey,
          status: 'failed',
          code: report.code ?? 'config_invalid_value',
        ));
      }
    }
    for (final entry in mapped.pending) {
      _offer(_Candidate(
        wireKey: entry.wireKey,
        value: entry.value,
        originalKey: entry.storageKey,
        source: source,
        priority: priority,
      ));
    }
  }

  void _offer(_Candidate candidate) {
    final existing = _chosen[candidate.wireKey];
    if (existing == null) {
      _chosen[candidate.wireKey] = candidate;
      return;
    }
    // Equal priority means a later payload wins (app_config.json is processed
    // after apps.json.appConfig). Grouped (higher) always wins over legacy.
    if (candidate.priority >= existing.priority) {
      _chosen[candidate.wireKey] = candidate;
      _mappingSuperseded.add(ConfigRestoreEntryResult(
        source: existing.source,
        wireKey: existing.wireKey,
        originalKey: existing.originalKey,
        status: 'superseded',
      ));
    } else {
      _mappingSuperseded.add(ConfigRestoreEntryResult(
        source: candidate.source,
        wireKey: candidate.wireKey,
        originalKey: candidate.originalKey,
        status: 'superseded',
      ));
    }
  }

  Future<ConfigRestoreReport> importWith(
    ConfigMigrationApi api, {
    required String source,
  }) async {
    final entries = <ConfigRestoreEntryResult>[..._mappingSuperseded];
    final failures = <String, String>{};

    // A mapping failure for a wire key that ultimately had a grouped/legacy
    // winner is a loser, not a failure (e.g. bad alias + good grouped value).
    final failedOnly = <ConfigRestoreEntryResult>[];
    for (final failure in _mappingFailures) {
      if (_chosen.containsKey(failure.wireKey)) {
        entries.add(ConfigRestoreEntryResult(
          source: failure.source,
          wireKey: failure.wireKey,
          originalKey: failure.originalKey,
          status: 'superseded',
        ));
      } else {
        failedOnly.add(failure);
        failures[failure.wireKey] = failure.code ?? 'config_invalid_value';
      }
    }

    final candidates = _chosen.values.toList();
    if (candidates.isNotEmpty) {
      MigrationImportResult result;
      try {
        result = await api.importEntries(
          <MigrationEntry>[
            for (final candidate in candidates)
              MigrationEntry(
                wireKey: candidate.wireKey,
                value: candidate.value,
              ),
          ],
          source: source,
        );
        for (final candidate in candidates) {
          final code = result.failed[candidate.wireKey];
          if (code == null) {
            entries.add(ConfigRestoreEntryResult(
              source: candidate.source,
              wireKey: candidate.wireKey,
              originalKey: candidate.originalKey,
              status: 'restored',
            ));
          } else {
            entries.add(ConfigRestoreEntryResult(
              source: candidate.source,
              wireKey: candidate.wireKey,
              originalKey: candidate.originalKey,
              status: 'failed',
              code: code,
            ));
            failures[candidate.wireKey] = code;
          }
        }
      } catch (_) {
        // The whole import seam is unavailable (core not initialized, FFI
        // down). Report it per key instead of aborting the caller's restore.
        for (final candidate in candidates) {
          entries.add(ConfigRestoreEntryResult(
            source: candidate.source,
            wireKey: candidate.wireKey,
            originalKey: candidate.originalKey,
            status: 'failed',
            code: 'config_import_failed',
          ));
          failures[candidate.wireKey] = 'config_import_failed';
        }
      }
    }

    entries.addAll(failedOnly);
    final restored = entries.where((e) => e.status == 'restored').length;
    final superseded = entries.where((e) => e.status == 'superseded').length;
    final attempted = candidates.length +
        failures.keys.where((key) => !_chosen.containsKey(key)).length;

    return ConfigRestoreReport(
      total: attempted,
      restored: restored,
      superseded: superseded,
      failures: Map<String, String>.unmodifiable(failures),
      entries: List<ConfigRestoreEntryResult>.unmodifiable(entries),
    );
  }
}

class _Candidate {
  const _Candidate({
    required this.wireKey,
    required this.value,
    required this.originalKey,
    required this.source,
    required this.priority,
  });

  final String wireKey;
  final Object? value;
  final String originalKey;
  final String source;
  final int priority;
}

class _Priority {
  _Priority._();

  static const int topLevel = 0;
  static const int legacyConfig = 1;
  static const int grouped = 2;
}

/// Returns the config map from a `ConfigBackupData`-shaped payload, or treats
/// the whole payload as a flat legacy map when there is no `configs` wrapper.
Map<String, dynamic> _configsOf(Map<String, dynamic> payload) {
  final wrapped = payload['configs'];
  if (wrapped is Map) return _asStringMap(wrapped) ?? <String, dynamic>{};
  final flat = <String, dynamic>{};
  for (final entry in payload.entries) {
    if (_envelopeKeys.contains(entry.key)) continue;
    flat[entry.key] = entry.value;
  }
  return flat;
}

/// A grouped wire key is a `module.key` name that is **not** a legacy storage
/// key. Legacy storage keys use dots too (`config_perf.profiles`,
/// `config_module.channel.enabled`), so the prefix tables are checked first.
///
/// Unknown modules are still treated as grouped and handed to Rust, which owns
/// the registry and rejects them with `config_unregistered_key`; this adapter
/// deliberately does not duplicate the Rust schema.
bool _isGroupedKey(String key) {
  if (kLegacyStorageKeyToWireKeys.containsKey(key)) return false;
  if (LegacyConfigKeys.all.contains(key)) return false;
  if (key.startsWith('config_') || key.startsWith('secure_config_')) {
    return false;
  }
  final dot = key.indexOf('.');
  return dot > 0 && dot < key.length - 1;
}

bool _isKnownLegacyKey(String key) {
  return kLegacyStorageKeyToWireKeys.containsKey(key) ||
      _legacyAliasToStorageKey.containsKey(key) ||
      _aggregateLegacyKeys.contains(key);
}

Map<String, Object?>? _splitDownloadConfig(Object? raw) {
  final decoded = decodeLegacyJsonLenient(raw);
  if (decoded is! Map) return null;
  final map = <String, Object?>{
    for (final entry in decoded.entries) entry.key.toString(): entry.value,
  };
  final out = <String, Object?>{};
  void take(String storageKey, String field) {
    if (map.containsKey(field)) out[storageKey] = map[field];
  }

  take('config_download_multi_segment', 'multiSegmentEnabled');
  take('config_download_max_concurrent', 'maxConcurrentDownloads');
  take('config_download_wifi_only', 'wifiOnly');
  take('config_download_max_retry', 'maxRetryCount');
  return out;
}

Map<String, Object?>? _splitWebdavConfig(Object? raw) {
  final decoded = decodeLegacyJsonLenient(raw);
  if (decoded is! Map) return null;
  final map = <String, Object?>{
    for (final entry in decoded.entries) entry.key.toString(): entry.value,
  };
  final out = <String, Object?>{};
  void take(String storageKey, String field) {
    if (map.containsKey(field)) out[storageKey] = map[field];
  }

  take('webdav_url', 'url');
  take('webdav_username', 'username');
  take('webdav_password', 'password');
  take('webdav_backup_path', 'backupPath');
  take('webdav_enable_https', 'enableHttps');
  return out;
}

Map<String, dynamic>? _asStringMap(Object? value) {
  if (value is! Map) return null;
  return <String, dynamic>{
    for (final entry in value.entries) entry.key.toString(): entry.value,
  };
}
