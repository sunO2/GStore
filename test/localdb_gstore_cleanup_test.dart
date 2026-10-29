/// `LocalDbGStoreCleanup` — one-time removal of the catalog-polluted `gstore`
/// membership produced by the broken `local_db` → `gstore` migration.
///
/// Pins the contract:
/// * the legit set comes from the pre-migration backup (injectable seam) and
///   every `gstore` app not in it is removed;
/// * confirm removes only the bogus rows (membership + tags + channel_apps) and
///   keeps the legit ones;
/// * cancel removes nothing but still writes the marker (never re-ask);
/// * the marker makes the pass idempotent.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/service/localdb_gstore_cleanup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/added_apps_read_seams.dart';
import 'support/discovery_facade_seams.dart' show FakeFlagsBackend;
import 'support/library_api_seam.dart';

class _FakeLegitSetReader implements LocalDbGStoreLegitSetReader {
  _FakeLegitSetReader(this.legit);

  final Set<String> legit;
  final List<String> calls = [];

  @override
  Future<Set<String>> readLegitAppIds({required String dataDir}) async {
    calls.add(dataDir);
    return legit;
  }
}

class _FakeCleanupUi implements LocalDbGStoreCleanupUi {
  _FakeCleanupUi({this.confirmResult = true});

  bool confirmResult;
  final List<int> confirmCounts = [];
  final List<int> progressStarts = [];
  final List<int> progressUpdates = [];
  int endProgressCalls = 0;

  @override
  Future<bool> confirmRemove(int count) async {
    confirmCounts.add(count);
    return confirmResult;
  }

  @override
  void beginProgress(int total) => progressStarts.add(total);

  @override
  void updateProgress(int done) => progressUpdates.add(done);

  @override
  void endProgress() => endProgressCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryAddedAppsBackend added;
  late FakeChannelApiBackend channels;
  late _FakeLegitSetReader reader;
  late _FakeCleanupUi ui;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    added = InMemoryAddedAppsBackend();
    added.seed('gstore', 'legit1');
    added.seed('gstore', 'bogus1');
    added.seed('gstore', 'bogus2');
    added.seedTag('gstore', 'legit1', 'keep');
    added.seedTag('gstore', 'bogus1', 'bad');
    added.seedTag('gstore', 'bogus2', 'bad');
    // Legacy channel data must be untouched by the cleanup.
    added.seed('local_db', 'legacy1');
    added.seedTag('local_db', 'legacy1', 'old');
    AddedAppsFacade.backendOverride = added;

    channels = FakeChannelApiBackend(FakeLibraryApi());
    RustChannelFacade.installBackend(channels);

    reader = _FakeLegitSetReader(<String>{'legit1'});
    ui = _FakeCleanupUi();
  });

  tearDown(() {
    CoreFlags.resetBackend();
    AddedAppsFacade.backendOverride = null;
    RustChannelFacade.resetBackend();
  });

  test('confirm removes only apps outside the legit set', () async {
    CoreFlags.installBackend(
      FakeFlagsBackend(const CoreFlagsSnapshot(channels: true)),
    );
    await CoreFlags.refresh();

    final report = await LocalDbGStoreCleanup.run(
      dataDir: '/tmp/data',
      reader: reader,
      ui: ui,
    );

    expect(report.removed, 2);
    expect(report.kept, 1);
    expect(report.failed, 0);
    expect(report.cancelled, isFalse);
    expect(reader.calls, ['/tmp/data']);
    expect(ui.confirmCounts, [2]);

    // Only bogus rows lost their membership; the legit row survives.
    final gstore = await added.listChannel('gstore');
    expect(gstore.map((a) => a.appId).toList(), ['legit1']);
    expect(await added.tags('gstore', 'legit1'), ['keep']);

    // Tags cleared for exactly the bogus rows.
    expect(await added.tags('gstore', 'bogus1'), isEmpty);
    expect(await added.tags('gstore', 'bogus2'), isEmpty);

    // channel_apps('gstore') removed exactly for the bogus rows.
    expect(channels.removeAppCalls.toSet(), {
      ('gstore', 'bogus1'),
      ('gstore', 'bogus2'),
    });

    // legacy channel untouched.
    expect((await added.listChannel('local_db')).map((a) => a.appId), ['legacy1']);
    expect(await added.tags('local_db', 'legacy1'), ['old']);

    // Determinate progress ran to completion.
    expect(ui.progressStarts, [2]);
    expect(ui.progressUpdates, [1, 2]);
    expect(ui.endProgressCalls, 1);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(LocalDbGStoreCleanup.markerKey), '1');
  });

  test('cancel removes nothing and writes the marker (never re-ask)', () async {
    CoreFlags.installBackend(
      FakeFlagsBackend(const CoreFlagsSnapshot(channels: true)),
    );
    await CoreFlags.refresh();
    ui.confirmResult = false;

    final report = await LocalDbGStoreCleanup.run(
      dataDir: '/tmp/data',
      reader: reader,
      ui: ui,
    );

    expect(report.cancelled, isTrue);
    expect(report.removed, 0);
    expect(report.kept, 1);
    expect(ui.confirmCounts, [2]);
    expect(ui.progressStarts, isEmpty);
    expect(ui.endProgressCalls, 0);

    final gstore = await added.listChannel('gstore');
    expect(gstore.map((a) => a.appId).toSet(), {'legit1', 'bogus1', 'bogus2'});
    expect(channels.removeAppCalls, isEmpty);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(LocalDbGStoreCleanup.markerKey), '1');
  });

  test('idempotent: marker skips every later pass', () async {
    CoreFlags.installBackend(
      FakeFlagsBackend(const CoreFlagsSnapshot(channels: true)),
    );
    await CoreFlags.refresh();

    await LocalDbGStoreCleanup.run(
      dataDir: '/tmp/data',
      reader: reader,
      ui: ui,
    );
    final second = await LocalDbGStoreCleanup.run(
      dataDir: '/tmp/data',
      reader: reader,
      ui: ui,
    );

    expect(second.alreadyDone, isTrue);
    expect(second.removed, 0);
    expect(ui.confirmCounts, [2]);
    expect(channels.removeAppCalls, hasLength(2));
  });

  test('no backup => legit set empty => every gstore row is a candidate',
      () async {
    CoreFlags.installBackend(
      FakeFlagsBackend(const CoreFlagsSnapshot(channels: true)),
    );
    await CoreFlags.refresh();
    reader = _FakeLegitSetReader(<String>{});

    final report = await LocalDbGStoreCleanup.run(
      dataDir: '/tmp/data',
      reader: reader,
      ui: ui,
    );

    expect(report.removed, 3);
    expect(report.kept, 0);
    expect(await added.listChannel('gstore'), isEmpty);
    // local_db is never a target.
    expect((await added.listChannel('local_db')).length, 1);
  });
}
