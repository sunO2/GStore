// Todo 30: backup round-trip and cross-version tests.
//
// Cases:
//   1. OLD backup (legacy flat `configs` + top-level proxy/WebDAV, embedded in
//      `apps.json.appConfig` only) → NEW app restore.
//   2. NEW backup (real export: `config_format: 2`, grouped keys + legacy
//      aliases + top-level mirrors, in BOTH archive locations) → NEW app
//      restore; every grouped key round-trips, grouped wins over a stale alias.
//   3. NEW backup → legacy-mirror readability: the legacy keys exist in
//      `configs` in BOTH archive locations and match the grouped values.
//   4. A config entry with a SECRET (WebDAV password / agent API key)
//      round-trips raw through the trusted restore path, is masked in
//      non-trusted surfaces/reports, and the archive scan stays consistent.
//   5. A CORRUPT config entry is reported per-key without data loss to the
//      other keys or the app data.
//
// No device, no network: an in-memory `ConfigMigrationApi` stands in for the
// trusted Rust `ConfigApi.import_` seam and the restore still goes through the
// production `BackupService` → `ConfigRestoreAdapter` path.
//
// Manual-QA channel: every case prints the key/value matrix (secrets redacted)
// and the per-key restore report. Run with:
//   flutter test test/backup_config_roundtrip_test.dart -r expanded
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io' show File, gzip;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/migration/config_migration_tool.dart';
import 'package:gstore/core/config/migration/config_restore_adapter.dart';
import 'package:gstore/core/config/migration/legacy_config_mapping.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/added_apps_read_seams.dart';

const String _proxy = 'https://new-backup-proxy.example/';
const String _webdavUrl = 'https://dav.example/dav';
const String _webdavUser = 'alice';
const String _webdavPassword = 'task30-webdav-secret';
const String _agentApiKey = 'sk-task30-agent-secret';
const String _catalogUrl = 'https://catalog.example/';

const String _oldProxy = 'https://old-backup-proxy.example/';
const String _oldWebdavUrl = 'https://old-dav.example/dav';
const String _oldWebdavUser = 'old-alice';
const String _oldWebdavPassword = 'task30-old-webdav-secret';
const String _oldAgentApiKey = 'sk-task30-old-agent-secret';

/// Mirrors Rust `ConfigSource::from_str`: only these six codes are accepted.
const Set<String> _allowedConfigSources = <String>{
  'internal',
  'user',
  'agent',
  'module',
  'migration',
  'restore',
};

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'GStore',
      packageName: 'com.gstore',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
      installerStore: null,
    );
    DatabaseEventBus.instance;
  });

  late InMemoryAddedAppsBackend backend;
  late BackupService service;
  late _RoundTripRestoreApi api;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ConfigStore.instance.initialize();
    ConfigService.instance.registerModule(AppCoreConfigModule());

    backend = InMemoryAddedAppsBackend();
    AddedAppsFacade.backendOverride = backend;

    service = BackupService.instance;
    service.setTestInitialized();
    api = _RoundTripRestoreApi();
    BackupService.debugConfigRestoreApi = api;
  });

  tearDown(() {
    AddedAppsFacade.backendOverride = null;
    BackupService.debugResetConfigRestore();
  });

  test('OLD backup (legacy flat configs + top-level mirrors) → NEW app restore',
      () async {
    final legacyAppConfig = _readFixture('backup_old_app_config.json');
    final bytes = _archiveMaps(
      appsJson: _appsJson(appConfig: legacyAppConfig),
    );
    final logs = <({String text, bool isError})>[];

    final result = await service.importBackupBytes(
      bytes,
      onLog: (message, {isError = false}) =>
          logs.add((text: message, isError: isError)),
    );

    // App data still imports alongside the config restore.
    expect(result.success, isTrue);
    expect(result.addedCount, 1);
    expect(await backend.totalCount(), 1);

    // Legacy storage keys → grouped wire keys.
    expect(api.stored[ConfigKeys.downloadMultiSegmentEnabled], isFalse);
    expect(api.stored[ConfigKeys.downloadMaxConcurrent], 7);
    expect(api.stored[ConfigKeys.downloadWifiOnly], isTrue);
    expect(api.stored[ConfigKeys.downloadMaxRetries], 2);
    expect(api.stored[ConfigKeys.themeMode], 1);
    // Aggregated legacy `config_update_config` split into grouped keys.
    expect(api.stored[ConfigKeys.updateChannel], 'beta');
    expect(api.stored[ConfigKeys.updateAutoUpdatePolicy], 'always');
    expect(api.stored[ConfigKeys.updateIgnorePrerelease], isFalse);
    expect(api.stored[ConfigKeys.updateSilentUpdate], isTrue);
    expect(api.stored[ConfigKeys.updateCheckIntervalHours], 12);
    expect(api.stored[ConfigKeys.updateLastCheckTime],
        '2025-05-31T00:00:00.000Z');
    expect(api.stored[ConfigKeys.updateLastUpdatedVersion], '1.2.3');
    // Bare legacy keys.
    expect(api.stored[ConfigKeys.agentSelectedModelId], 'm-old');
    expect(
      (api.stored[ConfigKeys.agentModels] as List).first['apiKey'],
      _oldAgentApiKey,
    );
    expect((api.stored[ConfigKeys.fdroidSources] as List).first['id'], 'fd1');
    expect(api.stored[ConfigKeys.selectedChannels], <String>['github', 'fdroid']);
    // Legacy proxy-page + module-toggle storage keys.
    expect(api.stored[ConfigKeys.proxyEngineMtu], 1400);
    expect(api.stored[ConfigKeys.moduleChannelEnabled], isFalse);

    // Top-level proxy/WebDAV mirrors from `apps.json.appConfig` are restored.
    expect(api.stored[ConfigKeys.proxyUrl], _oldProxy);
    expect(api.stored[ConfigKeys.webdavUrl], _oldWebdavUrl);
    expect(api.stored[ConfigKeys.webdavUsername], _oldWebdavUser);
    expect(api.stored[ConfigKeys.webdavPassword], _oldWebdavPassword);
    expect(api.stored[ConfigKeys.webdavBackupPath], '/GStore-legacy');
    expect(api.stored[ConfigKeys.webdavEnableHttps], isTrue);

    final report = BackupService.debugLastConfigRestoreReport!;
    expect(report.success, isTrue);
    expect(report.failures, isEmpty);
    expect(api.sources.toSet(), <String>{'restore'},
        reason: 'adapter must pass the canonical Rust source code');
    expect(
      report.entries.any((entry) =>
          entry.status == 'restored' &&
          entry.wireKey == ConfigKeys.webdavPassword),
      isTrue,
    );

    _printMatrix('old-backup->new-app', api);
    _printReport('old-backup->new-app', report);
    _expectNoSecretInLogs(logs, const <String>[
      _oldAgentApiKey,
      _oldWebdavPassword,
    ]);
    print('[task30] old-backup->new-app appData imported=${result.success} '
        'added=${result.addedCount} total=${await backend.totalCount()}');
  });

  test('NEW backup → NEW app restore: grouped round-trip + grouped wins',
      () async {
    backend.seed('github', 'a/b', addTime: 1000);
    await _seedNewAppConfig();
    final exported = await service.exportCompressedBackup(
      includeAppConfig: true,
    );
    final decoded = _decodeArchive(exported);
    final apps = _jsonEntry(decoded.archive, 'apps.json')!;
    final configBundle = _jsonEntry(decoded.archive, 'app_config.json')!;
    final configs = configBundle['configs'] as Map<String, dynamic>;

    // 1) Pristine new backup restores every grouped key.
    final first = await service.importBackupBytes(exported);
    expect(first.success, isTrue);
    expect(await backend.totalCount(), 1);

    final groupedKeys = configs.keys.where(_isGroupedWireKey).toList();
    expect(groupedKeys.length, ConfigKeys.all.length,
        reason: 'the new exporter writes every grouped registry key');
    for (final key in groupedKeys) {
      expect(api.stored[key], configs[key], reason: 'round-trip failed: $key');
    }
    final firstReport = BackupService.debugLastConfigRestoreReport!;
    expect(firstReport.success, isTrue);
    expect(firstReport.failures, isEmpty);
    expect(firstReport.restored, greaterThanOrEqualTo(groupedKeys.length));

    // 2) A stale/conflicting legacy mirror must LOSE to the grouped value.
    final mutatedBundle = _copyJson(configBundle);
    final mutatedConfigs = mutatedBundle['configs'] as Map<String, dynamic>;
    mutatedConfigs[LegacyConfigKeys.themeMode] = 0; // loses to theme.mode = 2
    mutatedConfigs[LegacyConfigKeys.proxyUrl] = 'https://alias-loses.example/';
    mutatedConfigs[LegacyConfigKeys.downloadConfig] = <String, dynamic>{
      ...(mutatedConfigs[LegacyConfigKeys.downloadConfig] as Map)
          .cast<String, dynamic>(),
      'multiSegmentEnabled': true,
    };
    mutatedBundle['proxy_url'] = 'https://top-level-loses.example/';

    final mutatedApps = _copyJson(apps);
    mutatedApps['appConfig'] = mutatedBundle;
    final api2 = _RoundTripRestoreApi();
    BackupService.debugConfigRestoreApi = api2;

    final second = await service.importBackupBytes(_archiveMaps(
      appsJson: mutatedApps,
      appConfigJson: mutatedBundle,
    ));
    expect(second.success, isTrue);
    final secondReport = BackupService.debugLastConfigRestoreReport!;
    expect(secondReport.failures, isEmpty);
    expect(api2.stored[ConfigKeys.themeMode], 2,
        reason: 'grouped theme.mode beats legacy theme_mode');
    expect(api2.stored[ConfigKeys.proxyUrl], _proxy,
        reason: 'grouped network.proxy_url beats alias and top-level mirror');
    expect(api2.stored[ConfigKeys.downloadMultiSegmentEnabled], isFalse,
        reason: 'grouped download switch beats download_config aggregate');
    final superseded = secondReport.entries
        .where((entry) => entry.status == 'superseded')
        .map((entry) => entry.wireKey)
        .toSet();
    expect(superseded, containsAll(<String>[
      ConfigKeys.themeMode,
      ConfigKeys.proxyUrl,
      ConfigKeys.downloadMultiSegmentEnabled,
    ]));

    _printMatrix('new-backup->new-app', api);
    _printReport('new-backup->new-app', firstReport);
    print('[task30] new-backup->new-app groupedKeys=${groupedKeys.length} '
        'allRoundTripped=true');
    _printReport('new-backup-stale-alias', secondReport);
    print('[task30] new-backup-stale-alias groupedWins='
        '{theme.mode=${api2.stored[ConfigKeys.themeMode]}, '
        'network.proxy_url=${api2.stored[ConfigKeys.proxyUrl]}, '
        'download.multi_segment.enabled='
        '${api2.stored[ConfigKeys.downloadMultiSegmentEnabled]}}');
  });

  test('NEW backup → legacy mirror readability in BOTH archive locations',
      () async {
    await _seedNewAppConfig();
    final exported = await service.exportCompressedBackup(
      includeAppConfig: true,
    );
    final decoded = _decodeArchive(exported);
    final apps = _jsonEntry(decoded.archive, 'apps.json')!;
    final configBundle = _jsonEntry(decoded.archive, 'app_config.json')!;
    final embedded = apps['appConfig'] as Map<String, dynamic>?;

    expect(configBundle['config_format'], 2);
    expect(configBundle['version'], 1,
        reason: 'ConfigBackupData.version must never be bumped');
    expect(embedded, isNotNull,
        reason: 'apps.json must keep the embedded appConfig for the old app');

    _expectLegacyMirrors(configBundle, 'app_config.json');
    _expectLegacyMirrors(embedded!, 'apps.json.appConfig');

    // Both archive locations carry the same shared payload.
    expect(configBundle['configs'], embedded['configs']);
    expect(configBundle['proxy_url'], embedded['proxy_url']);
    expect(configBundle['webdav_config'], embedded['webdav_config']);

    print('[task30] legacy-mirror locations={app_config.json, '
        'apps.json.appConfig} config_format=${configBundle['config_format']} '
        'top.proxy_url=${configBundle['proxy_url']} '
        'top.webdav_config=present');
    _printLegacyMirrorMatrix('app_config.json', configBundle);
  });

  test('SECRET round-trips raw through the trusted path, masked elsewhere',
      () async {
    await _seedNewAppConfig();
    final exported = await service.exportCompressedBackup(
      includeAppConfig: true,
    );
    final decoded = _decodeArchive(exported);
    final configBundle = _jsonEntry(decoded.archive, 'app_config.json')!;
    final configs = configBundle['configs'] as Map<String, dynamic>;

    // Raw secret lives in the trusted backup artifact (both grouped + alias).
    expect(configs[ConfigKeys.webdavPassword], _webdavPassword);
    expect(configs[LegacyConfigKeys.webdavPassword], _webdavPassword);
    expect((configs[LegacyConfigKeys.webdavConfig] as Map)['password'],
        _webdavPassword);
    expect(configBundle['webdav_config']['password'], _webdavPassword);
    expect((configs[ConfigKeys.agentModels] as List).first['apiKey'],
        _agentApiKey);
    expect((configs[LegacyConfigKeys.agentModels] as List).first['apiKey'],
        _agentApiKey);

    // Archive scan stays consistent: only the two config-bearing entries carry
    // the secret; nothing else in the archive does.
    expect(_filesContaining(decoded.archive, _webdavPassword),
        <String>{'apps.json', 'app_config.json'});
    expect(_filesContaining(decoded.archive, _agentApiKey),
        <String>{'apps.json', 'app_config.json'});

    // The includeAppConfig:false artifact remains secret-free.
    final noConfig = await service.exportCompressedBackup(
      includeAppConfig: false,
    );
    final noConfigArchive = _decodeArchive(noConfig).archive;
    expect(_filesContaining(noConfigArchive, _webdavPassword), isEmpty);
    expect(_filesContaining(noConfigArchive, _agentApiKey), isEmpty);

    // Trusted restore keeps the raw value.
    final logs = <({String text, bool isError})>[];
    final result = await service.importBackupBytes(
      exported,
      onLog: (message, {isError = false}) =>
          logs.add((text: message, isError: isError)),
    );
    expect(result.success, isTrue);
    expect(api.stored[ConfigKeys.webdavPassword], _webdavPassword);
    expect((api.stored[ConfigKeys.agentModels] as List).first['apiKey'],
        _agentApiKey);

    // Non-trusted surfaces mask the value ...
    expect(await ConfigService.instance.get(ConfigKeys.webdavPassword), '***');
    expect(await ConfigService.instance.get(ConfigKeys.agentModels), '***');
    expect(
      ConfigService.instance.debugMirror.containsKey(ConfigKeys.webdavPassword),
      isFalse,
      reason: 'sensitive plaintext must never enter the Dart mirror',
    );
    expect(ConfigService.instance.debugMirror.containsKey(ConfigKeys.agentModels),
        isFalse);

    // ... and neither the per-key report nor the progress log leaks a value.
    final report = BackupService.debugLastConfigRestoreReport!;
    _expectNoSecretInReport(report, <String>[_webdavPassword, _agentApiKey]);
    _expectNoSecretInLogs(logs, <String>[_webdavPassword, _agentApiKey]);

    _printSecretsMatrix('secret-roundtrip', configs);
    _printReport('secret-roundtrip', report);
    print('[task30] secret-roundtrip rawRestore='
        '{webdav.password=***, agent.models.apiKey=***} '
        'maskedSurface=*** report=<redacted> archiveScan='
        '{apps.json, app_config.json} noConfigScan=<empty>');
  });

  test('CORRUPT config entry reported per-key, other keys/app data intact',
      () async {
    final corruptBundle = _readFixture('backup_corrupt_config_bundle.json');
    final bytes = _archiveMaps(
      appsJson: _appsJson(appConfig: corruptBundle),
      appConfigJson: corruptBundle,
    );
    final logs = <({String text, bool isError})>[];

    final result = await service.importBackupBytes(
      bytes,
      onLog: (message, {isError = false}) =>
          logs.add((text: message, isError: isError)),
    );

    // App data is never lost because of a bad config entry.
    expect(result.success, isTrue);
    expect(await backend.totalCount(), 1);

    final report = BackupService.debugLastConfigRestoreReport!;
    expect(report.success, isFalse);
    expect(report.failures, <String, String>{
      // Malformed legacy aggregate → adapter-level JSON failure.
      LegacyConfigKeys.webdavConfig: 'config_invalid_json',
      // Unknown legacy key → reported, not thrown.
      'mystery_legacy_key': 'config_unrecognized_key',
      // Grouped key rejected by the trusted import seam (wrong type).
      ConfigKeys.catalogUrl: 'config_type_mismatch',
    });

    // Every healthy key still landed, and the top-level proxy mirror survived.
    expect(api.stored[ConfigKeys.themeMode], 1);
    expect(api.stored[ConfigKeys.downloadMaxConcurrent], 4);
    expect(api.stored[ConfigKeys.downloadMultiSegmentEnabled], isTrue);
    expect(api.stored[ConfigKeys.proxyUrl], 'https://corrupt-case-proxy.example/');
    expect(report.restored, greaterThanOrEqualTo(4));

    // Per-key report: each failure is isolated, no secret/value bytes.
    expect(report.entries.any((entry) =>
            entry.wireKey == LegacyConfigKeys.webdavConfig &&
            entry.status == 'failed' &&
            entry.code == 'config_invalid_json'),
        isTrue);
    expect(report.entries.any((entry) =>
            entry.wireKey == 'mystery_legacy_key' &&
            entry.status == 'failed' &&
            entry.code == 'config_unrecognized_key'),
        isTrue);
    expect(report.entries.any((entry) =>
            entry.wireKey == ConfigKeys.catalogUrl &&
            entry.status == 'failed' &&
            entry.code == 'config_type_mismatch'),
        isTrue);

    _printMatrix('corrupt-entry', api);
    _printReport('corrupt-entry', report);
    print('[task30] corrupt-entry appData imported=${result.success} '
        'total=${await backend.totalCount()} failures=${report.failedCount} '
        'otherKeysRestored=${report.restored}');
    expect(
      logs.any((log) => log.isError && log.text.contains('部分失败')),
      isTrue,
      reason: 'the user-facing progress must surface the partial failure',
    );
  });
}

// ---------------------------------------------------------------------------
// Seeding + archive helpers
// ---------------------------------------------------------------------------

/// Seeds a realistic new-app config through the real `ConfigService` facade.
Future<void> _seedNewAppConfig() async {
  final seeds = <String, Object?>{
    ConfigKeys.themeMode: 2,
    ConfigKeys.themeConfig: <String, dynamic>{'fontStyle': 3},
    ConfigKeys.downloadMultiSegmentEnabled: false,
    ConfigKeys.downloadWifiOnly: true,
    ConfigKeys.downloadMaxConcurrent: 5,
    ConfigKeys.downloadDefaultConnections: 6,
    ConfigKeys.downloadMaxRetries: 4,
    ConfigKeys.downloadSpeedLimitBps: 1048576,
    ConfigKeys.updateChannel: 'beta',
    ConfigKeys.updateAutoUpdatePolicy: 'always',
    ConfigKeys.updateIgnorePrerelease: false,
    ConfigKeys.updateSilentUpdate: true,
    ConfigKeys.updateCheckIntervalHours: 12,
    ConfigKeys.updateLastCheckTime: '2026-01-01T00:00:00.000Z',
    ConfigKeys.updateLastUpdatedVersion: '2.0.0',
    ConfigKeys.webdavUrl: _webdavUrl,
    ConfigKeys.webdavUsername: _webdavUser,
    ConfigKeys.webdavPassword: _webdavPassword,
    ConfigKeys.webdavBackupPath: '/GStore-new',
    ConfigKeys.webdavEnableHttps: false,
    ConfigKeys.proxyUrl: _proxy,
    ConfigKeys.catalogUrl: _catalogUrl,
    ConfigKeys.agentModels: <dynamic>[
      <String, dynamic>{
        'id': 'm-new',
        'name': 'New Model',
        'provider': 'google',
        'apiKey': _agentApiKey,
        'model': 'gemini',
        'baseUrl': '',
      },
    ],
    ConfigKeys.agentSelectedModelId: 'm-new',
    ConfigKeys.agentModelCatalog: <String, dynamic>{
      'https://api.example': <String>['m-new'],
    },
    ConfigKeys.fdroidSources: <dynamic>[
      <String, dynamic>{
        'id': 'fd1',
        'name': 'F-Droid',
        'url': 'https://f-droid.org/repo',
      },
    ],
    ConfigKeys.lastSourceId: 'fd1',
    ConfigKeys.selectedChannels: <String>['github', 'fdroid'],
    ConfigKeys.perfProfiles: <String, dynamic>{
      'com.example.app': <String, dynamic>{'enabled': true, 'gpu_level': 2},
    },
    ConfigKeys.perfProfilesEnabled: true,
    ConfigKeys.perfHistoryEnabled: true,
    ConfigKeys.moduleChannelEnabled: false,
    ConfigKeys.moduleDownloadEnabled: true,
    ConfigKeys.proxyRoutingMode: 'global',
    ConfigKeys.proxyEngineMtu: 1400,
  };
  for (final entry in seeds.entries) {
    final result = await ConfigService.instance.set(entry.key, entry.value);
    expect(result.success, isTrue,
        reason: 'seed failed for ${entry.key}: ${result.message}');
  }
}

Map<String, dynamic> _appsJson({Map<String, dynamic>? appConfig}) {
  return BackupData(
    metadata: BackupMetadata(
      version: BackupVersion.v2_1,
      exportDate: DateTime(2026, 1, 1),
      appVersion: '1.0.0',
      totalApps: 1,
      channelCounts: const <String, int>{'github': 1},
      options: const BackupOptions(),
    ),
    apps: const <BackupAppItem>[
      BackupAppItem(
        channelId: 'github',
        appId: 'a/b',
        appName: 'a/b',
        addTime: 1000,
        sortOrder: 0,
        isEnabled: true,
      ),
    ],
    appConfig: appConfig,
  ).toJson();
}

Uint8List _archiveMaps({
  required Map<String, dynamic> appsJson,
  Map<String, dynamic>? appConfigJson,
}) {
  final archive = Archive();
  final appsBytes = utf8.encode(jsonEncode(appsJson));
  archive.addFile(ArchiveFile('apps.json', appsBytes.length, appsBytes));
  if (appConfigJson != null) {
    final configBytes = utf8.encode(jsonEncode(appConfigJson));
    archive.addFile(
      ArchiveFile('app_config.json', configBytes.length, configBytes),
    );
  }
  return Uint8List.fromList(gzip.encode(TarEncoder().encode(archive)));
}

({Archive archive, List<String> entries}) _decodeArchive(Uint8List bytes) {
  final archive = TarDecoder().decodeBytes(gzip.decode(bytes));
  return (
    archive: archive,
    entries: archive.files.map((file) => file.name).toList(),
  );
}

Map<String, dynamic>? _jsonEntry(Archive archive, String name) {
  for (final file in archive.files) {
    if (file.name != name) continue;
    final content = file.content;
    final bytes = content is Uint8List
        ? content
        : Uint8List.fromList(content as List<int>);
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }
  return null;
}

/// Archive entry names whose bytes contain [needle] (binary entries skipped).
Set<String> _filesContaining(Archive archive, String needle) {
  final found = <String>{};
  for (final file in archive.files) {
    final content = file.content;
    final bytes = content is Uint8List
        ? content
        : Uint8List.fromList(content as List<int>);
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      continue;
    }
    if (text.contains(needle)) found.add(file.name);
  }
  return found;
}

Map<String, dynamic> _readFixture(String name) {
  final file = File('test/fixtures/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _copyJson(Map<String, dynamic> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

/// Mirrors `ConfigRestoreAdapter._isGroupedKey` (without importing its private).
bool _isGroupedWireKey(String key) {
  if (kLegacyStorageKeyToWireKeys.containsKey(key)) return false;
  if (LegacyConfigKeys.all.contains(key)) return false;
  if (key.startsWith('config_') || key.startsWith('secure_config_')) {
    return false;
  }
  return key.contains('.');
}

// ---------------------------------------------------------------------------
// Assertions for legacy-mirror readability (case 3)
// ---------------------------------------------------------------------------

void _expectLegacyMirrors(Map<String, dynamic> payload, String label) {
  final configs = payload['configs'] as Map<String, dynamic>;

  // Dotted grouped keys.
  expect(configs[ConfigKeys.themeMode], 2, reason: '$label grouped theme.mode');
  expect(configs[ConfigKeys.downloadMultiSegmentEnabled], isFalse,
      reason: '$label grouped download switch');
  expect(configs[ConfigKeys.downloadMaxConcurrent], 5);
  expect(configs[ConfigKeys.downloadWifiOnly], isTrue);
  expect(configs[ConfigKeys.downloadMaxRetries], 4);
  expect(configs[ConfigKeys.downloadDefaultConnections], 6);
  expect(configs[ConfigKeys.proxyUrl], _proxy);
  expect(configs[ConfigKeys.webdavPassword], _webdavPassword);
  expect(configs[ConfigKeys.agentModels], isA<List>());
  expect(configs[ConfigKeys.fdroidSources], isA<List>());
  expect(configs[ConfigKeys.selectedChannels], <String>['github', 'fdroid']);
  expect(configs[ConfigKeys.moduleChannelEnabled], isFalse);

  // Simple legacy aliases match their grouped value.
  final aliasPairs = <String, String>{
    LegacyConfigKeys.themeConfig: ConfigKeys.themeConfig,
    LegacyConfigKeys.themeMode: ConfigKeys.themeMode,
    LegacyConfigKeys.proxyUrl: ConfigKeys.proxyUrl,
    LegacyConfigKeys.catalogUrl: ConfigKeys.catalogUrl,
    LegacyConfigKeys.agentModels: ConfigKeys.agentModels,
    LegacyConfigKeys.agentSelectedModelId: ConfigKeys.agentSelectedModelId,
    LegacyConfigKeys.agentModelCatalog: ConfigKeys.agentModelCatalog,
    LegacyConfigKeys.fdroidSources: ConfigKeys.fdroidSources,
    LegacyConfigKeys.lastSourceId: ConfigKeys.lastSourceId,
    LegacyConfigKeys.selectedChannels: ConfigKeys.selectedChannels,
    LegacyConfigKeys.webdavUrl: ConfigKeys.webdavUrl,
    LegacyConfigKeys.webdavUsername: ConfigKeys.webdavUsername,
    LegacyConfigKeys.webdavPassword: ConfigKeys.webdavPassword,
    LegacyConfigKeys.webdavBackupPath: ConfigKeys.webdavBackupPath,
    LegacyConfigKeys.webdavEnableHttps: ConfigKeys.webdavEnableHttps,
  };
  aliasPairs.forEach((legacy, grouped) {
    expect(configs.containsKey(legacy), isTrue,
        reason: '$label missing legacy alias $legacy');
    expect(configs[legacy], configs[grouped],
        reason: '$label alias $legacy != grouped $grouped');
  });

  // Aggregated legacy objects re-expanded from the grouped values.
  final download = configs[LegacyConfigKeys.downloadConfig] as Map;
  expect(download['multiSegmentEnabled'],
      configs[ConfigKeys.downloadMultiSegmentEnabled]);
  expect(download['multiSegmentEnabled'], isFalse);
  expect(download['maxConcurrentDownloads'],
      configs[ConfigKeys.downloadMaxConcurrent]);
  expect(download['wifiOnly'], configs[ConfigKeys.downloadWifiOnly]);
  expect(download['maxRetryCount'], configs[ConfigKeys.downloadMaxRetries]);
  expect(download['maxSegments'], configs[ConfigKeys.downloadDefaultConnections]);

  final update = configs[LegacyConfigKeys.updateConfig] as Map;
  expect(update['channel'], configs[ConfigKeys.updateChannel]);
  expect(update['autoUpdatePolicy'], configs[ConfigKeys.updateAutoUpdatePolicy]);
  expect(update['ignorePrerelease'], configs[ConfigKeys.updateIgnorePrerelease]);
  expect(update['silentUpdate'], configs[ConfigKeys.updateSilentUpdate]);
  expect(update['checkIntervalHours'], configs[ConfigKeys.updateCheckIntervalHours]);
  expect(update['lastCheckTime'], configs[ConfigKeys.updateLastCheckTime]);
  expect(update['lastUpdatedVersion'],
      configs[ConfigKeys.updateLastUpdatedVersion]);

  final webdav = configs[LegacyConfigKeys.webdavConfig] as Map;
  expect(webdav['url'], configs[ConfigKeys.webdavUrl]);
  expect(webdav['username'], configs[ConfigKeys.webdavUsername]);
  expect(webdav['password'], configs[ConfigKeys.webdavPassword]);
  expect(webdav['backupPath'], configs[ConfigKeys.webdavBackupPath]);
  expect(webdav['enableHttps'], configs[ConfigKeys.webdavEnableHttps]);

  // Top-level mirrors for the old importer.
  expect(payload['proxy_url'], configs[ConfigKeys.proxyUrl]);
  expect(payload['webdav_config'], configs[LegacyConfigKeys.webdavConfig]);
}

// ---------------------------------------------------------------------------
// In-memory stand-in for the trusted Rust `ConfigApi.import_` seam
// ---------------------------------------------------------------------------

enum _WireType { boolean, integer, string, stringList, jsonObject, jsonArray }

/// Registry value types mirrored from Rust `schema.rs`, so the fake rejects a
/// grouped import exactly like `ConfigApi.import_` would.
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

/// In-memory `ConfigMigrationApi`: stores raw values exactly like the trusted
/// Rust import path and reports failures by stable code only (never a value).
class _RoundTripRestoreApi implements ConfigMigrationApi {
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
    if (!_allowedConfigSources.contains(source)) {
      // The real Rust host rejects an unknown ConfigSource wholesale.
      throw StateError('config_invalid_source: $source');
    }
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
      eventsPublished: applied,
      failed: failed,
    );
  }

  @override
  Future<MigrationVerifyResult> verifyEntries(List<MigrationEntry> entries) =>
      throw UnimplementedError('unused by backup restore');

  @override
  Future<String?> getMeta(String key) =>
      throw UnimplementedError('unused by backup restore');

  @override
  Future<void> setMeta(String key, String valueJson) =>
      throw UnimplementedError('unused by backup restore');
}

// ---------------------------------------------------------------------------
// Manual-QA output (secrets redacted)
// ---------------------------------------------------------------------------

bool _isSecretName(String name) {
  final lowered = name.toLowerCase();
  return lowered.contains('password') ||
      lowered.contains('api_key') ||
      lowered.contains('apikey');
}

Object? _redact(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString():
            _isSecretName(entry.key.toString()) ? '***' : _redact(entry.value),
    };
  }
  if (value is List) return value.map(_redact).toList();
  return value;
}

String _redactedJson(Object? value) {
  try {
    return jsonEncode(_redact(value));
  } catch (_) {
    return '${_redact(value)}';
  }
}

/// Redacts a scalar whose *key* itself names a secret (e.g. `webdav.password`).
String _redactedJsonForKey(String key, Object? value) {
  if (_isSecretName(key)) return '"***"';
  return _redactedJson(value);
}

void _printMatrix(String fixture, _RoundTripRestoreApi api) {
  final keys = api.stored.keys.toList()..sort();
  print('[task30] fixture=$fixture restored=${keys.length} '
      'sources=${api.sources.toSet().toList()}');
  for (final key in keys) {
    print('[task30] fixture=$fixture   $key = '
        '${_redactedJsonForKey(key, api.stored[key])}');
  }
}

void _printReport(String fixture, ConfigRestoreReport? report) {
  if (report == null) {
    print('[task30] fixture=$fixture report=<none>');
    return;
  }
  print('[task30] fixture=$fixture report total=${report.total} '
      'restored=${report.restored} superseded=${report.superseded} '
      'failed=${report.failedCount} failures=${report.failures}');
  for (final entry in report.entries) {
    print('[task30] fixture=$fixture   source=${entry.source} '
        'original=${entry.originalKey ?? '-'} wire=${entry.wireKey} '
        'status=${entry.status} code=${entry.code ?? '-'}');
  }
}

void _printLegacyMirrorMatrix(String label, Map<String, dynamic> payload) {
  final configs = payload['configs'] as Map<String, dynamic>;
  for (final key in <String>[
    LegacyConfigKeys.themeMode,
    LegacyConfigKeys.downloadConfig,
    LegacyConfigKeys.updateConfig,
    LegacyConfigKeys.proxyUrl,
    LegacyConfigKeys.webdavConfig,
    LegacyConfigKeys.agentModels,
    LegacyConfigKeys.fdroidSources,
    LegacyConfigKeys.selectedChannels,
  ]) {
    print('[task30] legacy-mirror[$label] $key = '
        '${_redactedJson(configs[key])}');
  }
  print('[task30] legacy-mirror[$label] grouped[module.*] present='
      '${configs.containsKey(ConfigKeys.moduleChannelEnabled) || configs.containsKey(ConfigKeys.moduleDownloadEnabled)} '
      'legacy[config_module.*] emitted='
      '${configs.keys.any((key) => key.startsWith('config_module.'))}');
}

void _printSecretsMatrix(String fixture, Map<String, dynamic> configs) {
  print('[task30] fixture=$fixture secretEntries='
      '{${ConfigKeys.webdavPassword}: present, '
      '${ConfigKeys.agentModels}: present, '
      '${LegacyConfigKeys.webdavConfig}.password: present, '
      '${LegacyConfigKeys.agentModels}[0].apiKey: present}');
  print('[task30] fixture=$fixture redacted='
      '${_redactedJson(<String, dynamic>{
        ConfigKeys.webdavPassword: configs[ConfigKeys.webdavPassword],
        ConfigKeys.agentModels: configs[ConfigKeys.agentModels],
        LegacyConfigKeys.webdavConfig:
            configs[LegacyConfigKeys.webdavConfig],
        LegacyConfigKeys.agentModels: configs[LegacyConfigKeys.agentModels],
      })}');
}

void _expectNoSecretInReport(ConfigRestoreReport report, List<String> secrets) {
  final blob = <String>[
    for (final entry in report.entries)
      '${entry.source}|${entry.originalKey}|${entry.wireKey}|'
          '${entry.status}|${entry.code}',
    for (final entry in report.failures.entries)
      '${entry.key}|${entry.value}',
  ].join('\n');
  for (final secret in secrets) {
    expect(blob.contains(secret), isFalse,
        reason: 'the per-key report leaked a secret value');
  }
}

void _expectNoSecretInLogs(
  List<({String text, bool isError})> logs,
  List<String> secrets,
) {
  final blob = logs.map((log) => log.text).join('\n');
  for (final secret in secrets) {
    expect(blob.contains(secret), isFalse,
        reason: 'the restore progress log leaked a secret value');
  }
}
