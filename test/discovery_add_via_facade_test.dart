/// Post-wave06 bug fix: the Discovery page's add-to-library (入库) operations must
/// write through the core `AddedAppsFacade`, never through the legacy
/// `AppAggregatorManager` write path (which fails closed with
/// `LegacyWriteBlocked(catalog)` once the Rust core owns `catalog`).
///
/// User report (verbatim): "点击添加入库 提示 LegacyWriteBlocked(catalog)
/// CODE_E_WRITE_BLOCKED".
///
/// The facade is the routing seam: `CoreFlags.catalog == true` → the core
/// backend, `false` → the legacy backend. These tests inject both seams
/// (`AddedAppsFacade.backendOverride` / `legacyBackendOverride`) and arm the
/// real `LegacyWriteGuard` to prove the add-to-home tap no longer touches the
/// guarded legacy writer.
///
/// NOTE: `CoreFlags` keeps a process-wide serialized future (`_queue`). Its
/// completion microtask is bound to the zone that created it, and every
/// `testWidgets` body runs in its own FakeAsync zone — so every `CoreFlags`
/// touch here runs inside `tester.runAsync` (the real zone), which IS shared
/// across tests. Mixing zones deadlocks the next test's `CoreFlags.refresh()`.
/// The dialog-driven `setTags` case lives in
/// `discovery_settags_via_facade_test.dart` (a single FakeAsync test).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';
import 'package:gstore/page/home/tab/discovery/logic.dart';

import 'support/discovery_facade_seams.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  (ProviderContainer, DiscoveryNotifier) makeContainer() {
    final notifier = DiscoveryNotifier();
    final container = ProviderContainer(overrides: [
      discoveryProvider.overrideWith(() => notifier),
    ]);
    container.read(discoveryProvider);
    return (container, notifier);
  }

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

  /// Captures a mounted [BuildContext] then unmounts it, so the fire-and-forget
  /// tag sheet is skipped and the test exercises only the write call.
  Future<BuildContext> unmountedContext(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }));
    await tester.pumpWidget(const SizedBox());
    return ctx;
  }

  /// Builds the flag + provider container on the REAL event loop (see the
  /// library doc-comment: every `CoreFlags` touch must share one zone). When
  /// [load] is set the initial `loadData` also runs there.
  Future<(ProviderContainer, DiscoveryNotifier)> boot(
    WidgetTester tester, {
    required bool catalog,
    bool load = false,
  }) async {
    late ProviderContainer container;
    late DiscoveryNotifier notifier;
    await tester.runAsync(() async {
      await setCatalogFlag(catalog: catalog);
      final made = makeContainer();
      container = made.$1;
      notifier = made.$2;
      container.listen(discoveryProvider, (_, __) {});
      if (load) {
        await notifier.loadData();
      }
    });
    addTearDown(container.dispose);
    return (container, notifier);
  }

  group('catalog ON: add-to-library goes through the core facade', () {
    testWidgets(
        '(a) add-to-home writes through the facade, succeeds, and does NOT '
        'throw LegacyWriteBlocked even with the legacy guard armed',
        (tester) async {
      final core = RecordingAddedApps('core');
      final legacy = RecordingAddedApps('legacy');
      AddedAppsFacade.backendOverride = core;
      AddedAppsFacade.legacyBackendOverride = legacy;

      // Arm the legacy catalog guard: the OLD path (`_aggregator.toggleApp`)
      // would now throw. The facade core path must not consult it.
      LegacyWriteGuard.probeOverride = (domain) async => domain == 'catalog';
      await expectLater(
        LegacyWriteGuard.assertAllowed('catalog'),
        throwsA(isA<LegacyWriteBlocked>()),
        reason: 'precondition: the legacy catalog guard is armed',
      );

      ChannelManager.instance
          .registerChannel(FakeEnumChannel(ChannelType.fdroid, const []));
      final agg = RecordingAggregate();
      ModuleManager.instance.bindByType(IAggregateService, agg);
      addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

      final (_, notifier) = await boot(tester, catalog: true);
      final ctx = await unmountedContext(tester);

      // Must complete without throwing LegacyWriteBlocked.
      await tester.runAsync(() => notifier.toggleApp(ctx, 'fdroid', sampleApp));

      expect(core.toggleCalls, contains(('fdroid', sampleApp.appId)),
          reason: 'the add must run through the facade core backend');
      expect(legacy.toggleCalls, isEmpty,
          reason: 'flag on must not touch the legacy backend');
      expect(agg.writeCalls, isEmpty,
          reason: 'the write must not go through the legacy aggregate writer');
      expect(core.notifyCalls, greaterThan(0),
          reason: 'a successful write must call notifyAppsChanged()');
    });

    testWidgets('(d) refresh hooks run after a successful add',
        (tester) async {
      final core = RecordingAddedApps('core');
      AddedAppsFacade.backendOverride = core;

      final channel = FakeEnumChannel(ChannelType.fdroid, const [sampleApp]);
      ChannelManager.instance.registerChannel(channel);
      final agg = RecordingAggregate();
      ModuleManager.instance.bindByType(IAggregateService, agg);
      addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

      final (_, notifier) = await boot(tester, catalog: true, load: true);

      // Bind the refreshed index only AFTER the initial load settles, so only
      // the write's _updateAddedAppsIndex observes it.
      final indexCallsBefore = agg.indexCalls;
      final refreshCallsBefore = channel.getAllAppsCalls;
      agg.index = {
        'fdroid': {'com.added'},
      };

      final ctx = await unmountedContext(tester);
      await tester.runAsync(() => notifier.toggleApp(ctx, 'fdroid', sampleApp));

      expect(channel.getAllAppsCalls, greaterThan(refreshCallsBefore),
          reason: '_refreshChannelApps must re-read the channel after the write');
      expect(agg.indexCalls, greaterThan(indexCallsBefore),
          reason: '_updateAddedAppsIndex must run after the write');
      expect(notifier.state.addedAppsIndex['fdroid'], contains('com.added'),
          reason: 'the refreshed index must be applied to state');
      expect(core.notifyCalls, greaterThan(0),
          reason: 'notifyAppsChanged() must run after the write');
    });

    testWidgets('(c2) batch addAllFromChannel adds each app through the facade',
        (tester) async {
      final core = RecordingAddedApps('core');
      AddedAppsFacade.backendOverride = core;

      const appA = AppSummary(
        appId: 'com.a',
        name: 'A',
        user: '',
        repositories: '',
        icon: '',
        des: '',
      );
      const appB = AppSummary(
        appId: 'com.b',
        name: 'B',
        user: '',
        repositories: '',
        icon: '',
        des: '',
      );
      ChannelManager.instance.registerChannel(
          FakeEnumChannel(ChannelType.fdroid, const [appA, appB]));
      final agg = RecordingAggregate();
      ModuleManager.instance.bindByType(IAggregateService, agg);
      addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

      final (_, notifier) = await boot(tester, catalog: true, load: true);
      await tester.runAsync(() => notifier.addAllFromChannel('fdroid'));

      expect(core.addCalls,
          containsAll([('fdroid', 'com.a'), ('fdroid', 'com.b')]),
          reason: 'batch add must add each app through the facade');
      expect(core.notifyCalls, greaterThan(0),
          reason: 'a batch add must call notifyAppsChanged()');
      expect(agg.writeCalls, isEmpty,
          reason: 'batch add must not go through the legacy aggregate writer');
    });

    testWidgets('(c3) clearChannel clears through the facade', (tester) async {
      final core = RecordingAddedApps('core');
      AddedAppsFacade.backendOverride = core;

      ChannelManager.instance
          .registerChannel(FakeEnumChannel(ChannelType.fdroid, const []));
      final agg = RecordingAggregate();
      ModuleManager.instance.bindByType(IAggregateService, agg);
      addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

      final (_, notifier) = await boot(tester, catalog: true);
      await tester.runAsync(() => notifier.clearChannel('fdroid'));

      expect(core.clearCalls, contains('fdroid'),
          reason: 'clearChannel must run through the facade core backend');
      expect(core.notifyCalls, greaterThan(0),
          reason: 'a clear must call notifyAppsChanged()');
      expect(agg.writeCalls, isEmpty,
          reason: 'clearChannel must not go through the legacy aggregate writer');
    });
  });

  group('catalog OFF: no regression, the legacy backend still runs', () {
    testWidgets('(b) add-to-home works via the legacy backend',
        (tester) async {
      final core = RecordingAddedApps('core');
      final legacy = RecordingAddedApps('legacy');
      AddedAppsFacade.backendOverride = core;
      AddedAppsFacade.legacyBackendOverride = legacy;

      ChannelManager.instance
          .registerChannel(FakeEnumChannel(ChannelType.fdroid, const []));
      final agg = RecordingAggregate();
      ModuleManager.instance.bindByType(IAggregateService, agg);
      addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

      final (_, notifier) = await boot(tester, catalog: false);
      final ctx = await unmountedContext(tester);
      await tester.runAsync(() => notifier.toggleApp(ctx, 'fdroid', sampleApp));

      expect(legacy.toggleCalls, contains(('fdroid', sampleApp.appId)),
          reason: 'flag off must route the add through the legacy backend');
      expect(core.toggleCalls, isEmpty,
          reason: 'flag off must not touch the core backend');
      expect(legacy.notifyCalls, greaterThan(0),
          reason: 'flag off must still announce the change');
    });
  });
}
