// Todo 29: every BackupService restore path must go through the single
// `ConfigRestoreAdapter` path.
//
// Manual-QA channel: each test prints, per fixture, the restored grouped wire
// keys + values (secrets redacted), the adapter's per-key status report and
// whether app data imported. Run with:
//   flutter test test/backup_restore_test.dart -r expanded
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/migration/config_migration_tool.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'support/added_apps_read_seams.dart';

const String _proxy = 'https://legacy-proxy.example/';
const String _webdavUrl = 'https://dav.example/dav';
const String _webdavUser = 'alice';
const String _webdavPassword = 'task29-webdav-secret';
const String _agentApiKey = 'sk-task29-agent-secret';

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
  late _RecordingRestoreApi api;

  setUp(() {
    backend = InMemoryAddedAppsBackend();
    AddedAppsFacade.backendOverride = backend;
    service = BackupService.instance;
    service.setTestInitialized();
    api = _RecordingRestoreApi();
    BackupService.debugConfigRestoreApi = api;
  });

  tearDown(() {
    AddedAppsFacade.backendOverride = null;
    BackupService.debugResetConfigRestore();
  });

  test('old backup: legacy flat configs restore + app data imports', () async {
    final apps = _appsJson();
    final legacyConfig = <String, dynamic>{
      'version': 1,
      'timestamp': '2025-01-01T00:00:00.000Z',
      'configs': <String, dynamic>{
        'config_download_max_concurrent': 6,
        'config_download_wifi_only': true,
        'config_download_multi_segment': false,
        'config_download_max_retry': 4,
        LegacyConfigKeys.themeMode: 2,
        LegacyConfigKeys.webdavConfig: <String, dynamic>{
          'url': _webdavUrl,
          'username': _webdavUser,
          'password': _webdavPassword,
          'backupPath': '/GStore',
          'enableHttps': true,
        },
        LegacyConfigKeys.agentModels: <dynamic>[
          <String, dynamic>{
            'id': 'm1',
            'name': 'Model 1',
            'provider': 'google',
            'apiKey': _agentApiKey,
            'model': 'gemini',
            'baseUrl': '',
          },
        ],
      },
      LegacyConfigKeys.proxyUrl: _proxy,
    };

    final result = await service.importBackupBytes(
      _archive(appsJson: apps, appConfigJson: legacyConfig),
    );

    expect(result.success, isTrue);
    expect(await backend.totalCount(), 1);
    expect(api.stored[ConfigKeys.downloadMaxConcurrent], 6);
    expect(api.stored[ConfigKeys.downloadWifiOnly], isTrue);
    expect(api.stored[ConfigKeys.downloadMultiSegmentEnabled], isFalse);
    expect(api.stored[ConfigKeys.downloadMaxRetries], 4);
    expect(api.stored[ConfigKeys.themeMode], 2);
    expect(api.stored[ConfigKeys.webdavUrl], _webdavUrl);
    expect(api.stored[ConfigKeys.webdavPassword], _webdavPassword);
    expect(api.stored[ConfigKeys.proxyUrl], _proxy);
    expect((api.stored[ConfigKeys.agentModels] as List).first['apiKey'],
        _agentApiKey);
    expect(BackupService.debugLastConfigRestoreReport!.success, isTrue);
    expect(api.sources, <String>['restore'],
        reason: 'adapter must pass the canonical Rust source code');

    _printMatrix('old-legacy', api, result, backend);
  });

  test('new backup: grouped wins over legacy, both archive locations read',
      () async {
    final embeddedAppConfig = <String, dynamic>{
      'version': 1,
      'config_format': 2,
      'configs': <String, dynamic>{
        // Grouped key wins over the legacy alias in the same payload.
        ConfigKeys.downloadMaxConcurrent: 5,
        'config_download_max_concurrent': 2,
        ConfigKeys.themeMode: 1,
        LegacyConfigKeys.themeMode: 0,
        ConfigKeys.downloadMultiSegmentEnabled: false,
      },
      LegacyConfigKeys.proxyUrl: _proxy,
      LegacyConfigKeys.webdavConfig: <String, dynamic>{
        'url': _webdavUrl,
        'username': _webdavUser,
        'password': _webdavPassword,
        'backupPath': '/GStore',
        'enableHttps': true,
      },
    };
    final standaloneAppConfig = <String, dynamic>{
      'version': 1,
      'config_format': 2,
      'configs': <String, dynamic>{
        // Only present in app_config.json: proves the file is read too.
        ConfigKeys.updateChannel: 'beta',
        ConfigKeys.catalogUrl: 'https://catalog.example/',
      },
    };

    final result = await service.importBackupBytes(
      _archive(
        appsJson: _appsJson(appConfig: embeddedAppConfig),
        appConfigJson: standaloneAppConfig,
      ),
    );

    expect(result.success, isTrue);
    expect(await backend.totalCount(), 1);
    expect(api.stored[ConfigKeys.downloadMaxConcurrent], 5,
        reason: 'grouped key must win over the legacy alias');
    expect(api.stored[ConfigKeys.themeMode], 1);
    expect(api.stored[ConfigKeys.updateChannel], 'beta');
    expect(api.stored[ConfigKeys.catalogUrl], 'https://catalog.example/');
    expect(api.stored[ConfigKeys.proxyUrl], _proxy);
    expect(api.stored[ConfigKeys.webdavPassword], _webdavPassword);

    final superseded = BackupService.debugLastConfigRestoreReport!.entries
        .where((entry) =>
            entry.wireKey == ConfigKeys.downloadMaxConcurrent &&
            entry.status == 'superseded')
        .length;
    expect(superseded, 1, reason: 'the losing legacy alias is reported');

    _printMatrix('new-grouped', api, result, backend);
  });

  test('bad config key is reported but app data still imports', () async {
    api.rejected[ConfigKeys.themeMode] = 'config_type_mismatch';
    final standalone = <String, dynamic>{
      'version': 1,
      'configs': <String, dynamic>{
        ConfigKeys.themeMode: 2,
        ConfigKeys.downloadMaxConcurrent: 3,
        // Unknown legacy key: adapter-level failure, never a throw.
        'mystery_legacy_key': 'ignored',
      },
    };
    final logs = <({String text, bool isError})>[];

    final result = await service.importBackupBytes(
      _archive(appsJson: _appsJson(), appConfigJson: standalone),
      onLog: (message, {isError = false}) =>
          logs.add((text: message, isError: isError)),
    );

    expect(result.success, isTrue, reason: 'config failure must not abort data');
    expect(await backend.totalCount(), 1);
    expect(api.stored[ConfigKeys.downloadMaxConcurrent], 3);

    final report = BackupService.debugLastConfigRestoreReport!;
    expect(report.success, isFalse);
    expect(report.failures[ConfigKeys.themeMode], 'config_type_mismatch');
    expect(report.failures['mystery_legacy_key'], 'config_unrecognized_key');
    expect(
      logs.any((log) => log.isError && log.text.contains('部分失败')),
      isTrue,
      reason: 'the user-facing progress reports the failure',
    );

    _printMatrix('bad-key', api, result, backend);
  });

  test('whole import seam failure is reported, app data still imports',
      () async {
    api.failAll = true;
    final result = await service.importBackupBytes(
      _archive(
        appsJson: _appsJson(appConfig: <String, dynamic>{
          'version': 1,
          'configs': <String, dynamic>{ConfigKeys.themeMode: 2},
        }),
      ),
    );

    expect(result.success, isTrue);
    expect(await backend.totalCount(), 1);
    final report = BackupService.debugLastConfigRestoreReport!;
    expect(report.failures[ConfigKeys.themeMode], 'config_import_failed');

    _printMatrix('seam-failure', api, result, backend);
  });

  test('restoreAppConfig=false skips config but still imports app data',
      () async {
    final result = await service.importBackupBytes(
      _archive(
        appsJson: _appsJson(appConfig: <String, dynamic>{
          'version': 1,
          'configs': <String, dynamic>{ConfigKeys.themeMode: 2},
        }),
      ),
      restoreAppConfig: false,
    );

    expect(result.success, isTrue);
    expect(await backend.totalCount(), 1);
    expect(api.stored, isEmpty);
    expect(BackupService.debugLastConfigRestoreReport, isNull);

    _printMatrix('skip-config', api, result, backend);
  });
}

/// In-memory stand-in for the Rust `ConfigApi.import_` seam. Reports failures
/// by stable code only (never values), exactly like the adapter expects.
class _RecordingRestoreApi implements ConfigMigrationApi {
  final Map<String, Object?> stored = <String, Object?>{};
  final Map<String, String> rejected = <String, String>{};
  final List<MigrationEntry> lastEntries = <MigrationEntry>[];
  final List<String> sources = <String>[];
  bool failAll = false;

  @override
  Future<MigrationImportResult> importEntries(
    List<MigrationEntry> entries, {
    required String source,
  }) async {
    sources.add(source);
    if (!_allowedConfigSources.contains(source)) {
      throw StateError('config_invalid_source: $source');
    }
    if (failAll) {
      throw StateError('config import seam unavailable');
    }
    lastEntries
      ..clear()
      ..addAll(entries);
    final failed = <String, String>{};
    var applied = 0;
    for (final entry in entries) {
      final code = rejected[entry.wireKey];
      if (code != null) {
        failed[entry.wireKey] = code;
        continue;
      }
      stored[entry.wireKey] = entry.value;
      applied++;
    }
    return MigrationImportResult(
      total: entries.length,
      applied: applied,
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

Uint8List _archive({
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

String _redact(String wireKey, Object? value) {
  final lowered = wireKey.toLowerCase();
  if (lowered.contains('password') ||
      lowered.contains('api_key') ||
      lowered.contains('apikey') ||
      lowered.contains('models')) {
    return '***';
  }
  return '$value';
}

/// Manual-QA output: restored values (secrets redacted), per-key status report
/// and app-data outcome. Never prints a secret.
void _printMatrix(
  String fixture,
  _RecordingRestoreApi api,
  BackupImportResult result,
  InMemoryAddedAppsBackend backend,
) {
  print('[task29] fixture=$fixture');
  print('[task29] fixture=$fixture appData.imported=${result.success} '
      'added=${result.addedCount} total=${result.totalCount}');
  print('[task29] fixture=$fixture restored=${api.stored.length} '
      'wireKeys=${api.stored.keys.toList()}');
  api.stored.forEach((key, value) {
    print('[task29] fixture=$fixture   $key = ${_redact(key, value)}');
  });
  final report = BackupService.debugLastConfigRestoreReport;
  if (report == null) {
    print('[task29] fixture=$fixture report=<skipped>');
    return;
  }
  print('[task29] fixture=$fixture report total=${report.total} '
      'restored=${report.restored} superseded=${report.superseded} '
      'failures=${report.failures}');
  for (final entry in report.entries) {
    print('[task29] fixture=$fixture   '
        'storageKey=${entry.originalKey ?? entry.wireKey} '
        'wireKey=${entry.wireKey} status=${entry.status} '
        'code=${entry.code ?? '-'}');
  }
}
