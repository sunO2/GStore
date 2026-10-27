/// Post-wave06 bug fix (READ leg): the last two legacy added-apps readers — the
/// HOME app list and the DETAIL tag panel — must read (and the detail panel must
/// write) through the core `AddedAppsFacade`, mirroring the discovery page
/// (`a9db3965`, `c3fbd9e3`).
///
/// Design (Oracle Option C): the facade routes rows+tags by `CoreFlags.catalog`
/// and delegates the metadata join to a now-PURE
/// `AppAggregatorManager.aggregateWithMeta(rows, tagsIndex: …)` that reads no
/// catalog DB and never calls back into the facade — so there is no
/// manager→facade edge and no recursion at any flag value.
///
/// This file covers the non-render cases: (1) flag on sources the aggregated
/// read from the core backend with the legacy lane never reached (no recursion /
/// no hang); (2) flag off still routes to the legacy backend and the join runs;
/// (3) the legacy `LegacyWriteGuard` still fails closed while the facade core
/// write does not; (4) a core-path `notifyAppsChanged()` pokes
/// `AppAggregatorManager.appsChangedStream`. The HOME render case lives in
/// `applist_reads_via_facade_test.dart` and the DETAIL tag case in
/// `detail_tags_via_facade_test.dart` — each in its own isolate, because a
/// rendered `ApplistPage` leaves a live binding and because a real-zone
/// `test(...)` before a FakeAsync `testWidgets` would deadlock the shared
/// `CoreFlags` queue.
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
    AddedAppsFacade.legacyBackendOverride = null;
    for (final type in ChannelType.values) {
      if (ChannelManager.instance.getChannel(type) != null) {
        ChannelManager.instance.unregisterChannel(type);
      }
    }
    ModuleManager.instance.unbind<ChannelManager>();
  });

  group('catalog ON: aggregated read goes through the core facade (no recursion)',
      () {
    test(
        '(recursion) getAggregatedAppsPage sources rows+tags from the core '
        'backend and NEVER reaches the legacy lane (returns, no hang)', () async {
      final core = FakeAddedApps('core')..added['fdroid'] = {'com.added'};
      final legacy = ThrowingAddedApps();
      AddedAppsFacade.backendOverride = core;
      AddedAppsFacade.legacyBackendOverride = legacy;

      ChannelManager.instance.registerChannel(
          FakeEnumChannel(ChannelType.fdroid, const [sampleApp]));
      // The pure join resolves channel details through the manager's channel
      // manager (channel domain, flag-independent).
      AppAggregatorManager.instance.debugChannelManager = ChannelManager.instance;

      await setCatalogFlag(catalog: true);

      final (apps, total) = await AddedAppsFacade.instance
          .getAggregatedAppsPage(offset: 0, limit: 20);

      expect(total, 1, reason: 'total is the core backend row count');
      expect(apps, hasLength(1), reason: 'the row must be joined and returned');
      expect(apps.single.addedAppInfo.channelId, 'fdroid');
      expect(apps.single.addedAppInfo.appId, 'com.added');
      expect(core.listCalls, greaterThan(0),
          reason: 'rows must come from the core backend');
      expect(core.tagsIndexCalls, greaterThan(0),
          reason: 'tags must come from the core backend');
      expect(legacy.calls, isEmpty,
          reason: 'flag on must never reach the legacy backend (no recursion, '
              'no legacy DB read) — a touched legacy member would throw');
    });

    test('(guard) legacy manager write still fails closed, facade core write does not',
        () async {
      LegacyWriteGuard.probeOverride = (domain) async => domain == 'catalog';
      await expectLater(
        AppAggregatorManager.instance
            .setTags(channelCode: 'fdroid', appId: 'x', tags: const ['t']),
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

  group('catalog OFF: aggregated read still uses the legacy backend', () {
    test(
        '(parity) getAggregatedAppsPage sources rows+tags from the legacy '
        'backend, runs the join, and never touches core', () async {
      final core = ThrowingAddedApps();
      final legacy = FakeAddedApps('legacy')..added['fdroid'] = {'com.legacy'};
      legacy.tagsByApp['fdroid:com.legacy'] = ['工具'];
      AddedAppsFacade.backendOverride = core;
      AddedAppsFacade.legacyBackendOverride = legacy;

      ChannelManager.instance.registerChannel(
          FakeEnumChannel(ChannelType.fdroid, const [sampleApp]));
      AppAggregatorManager.instance.debugChannelManager = ChannelManager.instance;

      await setCatalogFlag(catalog: false);

      final (apps, total) = await AddedAppsFacade.instance
          .getAggregatedAppsPage(offset: 0, limit: 20);

      expect(total, 1);
      expect(apps.single.addedAppInfo.appId, 'com.legacy');
      expect(apps.single.appInfo.category, contains('工具'),
          reason: 'the join must have run (tagsIndex merged into category)');
      expect(legacy.listCalls, greaterThan(0));
      expect(legacy.tagsIndexCalls, greaterThan(0));
      expect(core.calls, isEmpty,
          reason: 'flag off must never reach the core backend');
    });
  });

  group('refresh bridge', () {
    test(
        '(bridge) a core-path notifyAppsChanged() pokes the manager '
        'appsChangedStream', () async {
      // No real DB: the manager only needs `addedAppDao.getAllApps()` to poke its
      // stream, and a fake keeps the test off the sqflite FFI isolate path.
      AppAggregatorManager.instance.debugDatabase =
          FakeManagerDatabase(const <AddedAppInfo>[]);

      final core = FakeAddedApps('core');
      AddedAppsFacade.backendOverride = core;
      await setCatalogFlag(catalog: true);

      final emitted = <List<AddedAppInfo>>[];
      final sub =
          AppAggregatorManager.instance.appsChangedStream.listen(emitted.add);
      addTearDown(sub.cancel);

      await AddedAppsFacade.instance.notifyAppsChanged();
      // The poked stream reads the manager DB asynchronously before emitting.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(core.notifyCalls, greaterThan(0),
          reason: 'the backend notify must still run');
      expect(emitted, isNotEmpty,
          reason: 'the refresh bridge must poke the manager appsChangedStream '
              'so the home list reloads');
    });
  });
}
