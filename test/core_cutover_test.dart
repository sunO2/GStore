/// Durable one-time Wave 6 closeout: `cutover_v6.done` gates exactly one
/// pre-closeout snapshot and one ordered resync (`channels` → `jsChannel` →
/// `catalog` → `update`), then writes the marker atomically.
///
/// Every claim is proven against the real filesystem (file counts, not a spy)
/// so a "success" that created nothing cannot pass.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/core_cutover.dart';

/// Recording backend: the call order is the contract under test.
class _RecordingBackend implements CoreCutoverBackend {
  _RecordingBackend({
    this.failOn,
    this.parityOk = true,
    this.snapshotError,
  });

  final CutoverDomain? failOn;
  final bool parityOk;
  final Object? snapshotError;

  final List<String> calls = <String>[];

  @override
  Future<int> exportSnapshot({required String path}) async {
    calls.add('snapshot:$path');
    final error = snapshotError;
    if (error != null) throw error;
    // A real snapshot artifact: the test counts files, never trust the return.
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(const <int>[0x53, 0x51, 0x4c, 0x69, 0x74, 0x65]);
    return 6;
  }

  Future<CutoverStepResult> _step(CutoverDomain domain, int rows) async {
    calls.add('resync:${domain.name}');
    if (failOn == domain) throw StateError('forced ${domain.name} failure');
    return CutoverStepResult(rows: rows, parityOk: parityOk);
  }

  @override
  Future<CutoverStepResult> resyncChannels() => _step(CutoverDomain.channels, 3);

  @override
  Future<CutoverStepResult> resyncJsChannel() =>
      _step(CutoverDomain.jsChannel, 2);

  @override
  Future<CutoverStepResult> resyncCatalog() => _step(CutoverDomain.catalog, 9);

  @override
  Future<CutoverStepResult> resyncUpdate() => _step(CutoverDomain.update, 4);

  List<String> get resyncOrder => <String>[
        for (final call in calls)
          if (call.startsWith('resync:')) call.substring('resync:'.length),
      ];

  int get snapshotCount =>
      calls.where((call) => call.startsWith('snapshot:')).length;
}

/// Files matching `<dir>/migration/backups/pre-closeout-*.db`.
List<File> _snapshots(Directory filesDir) {
  final backups = Directory('${filesDir.path}/migration/backups');
  if (!backups.existsSync()) return const <File>[];
  return backups
      .listSync()
      .whereType<File>()
      .where((file) =>
          file.uri.pathSegments.last.startsWith('pre-closeout-') &&
          file.uri.pathSegments.last.endsWith('.db'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

File _marker(Directory filesDir) =>
    File('${filesDir.path}/migration/cutover_v6.done');

void main() {
  late Directory filesDir;

  setUp(() {
    CoreCutover.resetForTest();
    filesDir = Directory.systemTemp.createTempSync('gstore_cutover_');
  });

  tearDown(() {
    CoreCutover.resetForTest();
    if (filesDir.existsSync()) filesDir.deleteSync(recursive: true);
  });

  test('first launch snapshots once, resyncs in order, writes the marker',
      () async {
    final backend = _RecordingBackend();

    final result = await CoreCutover.run(
      filesDir: filesDir.path,
      backend: backend,
      nowMillis: () => 1700000000123,
    );

    expect(result.ran, isTrue);
    expect(result.resynced, <CutoverDomain>[
      CutoverDomain.channels,
      CutoverDomain.jsChannel,
      CutoverDomain.catalog,
      CutoverDomain.update,
    ]);
    expect(backend.resyncOrder, <String>[
      'channels',
      'jsChannel',
      'catalog',
      'update',
    ]);

    // Exactly ONE real snapshot file, at the documented path.
    final snapshots = _snapshots(filesDir);
    expect(snapshots, hasLength(1),
        reason: 'first launch must create exactly one pre-closeout snapshot');
    expect(snapshots.single.path, result.snapshotPath);
    expect(snapshots.single.path,
        endsWith('/migration/backups/pre-closeout-1700000000123.db'));

    // The marker is present and no temp file survived.
    expect(_marker(filesDir).existsSync(), isTrue);
    final leftovers = Directory('${filesDir.path}/migration')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.uri.pathSegments.last.contains('.tmp'))
        .toList();
    expect(leftovers, isEmpty, reason: 'the atomic write must rename, not leak');
  });

  test('second launch is a strict no-op: no snapshot, no resync', () async {
    await CoreCutover.run(
      filesDir: filesDir.path,
      backend: _RecordingBackend(),
      nowMillis: () => 1700000000123,
    );

    final second = _RecordingBackend();
    final result = await CoreCutover.run(
      filesDir: filesDir.path,
      backend: second,
      nowMillis: () => 1800000000000,
    );

    expect(result.ran, isFalse);
    expect(result.resynced, isEmpty);
    expect(second.calls, isEmpty,
        reason: 'the marker must short-circuit before any snapshot/resync');
    expect(_snapshots(filesDir), hasLength(1),
        reason: 'a later launch must never take another snapshot');
  });

  test('a stale marker created out-of-band short-circuits', () async {
    _marker(filesDir)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"version":6,"status":"done"}');

    final backend = _RecordingBackend();
    final result = await CoreCutover.run(
      filesDir: filesDir.path,
      backend: backend,
    );

    expect(result.ran, isFalse);
    expect(backend.calls, isEmpty);
    expect(_snapshots(filesDir), isEmpty);
  });

  test('a resync failure leaves NO marker and retries cleanly', () async {
    final failing = _RecordingBackend(failOn: CutoverDomain.catalog);

    await expectLater(
      CoreCutover.run(
        filesDir: filesDir.path,
        backend: failing,
        nowMillis: () => 1700000000123,
      ),
      throwsA(isA<StateError>()),
    );

    expect(_marker(filesDir).existsSync(), isFalse,
        reason: 'a failed resync must not write the done marker');
    expect(failing.resyncOrder, <String>['channels', 'jsChannel', 'catalog'],
        reason: 'the failure stops the ordered run at catalog');
    expect(_snapshots(filesDir), hasLength(1),
        reason: 'the pre-closeout snapshot was taken before the resync');

    // Retry: reuses the pre-closeout snapshot (never a second one) and
    // completes.
    final retry = _RecordingBackend();
    final result = await CoreCutover.run(
      filesDir: filesDir.path,
      backend: retry,
      nowMillis: () => 1900000000000,
    );

    expect(result.ran, isTrue);
    expect(retry.resyncOrder, <String>[
      'channels',
      'jsChannel',
      'catalog',
      'update',
    ]);
    expect(retry.snapshotCount, 0,
        reason: 'a retry must reuse the existing pre-closeout snapshot');
    expect(_snapshots(filesDir), hasLength(1),
        reason: 'exactly one pre-closeout snapshot exists across retries');
    expect(_marker(filesDir).existsSync(), isTrue);
  });

  test('a parity failure leaves NO marker', () async {
    final backend = _RecordingBackend(parityOk: false);

    await expectLater(
      CoreCutover.run(filesDir: filesDir.path, backend: backend),
      throwsA(isA<CoreCutoverException>()),
    );

    expect(_marker(filesDir).existsSync(), isFalse);
    expect(_snapshots(filesDir), hasLength(1));
  });

  test('a snapshot failure leaves NO marker', () async {
    final backend = _RecordingBackend(snapshotError: StateError('disk full'));

    await expectLater(
      CoreCutover.run(filesDir: filesDir.path, backend: backend),
      throwsA(isA<CoreCutoverException>()),
    );

    expect(backend.resyncOrder, isEmpty,
        reason: 'no resync may run when the snapshot failed');
    expect(_marker(filesDir).existsSync(), isFalse);
  });
}
