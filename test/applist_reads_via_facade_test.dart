/// Post-wave06 bug fix (READ leg, home): the HOME app list must source its rows
/// from the core `AddedAppsFacade`, not the legacy `AppAggregatorManager`
/// (`getAggregatedAppsPage` on the legacy DB). Mirrors
/// `discovery_read_via_facade_test.dart`.
///
/// This lives in its OWN file (its own test isolate): rendering `ApplistPage`
/// leaves a live widget/animation on the binding, which makes a following
/// `pumpAndSettle` in the same isolate never settle. Isolating the render keeps
/// the non-render cases (recursion / parity / guard / bridge / detail) in
/// `added_apps_reads_via_facade_test.dart` deterministic.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/home/tab/applist/logic.dart';
import 'package:gstore/page/home/tab/applist/view.dart';

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
    AddedAppsFacade.backendOverride = null;
    for (final type in ChannelType.values) {
      if (ChannelManager.instance.getChannel(type) != null) {
        ChannelManager.instance.unregisterChannel(type);
      }
    }
    ModuleManager.instance.unbind<ChannelManager>();
  });

  testWidgets(
      '(home) flag on: the list renders rows sourced from the facade core '
      'backend, not the legacy manager', (tester) async {
    final core = FakeAddedApps('core')..added['fdroid'] = {'com.added'};
    AddedAppsFacade.backendOverride = core;

    ChannelManager.instance.registerChannel(
        FakeEnumChannel(ChannelType.fdroid, const [sampleApp]));
    // The pure join resolves channel details through the manager's channel
    // manager (channel domain, flag-independent).
    AppAggregatorManager.instance.debugChannelManager = ChannelManager.instance;

    final agg = RecordingAggregate();
    ModuleManager.instance.bindByType(IAggregateService, agg);
    addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

    late ApplistNotifier notifier;
    late ProviderContainer container;
    await tester.runAsync(() async {
      await setCatalogFlag(catalog: true);
      notifier = ApplistNotifier();
      container = ProviderContainer(overrides: [
        applistProvider.overrideWith(() => notifier),
      ]);
      container.read(applistProvider);
      container.listen(applistProvider, (_, __) {});
      await notifier.loadAggregatedApps();
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ApplistPage()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The row is rendered by the page (cache-path name falls back to appId).
    expect(find.text('com.added'), findsWidgets,
        reason: 'the home list must render the row sourced from the facade');
    expect(core.pageCalls, greaterThan(0),
        reason: 'rows must come from LibraryApi.page');
    expect(agg.writeCalls, isEmpty,
        reason: 'the home read must not go through the legacy aggregate '
            'service (getAggregatedAppsPage)');
  });
}
