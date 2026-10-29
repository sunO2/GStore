/// One-time migration: legacy `local_db` library rows → the `gstore` channel.
///
/// Background: before the core took over the local library, added apps were
/// written under the `local_db` channel id. Restore and migration V5 moved the
/// bulk of that data to `gstore`, but rows written by an OLD backup restore (or
/// rows left over from before the cutover) can still sit under `local_db`:
///
/// * `added_apps('local_db')` — invisible on the home page (the projection reads
///   the core channels; `local_db` is not one of them), and
/// * `channel_apps('local_db')` — written through the legacy `LocalDbDriver`,
///   whose `add_app` / `remove_app` are `unsupported`.
///
/// **Scope guard (regression fix):** only rows that already have an
/// `added_apps('local_db')` membership are eligible. The catalog is NEVER
/// enumerated and no app is ever added that was not already in the library —
/// this pass only relocates an existing membership.
///
/// It is:
///
/// * **one-time** — a `localdb_gstore_v1.done` SharedPreferences marker (string
///   `'1'`), written only after a complete pass;
/// * **idempotent** — moving an app twice is safe (`addMembership` /
///   `addAppByCode` / `setTags` are upserts), and an interrupted pass leaves the
///   marker absent so the next launch retries;
/// * **non-fatal** — every per-app failure is counted, never thrown out.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/aggregate/added_app_types.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/model/AppSummary.dart';

/// Progress callback: `done` of `total` apps handled (0 ≤ done ≤ total).
typedef LocalDbMigrationProgress = void Function(int done, int total);

/// Outcome of one [LocalDbGStoreMigration.run] pass.
class MigrationReport {
  const MigrationReport({
    this.moved = 0,
    this.skipped = 0,
    this.failed = 0,
    this.alreadyDone = false,
  });

  /// Apps fully moved to `gstore`.
  final int moved;

  /// Apps ignored (blank appId).
  final int skipped;

  /// Apps that raised while moving; the marker stays absent so a later launch
  /// retries them.
  final int failed;

  /// `true` when the done marker was already present: nothing was read/written.
  final bool alreadyDone;

  int get total => moved + skipped + failed;

  @override
  String toString() => 'MigrationReport(moved: $moved, skipped: $skipped, '
      'failed: $failed, alreadyDone: $alreadyDone)';
}

/// Durable `local_db` → `gstore` migration (see the library doc).
class LocalDbGStoreMigration {
  LocalDbGStoreMigration._();

  /// SharedPreferences marker key; value `'1'` = completed.
  static const String markerKey = 'localdb_gstore_v1.done';

  /// Legacy channel id that must never receive new rows.
  static const String legacyChannel = 'local_db';

  /// Channel that owns the local library after the cutover.
  static const String targetChannel = 'gstore';

  /// Runs the one-time pass. Never throws.
  static Future<MigrationReport> run({
    LocalDbMigrationProgress? onProgress,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(markerKey) == '1') {
        appLog.info('LocalDbGStoreMigration: 已完成过（marker 存在），跳过');
        return const MigrationReport(alreadyDone: true);
      }

      final membership = await _readMembership();

      // Dedupe by appId. Nothing else is a source: catalog rows that were never
      // added to the library must never be pulled in.
      final appIds = <String>[];
      final membershipByApp = <String, AddedAppInfo>{};
      for (final row in membership) {
        if (membershipByApp.containsKey(row.appId)) continue;
        membershipByApp[row.appId] = row;
        appIds.add(row.appId);
      }

      final total = appIds.length;
      appLog.info(
          'LocalDbGStoreMigration: 开始迁移 local_db → gstore（$total 个应用）');
      onProgress?.call(0, total);

      var moved = 0;
      var skipped = 0;
      var failed = 0;
      for (var i = 0; i < appIds.length; i++) {
        final appId = appIds[i];
        if (appId.trim().isEmpty) {
          skipped++;
        } else {
          try {
            await _moveOne(appId, membership: membershipByApp[appId]);
            moved++;
          } catch (error) {
            failed++;
            appLog.warning('LocalDbGStoreMigration: 迁移失败 - $appId: $error');
          }
        }
        onProgress?.call(i + 1, total);
      }

      final report = MigrationReport(moved: moved, skipped: skipped, failed: failed);
      if (failed == 0) {
        await prefs.setString(markerKey, '1');
        appLog.info('LocalDbGStoreMigration: 迁移完成 $report');
      } else {
        // Marker stays absent: the next launch retries (idempotent upserts).
        appLog.warning('LocalDbGStoreMigration: 部分失败，下次启动重试 $report');
      }
      await AddedAppsFacade.instance.notifyAppsChanged();
      return report;
    } catch (error) {
      appLog.error('LocalDbGStoreMigration: 迁移中止（不影响启动）: $error');
      return const MigrationReport(failed: 1);
    }
  }

  /// Moves one library app: membership, metadata, tags, then its legacy rows.
  static Future<void> _moveOne(
    String appId, {
    AddedAppInfo? membership,
  }) async {
    await AddedAppsFacade.instance.addMembership(
      targetChannel,
      appId,
      sortOrder: membership?.sortOrder,
    );

    final summary = await _resolveSummary(appId);
    final added =
        await ChannelManager.instance.addAppByCode(targetChannel, summary);
    if (!added.success) {
      throw StateError('addAppByCode(gstore) 失败: ${added.error}');
    }

    final tags = await AddedAppsFacade.instance.tags(legacyChannel, appId);
    if (tags.isNotEmpty) {
      await AddedAppsFacade.instance.setTags(targetChannel, appId, tags);
    }

    try {
      await AddedAppsFacade.instance.remove(legacyChannel, appId);
    } catch (error) {
      // Membership already lives on `gstore`; a legacy-row delete failure must
      // not lose the app (this is exactly what the target-channel write above
      // guarantees). Logged only.
      appLog.warning('LocalDbGStoreMigration: 删除 local_db 成员失败 - $appId: $error');
    }

    // Only THIS moved app's legacy `channel_apps('local_db')` row is dropped.
    // `LocalDbDriver` may report `unsupported`, which is tolerated.
    try {
      final result =
          await ChannelManager.instance.removeAppByCode(legacyChannel, appId);
      if (!result.success) {
        debugPrint('LocalDbGStoreMigration: 清理 channel_apps(local_db) 跳过 '
            '$appId（${result.error}）');
      }
    } catch (error) {
      debugPrint(
          'LocalDbGStoreMigration: 清理 channel_apps(local_db) 失败 $appId: $error');
    }
  }

  /// Real catalog summary (name/icon) ?? minimal placeholder (never null).
  static Future<AppSummary> _resolveSummary(String appId) async {
    try {
      final catalog = await CatalogFacade.instance.getApp(appId);
      if (catalog != null) return catalog;
    } catch (error) {
      debugPrint('LocalDbGStoreMigration: 目录库查询失败 $appId: $error');
    }
    return _minimalSummary(appId);
  }

  static AppSummary _minimalSummary(String appId) => AppSummary(
        appId: appId,
        name: appId,
        user: '',
        repositories: '',
        icon: '',
        des: '',
      );

  /// `added_apps('local_db')` rows (membership + sort order).
  static Future<List<AddedAppInfo>> _readMembership() async {
    try {
      return await AddedAppsFacade.instance.listChannel(legacyChannel);
    } catch (error) {
      appLog.warning('LocalDbGStoreMigration: 读取 added_apps(local_db) 失败: $error');
      return const <AddedAppInfo>[];
    }
  }
}
