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

/// Result of one [MigrationHandoff.start] run.
class MigrationResult {
  const MigrationResult({
    required this.channelEnvImported,
    required this.updatePrefsImported,
  });

  final bool channelEnvImported;
  final bool updatePrefsImported;
}

/// Static-only ordered migration handoff.
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

  /// `<applicationSupport>/migration`, created if missing.
  static Future<Directory> migrationDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(
      '${support.path}${Platform.pathSeparator}migration',
    );
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
    await tmp.writeAsString(jsonEncode(document), flush: true);
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
