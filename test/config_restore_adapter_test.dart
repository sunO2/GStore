// Todo 27: backup config restore from both archive locations.
//
// Manual-QA channel: every test prints the restored wire-key/value matrix
// (secrets redacted) plus the per-key status/failure report. Run with:
//   flutter test test/config_restore_adapter_test.dart -r expanded
// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/migration/config_migration_tool.dart';
import 'package:gstore/core/config/migration/config_restore_adapter.dart';

const String _proxy = 'https://old-proxy.example/';
const String _webdavUrl = 'https://dav.example/dav';
const String _webdavUser = 'alice';
const String _webdavPassword = 'task27-webdav-secret';
const String _agentApiKey = 'sk-task27-agent-secret';

/// Registry value types mirrored from Rust `schema.rs`, so the fake rejects a
/// grouped import exactly like `ConfigApi.import_` would.
enum _WireType { boolean, integer, string, stringList, jsonObject, jsonArray }

const Map<String, _WireType> _registryTypes = <String, _WireType>{
  ConfigKeys.themeConfig: _WireType.jsonObject,
  ConfigKeys.themeMode: _WireType.integer,
  ConfigKeys.downloadMultiSegmentEnabled: _WireType.boolean,
  ConfigKeys.downloadWifiOnly: _WireType.boolean,
  ConfigKeys.downloadMaxConcurrent: _WireType.integer,
  ConfigKeys.downloadDefaultConnections: _WireType.integer,
  ConfigKeys.downloadMaxRetries: _WireType.integer,
  ConfigKeys.downloadSpeedLimitBps: _WireType.integer,
  ConfigKeys.updateChannel: _WireType.string,
  ConfigKeys.updateAutoUpdatePolicy: _WireType.string,
  ConfigKeys.updateIgnorePrerelease: _WireType.boolean,
  ConfigKeys.updateSilentUpdate: _WireType.boolean,
  ConfigKeys.updateCheckIntervalHours: _WireType.integer,
  ConfigKeys.updateLastCheckTime: _WireType.string,
  ConfigKeys.updateLastUpdatedVersion: _WireType.string,
  ConfigKeys.webdavUrl: _WireType.string,
  ConfigKeys.webdavUsername: _WireType.string,
  ConfigKeys.webdavPassword: _WireType.string,
  ConfigKeys.webdavBackupPath: _WireType.string,
  ConfigKeys.webdavEnableHttps: _WireType.boolean,
  ConfigKeys.proxyUrl: _WireType.string,
  ConfigKeys.catalogUrl: _WireType.string,
  ConfigKeys.agentModels: _WireType.jsonArray,
  ConfigKeys.agentSelectedModelId: _WireType.string,
  ConfigKeys.agentModelCatalog: _WireType.jsonObject,
  ConfigKeys.fdroidSources: _WireType.jsonArray,
  ConfigKeys.lastSourceId: _WireType.string,
  ConfigKeys.selectedChannels: _WireType.stringList,
  ConfigKeys.perfProfiles: _WireType.jsonObject,
  ConfigKeys.perfProfilesEnabled: _WireType.boolean,
  ConfigKeys.perfHistoryEnabled: _WireType.boolean,
  ConfigKeys.proxyEngineStack: _WireType.string,
  ConfigKeys.proxyEngineMtu: _WireType.integer,
  ConfigKeys.proxyRoutingMode: _WireType.string,
  ConfigKeys.proxyRunMode: _WireType.string,
  ConfigKeys.proxyActiveNodeLabel: _WireType.jsonObject,
  ConfigKeys.proxyActiveProfileId: _WireType.string,
  ConfigKeys.proxySheetViewMode: _WireType.string,
  ConfigKeys.proxySplitMode: _WireType.string,
  ConfigKeys.proxySplitApps: _WireType.stringList,
  ConfigKeys.proxyAlwaysOnIntent: _WireType.boolean,
  ConfigKeys.proxyLogLevel: _WireType.string,
};

_WireType? _wireTypeOf(String wireKey) {
  if (wireKey.startsWith('module.') && wireKey.endsWith('.enabled')) {
    return _WireType.boolean;
  }
  return _registryTypes[wireKey];
}

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

/// In-memory stand-in for `ConfigApi.import_`: applies the registry type
/// checks, reports failures by code only, and stores raw values exactly like
/// the trusted Rust import path.
class _FakeRestoreApi implements ConfigMigrationApi {
  final Map<String, Object?> stored = <String, Object?>{};
  final Map<String, String> rejected = <String, String>{};
  final List<String> sources = <String>[];
  final List<MigrationEntry> lastEntries = <MigrationEntry>[];

  @override
  Future<MigrationImportResult> importEntries(
    List<MigrationEntry> entries, {
    required String source,
  }) async {
    sources.add(source);
    lastEntries
      ..clear()
      ..addAll(entries);

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
  Future<String?> getMeta(String key) async => null;

  @override
  Future<void> setMeta(String key, String valueJson) async {}
}

Object? _redact(Object? value) {
  if (value is String) {
    if (value == _webdavPassword ||
        value == _agentApiKey ||
        value.contains('secret') ||
        value.startsWith('sk-')) {
      return '***';
    }
    return value;
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _redact(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _redact(item)];
  }
  return value;
}

/// Prints the restored value matrix and the per-key restore report.
void _printMatrix(
  String label,
  ConfigRestoreReport report,
  _FakeRestoreApi api,
) {
  final keys = api.stored.keys.toList()..sort();
  print('[task27] === $label ===');
  print('[task27] sources=${api.sources.toSet().toList()} '
      'wire_keys=${keys.length}');
  for (final key in keys) {
    final value = api.stored[key];
    // Redact by key as well: a fixture password need not contain "secret".
    final display =
        key.contains('password') || key.contains('api_key') ? '***' : _redact(value);
    print('[task27]   restored $key = $display');
  }
  for (final entry in report.entries) {
    if (entry.status == 'restored') continue;
    print('[task27]   ${entry.status} ${entry.wireKey}'
        '${entry.code == null ? '' : ' (${entry.code})'}'
        ' <- ${entry.originalKey ?? ''} [${entry.source}]');
  }
  print('[task27] $label report total=${report.total} '
      'restored=${report.restored} superseded=${report.superseded} '
      'failed=${report.failedCount}');
}

Map<String, dynamic> _webdavConfig({
  String url = _webdavUrl,
  String username = _webdavUser,
  String password = _webdavPassword,
  String backupPath = '/GStore',
  bool enableHttps = true,
}) {
  return <String, dynamic>{
    'url': url,
    'username': username,
    'password': password,
    'backupPath': backupPath,
    'enableHttps': enableHttps,
  };
}

void main() {
  test('old apps.json: restores legacy configs + top-level proxy/WebDAV',
      () async {
    final fake = _FakeRestoreApi();
    final appsJson = <String, dynamic>{
      'metadata': <String, dynamic>{'version': '2.1'},
      'apps': <dynamic>[],
      'appConfig': <String, dynamic>{
        'version': 1,
        'timestamp': '2026-10-30T00:00:00.000',
        'configs': <String, dynamic>{
          LegacyConfigKeys.themeMode: 2,
          LegacyConfigKeys.themeConfig: <String, dynamic>{
            'primaryColor': '#123456',
          },
          LegacyConfigKeys.downloadConfig: <String, dynamic>{
            'multiSegmentEnabled': false,
            'maxSegments': 8,
            'segmentSizeBytes': 8388608,
            'maxConcurrentDownloads': 5,
            'wifiOnly': true,
            'maxRetryCount': 4,
          },
          LegacyConfigKeys.updateConfig: <String, dynamic>{
            'channel': 1,
            'autoUpdatePolicy': 2,
            'ignorePrerelease': false,
            'silentUpdate': true,
            'checkIntervalHours': 6,
            'lastCheckTime': '2026-10-30T00:00:00.000',
            'lastUpdatedVersion': '2.1.0',
          },
          LegacyConfigKeys.agentModels: <dynamic>[
            <String, dynamic>{'id': 'legacy-model', 'apiKey': _agentApiKey},
          ],
          LegacyConfigKeys.agentSelectedModelId: 'legacy-model',
          LegacyConfigKeys.agentModelCatalog: <String, dynamic>{
            'legacy-model': <String, dynamic>{'name': 'Legacy Model'},
          },
          LegacyConfigKeys.fdroidSources: <dynamic>[
            <String, dynamic>{
              'id': 'legacy',
              'url': 'https://fdroid.example/repo',
            },
          ],
          LegacyConfigKeys.lastSourceId: 'legacy',
          LegacyConfigKeys.selectedChannels: <String>['github', 'fdroid'],
          'config_catalog_url': 'https://catalog.example/',
          'config_proxy_log_level': 'debug',
          'config_module.download.enabled': false,
        },
        LegacyConfigKeys.proxyUrl: _proxy,
        LegacyConfigKeys.webdavConfig: _webdavConfig(),
      },
    };

    final report =
        await ConfigRestoreAdapter(api: fake).restore(appsJson: appsJson);
    _printMatrix('old apps.json', report, fake);

    expect(report.success, isTrue);
    expect(report.failedCount, 0);
    expect(report.restored, greaterThan(20));
    expect(fake.sources, <String>[kConfigRestoreSource]);

    expect(fake.stored[ConfigKeys.themeMode], 2);
    expect(fake.stored[ConfigKeys.themeConfig],
        <String, Object?>{'primaryColor': '#123456'});
    expect(fake.stored[ConfigKeys.downloadMultiSegmentEnabled], isFalse);
    expect(fake.stored[ConfigKeys.downloadMaxConcurrent], 5);
    expect(fake.stored[ConfigKeys.downloadWifiOnly], isTrue);
    expect(fake.stored[ConfigKeys.downloadMaxRetries], 4);
    expect(fake.stored[ConfigKeys.updateChannel], 'beta');
    expect(fake.stored[ConfigKeys.updateAutoUpdatePolicy], 'always');
    expect(fake.stored[ConfigKeys.updateIgnorePrerelease], isFalse);
    expect(fake.stored[ConfigKeys.updateSilentUpdate], isTrue);
    expect(fake.stored[ConfigKeys.updateCheckIntervalHours], 6);
    expect(fake.stored[ConfigKeys.updateLastCheckTime],
        '2026-10-30T00:00:00.000');
    expect(fake.stored[ConfigKeys.updateLastUpdatedVersion], '2.1.0');
    expect(fake.stored[ConfigKeys.agentSelectedModelId], 'legacy-model');
    expect(fake.stored[ConfigKeys.agentModelCatalog],
        <String, Object?>{
          'legacy-model': <String, Object?>{'name': 'Legacy Model'},
        });
    expect(fake.stored[ConfigKeys.lastSourceId], 'legacy');
    expect(fake.stored[ConfigKeys.selectedChannels], <String>['github', 'fdroid']);
    expect(fake.stored[ConfigKeys.catalogUrl], 'https://catalog.example/');
    expect(fake.stored[ConfigKeys.proxyLogLevel], 'debug');
    expect(fake.stored[ConfigKeys.moduleDownloadEnabled], isFalse);

    // Top-level mirrors from apps.json.appConfig.
    expect(fake.stored[ConfigKeys.proxyUrl], _proxy);
    expect(fake.stored[ConfigKeys.webdavUrl], _webdavUrl);
    expect(fake.stored[ConfigKeys.webdavUsername], _webdavUser);
    expect(fake.stored[ConfigKeys.webdavPassword], _webdavPassword);
    expect(fake.stored[ConfigKeys.webdavBackupPath], '/GStore');
    expect(fake.stored[ConfigKeys.webdavEnableHttps], isTrue);
  });

  test('new app_config.json: grouped keys win over legacy aliases', () async {
    final fake = _FakeRestoreApi();
    final appConfigJson = <String, dynamic>{
      'version': 1,
      'timestamp': '2026-10-30T00:00:00.000',
      'config_format': 2,
      'configs': <String, dynamic>{
        // Same wire key twice: grouped must win.
        ConfigKeys.themeMode: 2,
        LegacyConfigKeys.themeMode: 0,
        ConfigKeys.downloadMultiSegmentEnabled: false,
        LegacyConfigKeys.downloadConfig: <String, dynamic>{
          'multiSegmentEnabled': true,
          'maxConcurrentDownloads': 9,
          'wifiOnly': false,
          'maxRetryCount': 1,
        },
        ConfigKeys.proxyUrl: 'https://grouped-proxy.example/',
        LegacyConfigKeys.proxyUrl: 'https://legacy-proxy.example/',
        ConfigKeys.catalogUrl: 'https://grouped-catalog.example/',
        LegacyConfigKeys.catalogUrl: 'https://legacy-catalog.example/',
        ConfigKeys.agentModels: <dynamic>[
          <String, dynamic>{'id': 'new-model', 'apiKey': _agentApiKey},
        ],
        LegacyConfigKeys.agentModels: <dynamic>[
          <String, dynamic>{'id': 'legacy-model'},
        ],
        ConfigKeys.webdavUrl: 'https://grouped-dav.example/',
        ConfigKeys.webdavUsername: 'grouped-user',
        ConfigKeys.webdavPassword: _webdavPassword,
        ConfigKeys.webdavBackupPath: '/grouped',
        ConfigKeys.webdavEnableHttps: false,
        LegacyConfigKeys.webdavConfig: _webdavConfig(
          url: 'https://legacy-dav.example/',
          username: 'legacy-user',
          password: 'legacy-password',
          backupPath: '/legacy',
          enableHttps: true,
        ),
        ConfigKeys.moduleDownloadEnabled: false,
        ConfigKeys.proxyLogLevel: 'warn',
      },
      // Top-level mirrors lose to grouped/legacy config values.
      LegacyConfigKeys.proxyUrl: 'https://top-proxy.example/',
      LegacyConfigKeys.webdavConfig: _webdavConfig(
        url: 'https://top-dav.example/',
        username: 'top-user',
        password: 'top-password',
        backupPath: '/top',
        enableHttps: true,
      ),
    };

    final report = await ConfigRestoreAdapter(api: fake)
        .restore(appConfigJson: appConfigJson);
    _printMatrix('new app_config.json', report, fake);

    expect(report.success, isTrue);
    expect(report.superseded, greaterThan(0));

    expect(fake.stored[ConfigKeys.themeMode], 2,
        reason: 'grouped theme.mode overrides legacy theme_mode');
    expect(fake.stored[ConfigKeys.downloadMultiSegmentEnabled], isFalse,
        reason: 'grouped download flag overrides download_config');
    expect(fake.stored[ConfigKeys.downloadMaxConcurrent], 9,
        reason: 'legacy-only field still restores');
    expect(fake.stored[ConfigKeys.downloadWifiOnly], isFalse);
    expect(fake.stored[ConfigKeys.downloadMaxRetries], 1);
    expect(fake.stored[ConfigKeys.proxyUrl], 'https://grouped-proxy.example/');
    expect(fake.stored[ConfigKeys.catalogUrl],
        'https://grouped-catalog.example/');
    expect(fake.stored[ConfigKeys.agentModels], <dynamic>[
      <String, dynamic>{'id': 'new-model', 'apiKey': _agentApiKey},
    ]);
    expect(fake.stored[ConfigKeys.webdavUrl], 'https://grouped-dav.example/');
    expect(fake.stored[ConfigKeys.webdavUsername], 'grouped-user');
    expect(fake.stored[ConfigKeys.webdavPassword], _webdavPassword);
    expect(fake.stored[ConfigKeys.webdavBackupPath], '/grouped');
    expect(fake.stored[ConfigKeys.webdavEnableHttps], isFalse);
    expect(fake.stored[ConfigKeys.moduleDownloadEnabled], isFalse);
    expect(fake.stored[ConfigKeys.proxyLogLevel], 'warn');
  });

  test('defensive flat map: no configs wrapper still restores', () async {
    final fake = _FakeRestoreApi();
    final appsJson = <String, dynamic>{
      'appConfig': <String, dynamic>{
        LegacyConfigKeys.themeMode: 1,
        'config_download_max_concurrent': 7,
        'config_proxy_url': 'https://flat-proxy.example/',
        LegacyConfigKeys.webdavUrl: 'https://flat-dav.example/',
        LegacyConfigKeys.webdavUsername: 'bob',
        LegacyConfigKeys.webdavPassword: _webdavPassword,
        LegacyConfigKeys.webdavBackupPath: '/flat',
        LegacyConfigKeys.webdavEnableHttps: false,
        LegacyConfigKeys.fdroidSources: <dynamic>[
          <String, dynamic>{
            'id': 'flat',
            'url': 'https://flat-fdroid.example/',
          },
        ],
        LegacyConfigKeys.selectedChannels: <String>['fdroid'],
      },
    };

    final report =
        await ConfigRestoreAdapter(api: fake).restore(appsJson: appsJson);
    _printMatrix('flat apps.json.appConfig', report, fake);

    expect(report.success, isTrue);
    expect(fake.stored[ConfigKeys.themeMode], 1);
    expect(fake.stored[ConfigKeys.downloadMaxConcurrent], 7);
    expect(fake.stored[ConfigKeys.proxyUrl], 'https://flat-proxy.example/');
    expect(fake.stored[ConfigKeys.webdavUrl], 'https://flat-dav.example/');
    expect(fake.stored[ConfigKeys.webdavUsername], 'bob');
    expect(fake.stored[ConfigKeys.webdavPassword], _webdavPassword);
    expect(fake.stored[ConfigKeys.webdavBackupPath], '/flat');
    expect(fake.stored[ConfigKeys.webdavEnableHttps], isFalse);
    expect(fake.stored[ConfigKeys.selectedChannels], <String>['fdroid']);
    expect(fake.stored[ConfigKeys.fdroidSources], <dynamic>[
      <String, dynamic>{'id': 'flat', 'url': 'https://flat-fdroid.example/'},
    ]);
  });

  test('top-level proxy/WebDAV restore from both archive locations', () async {
    final fake = _FakeRestoreApi();
    final appsJson = <String, dynamic>{
      'appConfig': <String, dynamic>{
        'version': 1,
        'configs': <String, dynamic>{},
        LegacyConfigKeys.proxyUrl: 'https://apps-proxy.example/',
        LegacyConfigKeys.webdavConfig: _webdavConfig(
          url: 'https://apps-dav.example/',
          username: 'apps-user',
          password: 'apps-password',
          backupPath: '/apps',
        ),
      },
    };
    final appConfigJson = <String, dynamic>{
      'version': 1,
      'config_format': 2,
      'configs': <String, dynamic>{},
      LegacyConfigKeys.proxyUrl: 'https://file-proxy.example/',
      LegacyConfigKeys.webdavConfig: _webdavConfig(
        url: 'https://file-dav.example/',
        username: 'file-user',
        password: 'file-password',
        backupPath: '/file',
        enableHttps: false,
      ),
    };

    final report = await ConfigRestoreAdapter(api: fake).restore(
      appsJson: appsJson,
      appConfigJson: appConfigJson,
    );
    _printMatrix('top-level both locations', report, fake);

    expect(report.success, isTrue);
    // app_config.json is the canonical config bundle and wins equal-priority
    // top-level mirrors.
    expect(fake.stored[ConfigKeys.proxyUrl], 'https://file-proxy.example/');
    expect(fake.stored[ConfigKeys.webdavUrl], 'https://file-dav.example/');
    expect(fake.stored[ConfigKeys.webdavUsername], 'file-user');
    expect(fake.stored[ConfigKeys.webdavPassword], 'file-password');
    expect(fake.stored[ConfigKeys.webdavBackupPath], '/file');
    expect(fake.stored[ConfigKeys.webdavEnableHttps], isFalse);
  });

  test('unknown/bad legacy keys are reported while the rest restore',
      () async {
    final fake = _FakeRestoreApi();
    final appConfigJson = <String, dynamic>{
      'version': 1,
      'config_format': 2,
      'configs': <String, dynamic>{
        LegacyConfigKeys.themeMode: 2,
        'bogus_legacy_key': 'x',
        'config_download_max_concurrent': 'not-a-number',
        LegacyConfigKeys.proxyUrl: 'https://ok-proxy.example/',
        'config_module.backup.enabled': true,
        // Unknown grouped key: handed to Rust as-is, rejected there.
        'unknown.module_key': 1,
      },
    };

    final report = await ConfigRestoreAdapter(api: fake)
        .restore(appConfigJson: appConfigJson);
    _printMatrix('unknown + bad legacy keys', report, fake);

    expect(report.success, isFalse);
    expect(report.failures['bogus_legacy_key'], 'config_unrecognized_key');
    expect(report.failures[ConfigKeys.downloadMaxConcurrent],
        'config_invalid_int');
    expect(report.failures['unknown.module_key'], 'config_unregistered_key');

    // Everything valid still restored.
    expect(fake.stored[ConfigKeys.themeMode], 2);
    expect(fake.stored[ConfigKeys.proxyUrl], 'https://ok-proxy.example/');
    expect(fake.stored[ConfigKeys.moduleBackupEnabled], isTrue);
    expect(fake.stored.containsKey(ConfigKeys.downloadMaxConcurrent), isFalse);
  });

  test('secrets restore raw through the trusted import seam', () async {
    final fake = _FakeRestoreApi();
    final appConfigJson = <String, dynamic>{
      'version': 1,
      'config_format': 2,
      'configs': <String, dynamic>{
        ConfigKeys.agentModels: <dynamic>[
          <String, dynamic>{'id': 'm1', 'apiKey': _agentApiKey},
        ],
        LegacyConfigKeys.webdavConfig: _webdavConfig(),
      },
    };

    final report = await ConfigRestoreAdapter(api: fake)
        .restore(appConfigJson: appConfigJson);
    _printMatrix('secret raw restore', report, fake);

    expect(report.success, isTrue);
    expect(fake.stored[ConfigKeys.webdavPassword], _webdavPassword,
        reason: 'the trusted import path must not mask secrets');
    expect(
      (fake.stored[ConfigKeys.agentModels]! as List).first,
      <String, Object?>{'id': 'm1', 'apiKey': _agentApiKey},
    );
    // The report itself carries codes only, never secret values.
    final reportText = jsonEncode(<String, Object?>{
      'failures': report.failures,
      'entries': <Object?>[
        for (final entry in report.entries)
          <String, Object?>{
            'wireKey': entry.wireKey,
            'status': entry.status,
            'code': entry.code,
          },
      ],
    });
    expect(reportText.contains(_webdavPassword), isFalse);
    expect(reportText.contains(_agentApiKey), isFalse);
  });
}
