import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsSnapshot flags) async {
    snapshot = flags;
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

  test('flags off keeps the old path authoritative', () async {
    await _useCoreWrites(false);
    LegacyWriteGuard.probeOverride = (domain) async => true;

    await LegacyWriteGuard.assertAllowed('channel');
  });
}
