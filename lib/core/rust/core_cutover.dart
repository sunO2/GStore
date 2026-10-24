/// Durable, one-time Wave 6 closeout.
///
/// This is the **durable** half of the flag flip. `CoreFlags.set` is a runtime
/// test seam with no persistence; the real cutover is:
///
/// 1. the Rust process default is `Flags::WAVE06_CLOSEOUT` (all six domains
///    core-owned), and
/// 2. on the first launch after the upgrade, [CoreCutover.run] takes **exactly
///    one** pre-closeout snapshot at
///    `<files_dir>/migration/backups/pre-closeout-<millis>.db`, replays the
///    retained Dart→core migration artifacts in the contractual order
///    `channels → jsChannel → catalog → update`, verifies parity, and only then
///    writes `<files_dir>/migration/cutover_v6.done` **atomically**
///    (write temp + rename).
///
/// Every later launch sees the marker and does nothing: no snapshot, no resync.
/// A failure at any step (snapshot, resync, parity) leaves the marker absent so
/// the next launch retries; the retry reuses the existing `pre-closeout-*.db`
/// instead of taking a second snapshot, so "one pre-closeout snapshot" holds
/// across interruptions too. Reusing the first snapshot is also the correct
/// choice: it is the pre-cutover state, not a half-resynced one.
///
/// The resync steps are the wave's own Dart→core handoff artifacts
/// (`channel_db`, `channel_env`, `pack`, `update_prefs`) replayed through
/// `CoreApi.importMigrationFile`. They are idempotent upserts and the Rust side
/// deletes each managed document only after its own import succeeds, so a
/// partial run resumes instead of re-applying. Parity is the resync fixpoint
/// (a second read of the same domain must report the same row count); the
/// legacy-vs-core row parity for each domain is already proven by the
/// B2–B5 parity suites.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

/// The four domains the durable cutover resyncs, in the contractual order.
///
/// The order is a real dependency: `catalog` must be authoritative before
/// `update` (`UpdateFacade` enforces `catalog -> update` at call time), and the
/// script-pack lane (`jsChannel`) lives on top of the channel registry.
enum CutoverDomain { channels, jsChannel, catalog, update }

/// Outcome of one resync step.
class CutoverStepResult {
  const CutoverStepResult({required this.rows, required this.parityOk});

  /// Rows the core reports for the domain after the replay.
  final int rows;

  /// Whether a second read of the same domain reported the same row count.
  final bool parityOk;

  @override
  String toString() => 'CutoverStepResult(rows: $rows, parityOk: $parityOk)';
}

/// Typed cutover failure. `CORE_E_*` codes mirror the Rust error vocabulary.
class CoreCutoverException implements Exception {
  const CoreCutoverException(this.code, this.message);

  /// Stable code: the pre-closeout snapshot could not be created.
  static const String snapshotFailed = 'CORE_E_CUTOVER_SNAPSHOT';

  /// Stable code: a domain did not reach its resync fixpoint.
  static const String parityFailed = 'CORE_E_CUTOVER_PARITY';

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

  /// Row counts observed per resynced domain.
  final Map<CutoverDomain, int> rows;

  @override
  String toString() => 'CutoverResult(ran: $ran, snapshot: $snapshotPath, '
      'resynced: ${resynced.map((d) => d.name).join(' -> ')})';
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

  /// Marker file name under `<files_dir>/migration`.
  static const String markerFileName = 'cutover_v6.done';

  /// Migration directory name under `<files_dir>`.
  static const String migrationDirName = 'migration';

  /// Backups directory name under the migration directory.
  static const String backupsDirName = 'backups';

  /// Pre-closeout snapshot prefix.
  static const String snapshotPrefix = 'pre-closeout-';

  /// Pre-closeout snapshot suffix.
  static const String snapshotSuffix = '.db';

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
    for (final step in _orderedSteps(transport)) {
      final result = await step.run();
      if (!result.parityOk) {
        throw CoreCutoverException(
          CoreCutoverException.parityFailed,
          '${step.domain.name} did not reach its resync fixpoint '
          '(rows=${result.rows}); $markerFileName not written',
        );
      }
      rows[step.domain] = result.rows;
      resynced.add(step.domain);
    }

    final completedAt = clock();
    await _writeMarkerAtomic(
      marker: marker,
      completedAt: completedAt,
      snapshotPath: snapshotPath,
      resynced: resynced,
      rows: rows,
    );

    final result = CutoverResult(
      ran: true,
      markerPath: marker.path,
      snapshotPath: snapshotPath,
      resynced: List<CutoverDomain>.unmodifiable(resynced),
      rows: Map<CutoverDomain, int>.unmodifiable(rows),
    );
    lastResult = result;
    debugPrint('[CoreCutover] completed: $result');
    return result;
  }

  /// The one pre-closeout snapshot.
  ///
  /// Reuses an existing `pre-closeout-*.db` (a previous interrupted run), so a
  /// retry never stacks a second snapshot on a half-resynced database.
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
    if (existing.isNotEmpty) {
      debugPrint('[CoreCutover] reusing snapshot: ${existing.first.path}');
      return existing.first.path;
    }

    final destination = File('${backups.path}/$snapshotPrefix$millis$snapshotSuffix');
    try {
      await transport.exportSnapshot(path: destination.path);
      if (!destination.existsSync()) {
        throw StateError('exportSnapshot reported success but wrote no file');
      }
    } catch (error) {
      // A half-written snapshot must never be reused by the retry.
      if (destination.existsSync()) {
        try {
          destination.deleteSync();
        } catch (cleanupError) {
          debugPrint('[CoreCutover] snapshot cleanup failed: $cleanupError');
        }
      }
      throw CoreCutoverException(
        CoreCutoverException.snapshotFailed,
        'pre-closeout snapshot failed: $error',
      );
    }
    return destination.path;
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
  }) async {
    final payload = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'version': markerVersion,
      'status': 'done',
      'completed_at': completedAt,
      'snapshot': snapshotPath,
      'resync_order': <String>[for (final domain in resynced) domain.name],
      'rows': <String, int>{
        for (final domain in resynced) domain.name: rows[domain] ?? 0,
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
