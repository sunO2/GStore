import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Debug-only core smoke bootstrap (F3 device QA).
///
/// Creates the real core directory shape, seeds one channel + app + local pack
/// + env value through the Rust `ChannelApi`, and logs exactly what it wrote.
/// It never touches `CoreFlags`, never changes a default, and is entirely
/// compiled out of normal startup because [enabled] is false unless the build
/// passes `--dart-define=GSTORE_CORE_SMOKE=true` (and `kDebugMode` holds).
///
/// ## Idempotency (stale_state)
///
/// Every step is an upsert:
/// * `register` re-registers the same record (registry row update / no-op);
/// * `addApp` upserts one `(channel_key, app_id)` row;
/// * the pack builder is deterministic, so re-importing the same bytes yields
///   the same SHA-256, reuses the version dir, and upserts one `channel_packs`
///   row;
/// * `envSet` upserts one `channel_env` row.
///
/// Running [run] twice therefore leaves no duplicate rows and no extra pack
/// version directories.
class CoreSmoke {
  CoreSmoke._();

  /// Channel that owns the smoke app (`kind: github`, the plan's fixture).
  static const String channelKey = 'smoke_github';

  /// Fixture app id.
  static const String appId = 'smoke/app';

  /// Local pack channel key and env key.
  static const String packKey = 'js_smoke';

  /// Pack env var written by the smoke.
  static const String packEnvName = 'SMOKE';

  /// Pack env value written by the smoke.
  static const String packEnvValue = '1';

  /// Flat-pack file name.
  ///
  /// The Rust importer derives the legacy key from the file stem: the imported
  /// key is `js_<stem>` (`legacy_key_from_path` in `pack_loader.rs`). The stem
  /// therefore **must** be `smoke` for the pack key to be [packKey].
  static const String packFileName = 'smoke.zip';

  /// True only for a debug build built with `GSTORE_CORE_SMOKE=true`.
  static bool get enabled =>
      kDebugMode && const bool.fromEnvironment('GSTORE_CORE_SMOKE');

  /// Non-empty discovery script for the flat pack.
  static const String entryJs = '''
// GStore core smoke pack — debug-only fixture (no network, no secrets).
function main(method, params) {
  if (method === 'getAllApps') return { ok: true, data: [] };
  return { ok: false, error: 'unsupported' };
}
''';

  /// `meta.json` matching the Rust pack validator (JSON object, string
  /// `requiredEnvVars` entries). `key` documents the legacy identity; the Rust
  /// importer still derives the real key from [packFileName].
  static const String metaJson = '{"key":"js_smoke","name":"Smoke Pack",'
      '"entry":"entry.js","version":"1.0.0",'
      '"description":"debug-only smoke fixture",'
      '"requiredEnvVars":["SMOKE"]}';

  /// Builds the flat smoke pack zip (pure: no IO, no globals, no clock).
  ///
  /// Layout is exactly `entry.js` + `meta.json` at the archive root — anything
  /// else is rejected by the Rust pack loader. A fixed `modified` timestamp
  /// keeps the bytes deterministic so re-importing is an idempotent upsert.
  static List<int> buildSmokePackZip() {
    final archive = Archive();
    final entryBytes = utf8.encode(entryJs);
    archive.addFile(ArchiveFile('entry.js', entryBytes.length, entryBytes));
    final metaBytes = utf8.encode(metaJson);
    archive.addFile(ArchiveFile('meta.json', metaBytes.length, metaBytes));
    final zip = ZipEncoder().encode(archive, modified: DateTime.utc(2020, 1, 1));
    if (zip == null) {
      throw StateError('CoreSmoke: ZipEncoder returned no bytes');
    }
    return zip;
  }

  /// Resolves/creates `<applicationSupport>/gstore_core/{data,files,cache}`.
  static Future<(String, String, String)> resolveDirs() async {
    final support = await getApplicationSupportDirectory();
    final root = '${support.path}/gstore_core';
    final dataDir = Directory('$root/data');
    final filesDir = Directory('$root/files');
    final cacheDir = Directory('$root/cache');
    for (final dir in <Directory>[dataDir, filesDir, cacheDir]) {
      await dir.create(recursive: true);
    }
    return (dataDir.path, filesDir.path, cacheDir.path);
  }

  /// Seeds the smoke fixtures. No-op unless [enabled].
  static Future<void> run() async {
    if (!enabled) return;
    final sw = Stopwatch()..start();

    final (dataDir, filesDir, cacheDir) = await resolveDirs();
    appLog.info('CoreSmoke: dirs ready', data: {
      'dataDir': dataDir,
      'filesDir': filesDir,
      'cacheDir': cacheDir,
    });

    await RustBridge.ensureInitialized();
    final api = await rust.ChannelApi.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );

    // 1) GitHub channel that owns the smoke app.
    const registration = rust.ChannelRegistration(
      key: channelKey,
      kind: 'github',
      name: 'Smoke GitHub',
      description: 'Debug smoke channel (GSTORE_CORE_SMOKE) for F3 QA.',
      enabled: true,
      priority: 1,
      supportOffline: false,
    );
    final entry = await api.register(registration: registration);
    appLog.info('CoreSmoke: channel registered', data: {
      'key': entry.key,
      'kind': entry.kind,
      'name': entry.name,
      'description': entry.description,
      'enabled': entry.enabled,
      'priority': entry.priority,
      'supportOffline': entry.supportOffline,
      'version': entry.version,
    });

    // 2) One app row under that channel.
    const app = rust.ChannelAppInfo(
      appId: appId,
      packageName: 'com.suno2.smoke',
      name: 'Smoke App',
      user: 'smoke',
      repositories: 'smoke',
      icon: '',
      des: 'smoke fixture',
      category: <String>['Tools'],
    );
    await api.addApp(key: channelKey, app: app);
    appLog.info('CoreSmoke: app added', data: {
      'key': channelKey,
      'appId': app.appId,
      'packageName': app.packageName,
      'name': app.name,
      'user': app.user,
      'repositories': app.repositories,
      'icon': app.icon,
      'des': app.des,
      'category': app.category,
    });

    // 3) Register the pack's own channel key. `envSet`/`envGet` require a
    //    registered channel (`require_channel`), and `channel_env` is keyed by
    //    it; `js_local` has no driver so nothing is bound or executed.
    const packChannel = rust.ChannelRegistration(
      key: packKey,
      kind: 'js_local',
      name: 'Smoke JS Pack',
      description: 'Debug smoke local JS pack (GSTORE_CORE_SMOKE).',
      enabled: false,
      priority: 0,
      supportOffline: true,
    );
    final packEntry = await api.register(registration: packChannel);
    appLog.info('CoreSmoke: pack channel registered', data: {
      'key': packEntry.key,
      'kind': packEntry.kind,
      'enabled': packEntry.enabled,
    });

    // 4) Build + import the flat pack. Deterministic bytes -> same hash ->
    //    one `channel_packs` row and one version dir on repeat runs.
    final packBytes = buildSmokePackZip();
    final packFile = File('$cacheDir/$packFileName');
    await packFile.writeAsBytes(packBytes, flush: true);
    appLog.info('CoreSmoke: smoke pack written', data: {
      'path': packFile.path,
      'bytes': packBytes.length,
      'entries': _packEntrySizes(packBytes),
    });

    final packInfo = await api.importPack(path: packFile.path);
    if (packInfo.key != packKey) {
      throw StateError(
        'CoreSmoke: imported pack key ${packInfo.key} != $packKey '
        '(legacy key is js_<zip stem>; expected file $packFileName)',
      );
    }
    appLog.info('CoreSmoke: pack imported', data: {
      'key': packInfo.key,
      'packHash': packInfo.packHash,
      'installedAt': packInfo.installedAt,
      'dir': packInfo.dir,
    });

    // 5) Env value required by the pack meta.
    await api.envSet(
      key: packKey,
      name: packEnvName,
      value: packEnvValue,
    );
    final readBack = await api.envGet(key: packKey, name: packEnvName);
    if (readBack != packEnvValue) {
      throw StateError(
        'CoreSmoke: env $packKey/$packEnvName read back as $readBack '
        '(expected $packEnvValue)',
      );
    }
    appLog.info('CoreSmoke: env set', data: {
      'key': packKey,
      'name': packEnvName,
      'value': readBack,
    });

    sw.stop();
    appLog.info('CoreSmoke: complete', data: {
      'elapsedMs': sw.elapsedMilliseconds,
      'channel': channelKey,
      'appId': appId,
      'pack': packKey,
    });
  }

  /// Entry name -> uncompressed bytes, for honest progress logging.
  static Map<String, int> _packEntrySizes(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    return <String, int>{
      for (final file in archive.files)
        file.name: (file.content as List<int>).length,
    };
  }
}
