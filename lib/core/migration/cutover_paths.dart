/// Single source of truth for the durable Wave 6 cutover's on-disk layout.
///
/// Both sides of the migration derive their paths from this contract:
///
/// * the **write/read side of the legacy data** is the app documents directory,
///   where the shipping Dart app has always stored it:
///   - `<legacyRoot>/channel_apps.db` — `ChannelDatabase.create()` (Floor v5,
///     table `channel_added_app`);
///   - `<legacyRoot>/added_apps.db` — `AppAddedDatabase.create()` (Floor v5,
///     tables `added_apps` + `added_app_tags`);
///   - `<legacyRoot>/gstore/apps.db` — `DbManager.init()` (the catalog copy);
///   - `<legacyRoot>/channels/*.zip` — `ChannelLoader` local channel packs;
///   - `SharedPreferences` keys `update_*` — `UpdateCache` (exported to
///     `<files>/migration/update_prefs.json` before the import).
/// * the **core-owned artifacts** live under the core files directory:
///   - `<files>/migration/cutover_v6.done` — the one-time marker;
///   - `<files>/migration/backups/pre-closeout-<millis>.db` — the one snapshot;
///   - `<files>/migration/update_prefs.json` — the exported prefs document.
///
/// `CoreBootstrap` resolves this once and hands the same instance to
/// [FrbCoreCutoverBackend], so the cutover can never read a different directory
/// from the one the exporter writes.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Immutable derived paths for one cutover run.
class CutoverPaths {
  const CutoverPaths({required this.legacyRoot, required this.filesDir});

  /// App documents directory (`getApplicationDocumentsDirectory()`): the root
  /// the legacy Dart writers used for every on-disk database and pack.
  final String legacyRoot;

  /// Core files directory (`<support>/gstore_core/files`): the root the Rust
  /// core and the cutover marker/artifacts use.
  final String filesDir;

  /// Directory name of the core migration workspace under [filesDir].
  static const String migrationDirName = 'migration';

  /// Directory name of the pre-closeout snapshot store.
  static const String backupsDirName = 'backups';

  /// One-time cutover marker file name.
  static const String markerFileName = 'cutover_v6.done';

  /// Pre-closeout snapshot prefix/suffix.
  static const String snapshotPrefix = 'pre-closeout-';
  static const String snapshotSuffix = '.db';

  // ---- Legacy (Dart-owned) sources ----------------------------------------

  static String channelDbAt(String legacyRoot) =>
      p.join(legacyRoot, 'channel_apps.db');

  static String addedAppsDbAt(String legacyRoot) =>
      p.join(legacyRoot, 'added_apps.db');

  static String catalogDbAt(String legacyRoot) =>
      p.join(legacyRoot, 'gstore', 'apps.db');

  static String packsDirAt(String legacyRoot) => p.join(legacyRoot, 'channels');

  String get legacyChannelDb => channelDbAt(legacyRoot);

  String get legacyAddedAppsDb => addedAppsDbAt(legacyRoot);

  String get legacyCatalogDb => catalogDbAt(legacyRoot);

  String get legacyPacksDir => packsDirAt(legacyRoot);

  // ---- Core-owned artifacts ------------------------------------------------

  static String migrationDirAt(String filesDir) =>
      p.join(filesDir, migrationDirName);

  String get migrationDir => migrationDirAt(filesDir);

  String get backupsDir => p.join(migrationDir, backupsDirName);

  String get markerPath => p.join(migrationDir, markerFileName);

  String get updatePrefsDocument => p.join(migrationDir, 'update_prefs.json');

  /// Resolves the contract from the two platform roots.
  ///
  /// [dirs] is the `(data, files, cache)` triple the bootstrap already
  /// resolved; [legacyRoot] lets a test (or a future platform host) inject the
  /// documents directory without touching `path_provider`.
  static Future<CutoverPaths> resolve({
    (String, String, String)? dirs,
    String? legacyRoot,
  }) async {
    final resolvedDirs = dirs ?? await defaultCoreDirs();
    final resolvedLegacy = legacyRoot ?? await _defaultLegacyRoot();
    return CutoverPaths(
      legacyRoot: resolvedLegacy,
      filesDir: resolvedDirs.$2,
    );
  }

  /// The default `(data, files, cache)` triple under the app support dir.
  static Future<(String, String, String)> defaultCoreDirs() async {
    final support = await getApplicationSupportDirectory();
    final root = '${support.path}/gstore_core';
    return ('$root/data', '$root/files', '$root/cache');
  }

  /// The legacy documents root on its own (used by exporters that do not need
  /// the core directories).
  static Future<String> resolveLegacyRoot() => _defaultLegacyRoot();

  static Future<String> _defaultLegacyRoot() async {
    final documents = await getApplicationDocumentsDirectory();
    return documents.path;
  }

  @override
  String toString() => 'CutoverPaths(legacyRoot: $legacyRoot, '
      'filesDir: $filesDir)';
}

/// Whether [path] exists and is a regular file.
bool cutoverFileExists(String path) =>
    FileSystemEntity.typeSync(path) == FileSystemEntityType.file;
