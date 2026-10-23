import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

rust.ResyncReportDto _report({int updated = 0, String? snapshotPath}) =>
    rust.ResyncReportDto(
      floorRows: 3,
      moduleRows: 4,
      coreRows: 5,
      matched: 2,
      updated: updated,
      missing: 3,
      conflicts: 0,
      needsRestart: 1,
      snapshotPath: snapshotPath,
    );

class _PlainBackend implements DownloadBackend {
  @override
  Future<int> start(rust.DownloadStartRequest request) async => 0;

  @override
  Future<List<rust.DownloadTaskDto>> list() async =>
      const <rust.DownloadTaskDto>[];

  @override
  Future<rust.DownloadTaskDto?> get(String moduleTaskId) async => null;

  @override
  Future<void> pause(String moduleTaskId) async {}

  @override
  Future<void> resume(String moduleTaskId) async {}

  @override
  Future<void> cancel(String moduleTaskId) async {}

  @override
  Future<void> retry(String moduleTaskId) async {}

  @override
  Future<void> restart(String moduleTaskId) async {}

  @override
  Future<void> remove(String moduleTaskId) async {}

  @override
  Stream<rust.DownloadTaskDto> watchAll() =>
      const Stream<rust.DownloadTaskDto>.empty();
}

class _RecordingResyncBackend extends _PlainBackend implements DownloadResync {
  _RecordingResyncBackend(this.report);

  final rust.ResyncReportDto report;
  final List<bool> applies = <bool>[];
  final List<String?> floorPaths = <String?>[];
  int calls = 0;

  @override
  Future<rust.ResyncReportDto> resyncDownloads({
    bool apply = false,
    String? floorDbPath,
  }) async {
    calls += 1;
    applies.add(apply);
    floorPaths.add(floorDbPath);
    return report;
  }
}

/// Minimal flag mirror so the post-flip tests can prove the resync path no
/// longer consults `CoreFlags` (the cutover left it core-owned regardless of
/// the Dart mirror's value).
class _MirrorBackend implements CoreFlagsBackend {
  _MirrorBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    snapshot = CoreFlagsSnapshot(
      channels: patch.channel ?? snapshot.channels,
      catalog: patch.catalog ?? snapshot.catalog,
      update: patch.update ?? snapshot.update,
      download: patch.download ?? snapshot.download,
      install: patch.install ?? snapshot.install,
      jsChannel: patch.jsChannel ?? snapshot.jsChannel,
      coreWrites: snapshot.coreWrites,
    );
  }
}

Future<void> _installMirror({
  required bool download,
  required bool install,
}) async {
  CoreFlags.installBackend(
    _MirrorBackend(
      CoreFlagsSnapshot(download: download, install: install),
    ),
  );
  await CoreFlags.refresh();
}

void main() {
  setUp(() => DownloadFacade.backendOverride = null);
  tearDown(() => DownloadFacade.backendOverride = null);

  test('resync_dry_run_is_default_and_forwards_no_writes', () async {
    final report = _report();
    final backend = _RecordingResyncBackend(report);
    final facade = DownloadFacade(backend: backend);

    final result = await facade.resyncDownloads();

    expect(backend.calls, 1, reason: 'the backend must be called exactly once');
    expect(backend.applies, <bool>[false], reason: 'dry-run is the default');
    expect(backend.floorPaths, <String?>[null]);
    expect(identical(result, report), isTrue,
        reason: 'the report must be returned unchanged');
    expect(result.updated, 0);
    expect(result.snapshotPath, isNull);
  });

  test('resync_apply_forwards_true_and_snapshot_path', () async {
    const snapshot = '/files/migration/backups/pre-resync-42.db';
    final report = _report(updated: 4, snapshotPath: snapshot);
    final backend = _RecordingResyncBackend(report);
    final facade = DownloadFacade(backend: backend);

    final result = await facade.resyncDownloads(apply: true);

    expect(backend.calls, 1);
    expect(backend.applies, <bool>[true]);
    expect(result.updated, 4);
    expect(result.snapshotPath, snapshot);
  });

  test('resync_forwards_explicit_floor_db_path', () async {
    final backend = _RecordingResyncBackend(_report());
    final facade = DownloadFacade(backend: backend);

    await facade.resyncDownloads(floorDbPath: '/data/floor/download_task.db');

    expect(backend.floorPaths, <String?>['/data/floor/download_task.db']);
    expect(backend.applies, <bool>[false]);
  });

  test('resync_rejects_backend_without_capability', () async {
    final facade = DownloadFacade(backend: _PlainBackend());

    // `resyncDownloads` throws synchronously when the capability is missing,
    // so the closure (not a Future) is what must be asserted.
    expect(
      () => facade.resyncDownloads(apply: true),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          contains('does not support download resync'),
        ),
      ),
    );
  });

  // ───────────────────────────────────────────────────────────────────────
  // Post-flip (Plan-Todo 4): `download` + `install` default to the cutover
  // flags, but the resync path was already flag-free. These tests pin what the
  // flip changes: the Dart mirror is irrelevant, the dry-run stays read-only,
  // and only an explicit `apply: true` forwards the snapshot mutation.
  // ───────────────────────────────────────────────────────────────────────
  group('post-cutover resync ignores the flag mirror', () {
    tearDown(CoreFlags.resetBackend);

    test('cutover mirror: dry-run is read-only, apply forwards exactly once',
        () async {
      await _installMirror(download: true, install: true);

      final dryBackend = _RecordingResyncBackend(_report());
      final dry = await DownloadFacade(backend: dryBackend).resyncDownloads();

      expect(dryBackend.calls, 1);
      expect(dryBackend.applies, <bool>[false],
          reason: 'a dry-run stays read-only after the flip');
      expect(dryBackend.floorPaths, <String?>[null]);
      expect(dry.snapshotPath, isNull,
          reason: 'a dry-run must not produce a snapshot path');
      expect(dry.updated, 0);

      const snapshot = '/files/migration/backups/pre-resync-42.db';
      final applyBackend = _RecordingResyncBackend(
        _report(updated: 4, snapshotPath: snapshot),
      );
      final applied = await DownloadFacade(backend: applyBackend)
          .resyncDownloads(apply: true);

      expect(applyBackend.calls, 1, reason: 'apply forwards exactly once');
      expect(applyBackend.applies, <bool>[true]);
      expect(applied.snapshotPath, snapshot);
      expect(applied.updated, 4);
    });

    test('all-false mirror still forwards: routing no longer reads the flags',
        () async {
      await _installMirror(download: false, install: false);
      final backend = _RecordingResyncBackend(_report());

      final result = await DownloadFacade(backend: backend).resyncDownloads();

      expect(backend.calls, 1,
          reason: 'a mirror reporting false must not gate the core resync');
      expect(backend.applies, <bool>[false]);
      expect(result.updated, 0);
    });

    test('backend without DownloadResync still throws after the flip', () async {
      await _installMirror(download: true, install: true);
      final facade = DownloadFacade(backend: _PlainBackend());

      expect(
        () => facade.resyncDownloads(apply: true),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('does not support download resync'),
          ),
        ),
      );
    });
  });
}
