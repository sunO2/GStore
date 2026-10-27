/// Row-level parity between the legacy Dart stores and the core projection.
///
/// Parity is deliberately **not** a second read of the same getter: it opens the
/// legacy source and the live core database read-only and compares the imported
/// row identities (and, for update prefs, values). Dropping one imported row
/// makes the corresponding comparison fail, so the durable cutover cannot
/// certify a migration that lost data.
library;

import 'dart:io';

import 'package:sqflite/sqflite.dart';

/// Read-only row comparison over two SQLite databases.
class CutoverParity {
  const CutoverParity();

  /// Number of rows returned by [sql] against [dbPath].
  Future<int> count(String dbPath, String sql) async {
    final rows = await _query(dbPath, sql);
    if (rows.isEmpty) return 0;
    final value = rows.first.values.first;
    return value is num ? value.toInt() : 0;
  }

  /// Every `(channelCode, appId)` legacy row exists in `channel_apps`.
  Future<bool> channels(String legacyPath, String corePath) async {
    final legacy = await _keys(
      legacyPath,
      'SELECT channelCode, appId FROM channel_added_app',
    );
    final core = await _keys(
      corePath,
      'SELECT channel_key, app_id FROM channel_apps',
    );
    return legacy.difference(core).isEmpty;
  }

  /// Every legacy pack stem maps to a `js_<stem>` row in `channel_packs`.
  Future<bool> packs(List<String> zipPaths, String corePath) async {
    final expected = <String>{
      for (final path in zipPaths)
        'js_${path.split(Platform.pathSeparator).last.replaceFirst(RegExp(r'\.zip$'), '')}',
    };
    final core = await _keys(corePath, 'SELECT key FROM channel_packs');
    return expected.difference(core).isEmpty;
  }

  /// Every legacy added app, tag, catalog app, category and config version is
  /// present in the core projection.
  Future<bool> catalog({
    required String addedAppsPath,
    required String catalogPath,
    required String corePath,
  }) async {
    if (File(addedAppsPath).existsSync()) {
      final apps = await _keys(
        addedAppsPath,
        'SELECT channelId, appId FROM added_apps',
      );
      final coreApps = await _keys(
        corePath,
        'SELECT channel_id, app_id FROM added_apps',
      );
      if (apps.difference(coreApps).isNotEmpty) return false;

      final tags = await _keys(
        addedAppsPath,
        'SELECT channelId, appId, tag FROM added_app_tags',
      );
      final coreTags = await _keys(
        corePath,
        'SELECT channel_id, app_id, tag FROM added_app_tags',
      );
      if (tags.difference(coreTags).isNotEmpty) return false;
    }

    if (File(catalogPath).existsSync()) {
      final apps = await _keys(catalogPath, 'SELECT appId FROM apps');
      final coreApps = await _keys(corePath, 'SELECT appId FROM apps');
      if (apps.difference(coreApps).isNotEmpty) return false;

      final categories = await _keys(catalogPath, 'SELECT id FROM category');
      final coreCategories = await _keys(corePath, 'SELECT id FROM categories');
      if (categories.difference(coreCategories).isNotEmpty) return false;

      final configs = await _keys(catalogPath, 'SELECT version FROM config');
      final coreConfigs =
          await _keys(corePath, 'SELECT version FROM app_config');
      if (configs.difference(coreConfigs).isNotEmpty) return false;
    }
    return true;
  }

  /// Every exported legacy prefs key has the same value in `update_prefs`.
  Future<bool> updatePrefs(
    Map<String, String> expected,
    String corePath,
  ) async {
    if (expected.isEmpty) return true;
    final rows = await _query(corePath, 'SELECT key, value FROM update_prefs');
    final core = <String, String>{
      for (final row in rows) row['key']! as String: row['value']! as String,
    };
    for (final entry in expected.entries) {
      if (core[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<Set<String>> _keys(String dbPath, String sql) async {
    final rows = await _query(dbPath, sql);
    return <String>{
      for (final row in rows)
        row.values.map((value) => '$value').join('\u0000'),
    };
  }

  Future<List<Map<String, Object?>>> _query(String dbPath, String sql) async {
    final db = await openReadOnlyDatabase(dbPath);
    try {
      return await db.rawQuery(sql);
    } finally {
      await db.close();
    }
  }
}
