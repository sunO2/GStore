/// One-time cleanup of the data polluted by the `local_db` → `gstore` bug.
///
/// The original migration accidentally enumerated the WHOLE local catalog
/// (`LocalDbDriver.get_all_apps` = `SELECT * FROM apps`) and added every row to
/// the `gstore` channel / home page. The migration itself is fixed
/// ([LocalDbGStoreMigration] now only moves existing `added_apps('local_db')`
/// membership rows), but devices that already ran the broken pass still carry
/// the bogus membership rows.
///
/// This cleanup computes the authoritative *legit* set from the pre-migration
/// database backup the Rust core writes before a schema upgrade
/// (`<data_dir>/gstore_core.db.bak-v4-<nanos>`, see `db.rs` `unique_backup_path`)
/// and removes only `gstore` membership entries that are NOT in that set.
///
/// * **one-time** — `localdb_gstore_cleanup_v1.done` SharedPreferences marker;
/// * **confirm-first** — a dangerous confirm sheet lists the count; cancel
///   writes the marker (never re-ask) and removes nothing;
/// * **non-fatal** — per-app failures are counted, never thrown; `local_db` and
///   the catalog are never touched.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/migration/cutover_paths.dart';

/// Progress callback: `done` of `total` apps handled.
typedef LocalDbCleanupProgress = void Function(int done, int total);

/// Outcome of one [LocalDbGStoreCleanup.run] pass.
class CleanupReport {
  const CleanupReport({
    this.removed = 0,
    this.kept = 0,
    this.failed = 0,
    this.alreadyDone = false,
    this.cancelled = false,
  });

  /// Membership rows deleted from `gstore`.
  final int removed;

  /// Legit `gstore` membership rows preserved.
  final int kept;

  /// Apps whose removal raised; the marker is still written after the pass.
  final int failed;

  /// `true` when the cleanup marker was already present.
  final bool alreadyDone;

  /// `true` when the user dismissed the confirm sheet.
  final bool cancelled;

  @override
  String toString() => 'CleanupReport(removed: $removed, kept: $kept, '
      'failed: $failed, alreadyDone: $alreadyDone, cancelled: $cancelled)';
}

/// Injectable seam: resolves the pre-migration legit set from a DB backup.
abstract class LocalDbGStoreLegitSetReader {
  Future<Set<String>> readLegitAppIds({required String dataDir});
}

/// Production reader over the newest `gstore_core.db.bak-v4-*` snapshot.
class SqfliteBackupLegitSetReader implements LocalDbGStoreLegitSetReader {
  const SqfliteBackupLegitSetReader();

  /// Prefix `unique_backup_path` gives the pre-v5 snapshot.
  static const String backupPrefix = 'gstore_core.db.bak-v4-';

  static final RegExp _backupPattern =
      RegExp(r'^gstore_core\.db\.bak-v4-(\d+)(?:-(\d+))?$');

  @override
  Future<Set<String>> readLegitAppIds({required String dataDir}) async {
    try {
      final backup = await _newestBackup(dataDir);
      if (backup == null) {
        debugPrint('LocalDbGStoreCleanup: 未找到迁移前备份，合法集为空');
        return const <String>{};
      }
      return await _readAppIds(backup);
    } catch (error) {
      debugPrint('LocalDbGStoreCleanup: 读取备份合法集失败: $error');
      return const <String>{};
    }
  }

  Future<String?> _newestBackup(String dataDir) async {
    final dir = Directory(dataDir);
    if (!await dir.exists()) return null;

    String? best;
    (int, int)? bestKey;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final match = _backupPattern.firstMatch(name);
      if (match == null) continue;
      final key = (
        int.tryParse(match.group(1)!) ?? 0,
        int.tryParse(match.group(2) ?? '') ?? 0,
      );
      if (bestKey == null ||
          key.$1 > bestKey.$1 ||
          (key.$1 == bestKey.$1 && key.$2 > bestKey.$2)) {
        bestKey = key;
        best = entity.path;
      }
    }
    return best;
  }

  Future<Set<String>> _readAppIds(String path) async {
    final db = await openDatabase(path, readOnly: true);
    try {
      final rows = await db.query(
        'added_apps',
        columns: const <String>['app_id'],
        where: 'channel_id = ?',
        whereArgs: const <Object>['local_db'],
      );
      return <String>{
        for (final row in rows)
          if (row['app_id'] case final String appId) appId,
      };
    } finally {
      await db.close();
    }
  }
}

/// Injectable seam: the confirm + progress UI the cleanup drives.
abstract class LocalDbGStoreCleanupUi {
  Future<bool> confirmRemove(int count);

  void beginProgress(int total);

  void updateProgress(int done);

  void endProgress();
}

/// Production UI: unified confirm sheet + determinate progress dialog.
class AppDialogsCleanupUi implements LocalDbGStoreCleanupUi {
  final ValueNotifier<({int done, int total, String message})> _progress =
      ValueNotifier<({int done, int total, String message})>(
    (done: 0, total: 0, message: '正在清理错误的 GStore 数据…'),
  );

  @override
  Future<bool> confirmRemove(int count) async {
    final result = await AppDialogs.showConfirmSheet(
      title: '清理 GStore 数据',
      message: '检测到 $count 个应用被错误加入 GStore（本地库迁移缺陷），是否移除？',
      confirmText: '移除',
      isDangerous: true,
    );
    return result == true;
  }

  @override
  void beginProgress(int total) {
    _progress.value = (
      done: 0,
      total: total,
      message: '正在清理错误的 GStore 数据…',
    );
    AppDialogs.showProgress(progress: _progress);
  }

  @override
  void updateProgress(int done) {
    _progress.value = (
      done: done,
      total: _progress.value.total,
      message: '正在清理错误的 GStore 数据…',
    );
  }

  @override
  void endProgress() {
    AppDialogs.dismissLoading();
    _progress.dispose();
  }
}

/// Durable, confirm-first cleanup of the catalog-polluted `gstore` membership.
class LocalDbGStoreCleanup {
  LocalDbGStoreCleanup._();

  /// SharedPreferences marker key; value `'1'` = completed (or dismissed).
  static const String markerKey = 'localdb_gstore_cleanup_v1.done';

  /// Channel that owns the local library after the cutover.
  static const String targetChannel = 'gstore';

  /// Legacy channel id: never modified here.
  static const String legacyChannel = 'local_db';

  /// Runs the pass. Never throws.
  static Future<CleanupReport> run({
    String? dataDir,
    LocalDbGStoreLegitSetReader? reader,
    LocalDbGStoreCleanupUi? ui,
    LocalDbCleanupProgress? onProgress,
  }) async {
    LocalDbGStoreCleanupUi? activeUi;
    var progressStarted = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(markerKey) == '1') {
        appLog.info('LocalDbGStoreCleanup: 已完成过（marker 存在），跳过');
        return const CleanupReport(alreadyDone: true);
      }

      final resolvedDataDir =
          dataDir ?? (await CutoverPaths.defaultCoreDirs()).$1;
      final legit = await (reader ?? const SqfliteBackupLegitSetReader())
          .readLegitAppIds(dataDir: resolvedDataDir);

      final current = <String>[];
      final seen = <String>{};
      for (final row in await AddedAppsFacade.instance.listChannel(targetChannel)) {
        if (seen.add(row.appId)) current.add(row.appId);
      }

      final toRemove = <String>[
        for (final appId in current)
          if (!legit.contains(appId)) appId,
      ];
      final kept = current.length - toRemove.length;

      if (toRemove.isEmpty) {
        appLog.info('LocalDbGStoreCleanup: 无需清理（gstore $kept 个均为合法）');
        await prefs.setString(markerKey, '1');
        return CleanupReport(kept: kept);
      }

      activeUi = ui ?? AppDialogsCleanupUi();
      final confirmed = await activeUi.confirmRemove(toRemove.length);
      if (!confirmed) {
        appLog.info('LocalDbGStoreCleanup: 用户取消，写入 marker 不再询问');
        await prefs.setString(markerKey, '1');
        return CleanupReport(kept: kept, cancelled: true);
      }

      activeUi.beginProgress(toRemove.length);
      progressStarted = true;
      onProgress?.call(0, toRemove.length);

      var removed = 0;
      var failed = 0;
      for (var i = 0; i < toRemove.length; i++) {
        final appId = toRemove[i];
        try {
          await AddedAppsFacade.instance.remove(targetChannel, appId);
          await AddedAppsFacade.instance.setTags(
            targetChannel,
            appId,
            const <String>[],
          );
          final channel = await ChannelManager.instance
              .removeAppByCode(targetChannel, appId);
          if (!channel.success) {
            // Membership + tags are already gone; a missing `channel_apps` row
            // (or an unsupported driver) must not fail the whole pass.
            debugPrint('LocalDbGStoreCleanup: 清理 channel_apps(gstore) 跳过 '
                '$appId（${channel.error}）');
          }
          removed++;
        } catch (error) {
          failed++;
          appLog.warning('LocalDbGStoreCleanup: 移除失败 - $appId: $error');
        }
        activeUi.updateProgress(i + 1);
        onProgress?.call(i + 1, toRemove.length);
      }

      activeUi.endProgress();
      progressStarted = false;
      await prefs.setString(markerKey, '1');
      await AddedAppsFacade.instance.notifyAppsChanged();

      final report = CleanupReport(
        removed: removed,
        kept: kept,
        failed: failed,
      );
      appLog.info('LocalDbGStoreCleanup: 清理完成 $report');
      return report;
    } catch (error) {
      appLog.error('LocalDbGStoreCleanup: 清理中止（不影响启动）: $error');
      if (progressStarted) activeUi?.endProgress();
      return const CleanupReport(failed: 1);
    }
  }
}
