// Todo 21 acceptance tests: real legacy storage keys → grouped Rust wire keys.
//
// Every fixture below uses the *actual* on-disk keys from the pre-Rust app
// (`config_*` SharedPreferences keys, bare `webdav_*`, and the stale
// `secure_config_webdav_*` provider copy). No legacy config stack / `ConfigStore`
// is involved: the tool is exercised through its `ConfigMigrationApi` and
// `LegacyConfigSource` seams, exactly like the production Rust path.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/migration/config_migration_tool.dart';

/// Registry value types mirrored from `rust/gstore_core/src/config/schema.rs`.
///
/// The fake **enforces** these against the DTO `valueJson`, so a migration that
/// writes a JSON string where Rust expects an object/array (or a string where
/// it expects bool/int/stringList) fails with `config_type_mismatch` instead of
/// passing the fake-level tests.
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

/// Mirrors `ConfigValueType::accepts` for the value_json the DTO carries.
String? _typeMismatchOf(String wireKey, String valueJson) {
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
  return accepted ? null : 'config_type_mismatch';
}

class _MapLegacySource implements LegacyConfigSource {
  _MapLegacySource(this._prefs, this._secure);

  final Map<String, Object?> _prefs;
  final Map<String, String?> _secure;

  @override
  Future<Map<String, Object?>> readPrefs() async => _prefs;

  @override
  Future<Map<String, String?>> readSecure() async => _secure;
}

/// Wraps a fixture source and counts reads, so the already-migrated short
/// circuit can prove the legacy stores are never touched.
class _CountingLegacySource implements LegacyConfigSource {
  _CountingLegacySource(this._delegate);

  final _MapLegacySource _delegate;
  int prefsReads = 0;
  int secureReads = 0;

  @override
  Future<Map<String, Object?>> readPrefs() {
    prefsReads++;
    return _delegate.readPrefs();
  }

  @override
  Future<Map<String, String?>> readSecure() {
    secureReads++;
    return _delegate.readSecure();
  }
}

_CountingLegacySource _countingSourceOf(Map<String, Object?> fixture) {
  return _CountingLegacySource(
    _MapLegacySource(_prefsOf(fixture), _secureOf(fixture)),
  );
}

/// Seeds an in-memory DB with a fixture's `meta` block, modelling an
/// already-migrated database (marker present).
void _seedFixtureMeta(_FakeMigrationApi fake, Map<String, Object?> fixture) {
  final raw = fixture['meta'];
  if (raw is! Map) return;
  for (final entry in raw.entries) {
    final value = entry.value;
    fake.meta[entry.key.toString()] =
        value is String ? value : jsonEncode(value);
  }
}

/// In-memory stand-in for `ConfigApi.import_` / `verify` / `meta_*`.
///
/// It applies the same semantics the Rust batch import has for our purpose:
/// changed values are applied, identical values are `unchanged`, rejected
/// entries are reported by code only, and verification compares committed JSON.
class _FakeMigrationApi implements ConfigMigrationApi {
  final Map<String, Object?> stored = <String, Object?>{};
  final Map<String, String> meta = <String, String>{};
  final Map<String, String> rejected = <String, String>{};
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
      final rejectCode = rejected[entry.wireKey];
      if (rejectCode != null) {
        failed[entry.wireKey] = rejectCode;
        continue;
      }
      final typeCode = _typeMismatchOf(entry.wireKey, entry.valueJson);
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

Map<String, Object?> _fixture(String name) {
  final file = File('test/fixtures/$name');
  final decoded = jsonDecode(file.readAsStringSync());
  return Map<String, Object?>.from(decoded as Map);
}

Map<String, Object?> _prefsOf(Map<String, Object?> fixture) {
  return Map<String, Object?>.from(fixture['prefs']! as Map);
}

Map<String, String?> _secureOf(Map<String, Object?> fixture) {
  final raw = Map<String, Object?>.from(fixture['secure']! as Map);
  return <String, String?>{
    for (final entry in raw.entries)
      entry.key: entry.value?.toString(),
  };
}

Future<ConfigMigrationReport> _run(
  Map<String, Object?> fixture, {
  _FakeMigrationApi? api,
  String? backupDir,
}) {
  final fake = api ?? _FakeMigrationApi();
  return ConfigMigrationTool.run(
    api: fake,
    source: _MapLegacySource(_prefsOf(fixture), _secureOf(fixture)),
    backupDir: backupDir,
  );
}

const List<String> _requiredStorageKeys = <String>[
  'config_download_multi_segment',
  'config_download_max_concurrent',
  'config_download_wifi_only',
  'config_download_max_retry',
  'config_update_config',
  'config_theme_config',
  'config_theme_mode',
  'config_perf.profiles',
  'config_perf.profiles.enabled',
  'config_perf.history.enabled',
  'config_agent_models',
  'config_agent_selected_model_id',
  'config_agent_model_catalog',
  'config_fdroid_sources',
  'config_last_source_id',
  'config_selected_channels',
  'config_proxy_url',
  'config_catalog_url',
  'config_proxy_engine_stack',
  'config_proxy_engine_mtu',
  'config_proxy_routing_mode',
  'config_proxy_run_mode',
  'config_proxy_active_node_label',
  'config_proxy_active_profile_id',
  'config_proxy_sheet_view_mode',
  'config_proxy_split_mode',
  'config_proxy_split_apps',
  'config_proxy_always_on_intent',
  'config_proxy_log_level',
  'config_module.channel.enabled',
  'config_module.download.enabled',
  'config_module.backup.enabled',
  'config_module.webdav.enabled',
  'config_module.fdroid.enabled',
  'config_module.theme.enabled',
  'config_module.install.enabled',
  'config_module.aggregate.enabled',
  'config_module.agent_tools.enabled',
  'config_module.update.enabled',
  'config_module.badge.enabled',
  'fdroid_sources',
  'last_source_id',
  'selected_channels',
  'agent_models',
  'agent_selected_model_id',
  'webdav_url',
  'webdav_username',
  'webdav_password',
  'webdav_backup_path',
  'webdav_enable_https',
  'secure_config_webdav_url',
  'secure_config_webdav_username',
  'secure_config_webdav_password',
  'secure_config_webdav_backup_path',
  'secure_config_webdav_enable_https',
];

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

void main() {
  test('explicit storage-key table covers every real legacy key', () {
    for (final key in _requiredStorageKeys) {
      expect(
        ConfigMigrationTool.allStorageKeys,
        contains(key),
        reason: 'missing storage key $key',
      );
    }
    // There is no single aggregated download/webdav value on disk.
    expect(
      ConfigMigrationTool.allStorageKeys,
      isNot(contains('config_download_config')),
    );
    expect(
      ConfigMigrationTool.allStorageKeys,
      isNot(contains('config_webdav_config')),
    );
    // The aggregated update JSON is split into seven grouped wire keys.
    expect(
      ConfigMigrationTool.storageKeyToWireKeys['config_update_config'],
      containsAll(<String>[
        'update.channel',
        'update.auto_update_policy',
        'update.ignore_prerelease',
        'update.silent_update',
        'update.check_interval_hours',
        'update.last_check_time',
        'update.last_updated_version',
      ]),
    );
  });

  test('real fixture migrates >=12 legacy keys and writes the marker', () async {
    final fixture = _fixture('legacy_config_migration.json');
    final fake = _FakeMigrationApi();
    final report = await _run(fixture, api: fake);

    expect(report.alreadyDone, isFalse);
    expect(report.coreReady, isTrue);
    expect(report.markerWritten, isTrue);
    expect(report.failed, 0);
    expect(report.verifyFailures, 0);
    expect(report.totalStorageKeys, greaterThanOrEqualTo(12));
    expect(report.applied, greaterThanOrEqualTo(12));
    expect(report.distinctWireKeys, greaterThanOrEqualTo(12));
    expect(report.errorCode, isNull);
    expect(fake.verifyCalls, 1);
    expect(fake.importCalls, 1);
    expect(fake.typeFailures, isEmpty);

    final markerJson = fake.meta[kConfigMigrationMarkerKey];
    expect(markerJson, isNotNull);
    final marker = jsonDecode(markerJson!) as Map<String, Object?>;
    expect(marker['version'], 1);
    expect(marker['markerKey'], kConfigMigrationMarkerKey);
    expect(marker['keys'], isA<List<Object?>>());
    expect((marker['keys']! as List<Object?>).length, report.keys.length);
    // config_meta structural ownership: only identifiers/statuses, no user
    // values (this is the honest "marker included in the secret scan" check).
    expect(ConfigMigrationTool.markerHasOnlyStructuralFields(marker), isTrue);

    // Reports / marker carry key/status only: never a value.
    expect(markerJson, isNot(contains('S3cret!')));
    expect(markerJson, isNot(contains('sk-agent-secret-123')));
    expect(markerJson, isNot(contains('https://dav.bare.example')));
    expect(report.toJson().toString(), isNot(contains('S3cret!')));
    expect(report.toJson().toString(), isNot(contains('sk-agent-secret-123')));
  });

  test('all 11 proxy keys and all 11 module toggles migrate', () async {
    final fixture = _fixture('legacy_config_migration.json');
    final fake = _FakeMigrationApi();
    await _run(fixture, api: fake);

    for (final name in _proxyNames) {
      expect(
        fake.stored,
        contains('proxy.$name'),
        reason: 'missing proxy.$name',
      );
    }
    for (final name in _moduleNames) {
      expect(
        fake.stored,
        contains('module.$name.enabled'),
        reason: 'missing module.$name.enabled',
      );
    }

    expect(fake.stored['proxy.engine_stack'], 'system');
    expect(fake.stored['proxy.engine_mtu'], 1400);
    expect(fake.stored['proxy.routing_mode'], 'rule');
    expect(fake.stored['proxy.run_mode'], 'vpn');
    expect(fake.stored['proxy.split_apps'], <String>[
      'com.example.one',
      'com.example.two',
    ]);
    expect(fake.stored['proxy.always_on_intent'], isTrue);
    expect(fake.stored['module.download.enabled'], isFalse);
    expect(fake.stored['module.badge.enabled'], isFalse);
  });

  test('bare WebDAV manager values win over stale secure_config_ copy', () async {
    final fixture = _fixture('legacy_config_migration.json');
    final fake = _FakeMigrationApi();
    final report = await _run(fixture, api: fake);

    expect(fake.stored['webdav.url'],
        'https://dav.bare.example/remote.php/dav/files/user');
    expect(fake.stored['webdav.username'], 'bare-user');
    expect(fake.stored['webdav.password'], 'S3cret!-webdav-bare');
    expect(fake.stored['webdav.backup_path'], '/BareBackup');
    expect(fake.stored['webdav.enable_https'], isTrue);

    // The stale provider copy is reported as superseded and never migrated.
    expect(
      report.keys.any((key) =>
          key.storageKey == 'secure_config_webdav_url' &&
          key.status == 'superseded'),
      isTrue,
    );
    final storedJson = jsonEncode(fake.stored);
    expect(storedJson, isNot(contains('dav.stale.example')));
    expect(storedJson, isNot(contains('stale-user')));
    expect(storedJson, isNot(contains('Stale!-webdav-copy')));
    expect(storedJson, isNot(contains('/StaleBackup')));
  });

  test('update enums are encoded as strings, never indices', () async {
    final fixture = _fixture('legacy_config_migration.json');
    final fake = _FakeMigrationApi();
    await _run(fixture, api: fake);

    expect(fake.stored['update.channel'], 'beta');
    expect(fake.stored['update.auto_update_policy'], 'wifi_only');
    expect(fake.stored['update.ignore_prerelease'], isFalse);
    expect(fake.stored['update.silent_update'], isTrue);
    expect(fake.stored['update.check_interval_hours'], 12);
    expect(fake.stored['update.last_check_time'], '2026-10-30T10:00:00.000');
    expect(fake.stored['update.last_updated_version'], '2.1.0');
  });

  test('legacy enum indices are translated to wire strings', () async {
    final prefs = <String, Object?>{
      'config_update_config': jsonEncode(<String, Object?>{
        'channel': 1,
        'autoUpdatePolicy': 1,
      }),
    };
    final fake = _FakeMigrationApi();
    final report = await ConfigMigrationTool.run(
      api: fake,
      source: _MapLegacySource(prefs, const <String, String?>{}),
    );

    expect(report.markerWritten, isTrue);
    expect(fake.stored['update.channel'], 'beta');
    expect(fake.stored['update.auto_update_policy'], 'wifi_only');
  });

  test('every migrated wire key has a registry type (no unknown decoder)', () {
    for (final wireKeys in ConfigMigrationTool.storageKeyToWireKeys.values) {
      for (final wireKey in wireKeys) {
        expect(
          _wireTypeOf(wireKey),
          isNotNull,
          reason: 'no registry value_type mirrored for $wireKey',
        );
      }
    }
  });

  test('proxy.active_node_label is a JSON object, not a quoted string',
      () async {
    final fixture = _fixture('legacy_config_migration.json');
    final fake = _FakeMigrationApi();
    final report = await _run(fixture, api: fake);

    // The fake enforces the Rust value_type; a double-encoded string would be
    // rejected with config_type_mismatch and the marker would never be written.
    expect(report.failed, 0);
    expect(report.verifyFailures, 0);
    expect(report.markerWritten, isTrue);
    expect(fake.typeFailures, isEmpty);

    final value = fake.stored['proxy.active_node_label'];
    expect(value, isA<Map<Object?, Object?>>());
    expect(value, isNot(isA<String>()));
    expect((value! as Map)['group'], 'auto');
    expect((value as Map)['node'], 'HK-01');
    // Exactly the object encoding Rust accepts (never "{\"group\":...}").
    expect(jsonEncode(value), '{"group":"auto","node":"HK-01"}');
  });

  test('fake enforces registry value_type (double-encoded Json is rejected)',
      () async {
    final fake = _FakeMigrationApi();
    // Simulates the pre-fix bug: a JSON string where Rust expects an object.
    final result = await fake.importEntries(
      const <MigrationEntry>[
        MigrationEntry(
          wireKey: 'proxy.active_node_label',
          value: '{"group":"auto","node":"HK-01"}',
        ),
      ],
      source: kConfigMigrationSource,
    );

    expect(result.applied, 0);
    expect(result.failed['proxy.active_node_label'], 'config_type_mismatch');
    expect(fake.typeFailures, contains('proxy.active_node_label'));
    expect(fake.stored.containsKey('proxy.active_node_label'), isFalse);
  });

  test('structured secret scan detects exact leaked values only', () {
    expect(
      ConfigMigrationTool.containsAnySecretValue(
        <String, Object?>{
          'secure': <String, Object?>{
            'webdav_password': 'S3cret!-webdav-bare',
          },
        },
        <String>['S3cret!-webdav-bare'],
      ),
      isTrue,
      reason: 'mutation proof: a raw secret in the backup must be detected',
    );
    expect(
      ConfigMigrationTool.containsAnySecretValue(
        <String, Object?>{
          'note': 'config prefs migration applied',
          'prefs': <String, Object?>{'config_theme_mode': 2},
        },
        <String>['S3cret!-webdav-bare'],
      ),
      isFalse,
      reason: 'ordinary English/status tokens must not false-positive',
    );
    // Exact value, not substring: a secret embedded in a larger string is not
    // how the structured backup stores secrets (sanitised values are masked).
    expect(
      ConfigMigrationTool.containsAnySecretValue(
        <String, Object?>{
          'note': 'prefix-S3cret!-webdav-bare-suffix',
        },
        <String>['S3cret!-webdav-bare'],
      ),
      isFalse,
    );
  });

  test('secret equal to marker vocabulary does not false-positive', () async {
    // `source:"migration"` and `status:"applied"` are structural marker
    // vocabulary, not leaked user data. A password with those exact values must
    // not block the marker.
    for (final token in <String>[
      'migration',
      'applied',
      'config',
      'superseded',
      'failed',
    ]) {
      final fake = _FakeMigrationApi();
      final report = await ConfigMigrationTool.run(
        api: fake,
        source: _MapLegacySource(
          const <String, Object?>{'config_theme_mode': 1},
          <String, String?>{'webdav_password': token},
        ),
      );

      expect(report.secretScanClean, isTrue, reason: 'password=$token');
      expect(report.markerWritten, isTrue, reason: 'password=$token');
      expect(report.errorCode, isNull, reason: 'password=$token');
      expect(fake.stored['webdav.password'], token, reason: 'password=$token');

      final markerJson = fake.meta[kConfigMigrationMarkerKey];
      expect(markerJson, isNotNull, reason: 'password=$token');
      final marker = jsonDecode(markerJson!) as Map<String, Object?>;
      // The marker contains only structural fields/values.
      expect(
        ConfigMigrationTool.markerHasOnlyStructuralFields(marker),
        isTrue,
        reason: 'password=$token',
      );
    }
  });

  test('marker structural scan rejects user values and unknown fields', () {
    final valid = <String, Object?>{
      'version': 1,
      'markerKey': kConfigMigrationMarkerKey,
      'source': kConfigMigrationSource,
      'alreadyDone': false,
      'totalStorageKeys': 1,
      'applied': 1,
      'unchanged': 0,
      'failed': 0,
      'verifyFailures': 0,
      'secretScanClean': true,
      'backupFile': null,
      'keys': <Object?>[
        <String, Object?>{
          'storageKey': 'webdav_password',
          'wireKey': 'webdav.password',
          'status': 'applied',
        },
      ],
    };
    expect(ConfigMigrationTool.markerHasOnlyStructuralFields(valid), isTrue);

    final leakedValue = <String, Object?>{
      ...valid,
      'leak': 'S3cret!-webdav-bare',
    };
    expect(
      ConfigMigrationTool.markerHasOnlyStructuralFields(leakedValue),
      isFalse,
    );

    final leakedInKeyEntry = <String, Object?>{
      ...valid,
      'keys': <Object?>[
        <String, Object?>{
          'storageKey': 'webdav_password',
          'wireKey': 'webdav.password',
          'status': 'applied',
          'value': 'S3cret!-webdav-bare',
        },
      ],
    };
    expect(
      ConfigMigrationTool.markerHasOnlyStructuralFields(leakedInKeyEntry),
      isFalse,
    );

    final unknownStorageKey = <String, Object?>{
      ...valid,
      'keys': <Object?>[
        <String, Object?>{
          'storageKey': 'user_supplied_secret',
          'wireKey': 'webdav.password',
          'status': 'applied',
        },
      ],
    };
    expect(
      ConfigMigrationTool.markerHasOnlyStructuralFields(unknownStorageKey),
      isFalse,
    );
  });

  test('read-back verify reports zero failures', () async {
    final fixture = _fixture('legacy_config_migration.json');
    final fake = _FakeMigrationApi();
    final report = await _run(fixture, api: fake);

    expect(fake.verifyCalls, 1);
    expect(report.verifyFailures, 0);
    expect(report.keys.where((key) => key.status == 'failed'), isEmpty);
  });

  test('plaintext backup contains no raw WebDAV password or agent API key',
      () async {
    final fixture = _fixture('legacy_config_migration.json');
    final temp = await Directory.systemTemp.createTemp('gstore_cfg_mig_');
    try {
      final fake = _FakeMigrationApi();
      final report = await _run(fixture, api: fake, backupDir: temp.path);

      expect(report.secretScanClean, isTrue);
      expect(report.backupPath, isNotNull);
      final backupFile = File(report.backupPath!);
      expect(backupFile.existsSync(), isTrue);

      final content = backupFile.readAsStringSync();
      expect(content, isNot(contains('S3cret!-webdav-bare')));
      expect(content, isNot(contains('Stale!-webdav-copy')));
      expect(content, isNot(contains('sk-agent-secret-123')));
      expect(content, contains('<redacted>'));

      final backup = jsonDecode(content) as Map<String, Object?>;
      final secure = Map<String, Object?>.from(backup['secure']! as Map);
      expect(secure.containsKey('webdav_password'), isFalse);
      expect(secure.containsKey('secure_config_webdav_password'), isFalse);

      final prefs = Map<String, Object?>.from(backup['prefs']! as Map);
      final models = prefs['config_agent_models']! as List<Object?>;
      final first = Map<String, Object?>.from(models.first! as Map);
      expect(first['apiKey'], '<redacted>');

      // The marker (`config_meta`) is secret-free too.
      final marker = fake.meta[kConfigMigrationMarkerKey];
      expect(marker, isNotNull);
      expect(marker, isNot(contains('S3cret!')));
      expect(marker, isNot(contains('sk-agent-secret-123')));
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('corrupt JSON is isolated per key; others apply; no marker', () async {
    final fixture = _fixture('legacy_config_migration_corrupt.json');
    final fake = _FakeMigrationApi();
    final report = await _run(fixture, api: fake);

    expect(report.markerWritten, isFalse);
    expect(report.failed, greaterThanOrEqualTo(2));
    expect(report.applied, greaterThanOrEqualTo(2));
    expect(fake.meta.containsKey(kConfigMigrationMarkerKey), isFalse);

    // Good keys still migrated.
    expect(fake.stored['download.max_concurrent'], 6);
    expect(fake.stored['module.download.enabled'], isTrue);
    expect(fake.stored['proxy.engine_stack'], 'gvisor');

    final failedWireKeys = report.keys
        .where((key) => key.status == 'failed')
        .map((key) => key.wireKey)
        .toSet();
    expect(failedWireKeys, containsAll(<String>['theme.config', 'agent.models']));
    for (final key in report.keys.where((key) => key.status == 'failed')) {
      expect(key.code, isNotNull);
    }

    // The tool never deletes old keys, so rollback remains possible.
    expect(_prefsOf(fixture)['config_theme_config'], isNotNull);
  });

  test('import rejection is isolated and blocks the marker', () async {
    final fixture = _fixture('legacy_config_migration.json');
    final fake = _FakeMigrationApi()
      ..rejected['theme.config'] = 'config_db_write_failed';
    final report = await _run(fixture, api: fake);

    expect(report.markerWritten, isFalse);
    expect(report.failed, greaterThanOrEqualTo(1));
    expect(fake.meta.containsKey(kConfigMigrationMarkerKey), isFalse);
    // A rejected entry is reported as failed (never silently skipped) and the
    // marker stays absent so the next launch retries.
    expect(
      report.keys.any((key) =>
          key.wireKey == 'theme.config' &&
          key.status == 'failed' &&
          key.code == 'config_db_write_failed'),
      isTrue,
    );
    // Other keys were still applied.
    expect(fake.stored['download.max_concurrent'], 5);
    expect(fake.stored['webdav.password'], 'S3cret!-webdav-bare');
  });

  test('second run is a no-op (marker short-circuit)', () async {
    final fixture = _fixture('legacy_config_migration.json');
    final fake = _FakeMigrationApi();
    final first = await _run(fixture, api: fake);
    expect(first.markerWritten, isTrue);
    final importCallsAfterFirst = fake.importCalls;
    final verifyCallsAfterFirst = fake.verifyCalls;
    final markerAfterFirst = fake.meta[kConfigMigrationMarkerKey];

    final second = await _run(fixture, api: fake);
    expect(second.alreadyDone, isTrue);
    expect(second.markerWritten, isFalse);
    expect(second.totalStorageKeys, 0);
    expect(fake.importCalls, importCallsAfterFirst);
    expect(fake.verifyCalls, verifyCallsAfterFirst);
    expect(fake.meta[kConfigMigrationMarkerKey], markerAfterFirst);
  });

  test('manual QA: prints per-key report, entries, marker, secret scan, no-op',
      () async {
    final fixture = _fixture('legacy_config_migration.json');
    final fake = _FakeMigrationApi();
    final temp = await Directory.systemTemp.createTemp('gstore_cfg_qa_');
    try {
      final first = await _run(fixture, api: fake, backupDir: temp.path);
      print('=== first run ===');
      print('summary: $first');
      print('grouped entries applied: ${first.applied} '
          '(distinct wire keys: ${first.distinctWireKeys})');
      print('per-key report (key/status only):');
      for (final key in first.keys) {
        print('  ${key.storageKey} -> ${key.wireKey}: ${key.status}'
            '${key.code == null ? '' : ' (${key.code})'}');
      }
      print('marker ($kConfigMigrationMarkerKey):');
      print(fake.meta[kConfigMigrationMarkerKey]);
      print('secret-scan clean: ${first.secretScanClean}');
      print('backup: ${first.backupPath}');
      print('verify failures: ${first.verifyFailures}');

      final second = await _run(fixture, api: fake, backupDir: temp.path);
      print('=== second run (no-op) ===');
      print('summary: $second');
      print('report: ${jsonEncode(second.toJson())}');

      expect(first.markerWritten, isTrue);
      expect(first.verifyFailures, 0);
      expect(first.secretScanClean, isTrue);
      expect(second.alreadyDone, isTrue);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  // ---------------------------------------------------------------------------
  // Todo 24: five required migration fixtures + failure modes.
  // ---------------------------------------------------------------------------

  test('prefs-only fixture migrates every key and writes the marker', () async {
    final fixture = _fixture('legacy_config_migration_prefs_only.json');
    final source = _countingSourceOf(fixture);
    final fake = _FakeMigrationApi();
    final report = await ConfigMigrationTool.run(api: fake, source: source);

    expect(report.alreadyDone, isFalse);
    expect(report.coreReady, isTrue);
    expect(report.totalStorageKeys, 7);
    expect(report.applied, 7);
    expect(report.unchanged, 0);
    expect(report.failed, 0);
    expect(report.verifyFailures, 0);
    expect(report.markerWritten, isTrue);
    expect(report.errorCode, isNull);
    expect(report.distinctWireKeys, 7);
    expect(report.secretScanClean, isTrue);

    expect(fake.importCalls, 1);
    expect(fake.verifyCalls, 1);
    expect(source.prefsReads, 1);
    expect(source.secureReads, 1);

    expect(fake.stored['download.multi_segment.enabled'], isFalse);
    expect(fake.stored['download.max_concurrent'], 3);
    expect(fake.stored['download.wifi_only'], isTrue);
    expect(fake.stored['download.max_retries'], 1);
    expect(fake.stored['theme.mode'], 1);
    expect(fake.stored['proxy.engine_stack'], 'system');
    expect(fake.stored['module.download.enabled'], isTrue);
    expect(fake.meta.containsKey(kConfigMigrationMarkerKey), isTrue);
    expect(_prefsOf(fixture), isNotEmpty,
        reason: 'old prefs are never deleted by the tool');
  });

  test('secure WebDAV bare-key fixture migrates and its backup is secret-free',
      () async {
    final fixture = _fixture('legacy_config_migration_secure_webdav_bare.json');
    final fake = _FakeMigrationApi();
    final temp = await Directory.systemTemp.createTemp('gstore_cfg_bare_');
    try {
      final report = await _run(fixture, api: fake, backupDir: temp.path);

      expect(report.totalStorageKeys, 5);
      expect(report.applied, 5);
      expect(report.failed, 0);
      expect(report.verifyFailures, 0);
      expect(report.markerWritten, isTrue);
      expect(report.secretScanClean, isTrue);
      expect(fake.stored['webdav.url'],
          'https://dav.bare-only.example/remote.php/dav/files/bare');
      expect(fake.stored['webdav.username'], 'bare-only-user');
      expect(fake.stored['webdav.password'], 'BareOnly!-webdav-secret');
      expect(fake.stored['webdav.backup_path'], '/BareOnlyBackup');
      expect(fake.stored['webdav.enable_https'], isTrue);

      // Secret scan covers the backup artifact and the marker payload.
      expect(report.backupPath, isNotNull);
      final backup = File(report.backupPath!);
      expect(backup.existsSync(), isTrue);
      final backupContent = backup.readAsStringSync();
      expect(backupContent, isNot(contains('BareOnly!-webdav-secret')));
      final backupJson = jsonDecode(backupContent) as Map<String, Object?>;
      final backupSecure =
          Map<String, Object?>.from(backupJson['secure']! as Map);
      expect(backupSecure.containsKey('webdav_password'), isFalse);
      final marker = fake.meta[kConfigMigrationMarkerKey]!;
      expect(marker, isNot(contains('BareOnly!-webdav-secret')));
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('secure_config_ fixture migrates the stale provider copy', () async {
    final fixture = _fixture('legacy_config_migration_secure_config_keys.json');
    final fake = _FakeMigrationApi();
    final report = await _run(fixture, api: fake);

    expect(report.totalStorageKeys, 5);
    expect(report.applied, 5);
    expect(report.failed, 0);
    expect(report.markerWritten, isTrue);
    expect(report.secretScanClean, isTrue);
    expect(fake.stored['webdav.url'],
        'https://dav.provider-copy.example/remote.php/dav/files/provider');
    expect(fake.stored['webdav.username'], 'provider-copy-user');
    expect(fake.stored['webdav.password'], 'ProviderCopy!-webdav-secret');
    expect(fake.stored['webdav.backup_path'], '/ProviderCopyBackup');
    expect(fake.stored['webdav.enable_https'], isFalse);
  });

  test('divergent WebDAV fixture migrates the bare copy only', () async {
    final fixture = _fixture('legacy_config_migration_webdav_divergent.json');
    final fake = _FakeMigrationApi();
    final report = await _run(fixture, api: fake);

    expect(report.totalStorageKeys, 10);
    expect(report.applied, 5, reason: 'only the bare WebDavConfigManager wins');
    expect(report.failed, 0);
    expect(report.verifyFailures, 0);
    expect(report.markerWritten, isTrue);

    final superseded = report.keys
        .where((key) => key.status == 'superseded')
        .toList();
    expect(superseded, hasLength(5));
    expect(
      superseded.every(
        (key) => key.storageKey.startsWith('secure_config_webdav_'),
      ),
      isTrue,
    );
    expect(
      report.keys.any((key) =>
          key.storageKey == 'secure_config_webdav_password' &&
          key.status == 'superseded' &&
          key.wireKey == 'webdav.password'),
      isTrue,
    );

    expect(fake.stored['webdav.url'],
        'https://dav.live-bare.example/remote.php/dav/files/live');
    expect(fake.stored['webdav.username'], 'live-bare-user');
    expect(fake.stored['webdav.password'], 'LiveBare!-webdav-secret');
    expect(fake.stored['webdav.backup_path'], '/LiveBareBackup');
    expect(fake.stored['webdav.enable_https'], isTrue);
    final storedJson = jsonEncode(fake.stored);
    expect(storedJson, isNot(contains('stale-copy.example')));
    expect(storedJson, isNot(contains('stale-copy-user')));
    expect(storedJson, isNot(contains('StaleCopy!-webdav-secret')));
    expect(storedJson, isNot(contains('/StaleCopyBackup')));
  });

  test('already-migrated fixture returns alreadyDone without reading/importing',
      () async {
    final fixture =
        _fixture('legacy_config_migration_already_migrated.json');
    final fake = _FakeMigrationApi();
    _seedFixtureMeta(fake, fixture);
    final markerBefore = fake.meta[kConfigMigrationMarkerKey];
    expect(markerBefore, isNotNull);

    final source = _countingSourceOf(fixture);
    final first = await ConfigMigrationTool.run(api: fake, source: source);

    expect(first.alreadyDone, isTrue);
    expect(first.coreReady, isTrue);
    expect(first.markerWritten, isFalse);
    expect(first.totalStorageKeys, 0);
    expect(first.applied, 0);
    expect(first.failed, 0);
    expect(first.keys, isEmpty);
    expect(fake.importCalls, 0);
    expect(fake.verifyCalls, 0);
    expect(fake.stored, isEmpty);
    expect(source.prefsReads, 0);
    expect(source.secureReads, 0);
    expect(fake.meta[kConfigMigrationMarkerKey], markerBefore);

    // A second call on the same already-migrated DB is still a no-op.
    final second = await ConfigMigrationTool.run(api: fake, source: source);
    expect(second.alreadyDone, isTrue);
    expect(second.markerWritten, isFalse);
    expect(fake.importCalls, 0);
    expect(fake.verifyCalls, 0);
    expect(source.prefsReads, 0);
    expect(source.secureReads, 0);
    expect(fake.meta[kConfigMigrationMarkerKey], markerBefore);
  });

  test('all five required fixtures produce their expected reports', () async {
    const expectations = <String, ({
      int total,
      int applied,
      int failed,
      bool marker,
      bool alreadyDone,
      String? errorCode,
    })>{
      'legacy_config_migration_prefs_only.json': (
        total: 7,
        applied: 7,
        failed: 0,
        marker: true,
        alreadyDone: false,
        errorCode: null,
      ),
      'legacy_config_migration_secure_webdav_bare.json': (
        total: 5,
        applied: 5,
        failed: 0,
        marker: true,
        alreadyDone: false,
        errorCode: null,
      ),
      'legacy_config_migration_secure_config_keys.json': (
        total: 5,
        applied: 5,
        failed: 0,
        marker: true,
        alreadyDone: false,
        errorCode: null,
      ),
      'legacy_config_migration_corrupt.json': (
        total: 5,
        applied: 3,
        failed: 2,
        marker: false,
        alreadyDone: false,
        errorCode: 'migration_incomplete',
      ),
      'legacy_config_migration_already_migrated.json': (
        total: 0,
        applied: 0,
        failed: 0,
        marker: false,
        alreadyDone: true,
        errorCode: null,
      ),
    };

    for (final entry in expectations.entries) {
      final fixture = _fixture(entry.key);
      final fake = _FakeMigrationApi();
      _seedFixtureMeta(fake, fixture);
      final report = await _run(fixture, api: fake);
      final expected = entry.value;

      expect(report.totalStorageKeys, expected.total,
          reason: '${entry.key}: total');
      expect(report.applied, expected.applied,
          reason: '${entry.key}: applied');
      expect(report.failed, expected.failed, reason: '${entry.key}: failed');
      expect(report.markerWritten, expected.marker,
          reason: '${entry.key}: markerWritten');
      expect(report.alreadyDone, expected.alreadyDone,
          reason: '${entry.key}: alreadyDone');
      expect(report.verifyFailures, 0, reason: '${entry.key}: verify');
      expect(report.secretScanClean, isTrue,
          reason: '${entry.key}: secret scan');
      expect(report.errorCode, expected.errorCode,
          reason: '${entry.key}: errorCode');
    }
  });

  test('manual QA: per-fixture counts, statuses and marker presence', () async {
    const fixtures = <String>[
      'legacy_config_migration_prefs_only.json',
      'legacy_config_migration_secure_webdav_bare.json',
      'legacy_config_migration_secure_config_keys.json',
      'legacy_config_migration_corrupt.json',
      'legacy_config_migration_already_migrated.json',
      'legacy_config_migration_webdav_divergent.json',
    ];

    for (final name in fixtures) {
      final fixture = _fixture(name);
      final fake = _FakeMigrationApi();
      _seedFixtureMeta(fake, fixture);
      final report = await _run(fixture, api: fake);

      print('=== $name ===');
      print('summary: $report');
      print('counts: total=${report.totalStorageKeys} '
          'applied=${report.applied} unchanged=${report.unchanged} '
          'failed=${report.failed} verifyFailures=${report.verifyFailures} '
          'distinctWireKeys=${report.distinctWireKeys}');
      print('alreadyDone=${report.alreadyDone} '
          'markerPresent=${fake.meta.containsKey(kConfigMigrationMarkerKey)} '
          'markerWritten=${report.markerWritten} '
          'secretScanClean=${report.secretScanClean} '
          'errorCode=${report.errorCode}');
      final byStatus = <String, int>{};
      for (final key in report.keys) {
        byStatus[key.status] = (byStatus[key.status] ?? 0) + 1;
      }
      print('statuses: $byStatus');
      for (final key in report.keys) {
        print('  ${key.storageKey} -> ${key.wireKey}: ${key.status}'
            '${key.code == null ? '' : ' (${key.code})'}');
      }
      if (fake.meta.containsKey(kConfigMigrationMarkerKey)) {
        print('marker: ${fake.meta[kConfigMigrationMarkerKey]}');
      } else {
        print('marker: <absent>');
      }

      // Every fixture must report honestly; no values in reports.
      expect(report.coreReady, isTrue);
      expect(report.toJson().toString(), isNot(contains('!-webdav-secret')));
    }
  });
}
