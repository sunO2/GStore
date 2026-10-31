// Todo 26 (C16): all three backup export paths must emit the grouped config +
// legacy mirror + top-level proxy/WebDAV mirrors, and must honour
// `includeAppConfig` (no config/secrets leak when false).
//
// Manual-QA channel: this file builds each export, lists every archive entry and
// prints the config_format / grouped+legacy key presence / top-level mirrors /
// negative-scan result. Run with:
//   flutter test test/backup_config_export_test.dart -r expanded
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/config/config_backup.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/rust/config_api.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/rust/generated/config_api.dart' as generated;
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/page/backup/logic.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/added_apps_read_seams.dart';
import 'support/grouped_config_fake.dart';

const String _secret = 'task26-super-secret';
const String _proxy = 'https://gh-proxy.org/';
const String _webdavUrl = 'https://dav.example/dav';
const String _webdavUser = 'alice';

/// Raw values that must never survive an `includeAppConfig:false` export.
const List<String> _configValues = <String>[
  _secret,
  _proxy,
  _webdavUrl,
  _webdavUser,
];

/// Config-bearing keys that must never appear when includeAppConfig=false.
final Set<String> _configKeys = <String>{
  ...ConfigKeys.all,
  ...LegacyConfigKeys.all,
  'config_format',
  'agent_models',
  'agent_selected_id',
  'js_envs',
  'js_envs_rust_lane_omitted',
  'fdroid_sources',
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
  });

  late InMemoryAddedAppsBackend backend;
  late BackupService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ConfigStore.instance.initialize();
    ConfigService.instance.registerModule(AppCoreConfigModule());

    backend = InMemoryAddedAppsBackend();
    AddedAppsFacade.backendOverride = backend;
    backend.seed('github', 'a/b', addTime: 1000);

    service = BackupService.instance;
    service.setTestInitialized();
    ModuleManager.instance.bind<IBackupService>(service);
  });

  tearDown(() {
    AddedAppsFacade.backendOverride = null;
  });

  Future<void> seedConfig() async {
    await ConfigService.instance.set(ConfigKeys.proxyUrl, _proxy);
    await ConfigService.instance.set(ConfigKeys.themeMode, 2);
    await ConfigService.instance.set(
        ConfigKeys.downloadMultiSegmentEnabled, false);
    await ConfigService.instance.set(ConfigKeys.webdavUrl, _webdavUrl);
    await ConfigService.instance.set(ConfigKeys.webdavUsername, _webdavUser);
    await ConfigService.instance.set(ConfigKeys.webdavPassword, _secret);
    await ConfigService.instance.set(ConfigKeys.webdavBackupPath, '/GStore');
    await ConfigService.instance.set(ConfigKeys.webdavEnableHttps, true);
  }

  Archive decodeArchive(Uint8List bytes) {
    final decompressed = gzip.decode(bytes);
    return TarDecoder().decodeBytes(decompressed);
  }

  Map<String, dynamic>? jsonEntry(Archive archive, String name) {
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

  void collectKeys(Object? node, Set<String> out) {
    if (node is Map) {
      for (final entry in node.entries) {
        out.add(entry.key.toString());
        collectKeys(entry.value, out);
      }
    } else if (node is List) {
      for (final item in node) {
        collectKeys(item, out);
      }
    }
  }

  /// Scans every archive entry (not just apps.json) for config keys/secrets.
  Set<String> scanArchive(Archive archive) {
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
        continue; // binary channel zip: no JSON config payload
      }
      if (text.contains(_secret)) found.add('SECRET:${file.name}');
      for (final value in _configValues) {
        if (text.contains(value)) found.add('VALUE:$value@${file.name}');
      }
      try {
        final decoded = jsonDecode(text);
        final keys = <String>{};
        collectKeys(decoded, keys);
        for (final key in keys) {
          if (_configKeys.contains(key)) found.add('$key@${file.name}');
        }
      } catch (_) {
        // not JSON
      }
    }
    return found;
  }

  /// Full negative scan of a serialized backup payload (P2.1): every grouped
  /// key, every legacy key, every config-bearing extra name and every raw value.
  void expectNoConfigPayload(String text, String label) {
    for (final key in _configKeys) {
      expect(text.contains(key), isFalse,
          reason: '$label leaked config key "$key"');
    }
    for (final value in _configValues) {
      expect(text.contains(value), isFalse,
          reason: '$label leaked raw value "$value"');
    }
  }

  void printInventory(String path, Map<String, dynamic>? appConfig,
      Iterable<String> entries, Set<String> negative) {
    final configs = appConfig?['configs'];
    print('[task26] path=$path entries=${entries.toList()}');
    print('[task26] path=$path config_format=${appConfig?['config_format']} '
        'version=${appConfig?['version']}');
    print('[task26] path=$path grouped.download.multi_segment.enabled='
        '${configs is Map ? configs.containsKey(ConfigKeys.downloadMultiSegmentEnabled) : false} '
        'legacy.download_config='
        '${configs is Map ? configs.containsKey(LegacyConfigKeys.downloadConfig) : false} '
        'legacy.theme_mode='
        '${configs is Map ? configs.containsKey(LegacyConfigKeys.themeMode) : false}');
    print('[task26] path=$path top.proxy_url=${appConfig?['proxy_url']} '
        'top.webdav_config=${appConfig?['webdav_config'] != null}');
    print('[task26] path=$path negative_scan=${negative.toList()}');
  }

  void expectConfigMirrors(Map<String, dynamic> appConfig) {
    expect(appConfig['config_format'], 2, reason: 'config_format is additive');
    expect(appConfig['version'], 1, reason: 'ConfigBackupData.version stays 1');
    final configs = appConfig['configs'] as Map<String, dynamic>;

    // Grouped key + its legacy alias.
    expect(configs[ConfigKeys.downloadMultiSegmentEnabled], isFalse);
    expect(configs[LegacyConfigKeys.downloadConfig], isA<Map>());
    expect(configs[ConfigKeys.themeMode], 2);
    expect(configs[LegacyConfigKeys.themeMode], 2);
    expect(configs[ConfigKeys.proxyUrl], _proxy);
    expect(configs[LegacyConfigKeys.proxyUrl], _proxy);
    expect(configs[LegacyConfigKeys.webdavConfig], isA<Map>());
    expect((configs[LegacyConfigKeys.webdavConfig] as Map)['password'], _secret);

    // Top-level mirrors for the old importer.
    expect(appConfig['proxy_url'], _proxy);
    final webdav = appConfig['webdav_config'] as Map;
    expect(webdav['url'], _webdavUrl);
    expect(webdav['username'], _webdavUser);
    expect(webdav['password'], _secret);
  }

  test('exportData: config_format=2 + grouped/legacy mirrors + top-level keys',
      () async {
    await seedConfig();
    final data = await service.exportData(includeAppConfig: true);

    expect(data.metadata.version, BackupVersion.v2_1);
    expect(data.appConfig, isNotNull);
    expectConfigMirrors(data.appConfig!);
    printInventory('exportData(true)', data.appConfig, const ['<memory>'],
        <String>{});
  });

  test('exportData: includeAppConfig=false omits appConfig + config extras',
      () async {
    await seedConfig();
    final data = await service.exportData(includeAppConfig: false);

    expect(data.appConfig, isNull);
    expect(data.extras, isNull);
    final text = jsonEncode(data.toJson());
    expectNoConfigPayload(text, 'exportData(false)');
    printInventory('exportData(false)', data.appConfig, const ['<memory>'],
        <String>{});
  });

  test('exportCompressedBackup: writes app_config.json + embeds apps.json appConfig',
      () async {
    await seedConfig();
    final bytes = await service.exportCompressedBackup(includeAppConfig: true);
    final archive = decodeArchive(bytes);
    final entries = archive.files.map((f) => f.name);

    final apps = jsonEntry(archive, 'apps.json')!;
    final configBundle = jsonEntry(archive, 'app_config.json')!;
    expect(apps['appConfig'], isNotNull);
    expectConfigMirrors(configBundle);
    expectConfigMirrors(
        Map<String, dynamic>.from(apps['appConfig'] as Map));

    printInventory('exportCompressedBackup(true)', configBundle, entries,
        <String>{});
  });

  test('exportCompressedBackup forwards includeAppConfig=false (no leak)',
      () async {
    await seedConfig();
    final bytes = await service.exportCompressedBackup(includeAppConfig: false);
    final archive = decodeArchive(bytes);

    expect(jsonEntry(archive, 'app_config.json'), isNull);
    final apps = jsonEntry(archive, 'apps.json')!;
    expect(apps['appConfig'], isNull);

    final negative = scanArchive(archive);
    expect(negative, isEmpty,
        reason: 'no config key or secret may appear in ANY archive entry');
    printInventory('exportCompressedBackup(false)', null,
        archive.files.map((f) => f.name), negative);
  });

  test('local path: forwards _state.includeAppConfig and keeps appConfig',
      () async {
    await seedConfig();
    final logic = BackupLogic();
    await Future<void>.delayed(Duration.zero);
    logic.toggleIncludeAppConfig(true);

    final result = await logic.buildLocalBackupArchive();
    final archive = decodeArchive(result.bytes);
    final entries = archive.files.map((f) => f.name);

    final apps = jsonEntry(archive, 'apps.json')!;
    final embedded = apps['appConfig'] as Map<String, dynamic>?;
    expect(embedded, isNotNull,
        reason: 'local path must no longer strip appConfig');
    expectConfigMirrors(embedded!);

    final configBundle = jsonEntry(archive, 'app_config.json')!;
    expectConfigMirrors(configBundle);
    printInventory('local(true)', configBundle, entries, <String>{});
  });

  test('local path: includeAppConfig=false omits config from every entry',
      () async {
    await seedConfig();
    final logic = BackupLogic();
    await Future<void>.delayed(Duration.zero);
    logic.toggleIncludeAppConfig(false);

    final result = await logic.buildLocalBackupArchive();
    final archive = decodeArchive(result.bytes);

    expect(jsonEntry(archive, 'app_config.json'), isNull);
    final apps = jsonEntry(archive, 'apps.json')!;
    expect(apps['appConfig'], isNull);
    final negative = scanArchive(archive);
    expect(negative, isEmpty);
    printInventory('local(false)', null, archive.files.map((f) => f.name),
        negative);
  });

  test('old-importer replica: restores configs via app_config.json and top-level '
      'proxy/WebDAV via apps.json.appConfig (version > 1 gate)', () async {
    await seedConfig();
    final bytes = await service.exportCompressedBackup(includeAppConfig: true);
    final archive = decodeArchive(bytes);
    final apps = jsonEntry(archive, 'apps.json')!;
    final configBundle = jsonEntry(archive, 'app_config.json')!;

    await ConfigService.instance.set(ConfigKeys.themeMode, 0);

    final restored = await _OldImporterReplica.restore(
      appsJson: apps,
      appConfigJson: configBundle,
    );

    expect(restored.proxyUrl, _proxy);
    expect(restored.webdavPassword, _secret);
    // Grouped config restored through app_config.json (new keys), legacy
    // aliases remained readable by the old-importer replica.
    expect(await ConfigService.instance.getRaw(ConfigKeys.themeMode), 2);
    expect(restored.legacyThemeMode, 2);
    expect(restored.groupedDownloadMultiSegment, isFalse);
    expect(restored.legacyDownloadMultiSegment, isFalse);

    // Real ConfigBackupData version gate: version > 1 is rejected.
    await expectLater(
      _OldImporterReplica.restore(
        appsJson: apps,
        appConfigJson: <String, dynamic>{...configBundle, 'version': 2},
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('agent backup-export tool opts into app config (P1 regression)',
      () async {
    await seedConfig();
    final recorder = _RecordingBackupService();
    ModuleManager.instance.bind<IBackupService>(recorder);

    final result = await AgentService().runTool('backup', {'action': 'export'});

    expect(recorder.exportCalls, 1);
    expect(recorder.includeAppConfigLast, isTrue,
        reason: 'agent export must keep config/models/API keys in the backup');
    expect(result, isA<String>());
  });

  test('malformed config_entry rows: export failure falls back and still backs up',
      () async {
    final client = _FailingExportClient();
    await client.set(
        module: 'network', key: 'proxy_url', valueJson: jsonEncode(_proxy), source: 'user');
    ConfigService.instance.debugSetApi(ConfigRustApi(client));

    final data = await service.exportData(includeAppConfig: true);

    expect(data.appConfig, isNotNull);
    final configs = data.appConfig!['configs'] as Map<String, dynamic>;
    expect(configs[ConfigKeys.proxyUrl], _proxy,
        reason: 'fallback per-key export kept the readable row');
  });
}

/// Minimal old-importer replica (C16): real `ConfigBackupData` parsing + version
/// gate + both archive locations.
class _OldImporterReplica {
  _OldImporterReplica._({
    required this.legacyThemeMode,
    required this.legacyDownloadMultiSegment,
    required this.groupedDownloadMultiSegment,
    required this.proxyUrl,
    required this.webdavPassword,
  });

  final int? legacyThemeMode;
  final bool? legacyDownloadMultiSegment;
  final bool? groupedDownloadMultiSegment;
  final String? proxyUrl;
  final String? webdavPassword;

  static Future<_OldImporterReplica> restore({
    required Map<String, dynamic> appsJson,
    required Map<String, dynamic>? appConfigJson,
  }) async {
    int? legacyThemeMode;
    bool? legacyDownloadMultiSegment;
    bool? groupedDownloadMultiSegment;

    if (appConfigJson != null) {
      // The old importer parses the real ConfigBackupData shape, then applies
      // the old importer's `version > 1` compatibility gate.
      final backup = ConfigBackupData.fromJson(appConfigJson);
      if (backup.version > 1) {
        throw StateError('old importer rejects config version > 1');
      }
      final configs = backup.configs;
      // The old importer reads legacy keys (theme + aggregate download).
      legacyThemeMode = configs[LegacyConfigKeys.themeMode] as int?;
      final legacyDownload = configs[LegacyConfigKeys.downloadConfig] as Map?;
      legacyDownloadMultiSegment =
          legacyDownload?['multiSegmentEnabled'] as bool?;
      // New grouped keys are restored as-is (ConfigService.set on a real app).
      groupedDownloadMultiSegment =
          configs[ConfigKeys.downloadMultiSegmentEnabled] as bool?;
      for (final key in ConfigKeys.all) {
        final value = configs[key];
        if (value != null) {
          await ConfigService.instance.set(key, value);
        }
      }
    }

    final embedded = appsJson['appConfig'] as Map<String, dynamic>?;
    final webdav = embedded?['webdav_config'] as Map?;
    return _OldImporterReplica._(
      legacyThemeMode: legacyThemeMode,
      legacyDownloadMultiSegment: legacyDownloadMultiSegment,
      groupedDownloadMultiSegment: groupedDownloadMultiSegment,
      proxyUrl: embedded?['proxy_url'] as String?,
      webdavPassword: webdav?['password'] as String?,
    );
  }
}

/// Records the includeAppConfig flag the agent backup tool passes through.
class _RecordingBackupService implements IBackupService {
  int exportCalls = 0;
  bool? includeAppConfigLast;

  @override
  Future<Uint8List> exportCompressedBackup({
    BackupOptions? options,
    List<ChannelType>? channels,
    bool includeAppConfig = false,
    BackupLogCallback? onLog,
  }) async {
    exportCalls++;
    includeAppConfigLast = includeAppConfig;
    return Uint8List.fromList(<int>[1, 2, 3]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

/// Simulates a Rust `ConfigApi.export` failure caused by a stale unregistered
/// `config_entry` row, while per-key reads still work.
class _FailingExportClient extends GroupedConfigApiClient
    implements ConfigExportApiClient {
  @override
  Future<generated.ConfigExportDto> export() async {
    throw StateError('config entry row has no registry key');
  }
}
