// Todo 25 — migration acceptance gate: upgrade from the previous release.
//
// This is an end-to-end *upgrade* gate, not another fixture unit test. It seeds
// one realistic pre-upgrade snapshot (real on-disk `config_*` prefs keys, bare
// `webdav_*` secure keys, and the stale `secure_config_webdav_*` provider
// copy), runs the real `ConfigMigrationTool.run` over the same in-memory seams
// production uses, and then asserts the *whole* grouped end state:
//
//   * every expected `module.key` holds the expected **typed** value,
//   * the `config.migrated.v1` marker exists and the reconstruction report
//     lists 0 failures,
//   * old keys are still present (rollback remains possible),
//   * the plaintext backup artifact contains no raw secrets.
//
// The injected API mirror-enforces the Rust registry value types, so a
// migration that writes e.g. a JSON *string* where Rust expects an object fails
// here with `config_type_mismatch` instead of passing a presence-only check.
//
// No device, no network, no native library.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/migration/config_migration_tool.dart';

/// Registry value types mirrored from `rust/gstore_core/src/config/schema.rs`.
enum _WireType { boolean, integer, string, stringList, jsonObject, jsonArray }

_WireType? _wireTypeOf(String wireKey) {
  if (wireKey.startsWith('module.') && wireKey.endsWith('.enabled')) {
    return _WireType.boolean;
  }
  return _registryTypes[wireKey];
}

const Map<String, _WireType> _registryTypes = <String, _WireType>{
  'theme.config': _WireType.jsonObject,
  'theme.mode': _WireType.integer,
  'download.multi_segment.enabled': _WireType.boolean,
  'download.wifi_only': _WireType.boolean,
  'download.max_concurrent': _WireType.integer,
  'download.max_retries': _WireType.integer,
  'update.channel': _WireType.string,
  'update.auto_update_policy': _WireType.string,
  'update.ignore_prerelease': _WireType.boolean,
  'update.silent_update': _WireType.boolean,
  'update.check_interval_hours': _WireType.integer,
  'update.last_check_time': _WireType.string,
  'update.last_updated_version': _WireType.string,
  'webdav.url': _WireType.string,
  'webdav.username': _WireType.string,
  'webdav.password': _WireType.string,
  'webdav.backup_path': _WireType.string,
  'webdav.enable_https': _WireType.boolean,
  'network.proxy_url': _WireType.string,
  'catalog.source_url': _WireType.string,
  'agent.models': _WireType.jsonArray,
  'agent.selected_model_id': _WireType.string,
  'agent.model_catalog': _WireType.jsonObject,
  'fdroid.sources': _WireType.jsonArray,
  'fdroid.last_source_id': _WireType.string,
  'discovery.selected_channels': _WireType.stringList,
  'perf.profiles': _WireType.jsonObject,
  'perf.profiles.enabled': _WireType.boolean,
  'perf.history.enabled': _WireType.boolean,
  'proxy.engine_stack': _WireType.string,
  'proxy.engine_mtu': _WireType.integer,
  'proxy.routing_mode': _WireType.string,
  'proxy.run_mode': _WireType.string,
  'proxy.active_node_label': _WireType.jsonObject,
  'proxy.active_profile_id': _WireType.string,
  'proxy.sheet_view_mode': _WireType.string,
  'proxy.split_mode': _WireType.string,
  'proxy.split_apps': _WireType.stringList,
  'proxy.always_on_intent': _WireType.boolean,
  'proxy.log_level': _WireType.string,
};

/// Enum sets mirrored from `rust/gstore_core/src/config/schema.rs`.
///
/// Rust `ConfigEntry::validate_value` enforces `enum_values` only when the
/// decoded JSON value is a string, so this map covers exactly the enumerated
/// **string** keys. The one numeric enum (`theme.mode` = 0|1|2) is documented
/// by the registry but, like Rust, is not enum-checked here for an int value.
const Map<String, Set<String>> _enumValuesByKey = <String, Set<String>>{
  'update.channel': <String>{'stable', 'beta', 'dev'},
  'update.auto_update_policy': <String>{'never', 'wifi_only', 'always'},
  'proxy.engine_stack': <String>{'gvisor', 'system'},
  'proxy.routing_mode': <String>{'direct', 'rule', 'global'},
  'proxy.run_mode': <String>{'off', 'vpn', 'lanProxy'},
  'proxy.sheet_view_mode': <String>{'grid', 'list'},
  'proxy.split_mode': <String>{'full', 'allow', 'disallow'},
  'proxy.log_level': <String>{'debug', 'info', 'warn', 'error'},
};

/// Inclusive numeric bounds mirrored from the committed registry.
///
/// Only keys that actually declare `.range(...)` / `.min(...)` appear here.
/// `update.check_interval_hours` deliberately has no bound because the
/// committed registry declares none (adding one would diverge from Rust).
class _NumericBounds {
  const _NumericBounds({this.min, this.max});

  final num? min;
  final num? max;
}

const Map<String, _NumericBounds> _numericBoundsByKey =
    <String, _NumericBounds>{
  'download.max_concurrent': _NumericBounds(min: 1, max: 10),
  'download.default_connections': _NumericBounds(min: 1),
  'download.max_retries': _NumericBounds(min: 0, max: 5),
  'download.speed_limit_bps': _NumericBounds(min: 0),
  'proxy.engine_mtu': _NumericBounds(min: 1280),
};

/// Mirrors Rust `ConfigEntry::validate_value`:
///   1. JSON type (`ConfigValueType::accepts`) -> `config_type_mismatch`,
///   2. numeric min/max and string enum membership -> `config_validation`.
///
/// The committed Rust import reports the registry error's stable code, which is
/// `config_validation` for both enum and range violations (NOT
/// `config_invalid_enum`; that code belongs to the legacy decoder's
/// enum-index translation, not to the Rust import seam).
String? _validationFailureOf(String wireKey, String valueJson) {
  final expected = _wireTypeOf(wireKey);
  if (expected == null) return 'config_unregistered_key';
  final decoded = jsonDecode(valueJson);
  final accepted = switch (expected) {
    _WireType.boolean => decoded is bool,
    _WireType.integer => decoded is int,
    _WireType.string => decoded is String,
    _WireType.stringList =>
      decoded is List && decoded.every((item) => item is String),
    _WireType.jsonObject => decoded is Map,
    _WireType.jsonArray => decoded is List,
  };
  if (!accepted) return 'config_type_mismatch';

  if (decoded is num) {
    final bounds = _numericBoundsByKey[wireKey];
    if (bounds != null) {
      final min = bounds.min;
      final max = bounds.max;
      if ((min != null && decoded < min) || (max != null && decoded > max)) {
        return 'config_validation';
      }
    }
  }

  if (decoded is String) {
    final allowed = _enumValuesByKey[wireKey];
    if (allowed != null && !allowed.contains(decoded)) {
      return 'config_validation';
    }
  }

  return null;
}

class _SnapshotSource implements LegacyConfigSource {
  _SnapshotSource(this._prefs, this._secure);

  final Map<String, Object?> _prefs;
  final Map<String, String?> _secure;
  int prefsReads = 0;
  int secureReads = 0;

  @override
  Future<Map<String, Object?>> readPrefs() {
    prefsReads++;
    return Future<Map<String, Object?>>.value(_prefs);
  }

  @override
  Future<Map<String, String?>> readSecure() {
    secureReads++;
    return Future<Map<String, String?>>.value(_secure);
  }
}

/// In-memory stand-in for `ConfigApi.import_` / `verify` / `meta_*`.
///
/// Enforces the full Rust registry contract for every key: JSON value type,
/// string enum membership, and numeric min/max. Enum/range violations are
/// reported with `config_validation`, exactly like `ConfigEntry::validate_value`
/// through the Rust import seam (not merely the JSON type). It applies the same
/// changed-vs-unchanged import semantics used by the production batch.
class _TypedFakeApi implements ConfigMigrationApi {
  final Map<String, Object?> stored = <String, Object?>{};
  final Map<String, String> meta = <String, String>{};
  final Set<String> typeFailures = <String>{};

  int importCalls = 0;
  int verifyCalls = 0;

  @override
  Future<MigrationImportResult> importEntries(
    List<MigrationEntry> entries, {
    required String source,
  }) async {
    importCalls++;
    var applied = 0;
    var unchanged = 0;
    final failed = <String, String>{};
    for (final entry in entries) {
      final typeCode = _validationFailureOf(entry.wireKey, entry.valueJson);
      if (typeCode != null) {
        typeFailures.add(entry.wireKey);
        failed[entry.wireKey] = typeCode;
        continue;
      }
      final existing = stored[entry.wireKey];
      if (existing != null && jsonEncode(existing) == entry.valueJson) {
        unchanged++;
      } else {
        applied++;
        stored[entry.wireKey] = entry.value;
      }
    }
    return MigrationImportResult(
      total: entries.length,
      applied: applied,
      unchanged: unchanged,
      failed: failed,
    );
  }

  @override
  Future<MigrationVerifyResult> verifyEntries(
    List<MigrationEntry> entries,
  ) async {
    verifyCalls++;
    var matched = 0;
    final failed = <String, String>{};
    for (final entry in entries) {
      final existing = stored[entry.wireKey];
      if (existing != null && jsonEncode(existing) == entry.valueJson) {
        matched++;
      } else {
        failed[entry.wireKey] = 'mismatch';
      }
    }
    return MigrationVerifyResult(
      total: entries.length,
      matched: matched,
      failed: failed,
    );
  }

  @override
  Future<String?> getMeta(String key) async => meta[key];

  @override
  Future<void> setMeta(String key, String valueJson) async {
    meta[key] = valueJson;
  }
}

Map<String, Object?> _fixture() {
  final file = File('test/fixtures/legacy_config_upgrade_snapshot.json');
  final decoded = jsonDecode(file.readAsStringSync());
  return Map<String, Object?>.from(decoded as Map);
}

Map<String, Object?> _prefsOf(Map<String, Object?> fixture) {
  return Map<String, Object?>.from(fixture['prefs']! as Map);
}

Map<String, String?> _secureOf(Map<String, Object?> fixture) {
  final raw = Map<String, Object?>.from(fixture['secure']! as Map);
  return <String, String?>{
    for (final entry in raw.entries) entry.key: entry.value?.toString(),
  };
}

const String _upgradePassword = 'Upgrade!-P@ss-2026';
const String _stalePassword = 'LegacyProvider!-stale-secret';
const String _upgradeApiKey = 'sk-upgrade-acceptance-secret-456';

const List<String> _proxyNames = <String>[
  'engine_stack',
  'engine_mtu',
  'routing_mode',
  'run_mode',
  'active_node_label',
  'active_profile_id',
  'sheet_view_mode',
  'split_mode',
  'split_apps',
  'always_on_intent',
  'log_level',
];

const List<String> _moduleNames = <String>[
  'channel',
  'download',
  'backup',
  'webdav',
  'fdroid',
  'theme',
  'install',
  'aggregate',
  'agent_tools',
  'update',
  'badge',
];

/// The complete expected grouped end state after the upgrade migration.
///
/// Every value is the *typed* value Rust must hold (bool/int/String/List/Map),
/// not a JSON string. `secure_config_webdav_*` is intentionally absent: the
/// bare `WebDavConfigManager` copy wins and the stale provider copy is
/// `superseded`.
Map<String, Object?> _expectedUpgradeConfig() => <String, Object?>{
      // ---- download ----
      'download.multi_segment.enabled': true,
      'download.max_concurrent': 8,
      'download.wifi_only': false,
      'download.max_retries': 3,
      // ---- update (split from one aggregated legacy JSON) ----
      'update.channel': 'dev',
      'update.auto_update_policy': 'always',
      'update.ignore_prerelease': true,
      'update.silent_update': false,
      'update.check_interval_hours': 24,
      'update.last_check_time': '2026-10-31T08:15:00.000',
      'update.last_updated_version': '2.2.1',
      // ---- theme / perf ----
      'theme.config': <String, Object?>{
        'useCustomColors': true,
        'fontStyle': 3,
        'darkMode': false,
      },
      'theme.mode': 1,
      'perf.profiles': <String, Object?>{
        'com.example.game': <String, Object?>{
          'package': 'com.example.game',
          'mode': 'performance',
          'enabled': true,
        },
        'com.example.reader': <String, Object?>{
          'package': 'com.example.reader',
          'mode': 'balanced',
          'enabled': false,
        },
      },
      'perf.profiles.enabled': true,
      'perf.history.enabled': true,
      // ---- agent (API key is a secret) ----
      'agent.models': <Object?>[
        <String, Object?>{
          'id': 'upgrade-model',
          'name': 'Upgrade GPT',
          'apiKey': _upgradeApiKey,
          'baseUrl': 'https://api.upgrade.example/v1',
          'model': 'gpt-4o',
        },
      ],
      'agent.selected_model_id': 'upgrade-model',
      'agent.model_catalog': <String, Object?>{
        'https://api.upgrade.example/v1': <Object?>['gpt-4o', 'gpt-4o-mini'],
      },
      // ---- F-Droid / discovery / network ----
      'fdroid.sources': <Object?>[
        <String, Object?>{
          'id': 'official',
          'name': 'F-Droid',
          'url': 'https://f-droid.org/repo',
          'enabled': true,
        },
        <String, Object?>{
          'id': 'izzy',
          'name': 'IzzyOnDroid',
          'url': 'https://apt.izzysoft.de/fdroid/repo',
          'enabled': false,
        },
      ],
      'fdroid.last_source_id': 'izzy',
      'discovery.selected_channels': <String>['gstore', 'fdroid', 'izzy'],
      'network.proxy_url': 'http://127.0.0.1:7890',
      'catalog.source_url': 'https://catalog.upgrade.example/db.json',
      // ---- all 11 proxy page keys ----
      'proxy.engine_stack': 'gvisor',
      'proxy.engine_mtu': 1420,
      'proxy.routing_mode': 'global',
      'proxy.run_mode': 'vpn',
      'proxy.active_node_label': <String, Object?>{
        'group': 'HK',
        'node': 'HK-02',
      },
      'proxy.active_profile_id': 'prof-upgrade-1',
      'proxy.sheet_view_mode': 'grid',
      'proxy.split_mode': 'disallow',
      'proxy.split_apps': <String>[
        'com.example.alpha',
        'com.example.beta',
        'com.example.gamma',
      ],
      'proxy.always_on_intent': false,
      'proxy.log_level': 'info',
      // ---- all 11 module toggles ----
      'module.channel.enabled': true,
      'module.download.enabled': true,
      'module.backup.enabled': false,
      'module.webdav.enabled': true,
      'module.fdroid.enabled': true,
      'module.theme.enabled': true,
      'module.install.enabled': true,
      'module.aggregate.enabled': false,
      'module.agent_tools.enabled': true,
      'module.update.enabled': false,
      'module.badge.enabled': true,
      // ---- WebDAV (bare manager wins) ----
      'webdav.url': 'https://dav.upgrade.example/remote.php/dav/files/upgrade',
      'webdav.username': 'upgrade-user',
      'webdav.password': _upgradePassword,
      'webdav.backup_path': '/UpgradeBackup',
      'webdav.enable_https': true,
    };

String _displayValue(String wireKey, Object? value) {
  if (wireKey == 'webdav.password') return '<redacted>';
  if (wireKey == 'agent.models') {
    final models = value is List ? value : const <Object?>[];
    return '[${models.length} model(s), apiKey=<redacted>]';
  }
  return jsonEncode(value);
}

void main() {
  test('upgrade acceptance: every grouped key, marker, and 0 failures',
      () async {
    final fixture = _fixture();
    final prefs = _prefsOf(fixture);
    final secure = _secureOf(fixture);
    final originalPrefsJson = jsonEncode(prefs);
    final originalSecureJson = jsonEncode(secure);

    final expected = _expectedUpgradeConfig();
    // Static-validate the expected fixture values against the mirrored registry
    // BEFORE running, so a stale/invalid fixture fails at the source.
    for (final entry in expected.entries) {
      expect(
        _validationFailureOf(entry.key, jsonEncode(entry.value)),
        isNull,
        reason: 'fixture value for ${entry.key} violates the registry',
      );
    }
    final fake = _TypedFakeApi();
    final source = _SnapshotSource(prefs, secure);
    final temp = await Directory.systemTemp.createTemp('gstore_upgrade_accept_');
    try {
      final report = await ConfigMigrationTool.run(
        api: fake,
        source: source,
        backupDir: temp.path,
      );

      // ---- report: the reconstruction lists 0 failures ----
      expect(report.alreadyDone, isFalse);
      expect(report.coreReady, isTrue);
      expect(report.errorCode, isNull);
      expect(report.failed, 0,
          reason: 'the acceptance report must list 0 failures');
      expect(report.verifyFailures, 0);
      expect(report.markerWritten, isTrue);
      expect(report.secretScanClean, isTrue);
      expect(fake.typeFailures, isEmpty,
          reason: 'registry type enforcement failed: ${fake.typeFailures}');
      expect(fake.importCalls, 1);
      expect(fake.verifyCalls, 1);
      expect(source.prefsReads, 1);
      expect(source.secureReads, 1);

      // 50 legacy storage keys (one aggregated update JSON, plus the 5 stale
      // secure_config_ copies) produce 51 distinct grouped wire keys.
      expect(expected, hasLength(51));
      expect(report.totalStorageKeys, 50);
      expect(report.applied, expected.length);
      expect(report.unchanged, 0);
      expect(report.distinctWireKeys, expected.length);
      expect(fake.stored.length, expected.length);

      // ---- EVERY grouped key equals the expected typed value ----
      final mismatches = <String>[];
      for (final entry in expected.entries) {
        final wireKey = entry.key;
        if (!fake.stored.containsKey(wireKey)) {
          mismatches.add('$wireKey (missing)');
          continue;
        }
        if (jsonEncode(fake.stored[wireKey]) != jsonEncode(entry.value)) {
          mismatches.add(wireKey);
        }
        expect(
          fake.stored[wireKey],
          equals(entry.value),
          reason: 'upgrade gate mismatch for $wireKey',
        );
      }
      expect(mismatches, isEmpty, reason: 'mismatched keys: $mismatches');

      // Explicit coverage of the 11 proxy keys and 11 module toggles.
      for (final name in _proxyNames) {
        expect(expected, contains('proxy.$name'));
        expect(fake.stored, contains('proxy.$name'));
      }
      for (final name in _moduleNames) {
        expect(expected, contains('module.$name.enabled'));
        expect(fake.stored, contains('module.$name.enabled'));
      }

      // ---- report per-key statuses: no failure; stale copy is superseded ----
      expect(
        report.keys.where((key) => key.status == 'failed'),
        isEmpty,
        reason: 'per-key report must contain no failed entries',
      );
      final appliedWireKeys = report.keys
          .where((key) => key.status == 'applied')
          .map((key) => key.wireKey)
          .toSet();
      expect(appliedWireKeys, containsAll(expected.keys));
      final superseded =
          report.keys.where((key) => key.status == 'superseded').toList();
      expect(superseded, hasLength(5));
      expect(
        superseded.every(
          (key) => key.storageKey.startsWith('secure_config_webdav_'),
        ),
        isTrue,
      );

      // ---- marker `config.migrated.v1` exists and is structural-only ----
      final markerJson = fake.meta[kConfigMigrationMarkerKey];
      expect(markerJson, isNotNull);
      final marker = jsonDecode(markerJson!) as Map<String, Object?>;
      expect(marker['version'], 1);
      expect(marker['markerKey'], 'config.migrated.v1');
      expect(marker['source'], kConfigMigrationSource);
      expect(marker['alreadyDone'], false);
      expect(marker['totalStorageKeys'], 50);
      expect(marker['applied'], expected.length);
      expect(marker['failed'], 0);
      expect(marker['verifyFailures'], 0);
      expect((marker['keys']! as List<Object?>).length, report.keys.length);
      expect(
        ConfigMigrationTool.markerHasOnlyStructuralFields(marker),
        isTrue,
      );

      // ---- old keys remain: rollback stays possible ----
      expect(jsonEncode(prefs), originalPrefsJson,
          reason: 'the tool must never mutate/delete old prefs keys');
      expect(jsonEncode(secure), originalSecureJson,
          reason: 'the tool must never mutate/delete old secure keys');
      expect(prefs['config_theme_config'], isNotNull);
      expect(prefs['config_agent_models'], contains(_upgradeApiKey));
      expect(prefs['config_update_config'], contains('2.2.1'));
      expect(secure['webdav_password'], _upgradePassword);
      expect(secure['secure_config_webdav_password'], _stalePassword);

      // The stale provider copy never wins the grouped state.
      final storedJson = jsonEncode(fake.stored);
      expect(storedJson, isNot(contains('legacy-provider.example')));
      expect(storedJson, isNot(contains('legacy-provider-user')));
      expect(storedJson, isNot(contains(_stalePassword)));
      expect(storedJson, isNot(contains('/LegacyProviderBackup')));

      // ---- backup artifact contains no raw secrets ----
      expect(report.backupPath, isNotNull);
      final backupFile = File(report.backupPath!);
      expect(backupFile.existsSync(), isTrue);
      final backupContent = backupFile.readAsStringSync();
      expect(backupContent, isNot(contains(_upgradePassword)));
      expect(backupContent, isNot(contains(_stalePassword)));
      expect(backupContent, isNot(contains(_upgradeApiKey)));
      final backup = jsonDecode(backupContent) as Map<String, Object?>;
      expect(backup['kind'], 'config_migration_backup');
      expect(backup['markerKey'], kConfigMigrationMarkerKey);
      final backupSecure =
          Map<String, Object?>.from(backup['secure']! as Map);
      expect(backupSecure.containsKey('webdav_password'), isFalse);
      expect(backupSecure.containsKey('secure_config_webdav_password'), isFalse);
      final backupPrefs = Map<String, Object?>.from(backup['prefs']! as Map);
      final backupModels = backupPrefs['config_agent_models']! as List<Object?>;
      expect(
        Map<String, Object?>.from(backupModels.first! as Map)['apiKey'],
        '<redacted>',
      );
      expect(backupContent, contains('<redacted>'));

      // ---- manual QA channel: redacted end-state table + key/status report ----
      final sortedKeys = expected.keys.toList()..sort();
      final tableLines = <String>[
        for (final wireKey in sortedKeys)
          '  $wireKey = ${_displayValue(wireKey, fake.stored[wireKey])}',
      ];
      print('=== upgrade acceptance: end-state grouped config '
          '(${tableLines.length} keys) ===');
      for (final line in tableLines) {
        print(line);
      }
      print('=== per-key migration report (key/status only) ===');
      for (final key in report.keys) {
        print('  ${key.storageKey} -> ${key.wireKey}: ${key.status}'
            '${key.code == null ? '' : ' (${key.code})'}');
      }
      print('marker $kConfigMigrationMarkerKey present: '
          '${fake.meta.containsKey(kConfigMigrationMarkerKey)}');
      print('report: $report');

      // The printed "success" must be honest: one line per expected key, and
      // the secret values are redacted, never printed.
      expect(tableLines, hasLength(expected.length));
      final printed = tableLines.join('\n');
      expect(printed, isNot(contains(_upgradePassword)));
      expect(printed, isNot(contains(_stalePassword)));
      expect(printed, isNot(contains(_upgradeApiKey)));
      for (final wireKey in expected.keys) {
        expect(printed, contains('$wireKey ='),
            reason: 'printed end-state omits $wireKey');
      }
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('registry fidelity: invalid legacy proxy enums are rejected', () async {
    // Regression for the acceptance-gate defect: the previous fixture used
    // `proxy.engine_stack="singbox"` and `proxy.run_mode="tun"`, which are NOT
    // valid Rust enum values (gvisor|system; off|vpn|lanProxy). A type-only
    // fake accepted them and the gate falsely reported 0 failures.
    final fake = _TypedFakeApi();
    final result = await fake.importEntries(
      const <MigrationEntry>[
        MigrationEntry(wireKey: 'proxy.engine_stack', value: 'singbox'),
        MigrationEntry(wireKey: 'proxy.run_mode', value: 'tun'),
        MigrationEntry(wireKey: 'proxy.routing_mode', value: 'rule'),
      ],
      source: kConfigMigrationSource,
    );

    expect(result.failed['proxy.engine_stack'], 'config_validation');
    expect(result.failed['proxy.run_mode'], 'config_validation');
    expect(result.failed.containsKey('proxy.routing_mode'), isFalse);
    expect(result.applied, 1);
    expect(result.unchanged, 0);
    expect(
      fake.typeFailures,
      containsAll(<String>['proxy.engine_stack', 'proxy.run_mode']),
    );
    expect(fake.stored.containsKey('proxy.engine_stack'), isFalse);
    expect(fake.stored.containsKey('proxy.run_mode'), isFalse);
    expect(fake.stored['proxy.routing_mode'], 'rule');
  });

  test('registry fidelity: out-of-range numerics are rejected', () async {
    final fake = _TypedFakeApi();
    final result = await fake.importEntries(
      const <MigrationEntry>[
        // download.max_concurrent is 1..10; 11 is above max.
        MigrationEntry(wireKey: 'download.max_concurrent', value: 11),
        // download.max_retries is 0..5; 6 is above max.
        MigrationEntry(wireKey: 'download.max_retries', value: 6),
        // proxy.engine_mtu has min 1280; 1279 is below min.
        MigrationEntry(wireKey: 'proxy.engine_mtu', value: 1279),
        // A valid control value in the same batch still applies.
        MigrationEntry(wireKey: 'proxy.engine_stack', value: 'gvisor'),
      ],
      source: kConfigMigrationSource,
    );

    expect(result.failed['download.max_concurrent'], 'config_validation');
    expect(result.failed['download.max_retries'], 'config_validation');
    expect(result.failed['proxy.engine_mtu'], 'config_validation');
    expect(result.applied, 1);
    expect(
      fake.typeFailures,
      containsAll(<String>[
        'download.max_concurrent',
        'download.max_retries',
        'proxy.engine_mtu',
      ]),
    );
    expect(fake.stored.containsKey('download.max_concurrent'), isFalse);
    expect(fake.stored.containsKey('download.max_retries'), isFalse);
    expect(fake.stored.containsKey('proxy.engine_mtu'), isFalse);
    expect(fake.stored['proxy.engine_stack'], 'gvisor');
  });

  test('malformed_input: one corrupt legacy value is reported, others apply',
      () async {
    final fixture = _fixture();
    final prefs = _prefsOf(fixture);
    // One corrupt legacy value: an unterminated theme JSON object.
    prefs['config_theme_config'] = '{"useCustomColors":true,';
    final secure = _secureOf(fixture);
    final fake = _TypedFakeApi();

    final report = await ConfigMigrationTool.run(
      api: fake,
      source: _SnapshotSource(prefs, secure),
    );

    expect(report.markerWritten, isFalse);
    expect(report.errorCode, 'migration_incomplete');
    expect(report.failed, 1);
    expect(fake.meta.containsKey(kConfigMigrationMarkerKey), isFalse);

    final failed = report.keys.where((key) => key.status == 'failed').toList();
    expect(failed, hasLength(1));
    expect(failed.single.wireKey, 'theme.config');
    expect(failed.single.code, 'config_invalid_json');
    expect(fake.stored.containsKey('theme.config'), isFalse);

    // The rest of the upgrade still migrated.
    expect(fake.stored['download.max_concurrent'], 8);
    expect(fake.stored['webdav.password'], _upgradePassword);
    expect(fake.stored['module.download.enabled'], isTrue);
    expect(fake.stored['proxy.engine_mtu'], 1420);

    // Old keys remain even on failure (rollback / retry possible).
    expect(prefs['config_theme_config'], '{"useCustomColors":true,');
    expect(secure['webdav_password'], _upgradePassword);
  });

  test('stale_state: marker short-circuits a second upgrade run', () async {
    final fixture = _fixture();
    final fake = _TypedFakeApi();
    final source = _SnapshotSource(_prefsOf(fixture), _secureOf(fixture));

    final first = await ConfigMigrationTool.run(api: fake, source: source);
    expect(first.markerWritten, isTrue);
    expect(first.failed, 0);
    final markerAfterFirst = fake.meta[kConfigMigrationMarkerKey];
    final storedAfterFirst = jsonEncode(fake.stored);
    final appliedAfterFirst = first.applied;

    final second = await ConfigMigrationTool.run(api: fake, source: source);
    expect(second.alreadyDone, isTrue);
    expect(second.markerWritten, isFalse);
    expect(second.totalStorageKeys, 0);
    expect(second.keys, isEmpty);
    expect(second.failed, 0);

    // No re-import, no re-read, no marker rewrite, no value drift.
    expect(fake.importCalls, 1);
    expect(fake.verifyCalls, 1);
    expect(source.prefsReads, 1);
    expect(source.secureReads, 1);
    expect(fake.meta[kConfigMigrationMarkerKey], markerAfterFirst);
    expect(jsonEncode(fake.stored), storedAfterFirst);
    expect(fake.stored.length, appliedAfterFirst);
  });
}
