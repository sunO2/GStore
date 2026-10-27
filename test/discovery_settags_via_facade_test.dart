/// Post-wave06 bug fix (tag-save leg): the discovery page's tag picker
/// (`showTagPickerForApp` → `setTags`) must write through the core
/// `AddedAppsFacade`, not the legacy `AppAggregatorManager` write path.
///
/// This is a SINGLE `testWidgets`: the tag picker needs a pumped dialog
/// (FakeAsync), and `CoreFlags`' process-wide serialized future is bound to the
/// zone that created it, so a second FakeAsync test would deadlock the next
/// `CoreFlags.refresh()`. See `discovery_add_via_facade_test.dart` for the
/// runAsync-based cases.
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
    AddedAppsFacade.legacyBackendOverride = null;
    for (final type in ChannelType.values) {
      if (ChannelManager.instance.getChannel(type) != null) {
        ChannelManager.instance.unregisterChannel(type);
      }
    }
    ModuleManager.instance.unbind<ChannelManager>();
  });

  testWidgets('(c1) setTags writes through the facade core backend',
      (tester) async {
    final core = RecordingAddedApps('core');
    AddedAppsFacade.backendOverride = core;

    ChannelManager.instance
        .registerChannel(FakeEnumChannel(ChannelType.fdroid, const []));
    final agg = RecordingAggregate();
    ModuleManager.instance.bindByType(IAggregateService, agg);
    addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

    // Container on the real loop (avoids the autoDispose FakeAsync timer);
    // the flag + the write stay in this test's FakeAsync zone.
    late DiscoveryNotifier notifier;
    late ProviderContainer container;
    await tester.runAsync(() async {
      final made = makeContainer();
      container = made.$1;
      notifier = made.$2;
      container.listen(discoveryProvider, (_, __) {});
    });
    addTearDown(container.dispose);

    await setCatalogFlag(catalog: true);

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const Scaffold(body: SizedBox());
      }),
    ));

    // Confirm the picker with no tags selected → setTags([]) via the facade.
    final picker = notifier.showTagPickerForApp(ctx, 'fdroid', sampleApp);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await picker;

    expect(core.setTagsCalls, isNotEmpty,
        reason: 'setTags must run through the facade core backend');
    expect(core.setTagsCalls.single.$1, 'fdroid');
    expect(core.setTagsCalls.single.$2, sampleApp.appId,
        reason: 'the canonical appId must be used');
    expect(core.notifyCalls, greaterThan(0),
        reason: 'a tag change must call notifyAppsChanged()');
    expect(agg.writeCalls, isEmpty,
        reason: 'setTags must not go through the legacy aggregate writer');
  });
}
