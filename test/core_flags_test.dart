import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

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

void main() {
  tearDown(CoreFlags.resetBackend);

  test('all flags default to false before any backend read', () {
    expect(CoreFlags.snapshot, CoreFlagsSnapshot.disabled);
    expect(CoreFlags.channels, isFalse);
    expect(CoreFlags.catalog, isFalse);
    expect(CoreFlags.update, isFalse);
    expect(CoreFlags.download, isFalse);
    expect(CoreFlags.install, isFalse);
    expect(CoreFlags.jsChannel, isFalse);
    expect(CoreFlags.coreWrites, isFalse);
  });

  test('backend snapshot is reflected after refresh', () async {
    const snapshot = CoreFlagsSnapshot(
      channels: true,
      catalog: true,
      update: true,
      download: true,
      install: true,
      jsChannel: true,
    );
    CoreFlags.installBackend(_FakeFlagsBackend(snapshot));

    expect(CoreFlags.channels, isFalse,
        reason: 'mirror stays all-false before the first read');

    await CoreFlags.refresh();

    expect(CoreFlags.snapshot, snapshot);
    expect(CoreFlags.channels, isTrue);
    expect(CoreFlags.catalog, isTrue);
    expect(CoreFlags.update, isTrue);
    expect(CoreFlags.download, isTrue);
    expect(CoreFlags.install, isTrue);
    expect(CoreFlags.jsChannel, isTrue);
  });

  test('coreWrites remains false in the Rust-owned default snapshot', () async {
    CoreFlags.installBackend(
      _FakeFlagsBackend(CoreFlagsSnapshot.disabled),
    );
    await CoreFlags.refresh();

    expect(CoreFlags.coreWrites, isFalse);
    expect(CoreFlags.snapshot, CoreFlagsSnapshot.disabled);
  });

  test('legacy guard still probes and blocks on a marker while flags are off',
      () async {
    final probed = <String>[];
    LegacyWriteGuard.probeOverride = (domain) async {
      probed.add(domain);
      return true;
    };
    addTearDown(() => LegacyWriteGuard.probeOverride = null);

    CoreFlags.installBackend(_FakeFlagsBackend(CoreFlagsSnapshot.disabled));
    await CoreFlags.refresh();
    expect(CoreFlags.coreWrites, isFalse);

    await expectLater(
      LegacyWriteGuard.assertAllowed('channel'),
      throwsA(isA<LegacyWriteBlocked>()),
    );

    expect(probed, <String>['channel'],
        reason: 'the per-domain marker is authoritative, not the global flag');
  });
}
