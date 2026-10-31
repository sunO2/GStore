/// Pure legacy → grouped config mapping (plan Todo 21 + Todo 22).
///
/// This library deliberately has **zero** Flutter / FRB / IO imports so it can
/// be shared by two very different consumers:
///
/// * `ConfigMigrationTool` (Todo 21) — runs on-device and pushes the mapped
///   entries through `ConfigApi`,
/// * `tool/migrate_config.dart` (Todo 22) — an offline JSON transformer that
///   runs on a plain Dart VM with no engine and no device.
///
/// Keeping the storage-key table and the decoders here is what stops the two
/// paths from drifting: there is exactly one table and one decoder.
library;

import 'dart:convert';

/// Explicit **storage key → grouped wire key(s)** table (C15).
///
/// These are the real on-disk keys, not logical object names. There is no
/// single `download_config` / `webdav_config` value on disk: download is
/// stored per field, WebDAV per field, and `config_update_config` is the only
/// aggregated JSON whose fields are split **after** parsing.
const Map<String, List<String>> kLegacyStorageKeyToWireKeys =
    <String, List<String>>{
  // ---- download (per-field storage, no `config_download_config`) ----
  'config_download_multi_segment': <String>['download.multi_segment.enabled'],
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

const Set<String> kLegacyBareStorageKeys = <String>{
  'fdroid_sources',
  'last_source_id',
  'selected_channels',
  'agent_models',
  'agent_selected_model_id',
};

const Set<String> kLegacyAgentModelsStorageKeys = <String>{
  'config_agent_models',
  'agent_models',
  'secure_config_agent_models',
};

/// Registry value shapes for keys that are not bare module toggles.
enum LegacyShape { boolean, integer, string, jsonMap, jsonList, stringList }

const Map<String, LegacyShape> kLegacyShapeByWireKey = <String, LegacyShape>{
  'download.multi_segment.enabled': LegacyShape.boolean,
  'download.max_concurrent': LegacyShape.integer,
  'download.wifi_only': LegacyShape.boolean,
  'download.max_retries': LegacyShape.integer,
  'theme.config': LegacyShape.jsonMap,
  'theme.mode': LegacyShape.integer,
  'perf.profiles': LegacyShape.jsonMap,
  'perf.profiles.enabled': LegacyShape.boolean,
  'perf.history.enabled': LegacyShape.boolean,
  'agent.models': LegacyShape.jsonList,
  'agent.selected_model_id': LegacyShape.string,
  'agent.model_catalog': LegacyShape.jsonMap,
  'fdroid.sources': LegacyShape.jsonList,
  'fdroid.last_source_id': LegacyShape.string,
  'discovery.selected_channels': LegacyShape.stringList,
  'network.proxy_url': LegacyShape.string,
  'catalog.source_url': LegacyShape.string,
  'proxy.engine_stack': LegacyShape.string,
  'proxy.engine_mtu': LegacyShape.integer,
  'proxy.routing_mode': LegacyShape.string,
  'proxy.run_mode': LegacyShape.string,
  // Rust registry: `proxy.active_node_label` is ConfigValueType::Json (object),
  // NOT String. The legacy store holds a JSON *string*; it must be parsed to
  // a Map before crossing the FFI seam (otherwise file-level import fails with
  // config_type_mismatch).
  'proxy.active_node_label': LegacyShape.jsonMap,
  'proxy.active_profile_id': LegacyShape.string,
  'proxy.sheet_view_mode': LegacyShape.string,
  'proxy.split_mode': LegacyShape.string,
  'proxy.split_apps': LegacyShape.stringList,
  'proxy.always_on_intent': LegacyShape.boolean,
  'proxy.log_level': LegacyShape.string,
  'webdav.url': LegacyShape.string,
  'webdav.username': LegacyShape.string,
  'webdav.password': LegacyShape.string,
  'webdav.backup_path': LegacyShape.string,
  'webdav.enable_https': LegacyShape.boolean,
};

/// All storage keys in the explicit table (static guard helper).
Set<String> get allLegacyStorageKeys => kLegacyStorageKeyToWireKeys.keys.toSet();

/// A mapped grouped entry (`module.key` → decoded value).
class MappedLegacyValue {
  const MappedLegacyValue({
    required this.storageKey,
    required this.wireKey,
    required this.value,
  });

  final String storageKey;
  final String wireKey;
  final Object? value;

  String get module => wireKey.substring(0, wireKey.indexOf('.'));

  String get key => wireKey.substring(wireKey.indexOf('.') + 1);

  String get valueJson => jsonEncode(value);
}

/// Per-key outcome. **No values.**
class LegacyKeyStatus {
  const LegacyKeyStatus({
    required this.storageKey,
    required this.wireKey,
    required this.status,
    this.code,
  });

  final String storageKey;
  final String wireKey;

  /// `superseded` / `failed` (winners are resolved by the caller after import).
  final String status;

  /// Stable failure code (`config_invalid_json`, `config_invalid_enum`, …).
  final String? code;
}

/// Result of a pure mapping pass.
class LegacyMappingResult {
  const LegacyMappingResult({
    required this.totalStorageKeys,
    required this.pending,
    required this.reports,
  });

  /// Number of legacy storage keys actually present in the export.
  final int totalStorageKeys;

  /// Winning entries, in low → high precedence storage order.
  final List<MappedLegacyValue> pending;

  /// Non-winning per-key statuses (`superseded`) plus hard failures.
  final List<LegacyKeyStatus> reports;

  int get failedCount =>
      reports.where((report) => report.status == 'failed').length;

  /// Winners grouped as `module -> key -> value` (the real output artifact).
  Map<String, Map<String, Object?>> get groupedConfig {
    final grouped = <String, Map<String, Object?>>{};
    for (final entry in pending) {
      grouped.putIfAbsent(entry.module, () => <String, Object?>{})[entry.key] =
          entry.value;
    }
    return grouped;
  }
}

/// Raised for structurally invalid exports (not per-key decode failures).
class LegacyMappingException implements Exception {
  const LegacyMappingException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'LegacyMappingException($code: $message)';
}

class _DecodeException implements Exception {
  const _DecodeException(this.code);

  final String code;
}

class _DecodedBatch {
  _DecodedBatch(
    this.storageKey, {
    List<MappedLegacyValue>? entries,
    Map<String, String>? failures,
  })  : entries = entries ?? <MappedLegacyValue>[],
        failures = failures ?? <String, String>{};

  final String storageKey;
  final List<MappedLegacyValue> entries;

  /// Wire key → stable code for fields that could not be decoded.
  final Map<String, String> failures;
}

/// Low → high precedence order (stable within a priority band).
List<String> orderedLegacyStorageKeys() {
  final ordered = <String>[];
  for (var priority = 0; priority <= 3; priority++) {
    for (final key in kLegacyStorageKeyToWireKeys.keys) {
      if (_priorityOf(key) == priority) ordered.add(key);
    }
  }
  return ordered;
}

int _priorityOf(String storageKey) {
  if (storageKey.startsWith('secure_config_')) return 0;
  if (storageKey.startsWith('webdav_')) return 1;
  if (kLegacyBareStorageKeys.contains(storageKey)) return 2;
  return 3;
}

/// Reads a key from the store that actually owns it (secure for credentials).
Object? legacyRawValueOf(
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

/// Maps a legacy prefs/secure snapshot to grouped entries, one pass.
///
/// Per-key failures never abort the pass: every present key is decoded, the
/// failures are collected, and the remaining winners are returned. WebDAV
/// resolves as bare `WebDavConfigManager` > stale `secure_config_` copy.
LegacyMappingResult mapLegacyConfig({
  required Map<String, Object?> prefs,
  required Map<String, String?> secure,
}) {
  final presentKeys = <String>[
    for (final key in orderedLegacyStorageKeys())
      if (legacyRawValueOf(key, prefs, secure) != null) key,
  ];

  final batches = <_DecodedBatch>[
    for (final key in presentKeys)
      _decodeStorageKey(key, legacyRawValueOf(key, prefs, secure)),
  ];

  // Merge by wire key: keys are visited low → high priority, so a later
  // (higher-priority) value overwrites the stale copy.
  final winner = <String, MappedLegacyValue>{};
  for (final batch in batches) {
    for (final entry in batch.entries) {
      winner[entry.wireKey] = entry;
    }
    for (final wireKey in batch.failures.keys) {
      winner.remove(wireKey);
    }
  }

  final reports = <LegacyKeyStatus>[];
  final pending = <MappedLegacyValue>[];
  for (final batch in batches) {
    for (final entry in batch.entries) {
      if (identical(winner[entry.wireKey], entry)) {
        pending.add(entry);
      } else {
        reports.add(
          LegacyKeyStatus(
            storageKey: batch.storageKey,
            wireKey: entry.wireKey,
            status: 'superseded',
          ),
        );
      }
    }
    batch.failures.forEach((wireKey, code) {
      reports.add(
        LegacyKeyStatus(
          storageKey: batch.storageKey,
          wireKey: wireKey,
          status: winner.containsKey(wireKey) ? 'superseded' : 'failed',
          code: winner.containsKey(wireKey) ? null : code,
        ),
      );
    });
  }

  return LegacyMappingResult(
    totalStorageKeys: presentKeys.length,
    pending: pending,
    reports: reports,
  );
}

_DecodedBatch _decodeStorageKey(String storageKey, Object? raw) {
  final wireKeys = kLegacyStorageKeyToWireKeys[storageKey]!;
  if (storageKey == 'config_update_config') {
    return _decodeUpdateConfig(storageKey, raw);
  }
  final wireKey = wireKeys.single;
  final shape = wireKey.startsWith('module.') && wireKey.endsWith('.enabled')
      ? LegacyShape.boolean
      : (kLegacyShapeByWireKey[wireKey] ?? LegacyShape.string);
  try {
    final value = _decodeScalar(shape, raw);
    return _DecodedBatch(
      storageKey,
      entries: <MappedLegacyValue>[
        MappedLegacyValue(storageKey: storageKey, wireKey: wireKey, value: value),
      ],
    );
  } on _DecodeException catch (error) {
    return _DecodedBatch(
      storageKey,
      failures: <String, String>{wireKey: error.code},
    );
  }
}

_DecodedBatch _decodeUpdateConfig(String storageKey, Object? raw) {
  final decoded = decodeLegacyJsonLenient(raw);
  if (decoded is! Map) {
    return _DecodedBatch(
      storageKey,
      failures: <String, String>{
        for (final wireKey in kLegacyStorageKeyToWireKeys[storageKey]!)
          wireKey: 'config_invalid_json',
      },
    );
  }
  final json = <String, Object?>{
    for (final entry in decoded.entries) entry.key.toString(): entry.value,
  };
  final batch = _DecodedBatch(storageKey);

  void put(String wireKey, Object? value) {
    batch.entries.add(
      MappedLegacyValue(storageKey: storageKey, wireKey: wireKey, value: value),
    );
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

String? _encodeUpdateChannel(Object? raw) {
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

String? _encodeUpdatePolicy(Object? raw) {
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

Object? _decodeScalar(LegacyShape shape, Object? raw) {
  return switch (shape) {
    LegacyShape.boolean => _asBool(raw),
    LegacyShape.integer => _asInt(raw),
    LegacyShape.string => _asString(raw),
    LegacyShape.jsonMap => _asJsonMap(raw),
    LegacyShape.jsonList => _asJsonList(raw),
    LegacyShape.stringList => _asStringList(raw),
  };
}

bool _asBool(Object? raw) {
  if (raw is bool) return raw;
  if (raw is int) return raw != 0;
  if (raw is String) {
    final text = raw.trim().toLowerCase();
    if (text == 'true' || text == '1') return true;
    if (text == 'false' || text == '0') return false;
  }
  throw const _DecodeException('config_invalid_bool');
}

int _asInt(Object? raw) {
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

String _asString(Object? raw) {
  if (raw is String) return raw;
  if (raw is Map || raw is List) return jsonEncode(raw);
  if (raw is num || raw is bool) return raw.toString();
  throw const _DecodeException('config_invalid_string');
}

Map<String, Object?> _asJsonMap(Object? raw) {
  final decoded = decodeLegacyJsonLenient(raw);
  if (decoded is Map) {
    return <String, Object?>{
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
    };
  }
  throw const _DecodeException('config_invalid_json');
}

List<Object?> _asJsonList(Object? raw) {
  final decoded = decodeLegacyJsonLenient(raw);
  if (decoded is List) return List<Object?>.from(decoded);
  throw const _DecodeException('config_invalid_json');
}

List<String> _asStringList(Object? raw) {
  if (raw is List) {
    return <String>[for (final item in raw) item.toString()];
  }
  if (raw is String) {
    final text = raw.trim();
    if (text.isEmpty) return const <String>[];
    if (text.startsWith('[')) {
      final decoded = decodeLegacyJsonLenient(text);
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
Object? decodeLegacyJsonLenient(Object? raw) {
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

/// Agent model lists carry API keys; used by the backup redactor/tests.
bool isLegacyAgentModelsKey(String key) =>
    kLegacyAgentModelsStorageKeys.contains(key);
