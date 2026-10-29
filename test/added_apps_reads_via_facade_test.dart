/// Post-wave06 bug fix (READ leg): the last two legacy added-apps readers — the
/// HOME app list and the DETAIL tag panel — must read (and the detail panel must
/// write) through the core `AddedAppsFacade`, mirroring the discovery page
/// (`a9db3965`, `c3fbd9e3`).
///
/// The facade is now core-only (the legacy Dart store was deleted) and delegates
/// the metadata join to a PURE
/// `AppAggregatorManager.aggregateWithMeta(rows, tagsIndex: …)` that reads no
/// catalog DB and never calls back into the facade — so there is no
/// manager→facade edge and no recursion.
///
/// This file covers the non-render cases: (1) the aggregated read is sourced
/// from the core backend (no recursion / no hang); (2) the legacy
/// `LegacyWriteGuard` still fails closed while the facade core write does not;
/// (3) a core-path `notifyAppsChanged()` pokes
/// `AppAggregatorManager.appsChangedStream`. The HOME render case lives in
/// `applist_reads_via_facade_test.dart` and the DETAIL tag case in
/// `detail_tags_via_facade_test.dart` — each in its own isolate.
///
/// NOTE (zone): these are all plain `test(...)` cases on the real loop; they
/// share one `CoreFlags` zone and always settle the queue.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

import 'support/added_apps_read_seams.dart';
import 'support/discovery_facade_seams.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    LegacyWriteGuard.resetForTest();
    AddedAppsFacade.backendOverride = null;
    for (final type in ChannelType.values) {
      if (ChannelManager.instance.getChannel(type) != null) {
        ChannelManager.instance.unregisterChannel(type);
      }
    }
    ModuleManager.instance.unbind<ChannelManager>();
  });

  group('aggregated read goes through the core facade (no recursion)', () {
    test(
        '(recursion) getAggregatedAppsPage sources rows+tags from the core '
        'backend and returns (no hang)', () async {
      final core = FakeAddedApps('core')..added['fdroid'] = {'com.added'};
      AddedAppsFacade.backendOverride = core;

      ChannelManager.instance.registerChannel(
          FakeEnumChannel(ChannelType.fdroid, const [sampleApp]));
      // The pure join resolves channel details through the manager's channel
      // manager (channel domain, flag-independent).
      AppAggregatorManager.instance.debugChannelManager = ChannelManager.instance;

      await setCatalogFlag(catalog: true);

      final (apps, total) = await AddedAppsFacade.instance
          .getAggregatedAppsPage(offset: 0, limit: 20);

      expect(total, 1, reason: 'total is the Rust page row count');
      expect(apps, hasLength(1), reason: 'the page row must be returned');
      expect(apps.single.addedAppInfo.channelId, 'fdroid');
      expect(apps.single.addedAppInfo.appId, 'com.added');
      expect(core.pageCalls, greaterThan(0),
          reason: 'rows must come from LibraryApi.page');
      expect(core.tagsIndexCalls, 0,
          reason: 'tags are merged by Rust; Dart must not run the old join');
    });

    test('(guard) legacy writer guard still fails closed, facade core write does not',
        () async {
      LegacyWriteGuard.probeOverride = (domain) async => domain == 'catalog';
      await expectLater(
        LegacyWriteGuard.assertAllowed('catalog'),
        throwsA(isA<LegacyWriteBlocked>()),
        reason: 'the legacy writer guard must remain armed/fail-closed',
      );

      final core = FakeAddedApps('core');
      AddedAppsFacade.backendOverride = core;
      await setCatalogFlag(catalog: true);

      // Must complete without throwing LegacyWriteBlocked.
      await AddedAppsFacade.instance.setTags('fdroid', 'x', const ['t']);
      await AddedAppsFacade.instance.notifyAppsChanged();

      expect(core.setTagsCalls, hasLength(1),
          reason: 'the facade core write must run through the core backend');
      expect(core.setTagsCalls.single.$1, 'fdroid');
      expect(core.setTagsCalls.single.$2, 'x');
      expect(core.setTagsCalls.single.$3, const ['t']);
    });
  });

  group('refresh bridge', () {
    test(
        '(bridge) a core-path notifyAppsChanged() pokes the manager '
        'appsChangedStream', () async {
      final core = FakeAddedApps('core');
      AddedAppsFacade.backendOverride = core;
      await setCatalogFlag(catalog: true);

      final emitted = <List<AddedAppInfo>>[];
      final sub =
          AppAggregatorManager.instance.appsChangedStream.listen(emitted.add);
      addTearDown(sub.cancel);

      await AddedAppsFacade.instance.notifyAppsChanged();
      // The manager stream is a broadcast controller: delivery is a microtask.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(core.notifyCalls, greaterThan(0),
          reason: 'the backend notify must still run');
      expect(emitted, isNotEmpty,
          reason: 'the refresh bridge must poke the manager appsChangedStream '
              'so the home list reloads');
    });
  });
}
