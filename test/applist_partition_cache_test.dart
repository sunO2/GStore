/// Guards the home-page partition caches (`recentApps` / `updatableApps`).
///
/// Both getters used to re-copy + re-sort the whole `state.apps` list on every
/// rebuild, which runs on every scroll frame. They are now memoised by the
/// identity of `state.apps` (and `state.updateStates` for `updatableApps`).
///
/// The dangerous failure mode of such a cache is silent staleness: after new
/// rows load, the "recently added" row would keep showing the old list. This
/// test pins both halves by driving the notifier through its real load path
/// (facade-backed `loadAggregatedApps`) and then checking that the cache is
/// reused, and that it is dropped when `apps` / `updateStates` are replaced.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/home/tab/applist/logic.dart';

import 'support/added_apps_read_seams.dart';
import 'support/discovery_facade_seams.dart';

List<String> _ids(List<AggregatedAppInfo> apps) =>
    apps.map((a) => a.appInfo.appId).toList();

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
    ModuleManager.instance.unbindByType(IAggregateService);
  });

  Future<(ApplistNotifier, ProviderContainer)> boot(
    WidgetTester tester, {
    required Map<String, Set<String>> added,
    required List<AppSummary> channelApps,
  }) async {
    final core = FakeAddedApps('core')..added.addAll(added);
    AddedAppsFacade.backendOverride = core;
    ChannelManager.instance
        .registerChannel(FakeEnumChannel(ChannelType.github, channelApps));
    AppAggregatorManager.instance.debugChannelManager = ChannelManager.instance;
    ModuleManager.instance
        .bindByType(IAggregateService, RecordingAggregate());

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
    return (notifier, container);
  }

  AppSummary summary(String appId) => AppSummary(
        appId: appId,
        name: appId,
        user: '',
        repositories: '',
        icon: '',
        des: '',
      );

  testWidgets('recentApps caches by apps identity and invalidates on reload',
      (tester) async {
    final (notifier, _) = await boot(
      tester,
      added: {
        'github': {'a', 'b', 'c'},
      },
      channelApps: [summary('a'), summary('b'), summary('c')],
    );

    final first = notifier.recentApps();
    final second = notifier.recentApps();
    expect(identical(first, second), isTrue,
        reason: 'stable state.apps must not be re-copied and re-sorted');
  });

  testWidgets('recentApps recomputes after the list is reloaded',
      (tester) async {
    final (notifier, container) = await boot(
      tester,
      added: {
        'github': {'a'},
      },
      channelApps: [summary('a')],
    );
    expect(_ids(notifier.recentApps()), ['a']);

    // Reload with one more row: `state.apps` is replaced wholesale.
    final core = FakeAddedApps('core..')..added['github'] = {'a', 'z'};
    AddedAppsFacade.backendOverride = core;
    await tester.runAsync(() async {
      container.read(applistProvider.notifier).loadAggregatedApps();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    final ids = _ids(notifier.recentApps());
    expect(ids.toSet(), containsAll(<String>{'a', 'z'}),
        reason: 'a new apps instance must drop the cached partition');
  });

  testWidgets('recentApps honours a different count on the same instance',
      (tester) async {
    final (notifier, _) = await boot(
      tester,
      added: {
        'github': {'a', 'b', 'c'},
      },
      channelApps: [summary('a'), summary('b'), summary('c')],
    );

    expect(notifier.recentApps(count: 2), hasLength(2));
    expect(notifier.recentApps(count: 3), hasLength(3),
        reason: 'count is part of the cache key');
  });

  testWidgets('updatableApps is cached and keyed on updateStates',
      (tester) async {
    final (notifier, _) = await boot(
      tester,
      added: {
        'github': {'a', 'b'},
      },
      channelApps: [summary('a'), summary('b')],
    );

    final first = notifier.updatableApps;
    final second = notifier.updatableApps;
    expect(identical(first, second), isTrue,
        reason: 'stable apps + updateStates must hit the cache');
    expect(first, isEmpty, reason: 'no update states seeded yet');
  });
}
