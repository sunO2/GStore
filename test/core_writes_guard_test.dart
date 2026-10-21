import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

Future<void> fakeLegacyWrite() async {
  await LegacyWriteGuard.assertAllowed('channel');
}

void main() {
  setUp(() {
    CoreFlags.coreWrites = true;
  });

  tearDown(() {
    CoreFlags.coreWrites = false;
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
    CoreFlags.coreWrites = false;
    LegacyWriteGuard.probeOverride = (domain) async => true;

    await LegacyWriteGuard.assertAllowed('channel');
  });
}
