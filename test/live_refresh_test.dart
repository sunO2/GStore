/// Plan-Todo 12 — the channel/catalog UI re-runs its **existing** loaders on the
/// live `channel.changed` / `catalog.changed` events, debounced.
///
/// The Rust core pushes the events (Todo 10); Dart maps them to typed [AppEvent]s
/// on [AppEventBus] (Todo 11). These tests drive a typed event through the bus
/// and assert the loader **actually re-ran** (call-count, not merely that a
/// listener exists), that a burst coalesces to ONE re-run, that the Rust pack
/// lane refreshes on `channel.changed`, and that the detail page re-fetches only
/// for its own app / a whole-channel change.
///
/// A debounce test (group `debounce`) is also selectable via
/// `--plain-name debounce` for the `12-debounce.txt` evidence.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/event/app_event.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/page/detail/logic.dart';
import 'package:gstore/page/detail/state.dart';
import 'package:gstore/page/home/tab/applist/logic.dart';
import 'package:gstore/page/home/tab/discovery/logic.dart';
import 'package:gstore/page/search/providers.dart';

import 'support/discovery_facade_seams.dart';

/// Longer than the 200ms debounce window, plus a delivery turn.
const Duration _pastDebounce = Duration(milliseconds: 300);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void _emitChannelChanged({String key = 'js_probe'}) {
  AppEventBus.instance.emit(
    AppEventTypes.channelChanged,
    source: AppEventSource.rust,
    data: {'key': key, 'kind': 'js_local'},
  );
}

void _emitCatalogChanged({String? key, String? appId}) {
  AppEventBus.instance.emit(
    AppEventTypes.catalogChanged,
    source: AppEventSource.rust,
    data: {'key': key, 'app_id': appId, 'removed': false},
  );
}

// ---------------------------------------------------------------------------
// Fakes / subclasses that COUNT the loader re-run (the misleading-success guard:
// a passing assertion proves the loader ran, not that a listener merely exists).
// ---------------------------------------------------------------------------

class _CountingApplist extends ApplistNotifier {
  int loads = 0;

  @override
  Future<void> loadAggregatedApps() async {
    loads++;
  }
}

class _CountingDiscovery extends DiscoveryNotifier {
  int loads = 0;

  @override
  Future<void> loadData() async {
    loads++;
  }
}

class _FakeLane extends RustScriptChannelLane {
  int refreshCalls = 0;

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }
}

class _RecordingCatalog implements CatalogBackend {
  int categoryCalls = 0;
  int searchCalls = 0;
  final Map<String, List<AppSummary>> categoryResults = {};
  final Map<String, List<AppSummary>> searchResults = {};

  @override
  Future<List<AppSummary>> byCategory(String categoryId) async {
    categoryCalls++;
    return categoryResults[categoryId] ?? const [];
  }

  @override
  Future<List<AppSummary>> search(String keyword) async {
    searchCalls++;
    return searchResults[keyword] ?? const [];
  }

  @override
  Future<List<AppSummary>> list() => throw UnsupportedError('not used');
  @override
  Future<CatalogPageData> listPage({required int offset, required int limit}) =>
      throw UnsupportedError('not used');
  @override
  Future<AppSummary?> getApp(String appId) => throw UnsupportedError('not used');
  @override
  Future<List<db.AppCategory>> categories() =>
      throw UnsupportedError('not used');
  @override
  Future<AppDetailInfo?> getAppDetail(String appId) =>
      throw UnsupportedError('not used');
  @override
  Future<CatalogRefreshOutcome> refresh(String url) =>
      throw UnsupportedError('not used');

  // 新增的版本仓库方法本文件未使用；由 noSuchMethod 兜底（否则接口新增成员会编译失败）。
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(
          'unused CatalogBackend member: ${invocation.memberName}');

}

class _CountingDetailChannel extends IDetailChannel {
  _CountingDetailChannel(this.appId);

  @override
  final String appId;

  int loads = 0;

  @override
  void bind(DetailState state, DetailCallbacks callbacks) {}

  @override
  Future<void> load() async {
    loads++;
  }

  @override
  List<DetailAction> getActions() => const [];

  @override
  Future<void> startDownload(DownloadInfo info) async {}

  @override
  Future<void> dispose() async {}
}

/// A registered Dart channel whose `getDetailChannel` returns the counting fake,
/// so `DetailLogic.start()` resolves it and re-fetch drives the same instance.
class _DetailStubChannel extends FakeEnumChannel {
  _DetailStubChannel(this.detailChannel)
      : super(ChannelType.github, const []);

  final IDetailChannel detailChannel;

  @override
  IDetailChannel? getDetailChannel(String appId) => detailChannel;
}

/// Disposes [container] once, so a test can dispose early (leak check) and the
/// tearDown remains safe.
ProviderContainer _container(List<Override> overrides) {
  final container = ProviderContainer(overrides: overrides);
  var disposed = false;
  addTearDown(() {
    if (!disposed) {
      disposed = true;
      container.dispose();
    }
  });
  // Expose an idempotent dispose to the test body via a closure captured below.
  _disposeRegistry[container] = () {
    if (disposed) return;
    disposed = true;
    container.dispose();
  };
  return container;
}

final Map<ProviderContainer, void Function()> _disposeRegistry = {};

void _disposeNow(ProviderContainer container) => _disposeRegistry[container]?.call();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AppEventBus.instance.resetGuards();
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
  });

  tearDown(() async {
    RustScriptChannelLane.resetForTest();
    AppEventBus.instance.resetGuards();
    await ModuleManager.instance.clear();
  });

  group('applist', () {
    test('re-runs loadAggregatedApps on channel.changed / catalog.changed',
        () async {
      final notifier = _CountingApplist();
      final container = _container([
        applistProvider.overrideWith(() => notifier),
      ]);
      container.read(applistProvider);
      container.listen(applistProvider, (_, __) {});
      await _settle();

      expect(notifier.loads, 0, reason: 'no aggregate module → no initial load');

      _emitChannelChanged();
      await Future<void>.delayed(_pastDebounce);
      expect(notifier.loads, 1,
          reason: 'the app list loader must re-run on channel.changed');

      _emitCatalogChanged(key: 'local_db', appId: 'com.a');
      await Future<void>.delayed(_pastDebounce);
      expect(notifier.loads, 2,
          reason: 'the app list loader must re-run on catalog.changed');
    });

    test('disposing the notifier cancels the bus subscription (no leak)',
        () async {
      final notifier = _CountingApplist();
      final container = _container([
        applistProvider.overrideWith(() => notifier),
      ]);
      container.read(applistProvider);
      container.listen(applistProvider, (_, __) {});
      await _settle();

      _emitChannelChanged();
      await Future<void>.delayed(_pastDebounce);
      expect(notifier.loads, 1);

      _disposeNow(container);
      _emitChannelChanged(key: 'js_other');
      await Future<void>.delayed(_pastDebounce);
      expect(notifier.loads, 1,
          reason: 'a disposed notifier must not react to further events');
    });
  });

  group('discovery', () {
    test('re-runs loadData and refreshes the Rust pack lane on channel.changed',
        () async {
      final lane = _FakeLane();
      RustScriptChannelLane.installForTest(lane);

      final notifier = _CountingDiscovery();
      final container = _container([
        discoveryProvider.overrideWith(() => notifier),
      ]);
      container.read(discoveryProvider);
      container.listen(discoveryProvider, (_, __) {});
      await _settle();
      notifier.loads = 0; // drop the initial loadData

      _emitChannelChanged();
      await Future<void>.delayed(_pastDebounce);
      expect(notifier.loads, 1,
          reason: 'the discovery loader must re-run on channel.changed');
      expect(lane.refreshCalls, 1,
          reason: 'channel.changed must refresh the Rust pack lane');
    });

    test('catalog.changed re-runs loadData but does NOT refresh the pack lane',
        () async {
      final lane = _FakeLane();
      RustScriptChannelLane.installForTest(lane);

      final notifier = _CountingDiscovery();
      final container = _container([
        discoveryProvider.overrideWith(() => notifier),
      ]);
      container.read(discoveryProvider);
      container.listen(discoveryProvider, (_, __) {});
      await _settle();
      notifier.loads = 0;

      _emitCatalogChanged(key: 'local_db', appId: 'com.a');
      await Future<void>.delayed(_pastDebounce);
      expect(notifier.loads, 1,
          reason: 'the discovery loader must re-run on catalog.changed');
      expect(lane.refreshCalls, 0,
          reason: 'only channel.changed refreshes the pack lane');
    });
  });

  group('search', () {
    test('re-runs the active category loader on a live event', () async {
      final backend = _RecordingCatalog();
      final container = _container([
        catalogFacadeProvider.overrideWithValue(CatalogFacade(frb: backend)),
      ]);
      final notifier = container.read(searchProvider.notifier);

      await notifier.loadCategory(db.AppCategory('game', '游戏', ''));
      expect(backend.categoryCalls, 1);

      _emitCatalogChanged(key: 'local_db', appId: 'com.a');
      await Future<void>.delayed(_pastDebounce);
      expect(backend.categoryCalls, 2,
          reason: 'the category loader must re-run on a live event');
    });

    test('re-runs the active keyword search loader on a live event', () async {
      final backend = _RecordingCatalog()
        ..searchResults['wx'] = const [
          AppSummary(appId: 'wx', name: '微信', user: '', repositories: '', icon: '', des: ''),
        ];
      final container = _container([
        catalogFacadeProvider.overrideWithValue(CatalogFacade(frb: backend)),
      ]);
      final notifier = container.read(searchProvider.notifier);

      notifier.onInputChanged('wx');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(backend.searchCalls, 1);
      expect(container.read(searchProvider), hasLength(1));

      _emitChannelChanged();
      await Future<void>.delayed(_pastDebounce);
      expect(backend.searchCalls, 2,
          reason: 'the keyword search loader must re-run on a live event');
    });
  });

  group('detail', () {
    test('re-fetches only the affected app or the whole channel', () async {
      final dc = _CountingDetailChannel('com.app');
      final stub = _DetailStubChannel(dc);
      ChannelManager.instance.registerChannel(stub);
      ModuleManager.instance
          .bindByType(ChannelManager, ChannelManager.instance);
      addTearDown(() {
        ChannelManager.instance.unregisterChannel(ChannelType.github);
        ModuleManager.instance.unbindByType(ChannelManager);
      });

      final state = DetailState();
      final logic = DetailLogic(state: state);
      logic.setRouteExtra(const AppDetailRequest(
        appId: 'com.app',
        name: 'App',
        channel: ChannelType.github,
        channelCode: 'github',
      ));
      await logic.start();
      addTearDown(logic.shutdown);

      expect(dc.loads, 1, reason: 'the page loaded once on start');

      // A catalog change for a DIFFERENT app must not re-fetch.
      _emitCatalogChanged(key: 'github', appId: 'com.other');
      await Future<void>.delayed(_pastDebounce);
      expect(dc.loads, 1,
          reason: 'a catalog change for another app must not re-fetch');

      // The affected app DOES re-fetch.
      _emitCatalogChanged(key: 'github', appId: 'com.app');
      await Future<void>.delayed(_pastDebounce);
      expect(dc.loads, 2,
          reason: 'the affected app must re-fetch on catalog.changed');

      // A whole-channel change (app_id == null) re-fetches.
      _emitCatalogChanged(key: 'github', appId: null);
      await Future<void>.delayed(_pastDebounce);
      expect(dc.loads, 3,
          reason: 'a whole-channel change must re-fetch');

      // A channel.changed is not a detail-refresh trigger.
      _emitChannelChanged(key: 'github');
      await Future<void>.delayed(_pastDebounce);
      expect(dc.loads, 3,
          reason: 'channel.changed must not re-fetch the detail page');

      // A whole-channel change for ANOTHER channel must not re-fetch.
      _emitCatalogChanged(key: 'other_channel', appId: null);
      await Future<void>.delayed(_pastDebounce);
      expect(dc.loads, 3,
          reason: 'another channel\'s change must not re-fetch this detail');
    });
  });

  group('debounce', () {
    test('a burst of N events triggers exactly ONE loader re-run', () async {
      final notifier = _CountingApplist();
      final container = _container([
        applistProvider.overrideWith(() => notifier),
      ]);
      container.read(applistProvider);
      container.listen(applistProvider, (_, __) {});
      await _settle();

      // A burst within the debounce window: distinct payloads so the bus dedup
      // window does not swallow them — the loader must still run only once.
      for (var i = 0; i < 12; i++) {
        _emitCatalogChanged(key: 'local_db', appId: 'com.app.$i');
      }
      await Future<void>.delayed(_pastDebounce);

      expect(notifier.loads, 1,
          reason: 'a burst must coalesce into a single loader re-run');

      // A second burst, after quiet, re-runs exactly once more.
      for (var i = 0; i < 12; i++) {
        _emitChannelChanged(key: 'js_$i');
      }
      await Future<void>.delayed(_pastDebounce);
      expect(notifier.loads, 2,
          reason: 'each settled burst re-runs the loader exactly once');
    });
  });
}
