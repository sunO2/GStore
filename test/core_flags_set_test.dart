import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/download/core_download_builder.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Recording fake: keeps the last snapshot, merges partial patches exactly like
/// the Rust `FlagsApi` (only supplied fields change) and records every write.
class _RecordingFlagsBackend implements CoreFlagsBackend {
  _RecordingFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;
  final List<CoreFlagsPatch> writes = <CoreFlagsPatch>[];
  int reads = 0;
  Object? writeError;
  Object? readError;
  Completer<void>? writeGate;

  @override
  Future<CoreFlagsSnapshot> read() async {
    reads++;
    final error = readError;
    if (error != null) throw error;
    return snapshot;
  }

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    writes.add(patch);
    final gate = writeGate;
    if (gate != null) await gate.future;
    final error = writeError;
    if (error != null) throw error;
    snapshot = CoreFlagsSnapshot(
      channels: patch.channel ?? snapshot.channels,
      catalog: patch.catalog ?? snapshot.catalog,
      update: patch.update ?? snapshot.update,
      download: patch.download ?? snapshot.download,
      install: patch.install ?? snapshot.install,
      jsChannel: patch.jsChannel ?? snapshot.jsChannel,
      // coreWrites is never operator-settable: always carried from the state.
      coreWrites: snapshot.coreWrites,
    );
  }
}

/// Fake download API: records the start call.
class _RecordingDownloadApi implements CoreDownloadApi {
  int starts = 0;
  CoreDownloadRequest? last;

  @override
  Future<int> start(CoreDownloadRequest request) async {
    starts++;
    last = request;
    return starts;
  }
}

Future<CoreDownloadRequest> _request() => CoreDownloadBuilder.build(
      appId: 'com.example.app',
      appName: 'Example',
      version: '1.0.0',
      fileName: 'app.apk',
      url: 'https://example.com/app.apk',
      saveFileName: '/tmp/gstore/app.apk',
      docsDir: '/tmp/gstore',
    );

void main() {
  tearDown(CoreFlags.resetBackend);

  test('core_flags_set_is_partial', () async {
    final backend = _RecordingFlagsBackend(CoreFlagsSnapshot.disabled);
    CoreFlags.installBackend(backend);

    final snapshot = await CoreFlags.set(download: true);

    expect(backend.writes, hasLength(1));
    final patch = backend.writes.single;
    expect(patch.download, isTrue);
    expect(patch.channel, isNull);
    expect(patch.catalog, isNull);
    expect(patch.update, isNull);
    expect(patch.install, isNull);
    expect(patch.jsChannel, isNull);

    expect(backend.reads, 1, reason: 'set must refresh after the write');
    expect(CoreFlags.download, isTrue);
    expect(snapshot.download, isTrue);
    expect(CoreFlags.snapshot, snapshot);
  });

  test('core_flags_wire_patch_sends_null_for_omitted_flags', () {
    final wire = FrbCoreFlagsBackend.toRustPatch(
      const CoreFlagsPatch(download: true),
    );

    expect(wire.download, isTrue);
    expect(wire.channels, isNull);
    expect(wire.catalog, isNull);
    expect(wire.update, isNull);
    expect(wire.install, isNull);
    expect(wire.jsChannel, isNull);
    expect(wire.coreWrites, isNull);
    // `coreWrites` has no operator-settable counterpart by construction.
    expect(wire, isA<rust.FlagsPatch>());
  });

  test('core_flags_set_leaves_omitted_flags_unchanged', () async {
    final backend = _RecordingFlagsBackend(
      const CoreFlagsSnapshot(catalog: true, update: true),
    );
    CoreFlags.installBackend(backend);

    final snapshot = await CoreFlags.set(download: true);

    final patch = backend.writes.single;
    expect(patch.catalog, isNull, reason: 'omitted flags must not be stomped');
    expect(patch.update, isNull, reason: 'omitted flags must not be stomped');
    expect(snapshot.catalog, isTrue);
    expect(snapshot.update, isTrue);
    expect(CoreFlags.catalog, isTrue);
    expect(CoreFlags.update, isTrue);
    expect(CoreFlags.download, isTrue);
  });

  test('core_flags_set_all_null_is_pure_refresh', () async {
    final backend = _RecordingFlagsBackend(
      const CoreFlagsSnapshot(catalog: true),
    );
    CoreFlags.installBackend(backend);

    final snapshot = await CoreFlags.set();

    expect(backend.writes, isEmpty, reason: 'an all-null patch writes nothing');
    expect(backend.reads, 1);
    expect(snapshot.catalog, isTrue);
    expect(CoreFlags.catalog, isTrue);
  });

  test('core_flags_set_never_sets_core_writes', () async {
    final backend = _RecordingFlagsBackend(
      const CoreFlagsSnapshot(coreWrites: true),
    );
    CoreFlags.installBackend(backend);

    await CoreFlags.set(download: true);

    expect(backend.writes.single.download, isTrue);
    expect(CoreFlags.coreWrites, isTrue,
        reason: 'set must not touch the Rust-owned coreWrites projection');
    expect(backend.snapshot.coreWrites, isTrue);
  });

  test('core_flags_refresh_visible_to_download', () async {
    final backend = _RecordingFlagsBackend(CoreFlagsSnapshot.disabled);
    CoreFlags.installBackend(backend);
    // Another process armed the Rust flag after the mirror was read.
    backend.snapshot = const CoreFlagsSnapshot(download: true);

    expect(CoreFlags.download, isFalse,
        reason: 'mirror is still disabled before the read path refreshes');

    final api = _RecordingDownloadApi();
    final result = await CoreDownloadBuilder.startIfEnabled(api, await _request());

    expect(backend.reads, 1,
        reason: 'the download read path refreshes a disabled mirror');
    expect(result, 1);
    expect(api.starts, 1);
    expect(CoreFlags.download, isTrue);
  });

  test('core_flags_set_propagates_write_error_and_keeps_mirror', () async {
    final backend = _RecordingFlagsBackend(CoreFlagsSnapshot.disabled)
      ..writeError = StateError('flag write failed');
    CoreFlags.installBackend(backend);
    await CoreFlags.refresh();

    await expectLater(
      CoreFlags.set(download: true),
      throwsA(isA<StateError>()),
    );

    expect(backend.writes, hasLength(1));
    expect(CoreFlags.download, isFalse,
        reason: 'a failed write leaves the previous mirror untouched');
    expect(backend.reads, 1, reason: 'only the explicit refresh before set');
  });

  test('concurrent CoreFlags.set calls last-write-wins without crashing',
      () async {
    final backend = _RecordingFlagsBackend(CoreFlagsSnapshot.disabled);
    CoreFlags.installBackend(backend);

    await Future.wait(<Future<CoreFlagsSnapshot>>[
      CoreFlags.set(download: true),
      CoreFlags.set(install: true),
    ]);

    expect(backend.writes, hasLength(2));
    expect(backend.writes[0].download, isTrue);
    expect(backend.writes[1].install, isTrue);
    expect(CoreFlags.download, isTrue);
    expect(CoreFlags.install, isTrue,
        reason: 'both flips are retained in the backend state');
  });

  test('refresh during a set does not lose the set update', () async {
    final backend = _RecordingFlagsBackend(CoreFlagsSnapshot.disabled);
    final gate = Completer<void>();
    backend.writeGate = gate;
    CoreFlags.installBackend(backend);

    final pendingSet = CoreFlags.set(download: true);
    // Enqueued while the write is still in flight.
    final pendingRefresh = CoreFlags.refresh();

    gate.complete();
    await Future.wait<void>(<Future<void>>[pendingSet, pendingRefresh]);

    expect(CoreFlags.download, isTrue,
        reason: 'set(write+refresh) and refresh are serialized in enqueue order');
    expect(backend.writes, hasLength(1));
    expect(backend.reads, 2);
  });
}
