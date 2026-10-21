import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

/// Characterization of the pre-mirror CoreFlags contract. These assertions must
/// pass both before and after the read-only-mirror migration.
void main() {
  test('all flags default to false', () {
    expect(CoreFlags.coreWrites, isFalse);
    expect(CoreFlags.download, isFalse);
  });

  test('legacy guard consumers observe false by default', () async {
    var probed = false;
    LegacyWriteGuard.probeOverride = (domain) async {
      probed = true;
      return true;
    };
    addTearDown(() => LegacyWriteGuard.probeOverride = null);

    await LegacyWriteGuard.assertAllowed('channel');

    expect(probed, isFalse,
        reason: 'legacy write guard must be a no-op while coreWrites is false');
  });
}
