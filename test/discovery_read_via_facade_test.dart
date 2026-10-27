/// Post-wave06 bug fix (READ leg): the Discovery page's added-app READS must go
/// through the core `AddedAppsFacade`, mirroring the WRITES that already do
/// (commit a9db3965).
///
/// User report (verbatim): "发现页点击图标 弹出分类sheet，选择后确认，没有看到已入库
/// 角标，并且再次点击会提示，已从首页移除提示，不仅仅是js渠道 所有渠道都是".
///
/// Root cause: the write path was moved to the facade (which routes by
/// `CoreFlags.catalog`), but `_updateAddedAppsIndex` / `getTags` / `isAppAdded` /
/// `removeApp` still read the LEGACY `IAggregateService`. With the flag on the
/// row lands in the core, so the legacy read never sees it → no badge; a second
/// tap then says "已从首页移除". Being a read/write split, EVERY channel is hit.
///
/// These tests inject both facade seams and prove: (a) a catalog-ON add yields
/// the badge index, (b) the same for a NON-js channel, (c) catalog-OFF still
/// routes index/tags/isAdded/remove to the legacy backend, and (d) the remove
/// path uses the facade.
///
/// NOTE (zone): `CoreFlags` keeps a process-wide serialized future bound to the
/// zone that created it, and every `testWidgets` body is its own FakeAsync zone,
/// so every `CoreFlags` touch runs inside `tester.runAsync` (the shared real
/// zone). See `discovery_add_via_facade_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
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
    AddedAppsFacade.backendOverride = null;
    for (final type in ChannelType.values) {
      if (ChannelManager.instance.getChannel(type) != null) {
        ChannelManager.instance.unregisterChannel(type);
      }
    }
    ModuleManager.instance.unbind<ChannelManager>();
  });

  /// Captures a mounted [BuildContext] then unmounts it, so the fire-and-forget
  /// tag sheet is skipped and the test exercises only the read/write call.
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

  group('catalog ON: added-app reads go through the core facade', () {
    testWidgets(
        '(a) adding an app makes the badge index contain it WITHOUT re-entering '
        'the page (the index is rebuilt from the facade, not the legacy manager)',
        (tester) async {
      final core = RecordingAddedApps('core');
      AddedAppsFacade.backendOverride = core;

      ChannelManager.instance
          .registerChannel(FakeEnumChannel(ChannelType.fdroid, const [sampleApp]));
      final agg = RecordingAggregate();
      ModuleManager.instance.bindByType(IAggregateService, agg);
      addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

      final (_, notifier) = await boot(tester, catalog: true, load: true);
      expect(notifier.state.addedAppsIndex['fdroid'] ?? const <String>{},
          isEmpty,
          reason: 'precondition: nothing is added yet');

      final ctx = await unmountedContext(tester);
      await tester.runAsync(() => notifier.toggleApp(ctx, 'fdroid', sampleApp));

      expect(notifier.state.addedAppsIndex['fdroid'], contains(sampleApp.appId),
          reason: 'the badge index must reflect the core write');
      expect(core.listCalls, greaterThan(0),
          reason: 'the index must be rebuilt from AddedAppsFacade.list()');
      expect(agg.indexCalls, 0,
          reason: 'the read must not go through the legacy aggregate service');
    });

    testWidgets(
        '(b) the badge index also reflects a NON-js channel add (the user\'s '
        '"所有渠道" point)', (tester) async {
      final core = RecordingAddedApps('core');
      AddedAppsFacade.backendOverride = core;

      // 'github' is an enum (non-js) channel: the bug was never js-specific.
      ChannelManager.instance
          .registerChannel(FakeEnumChannel(ChannelType.github, const [sampleApp]));
      final agg = RecordingAggregate();
      ModuleManager.instance.bindByType(IAggregateService, agg);
      addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

      final (_, notifier) = await boot(tester, catalog: true, load: true);

      final ctx = await unmountedContext(tester);
      await tester.runAsync(() => notifier.toggleApp(ctx, 'github', sampleApp));

      expect(notifier.state.addedAppsIndex['github'], contains(sampleApp.appId),
          reason: 'a non-js channel add must also show the badge');
      expect(core.listCalls, greaterThan(0));
      expect(agg.indexCalls, 0);
    });

    testWidgets('(d) the remove path reads and removes through the facade',
        (tester) async {
      final core = RecordingAddedApps('core')..added['fdroid'] = {'com.added'};
      AddedAppsFacade.backendOverride = core;

      ChannelManager.instance
          .registerChannel(FakeEnumChannel(ChannelType.fdroid, const [sampleApp]));
      final agg = RecordingAggregate();
      ModuleManager.instance.bindByType(IAggregateService, agg);
      addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

      final (_, notifier) = await boot(tester, catalog: true);

      await tester
          .runAsync(() => notifier.removeFromChannel('fdroid', 'com.added'));

      expect(core.isAddedCalls, contains(('fdroid', 'com.added')),
          reason: 'the remove path must read isAdded through the facade');
      expect(core.removeCalls, contains(('fdroid', 'com.added')),
          reason: 'the remove path must remove through the facade');
      expect(agg.writeCalls, isEmpty,
          reason: 'the remove path must not touch the legacy aggregate writer');
    });
  });
}
