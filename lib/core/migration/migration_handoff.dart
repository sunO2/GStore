/// Ordered Dart→Rust migration handoff.
///
/// Exports versioned, atomic `0600` documents, runs the Rust path migration,
/// imports each document, and only deletes a document after its own import
/// succeeded. Files are retained on failure so a retry resumes instead of
/// losing data.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/migration/cutover_paths.dart';

/// Result of one [MigrationHandoff.start] run.
class MigrationResult {
  const MigrationResult({
    required this.channelEnvImported,
    required this.updatePrefsImported,
  });

  final bool channelEnvImported;
  final bool updatePrefsImported;
}

/// One JS channel's environment variables to export during the Todo 12
/// channel-data handoff.
class ChannelEnvExport {
  const ChannelEnvExport({required this.channelKey, required this.env});

  final String channelKey;
  final Map<String, String> env;
}

/// Observable result of [MigrationHandoff.startChannelMigration].
///
/// The `*Exported`/`*Copied`/`backupsCreated` counters are deliberately
/// explicit so a retry can prove it reused retained artifacts instead of
/// rewriting them.
class ChannelMigrationResult {
  const ChannelMigrationResult({
    required this.channelDbImported,
    required this.envImported,
    required this.fdroidImported,
    required this.packsImported,
    required this.envExported,
    required this.fdroidExported,
    required this.packsCopied,
    required this.backupsCreated,
  });

  final bool channelDbImported;
  final int envImported;
  final bool fdroidImported;
  final int packsImported;
  final int envExported;
  final int fdroidExported;
  final int packsCopied;
  final int backupsCreated;
}

/// Static-only ordered migration handoff.
///
/// Wave 2 keeps the entry point caller-injected: the production bootstrap does
/// not call [start] yet, and every core flag (including `coreWrites`) stays
/// false, so the legacy Dart writers remain authoritative. Wiring the handoff
/// into startup is a later plan todo.
class MigrationHandoff {
  MigrationHandoff._();

  /// Version written into every exported document; Rust requires `1`.
  static const int documentVersion = 1;

  static const String channelEnvFileName = 'channel_env.json';
  static const String updatePrefsFileName = 'update_prefs.json';

  /// Keys owned by `UpdateCache` (kept in sync there).
  static const List<String> _updatePrefKeys = <String>[
    'update_last_checked_at',
    'update_results_v1',
    'update_check_logs_v1',
    'update_preferred_apk',
  ];

  /// `<files>/migration`, created if missing.
  ///
  /// `files` is the core files dir (`<support>/gstore_core/files`), the same
  /// root the cutover reads. Deriving it from [CutoverPaths] is what keeps the
  /// exporter and the cutover from drifting onto different directories.
  static Future<Directory> migrationDir() async {
    final dirs = await CutoverPaths.defaultCoreDirs();
    final dir = Directory(CutoverPaths.migrationDirAt(dirs.$2));
    await dir.create(recursive: true);
    return dir;
  }

  /// Export one channel's env document.
  static Future<File> exportChannelEnv({
    required String channelKey,
    required Map<String, String> env,
    Directory? into,
  }) async {
    final dir = into ?? await migrationDir();
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}$channelEnvFileName',
    );
    final document = <String, Object?>{
      'version': documentVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'channel_key': channelKey,
      'env': env,
    };
    await _writeAtomic(file, document);
    return file;
  }

  /// Export update preferences.
  ///
  /// When [prefs] is null the four `UpdateCache` keys are read from
  /// SharedPreferences. All values are normalized to strings because the Rust
  /// `update_prefs` table stores text.
  static Future<File> exportUpdatePrefs({
    Map<String, Object?>? prefs,
    Directory? into,
  }) async {
    final dir = into ?? await migrationDir();
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}$updatePrefsFileName',
    );

    final source = prefs ?? await _readUpdatePrefs();
    final normalized = <String, String>{};
    for (final entry in source.entries) {
      final value = entry.value;
      if (value == null) continue;
      normalized[entry.key] = value is String ? value : value.toString();
    }

    final document = <String, Object?>{
      'version': documentVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'prefs': normalized,
    };
    await _writeAtomic(file, document);
    return file;
  }

  /// Run the ordered handoff.
  ///
  /// Strict order:
  /// 1. ensure `channel_env.json` + `update_prefs.json` exist (existing files
  ///    are reused verbatim — this is what makes a retry resume),
  /// 2. `migratePaths()`,
  /// 3. import `channel_env`,
  /// 4. import `update_prefs`,
  /// 5. delete each file only after its own import succeeded.
  ///
  /// On any failure the files are kept and the error is rethrown.
  ///
  /// [channelKey]/[env] are optional only so the documented five-argument call
  /// shape still works; they are used to export a missing `channel_env.json`.
  /// A missing channel document without them is an error.
  static Future<MigrationResult> start({
    required Future<void> Function() migratePaths,
    required Future<int> Function(String kind, String path) importDocument,
    Directory? into,
    bool deleteAfterImport = true,
    String? channelKey,
    Map<String, String>? env,
  }) async {
    final dir = into ?? await migrationDir();
    await dir.create(recursive: true);

    final channelFile = File(
      '${dir.path}${Platform.pathSeparator}$channelEnvFileName',
    );
    final prefsFile = File(
      '${dir.path}${Platform.pathSeparator}$updatePrefsFileName',
    );

    // 1. Ensure both documents exist; never overwrite a retained document.
    if (!await channelFile.exists()) {
      if (channelKey == null || env == null) {
        throw StateError(
          'channel_env.json is missing and channelKey/env were not provided',
        );
      }
      await exportChannelEnv(channelKey: channelKey, env: env, into: dir);
    }
    if (!await prefsFile.exists()) {
      await exportUpdatePrefs(into: dir);
    }

    // 2. Rust owns paths/markers before any document import.
    await migratePaths();

    // 3. channel_env import.
    await importDocument('channel_env', channelFile.path);
    if (deleteAfterImport && await channelFile.exists()) {
      await channelFile.delete();
    }

    // 4. update_prefs import.
    await importDocument('update_prefs', prefsFile.path);
    if (deleteAfterImport && await prefsFile.exists()) {
      await prefsFile.delete();
    }

    return const MigrationResult(
      channelEnvImported: true,
      updatePrefsImported: true,
    );
  }

  static const String channelDbFileName = 'channel_apps.db';
  static const String fdroidSourcesFileName = 'fdroid_sources.json';
  static const String channelEnvPrefix = 'channel_env.';
  static const String channelEnvSuffix = '.json';

  /// Ordered Todo 12 channel-data handoff.
  ///
  /// Strict order:
  /// 1. export one `channel_env.<sanitized-key>.json` per JS channel, the
  ///    `fdroid_sources.json` document, and copies of local `channels/*.zip`
  ///    packs (all `0600`/fsynced; a retained file is reused verbatim),
  /// 2. copy the legacy `channel_apps.db` to `migration/backups/`,
  /// 3. `migratePaths()`,
  /// 4. import `channel_db`,
  /// 5. import every `channel_env` document,
  /// 6. import `fdroid_sources`,
  /// 7. import every copied pack,
  /// 8. delete each managed file only after its own import succeeded.
  ///
  /// The legacy DB and the original `channels/*.zip` sources are never moved
  /// or deleted. On any failure the failed and not-yet-imported files remain,
  /// so a retry resumes without re-exporting retained documents.
  ///
  /// [importDocument] is the only bridge to native code in this path; tests
  /// inject it together with [migratePaths] and never load the Rust library.
  static Future<ChannelMigrationResult> startChannelMigration({
    required Future<void> Function() migratePaths,
    required Future<int> Function(String kind, String path) importDocument,
    Directory? into,
    String? channelDatabasePath,
    List<ChannelEnvExport> channelEnvs = const <ChannelEnvExport>[],
    Map<String, Object?>? fdroidDocument,
    Directory? packsSourceDir,
    String? proxyUrl,
    String? githubToken,
    bool deleteAfterImport = true,
    void Function(String path)? onExport,
  }) async {
    final dir = into ?? await migrationDir();
    await dir.create(recursive: true);
    Directory? cachedDocuments;
    Future<Directory> documentsDir() async =>
        cachedDocuments ??= await getApplicationDocumentsDirectory();
    final dbPath = channelDatabasePath ??
        CutoverPaths.channelDbAt((await documentsDir()).path);

    var envExported = 0;
    var fdroidExported = 0;
    var packsCopied = 0;
    var backupsCreated = 0;

    // 1. Export env documents. A file that survived a failed run is reused.
    for (final channel in channelEnvs) {
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        '$channelEnvPrefix${_sanitizeKey(channel.channelKey)}$channelEnvSuffix',
      );
      if (await file.exists()) continue;
      await _writeAtomic(file, <String, Object?>{
        'version': documentVersion,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'channel_key': channel.channelKey,
        'env': channel.env,
      });
      envExported++;
      onExport?.call(file.path);
    }

    // 2. Export F-Droid sources + last_source_id (and optional global config).
    final fdroidFile = File(
      '${dir.path}${Platform.pathSeparator}$fdroidSourcesFileName',
    );
    if (!await fdroidFile.exists()) {
      final document = await _fdroidDocument(
        fdroidDocument,
        proxyUrl: proxyUrl,
        githubToken: githubToken,
      );
      await _writeAtomic(fdroidFile, document);
      fdroidExported++;
      onExport?.call(fdroidFile.path);
    }

    // 3. Copy local packs into the migration workspace (COPY, never move).
    final packDir = Directory('${dir.path}${Platform.pathSeparator}packs');
    await packDir.create(recursive: true);
    final sourcePacks = packsSourceDir ??
        Directory(CutoverPaths.packsDirAt((await documentsDir()).path));
    if (await sourcePacks.exists()) {
      final zips = await sourcePacks
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.zip'))
          .cast<File>()
          .toList();
      zips.sort((a, b) => a.path.compareTo(b.path));
      for (final source in zips) {
        final name = source.uri.pathSegments.last;
        final target = File('${packDir.path}${Platform.pathSeparator}$name');
        if (await target.exists()) continue;
        await _copyAtomic(source, target);
        packsCopied++;
        onExport?.call(target.path);
      }
    }

    // 4. Backup the legacy DB before any import touches it.
    final legacyDb = File(dbPath);
    if (await legacyDb.exists()) {
      backupsCreated = await _backupOnce(legacyDb, dir, onExport);
    }

    // 5. Rust owns paths/markers before any artifact import.
    await migratePaths();

    // 6. Legacy channel DB (source is retained; Rust writes its own backup).
    var channelDbImported = false;
    if (await legacyDb.exists()) {
      await importDocument('channel_db', legacyDb.path);
      channelDbImported = true;
    }

    // 7. Every exported/retained env document, in deterministic key order.
    var envImported = 0;
    final envFiles = await _migrationFiles(
      dir,
      prefix: channelEnvPrefix,
      suffix: channelEnvSuffix,
    );
    for (final file in envFiles) {
      await importDocument('channel_env', file.path);
      envImported++;
      if (deleteAfterImport && await file.exists()) {
        await file.delete();
      }
    }

    // 8. F-Droid sources.
    var fdroidImported = false;
    if (await fdroidFile.exists()) {
      await importDocument('fdroid_sources', fdroidFile.path);
      fdroidImported = true;
      if (deleteAfterImport && await fdroidFile.exists()) {
        await fdroidFile.delete();
      }
    }

    // 9. Every copied pack, in deterministic file-name order.
    var packsImported = 0;
    final packFiles = await _migrationFiles(packDir, suffix: '.zip');
    for (final file in packFiles) {
      await importDocument('pack', file.path);
      packsImported++;
      if (deleteAfterImport && await file.exists()) {
        await file.delete();
      }
    }

    return ChannelMigrationResult(
      channelDbImported: channelDbImported,
      envImported: envImported,
      fdroidImported: fdroidImported,
      packsImported: packsImported,
      envExported: envExported,
      fdroidExported: fdroidExported,
      packsCopied: packsCopied,
      backupsCreated: backupsCreated,
    );
  }

  static String _sanitizeKey(String key) {
    final sanitized = key.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    return sanitized.isEmpty ? '_' : sanitized;
  }

  static Future<List<File>> _migrationFiles(
    Directory dir, {
    String prefix = '',
    required String suffix,
  }) async {
    if (!await dir.exists()) return const <File>[];
    final files = await dir
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .where((file) {
      final name = file.uri.pathSegments.last;
      return name.startsWith(prefix) && name.endsWith(suffix);
    }).toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  static Future<Map<String, Object?>> _fdroidDocument(
    Map<String, Object?>? supplied, {
    String? proxyUrl,
    String? githubToken,
  }) async {
    Map<String, Object?> source;
    if (supplied != null) {
      source = supplied;
    } else {
      final prefs = await SharedPreferences.getInstance();
      var sources = <Object?>[];
      final raw = prefs.get('fdroid_sources');
      if (raw is List) {
        sources = raw.cast<Object?>();
      } else if (raw is String && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) sources = decoded.cast<Object?>();
        } catch (_) {
          // Corrupt legacy value: export an empty list instead of invalid JSON.
        }
      }
      source = <String, Object?>{
        'sources': sources,
        'last_source_id': prefs.get('last_source_id'),
      };
    }
    return <String, Object?>{
      'version': documentVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'sources': source['sources'] ?? const <Object?>[],
      'last_source_id': source['last_source_id'],
      if (proxyUrl != null && proxyUrl.isNotEmpty) 'proxy_url': proxyUrl,
      if (githubToken != null && githubToken.isNotEmpty)
        'github_token': githubToken,
    };
  }

  /// Copies [source] into `migration/backups/` once. Returns 1 when a new
  /// backup was written, 0 when one already exists (retry path).
  static Future<int> _backupOnce(
    File source,
    Directory dir,
    void Function(String path)? onExport,
  ) async {
    final backupDir = Directory('${dir.path}${Platform.pathSeparator}backups');
    await backupDir.create(recursive: true);
    final name = source.uri.pathSegments.last;
    final existing = await backupDir
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .where((file) {
      final candidate = file.uri.pathSegments.last;
      return candidate.startsWith('$name.') && candidate.endsWith('.bak');
    }).toList();
    if (existing.isNotEmpty) return 0;
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final backup = File(
      '${backupDir.path}${Platform.pathSeparator}$name.$stamp.bak',
    );
    await _copyAtomic(source, backup);
    if (!Platform.isWindows) await _chmod600(backup);
    onExport?.call(backup.path);
    return 1;
  }

  /// Copies bytes to `<dest>.tmp`, fsyncs, then renames into place.
  static Future<void> _copyAtomic(File source, File dest) async {
    await dest.parent.create(recursive: true);
    final tmp = File('${dest.path}.tmp');
    final input = source.openRead();
    final output = tmp.openSync(mode: FileMode.write);
    try {
      await for (final chunk in input) {
        output.writeFromSync(chunk);
      }
      output.flushSync();
    } finally {
      output.closeSync();
    }
    try {
      await tmp.rename(dest.path);
    } on FileSystemException {
      if (await dest.exists()) await dest.delete();
      await tmp.rename(dest.path);
    }
  }

  static Future<Map<String, Object?>> _readUpdatePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, Object?>{};
    for (final key in _updatePrefKeys) {
      final value = prefs.get(key);
      if (value != null) out[key] = value;
    }
    return out;
  }

  /// Write `<name>.tmp`, flush, then rename into place.
  static Future<void> _writeAtomic(
    File file,
    Map<String, Object?> document,
  ) async {
    final tmp = File('${file.path}.tmp');
    final handle = tmp.openSync(mode: FileMode.write);
    try {
      handle.writeStringSync(jsonEncode(document));
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // Windows cannot rename onto an existing file.
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    }
    await _chmod600(file);
  }

  /// Best-effort `0600`; failures are non-fatal (and Windows has no chmod).
  static Future<void> _chmod600(File file) async {
    if (Platform.isWindows) return;
    try {
      final result = await Process.run('chmod', <String>['600', file.path]);
      if (result.exitCode != 0) {
        debugPrint(
          'MigrationHandoff: chmod 600 ${file.path} failed '
          '(exit ${result.exitCode})',
        );
      }
    } catch (e) {
      debugPrint('MigrationHandoff: chmod 600 ${file.path} failed: $e');
    }
  }
}
