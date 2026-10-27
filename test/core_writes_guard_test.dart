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

Future<void> _useCoreWrites(bool value) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(coreWrites: value)),
  );
  await CoreFlags.refresh();
}

Future<void> fakeLegacyWrite() async {
  await LegacyWriteGuard.assertAllowed('channel');
}

void main() {
  setUp(() async {
    await _useCoreWrites(true);
  });

  tearDown(() {
    CoreFlags.resetBackend();
    LegacyWriteGuard.probeOverride = null;
  });

  test('post-cutover legacy write fails closed', () async {
    String? captured;
    LegacyWriteGuard.probeOverride = (domain) async {
      captured = domain;
      return true;
    };

    await expectLater(
      fakeLegacyWrite(),
      throwsA(isA<LegacyWriteBlocked>()),
    );
    expect(captured, 'channel');
  });

  test('no marker allows the legacy write', () async {
    LegacyWriteGuard.probeOverride = (domain) async => false;

    await LegacyWriteGuard.assertAllowed('channel');
  });

  test('a domain marker blocks even while the global flag is false', () async {
    await _useCoreWrites(false);
    expect(CoreFlags.coreWrites, isFalse);
    final seen = <String>[];
    LegacyWriteGuard.probeOverride = (domain) async {
      seen.add(domain);
      return true;
    };

    await expectLater(
      LegacyWriteGuard.assertAllowed('channel'),
      throwsA(isA<LegacyWriteBlocked>()),
    );
    expect(seen, <String>['channel'],
        reason: 'the per-domain marker, not the global flag, owns the decision');
  });
}
