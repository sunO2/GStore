/// Durable, one-time Wave 6 closeout.
///
/// This is the **durable** half of the flag flip. `CoreFlags.set` is a runtime
/// test seam with no persistence; the real cutover is:
///
/// 1. the Rust process default is `Flags::WAVE06_CLOSEOUT` (all six domains
///    core-owned), and
/// 2. on the first launch after the upgrade, [CoreCutover.run] takes **exactly
///    one** pre-closeout snapshot at
///    `<files_dir>/migration/backups/pre-closeout-<millis>.db`, imports the
///    legacy data from the paths in `CutoverPaths` in the contractual order
///    `channels → jsChannel → catalog → update`, verifies row-level parity
///    against that data, and only then writes
///    `<files_dir>/migration/cutover_v6.done` **atomically** (write temp +
///    rename).
///
/// Every later launch sees the marker and does nothing: no snapshot, no resync.
/// A failure at any step (snapshot, import, parity) leaves the marker absent so
/// the next launch retries; the retry reuses a *validated* existing
/// `pre-closeout-*.db` instead of taking a second snapshot, so "one pre-closeout
/// snapshot" holds across interruptions too. A partial or corrupt snapshot is
/// never reused.
///
/// Fail-closed rule: if a domain's legacy data exists but the replay imported
/// zero rows, [CoreCutoverException.emptyImport] is thrown and the marker is
/// not written. A genuinely fresh install (no legacy artifacts at all) is
/// allowed to complete with zero imported rows.
///
/// Parity is a row-level comparison of the imported legacy rows against the
/// core projection (not a second read of the same getter), so dropping one
/// imported row fails the cutover.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'package:gstore/core/migration/cutover_paths.dart';

/// The four domains the durable cutover resyncs, in the contractual order.
///
/// The order is a real dependency: `catalog` must be authoritative before
/// `update` (`UpdateFacade` enforces `catalog -> update` at call time), and the
/// script-pack lane (`jsChannel`) lives on top of the channel registry.
enum CutoverDomain { channels, jsChannel, catalog, update }

/// Outcome of one resync step.
class CutoverStepResult {
  const CutoverStepResult({
    required this.rows,
    required this.parityOk,
    this.imported = 0,
    this.legacyPresent = false,
  });

  /// Rows the core projection holds for the domain after the replay.
  final int rows;

  /// Whether the row-level parity check proved every imported legacy row is in
  /// the core projection (and no core row is missing from the source).
  final bool parityOk;

  /// Rows the replay actually wrote for the domain.
  final int imported;

  /// Whether genuine legacy data was found for the domain.
  ///
  /// A step with `legacyPresent == true` and `imported == 0` fails the cutover:
  /// that is exactly the silent no-op this repair exists to prevent. A fresh
  /// install has `legacyPresent == false` and is allowed to complete.
  final bool legacyPresent;

  @override
  String toString() => 'CutoverStepResult(rows: $rows, imported: $imported, '
      'legacyPresent: $legacyPresent, parityOk: $parityOk)';
}

/// Typed cutover failure. `CORE_E_*` codes mirror the Rust error vocabulary.
class CoreCutoverException implements Exception {
  const CoreCutoverException(this.code, this.message);

  /// Stable code: the pre-closeout snapshot could not be created.
  static const String snapshotFailed = 'CORE_E_CUTOVER_SNAPSHOT';

  /// Stable code: a domain did not reach its resync fixpoint.
  static const String parityFailed = 'CORE_E_CUTOVER_PARITY';

  /// Stable code: legacy data exists but the domain imported zero rows.
  static const String emptyImport = 'CORE_E_CUTOVER_EMPTY_IMPORT';

  /// Stable code: the done marker could not be written atomically.
  static const String markerFailed = 'CORE_E_CUTOVER_MARKER';

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Result of [CoreCutover.run].
class CutoverResult {
  const CutoverResult({
    required this.ran,
    required this.markerPath,
    this.snapshotPath,
    this.resynced = const <CutoverDomain>[],
    this.rows = const <CutoverDomain, int>{},
    this.imported = const <CutoverDomain, int>{},
  });

  /// `false` when the marker already existed: nothing snapshotted, nothing
  /// resynced.
  final bool ran;

  /// Absolute path of `<files_dir>/migration/cutover_v6.done`.
  final String markerPath;

  /// Path of the single pre-closeout snapshot, or `null` when [ran] is false.
  final String? snapshotPath;

  /// Domains resynced, in execution order (empty when [ran] is false).
  final List<CutoverDomain> resynced;

  /// Projection row counts observed per resynced domain.
  final Map<CutoverDomain, int> rows;

  /// Rows imported per resynced domain.
  final Map<CutoverDomain, int> imported;

  @override
  String toString() => 'CutoverResult(ran: $ran, snapshot: $snapshotPath, '
      'resynced: ${resynced.map((d) => d.name).join(' -> ')}, '
      'imported: ${imported.map((d, v) => MapEntry(d.name, v))})';
}

/// Transport seam for [CoreCutover]. Production is [FrbCoreCutoverBackend];
/// tests inject a fake so no native library (and no real SQLite) is required.
abstract class CoreCutoverBackend {
  /// Writes one `VACUUM INTO` snapshot at [path] and returns its byte size.
  Future<int> exportSnapshot({required String path});

  Future<CutoverStepResult> resyncChannels();

  Future<CutoverStepResult> resyncJsChannel();

  Future<CutoverStepResult> resyncCatalog();

  Future<CutoverStepResult> resyncUpdate();
}

/// One-time durable cutover orchestrator.
class CoreCutover {
  CoreCutover._();

  /// Marker file name under `<files_dir>/migration` (canonical: [CutoverPaths]).
  static const String markerFileName = CutoverPaths.markerFileName;

  /// Migration directory name under `<files_dir>`.
  static const String migrationDirName = CutoverPaths.migrationDirName;

  /// Backups directory name under the migration directory.
  static const String backupsDirName = CutoverPaths.backupsDirName;

  /// Pre-closeout snapshot prefix.
  static const String snapshotPrefix = CutoverPaths.snapshotPrefix;

  /// Pre-closeout snapshot suffix.
  static const String snapshotSuffix = CutoverPaths.snapshotSuffix;

  /// Marker payload version.
  static const int markerVersion = 6;

  /// Last result, for diagnostics/tests. `null` until the first run.
  static CutoverResult? lastResult;

  /// Test-only: clears [lastResult].
  @visibleForTesting
  static void resetForTest() {
    lastResult = null;
  }

  /// Runs the cutover once over [filesDir]. Never runs twice.
  ///
  /// Throws [CoreCutoverException] when the snapshot, a resync, parity or the
  /// marker write fails. The marker is only written after every step succeeded,
  /// so a thrown error means the next launch retries.
  static Future<CutoverResult> run({
    required String filesDir,
    required CoreCutoverBackend backend,
    int Function()? nowMillis,
  }) async {
    final clock = nowMillis ?? _defaultNowMillis;
    final migrationDir = Directory('$filesDir/$migrationDirName');
    final marker = File('${migrationDir.path}/$markerFileName');

    // Stale state short-circuit: a real marker file wins over everything.
    if (marker.existsSync()) {
      final skipped = CutoverResult(ran: false, markerPath: marker.path);
      lastResult = skipped;
      debugPrint('[CoreCutover] marker present, skipping: ${marker.path}');
      return skipped;
    }

    final transport = backend;
    await migrationDir.create(recursive: true);

    final snapshotPath = await _ensureSnapshot(
      transport: transport,
      migrationDir: migrationDir,
      millis: clock(),
    );

    final resynced = <CutoverDomain>[];
    final rows = <CutoverDomain, int>{};
    final imported = <CutoverDomain, int>{};
    for (final step in _orderedSteps(transport)) {
      final result = await step.run();
      if (result.legacyPresent && result.imported == 0) {
        throw CoreCutoverException(
          CoreCutoverException.emptyImport,
          '${step.domain.name}: legacy data exists but the import wrote 0 rows '
          '(rows=${result.rows}); $markerFileName not written',
        );
      }
      if (!result.parityOk) {
        throw CoreCutoverException(
          CoreCutoverException.parityFailed,
          '${step.domain.name} failed row-level parity '
          '(rows=${result.rows}, imported=${result.imported}); '
          '$markerFileName not written',
        );
      }
      rows[step.domain] = result.rows;
      imported[step.domain] = result.imported;
      resynced.add(step.domain);
    }

    final completedAt = clock();
    await _writeMarkerAtomic(
      marker: marker,
      completedAt: completedAt,
      snapshotPath: snapshotPath,
      resynced: resynced,
      rows: rows,
      imported: imported,
    );

    final result = CutoverResult(
      ran: true,
      markerPath: marker.path,
      snapshotPath: snapshotPath,
      resynced: List<CutoverDomain>.unmodifiable(resynced),
      rows: Map<CutoverDomain, int>.unmodifiable(rows),
      imported: Map<CutoverDomain, int>.unmodifiable(imported),
    );
    lastResult = result;
    debugPrint('[CoreCutover] completed: $result');
    return result;
  }

  /// The one pre-closeout snapshot.
  ///
  /// Reuses an existing `pre-closeout-*.db` (a previous interrupted run) only
  /// after validating it: a crash between `VACUUM INTO` and its post-write check
  /// can leave a partial file, which must never be treated as the pre-cutover
  /// state. Invalid snapshots are deleted and a fresh one is exported to a temp
  /// name, validated, then renamed into place.
  static Future<String> _ensureSnapshot({
    required CoreCutoverBackend transport,
    required Directory migrationDir,
    required int millis,
  }) async {
    final backups = Directory('${migrationDir.path}/$backupsDirName');
    await backups.create(recursive: true);

    final existing = backups
        .listSync()
        .whereType<File>()
        .where((file) => _isSnapshot(file.uri.pathSegments.last))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in existing) {
      if (_isValidSnapshot(file)) {
        debugPrint('[CoreCutover] reusing snapshot: ${file.path}');
        return file.path;
      }
      debugPrint('[CoreCutover] rejecting invalid snapshot: ${file.path}');
      _tryDelete(file);
    }

    final destination =
        File('${backups.path}/$snapshotPrefix$millis$snapshotSuffix');
    final temp = File('${destination.path}.tmp-$pid');
    try {
      await transport.exportSnapshot(path: temp.path);
      if (!temp.existsSync()) {
        throw StateError('exportSnapshot reported success but wrote no file');
      }
      if (!_isValidSnapshot(temp)) {
        throw StateError('exportSnapshot wrote an unreadable SQLite file');
      }
      await temp.rename(destination.path);
    } catch (error) {
      _tryDelete(temp);
      _tryDelete(destination);
      throw CoreCutoverException(
        CoreCutoverException.snapshotFailed,
        'pre-closeout snapshot failed: $error',
      );
    }
    return destination.path;
  }

  static void _tryDelete(File file) {
    if (!file.existsSync()) return;
    try {
      file.deleteSync();
    } catch (cleanupError) {
      debugPrint('[CoreCutover] snapshot cleanup failed: $cleanupError');
    }
  }

  /// A readable, non-truncated SQLite database: valid 16-byte header, a
  /// power-of-two page size, and a file length that is a whole number of pages.
  static bool _isValidSnapshot(File file) {
    RandomAccessFile? handle;
    try {
      if (!file.existsSync()) return false;
      final length = file.lengthSync();
      if (length < 100) return false;
      handle = file.openSync();
      final header = handle.readSync(16);
      if (header.length != 16 ||
          String.fromCharCodes(header) != 'SQLite format 3\u0000') {
        return false;
      }
      handle.setPositionSync(16);
      final pageBytes = handle.readSync(2);
      if (pageBytes.length != 2) return false;
      var pageSize = (pageBytes[0] << 8) | pageBytes[1];
      if (pageSize == 1) pageSize = 65536;
      if (pageSize < 512 ||
          pageSize > 65536 ||
          (pageSize & (pageSize - 1)) != 0) {
        return false;
      }
      return length >= pageSize && length % pageSize == 0;
    } catch (error) {
      debugPrint('[CoreCutover] snapshot validation failed: $error');
      return false;
    } finally {
      handle?.closeSync();
    }
  }

  static bool _isSnapshot(String name) =>
      name.startsWith(snapshotPrefix) && name.endsWith(snapshotSuffix);

  static List<_CutoverStep> _orderedSteps(CoreCutoverBackend transport) =>
      <_CutoverStep>[
        _CutoverStep(CutoverDomain.channels, transport.resyncChannels),
        _CutoverStep(CutoverDomain.jsChannel, transport.resyncJsChannel),
        _CutoverStep(CutoverDomain.catalog, transport.resyncCatalog),
        _CutoverStep(CutoverDomain.update, transport.resyncUpdate),
      ];

  /// Atomic marker write: temp file in the same directory, flush, rename.
  ///
  /// `rename(2)` within one filesystem is atomic, so a crash either leaves the
  /// old state (no marker) or the complete marker — never a partial one.
  static Future<void> _writeMarkerAtomic({
    required File marker,
    required int completedAt,
    required String snapshotPath,
    required List<CutoverDomain> resynced,
    required Map<CutoverDomain, int> rows,
    required Map<CutoverDomain, int> imported,
  }) async {
    final payload =
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'version': markerVersion,
      'status': 'done',
      'completed_at': completedAt,
      'snapshot': snapshotPath,
      'resync_order': <String>[for (final domain in resynced) domain.name],
      'rows': <String, int>{
        for (final domain in resynced) domain.name: rows[domain] ?? 0,
      },
      'imported': <String, int>{
        for (final domain in resynced) domain.name: imported[domain] ?? 0,
      },
    });
    final temp = File('${marker.path}.tmp-$pid-$completedAt');
    try {
      await temp.writeAsString(payload, flush: true);
      await temp.rename(marker.path);
    } catch (error) {
      if (temp.existsSync()) {
        try {
          temp.deleteSync();
        } catch (cleanupError) {
          debugPrint('[CoreCutover] marker temp cleanup failed: $cleanupError');
        }
      }
      throw CoreCutoverException(
        CoreCutoverException.markerFailed,
        'write $markerFileName atomically: $error',
      );
    }
  }

  static int _defaultNowMillis() => DateTime.now().millisecondsSinceEpoch;
}

/// Internal (domain, thunk) pair so the execution order is one literal list.
class _CutoverStep {
  const _CutoverStep(this.domain, this.run);

  final CutoverDomain domain;
  final Future<CutoverStepResult> Function() run;
}
