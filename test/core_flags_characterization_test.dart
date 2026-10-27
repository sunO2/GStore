import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

/// Characterization of the read-only CoreFlags mirror plus the G6A.3 guard
/// contract: the global mirror defaults to false, while the per-domain marker
/// (injected here) is what blocks a legacy write.
void main() {
  test('all flags default to false', () {
    expect(CoreFlags.coreWrites, isFalse);
    expect(CoreFlags.download, isFalse);
  });

  test('legacy guard blocks by marker while flags default to false', () async {
    final probed = <String>[];
    LegacyWriteGuard.probeOverride = (domain) async {
      probed.add(domain);
      return true;
    };
    addTearDown(() => LegacyWriteGuard.probeOverride = null);

    await expectLater(
      LegacyWriteGuard.assertAllowed('channel'),
      throwsA(isA<LegacyWriteBlocked>()),
    );

    expect(probed, <String>['channel'],
        reason: 'the guard probes the domain marker even with coreWrites false');
  });
}
