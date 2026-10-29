/// Production [CoreCutoverBackend] over the real legacy stores and core APIs.
///
/// The cutover used to read `<files>/migration`, a directory nothing writes.
/// This backend reads the stores the shipping Dart app actually wrote, per
/// [CutoverPaths]:
///
/// * `channels`  — `<documents>/channel_apps.db` (`channel_added_app`);
/// * `jsChannel` — `<documents>/channels/*.zip` packs;
/// * `catalog`   — `<documents>/added_apps.db` + `<documents>/gstore/apps.db`;
/// * `update`    — the four `SharedPreferences` keys, exported to
///   `<files>/migration/update_prefs.json` before the import.
///
/// Each step reports how many rows it imported and whether every imported row is
/// present in the core projection. `legacyPresent` distinguishes a real upgrade
/// from a fresh install so an empty import of existing data fails closed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:gstore/core/migration/cutover_parity.dart';
import 'package:gstore/core/migration/cutover_paths.dart';
import 'package:gstore/core/migration/migration_handoff.dart';
import 'package:gstore/core/rust/CoreApiFacade.dart';
import 'package:gstore/core/rust/core_cutover.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:shared_preferences/shared_preferences.dart';

/// The four `UpdateCache` keys migrated by the `update` step.
const List<String> kCutoverUpdatePrefKeys = <String>[
  'update_last_checked_at',
  'update_results_v1',
  'update_check_logs_v1',
  'update_preferred_apk',
];

/// Core transport seam. Production calls the FRB `CoreApi`; tests can inject a
/// fake without loading the native library.
abstract class CutoverCore {
  Future<int> exportSnapshot(String path);

  Future<int> importMigrationFile(String kind, String path);

  Future<String> coreDbPath();
}

/// Production [CutoverCore] over [CoreApiFacade].
class FrbCutoverCore implements CutoverCore {
  FrbCutoverCore({
    required this.dataDir,
    required this.filesDir,
    required this.cacheDir,
  });

  final String dataDir;
  final String filesDir;
  final String cacheDir;

  Future<rust.CoreApi> get _api => CoreApiFacade.init(
        dataDir: dataDir,
        filesDir: filesDir,
        cacheDir: cacheDir,
      );

  @override
  Future<int> exportSnapshot(String path) async =>
      (await (await _api).exportSnapshot(path: path)).toInt();

  @override
  Future<int> importMigrationFile(String kind, String path) async =>
      (await _api).importMigrationFile(kind: kind, path: path);

  @override
  Future<String> coreDbPath() async =>
      (await (await _api).migratePaths()).dbPath;
}

/// Production backend over the real legacy paths.
class FrbCoreCutoverBackend
    implements CoreCutoverBackend, ChannelBackfillProbe {
  FrbCoreCutoverBackend({
    required this.paths,
    required this.dataDir,
    required this.cacheDir,
    CutoverCore? core,
    CutoverParity parity = const CutoverParity(),
    Future<SharedPreferences> Function()? preferences,
  })  : _core = core ??
            FrbCutoverCore(
              dataDir: dataDir,
              filesDir: paths.filesDir,
              cacheDir: cacheDir,
            ),
        _parity = parity,
        _preferences = preferences ?? SharedPreferences.getInstance;

  final CutoverPaths paths;
  final String dataDir;
  final String cacheDir;
  final CutoverCore _core;
  final CutoverParity _parity;
  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<int> exportSnapshot({required String path}) =>
      _core.exportSnapshot(path);

  @override
  Future<CutoverStepResult> resyncChannels() async {
    final source = paths.legacyChannelDb;
    final count = await _count(source, 'channel_added_app');
    final legacyPresent = count == null || count > 0;

    var imported = 0;
    if (File(source).existsSync()) {
      imported += await _core.importMigrationFile('channel_db', source);
    }

    final coreDb = await _core.coreDbPath();
    final rows =
        await _parity.count(coreDb, 'SELECT COUNT(*) FROM channel_apps');
    final parityOk =
        legacyPresent ? await _parity.channels(source, coreDb) : true;
    return CutoverStepResult(
      rows: rows,
      parityOk: parityOk,
      imported: imported,
      legacyPresent: legacyPresent,
    );
  }

  /// A repair is needed when the legacy `<documents>/channel_apps.db` still has
  /// `channel_added_app` rows that the core `channel_apps` projection is
  /// missing — the fingerprint of the "add to home wrote only added_apps" bug.
  ///
  /// Once every legacy enum-channel row is projected this returns `false`, so
  /// the marker-present repair runs at most once; `resyncChannels` is idempotent
  /// (upsert), so a partial projection is also repaired safely.
  @override
  Future<bool> channelBackfillNeeded() async {
    final source = paths.legacyChannelDb;
    final legacyCount = await _count(source, 'channel_added_app');
    // Missing file (0) or an unreadable-but-present file (null): nothing a repair
    // could import. Only genuine rows justify a re-run.
    if (legacyCount == null || legacyCount == 0) return false;
    final coreDb = await _core.coreDbPath();
    try {
      return !await _parity.channels(source, coreDb);
    } catch (_) {
      // Core DB/table unreadable: the projection cannot contain the legacy rows,
      // so a one-time (idempotent) repair is warranted.
      return true;
    }
  }

  @override
  Future<CutoverStepResult> resyncJsChannel() async {
    final packs = _legacyPacks();
    final legacyPresent = packs.isNotEmpty;

    var imported = 0;
    for (final zip in packs) {
      imported += await _core.importMigrationFile('pack', zip.path);
    }

    final coreDb = await _core.coreDbPath();
    final rows =
        await _parity.count(coreDb, 'SELECT COUNT(*) FROM channel_packs');
    final parityOk = legacyPresent
        ? await _parity.packs(packs.map((f) => f.path).toList(), coreDb)
        : true;
    return CutoverStepResult(
      rows: rows,
      parityOk: parityOk,
      imported: imported,
      legacyPresent: legacyPresent,
    );
  }

  @override
  Future<CutoverStepResult> resyncCatalog() async {
    final addedApps = paths.legacyAddedAppsDb;
    final catalog = paths.legacyCatalogDb;
    final addedAppsCount = await _count(addedApps, 'added_apps');
    final tagCount = await _count(addedApps, 'added_app_tags');
    final catalogCount = await _count(catalog, 'apps');
    final legacyPresent = addedAppsCount == null ||
        tagCount == null ||
        catalogCount == null ||
        (addedAppsCount + tagCount + catalogCount) > 0;

    var imported = 0;
    if (File(addedApps).existsSync()) {
      imported += await _core.importMigrationFile('added_apps_db', addedApps);
    }
    if (File(catalog).existsSync()) {
      imported += await _core.importMigrationFile('catalog_db', catalog);
    }

    final coreDb = await _core.coreDbPath();
    final rows = await _parity.count(
      coreDb,
      'SELECT (SELECT COUNT(*) FROM added_apps) + '
      '(SELECT COUNT(*) FROM added_app_tags) + '
      '(SELECT COUNT(*) FROM apps)',
    );
    final parityOk = legacyPresent
        ? await _parity.catalog(
            addedAppsPath: addedApps,
            catalogPath: catalog,
            corePath: coreDb,
          )
        : true;
    return CutoverStepResult(
      rows: rows,
      parityOk: parityOk,
      imported: imported,
      legacyPresent: legacyPresent,
    );
  }

  @override
  Future<CutoverStepResult> resyncUpdate() async {
    final prefs = await _preferences();
    final legacyPresent =
        kCutoverUpdatePrefKeys.any((key) => prefs.containsKey(key));

    final document = await MigrationHandoff.exportUpdatePrefs(
      into: Directory(paths.migrationDir),
    );
    final imported =
        await _core.importMigrationFile('update_prefs', document.path);

    final expected = _exportedPrefs(document);
    final coreDb = await _core.coreDbPath();
    final rows =
        await _parity.count(coreDb, 'SELECT COUNT(*) FROM update_prefs');
    final parityOk =
        legacyPresent ? await _parity.updatePrefs(expected, coreDb) : true;
    return CutoverStepResult(
      rows: rows,
      parityOk: parityOk,
      imported: imported,
      legacyPresent: legacyPresent,
    );
  }

  List<File> _legacyPacks() {
    final dir = Directory(paths.legacyPacksDir);
    if (!dir.existsSync()) return const <File>[];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.zip'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// Row count, or `null` when the file exists but cannot be read (a corrupt
  /// source must be treated as "legacy data present" so the import fails).
  Future<int?> _count(String dbPath, String table) async {
    if (!File(dbPath).existsSync()) return 0;
    try {
      return await _parity.count(dbPath, 'SELECT COUNT(*) FROM $table');
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _exportedPrefs(File document) {
    final decoded =
        jsonDecode(document.readAsStringSync()) as Map<String, dynamic>;
    final prefs = decoded['prefs'] as Map<String, dynamic>? ?? const {};
    return <String, String>{
      for (final entry in prefs.entries) entry.key: entry.value.toString(),
    };
  }
}
