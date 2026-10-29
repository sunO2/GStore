/// Plan todo 16/17 (Dart): the home app list must refresh WITHOUT blanking an
/// already-populated list.
///
/// Covered here:
///  * `ApplistState.isRefreshing` + `loadAggregatedApps` re-entrancy guard
///    ("已有 19 行时再次加载不进入 isLoading"),
///  * "加载进行中再次调用不会产生第二次 Rust 调用",
///  * `_loadedOffset` is advanced on the SUCCESS path only (a failed silent
///    refresh must not resurrect `hasMore` / re-fetch page 0),
///  * widget: while refreshing the old rows stay in the tree, `LoadingState`
///    is absent and a `LinearProgressIndicator` is shown.
///
/// Transport seam is the established one: `AddedAppsFacade.backendOverride`
/// (see `test/applist_reads_via_facade_test.dart`). No new global seam.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_app_types.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/home/tab/applist/logic.dart';
import 'package:gstore/page/home/tab/applist/view.dart';

/// One fake home row (alternating channel so the channel distribution log and
/// the grid both have more than one channel).
AggregatedAppInfo _row(int i) => AggregatedAppInfo(
      addedAppInfo: AddedAppInfo(
        id: i + 1,
        channelId: i.isEven ? 'fdroid' : 'github',
        appId: 'com.app.$i',
        addTime: 1000 + i,
      ),
      appInfo: AppSummary(
        appId: 'com.app.$i',
        name: 'com.app.$i',
        user: '',
        repositories: '',
        icon: '',
        des: '',
      ),
      channel: i.isEven ? ChannelType.fdroid : ChannelType.github,
      channelCode: i.isEven ? 'fdroid' : 'github',
    );

/// Counting `AddedAppsBackend` whose `page()` can be parked on a [Completer].
class _GatedPageBackend implements AddedAppsBackend {
  _GatedPageBackend({this.rowCount = 19});

  int rowCount;
  int pageCalls = 0;
  bool throwOnPage = false;

  /// When set, `page()` waits for it before answering (deterministic "in
  /// flight" window; no timers involved).
  Completer<void>? gate;

  @override
  Future<(List<AggregatedAppInfo>, int)> page({
    required int offset,
    required int limit,
  }) async {
    pageCalls++;
    final g = gate;
    if (g != null) await g.future;
    if (throwOnPage) throw StateError('page failed (test)');
    final rows = [for (var i = 0; i < rowCount; i++) _row(i)];
    final total = rows.length;
    if (offset >= total || limit <= 0) {
      return (<AggregatedAppInfo>[], total);
    }
    final end = math.min(offset + limit, total);
    return (rows.sublist(offset, end), total);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unexpected backend call: ${invocation.memberName}');
}

/// Boots an `ApplistNotifier` in its own container. No `IAggregateService` is
/// bound, so the notifier's `_init` short-circuits and never auto-loads — every
/// facade call in these tests is the one the test itself makes.
Future<ProviderContainer> _boot(ApplistNotifier notifier) async {
  final container = ProviderContainer(overrides: [
    applistProvider.overrideWith(() => notifier),
  ]);
  container.read(applistProvider);
  container.listen(applistProvider, (_, __) {});
  // Let the notifier's first-frame microtask (`_init`) run and settle.
  await pumpEventQueue();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
  });

  tearDown(() async {
    AddedAppsFacade.backendOverride = null;
    await ModuleManager.instance.clear();
  });

  test('已有 19 行时再次加载不进入 isLoading', () async {
    final backend = _GatedPageBackend(rowCount: 19);
    AddedAppsFacade.backendOverride = backend;
    final notifier = ApplistNotifier();
    final container = await _boot(notifier);
    addTearDown(container.dispose);

    // First (empty-list) load → full-screen loading is allowed there.
    await notifier.loadAggregatedApps();
    expect(notifier.state.apps, hasLength(19),
        reason: 'the 19 seeded rows must land in state');
    expect(notifier.state.isLoading, isFalse);

    // Second load with 19 rows already on screen → must NOT set isLoading.
    final gate = Completer<void>();
    backend.gate = gate;
    final callsBefore = backend.pageCalls;
    final refresh = notifier.loadAggregatedApps();

    // `_loadAggregatedPage` sets its flags synchronously before its first await.
    expect(notifier.state.isLoading, isFalse,
        reason: 'with rows on screen a reload must not blank the list');
    expect(notifier.state.isRefreshing, isTrue,
        reason: 'a non-blocking refresh flag must be raised instead');
    expect(notifier.state.apps, hasLength(19),
        reason: 'the old rows stay in state while the refresh is in flight');

    await pumpEventQueue();
    expect(backend.pageCalls, callsBefore + 1,
        reason: 'exactly one facade call for this refresh');

    gate.complete();
    await refresh;
    expect(notifier.state.isRefreshing, isFalse,
        reason: 'the refresh flag must be restored in finally');
    expect(notifier.state.isLoading, isFalse);
    expect(notifier.state.apps, hasLength(19));
  });

  test('加载进行中再次调用不会产生第二次 Rust 调用', () async {
    final backend = _GatedPageBackend(rowCount: 19);
    AddedAppsFacade.backendOverride = backend;
    final notifier = ApplistNotifier();
    final container = await _boot(notifier);
    addTearDown(container.dispose);

    final gate = Completer<void>();
    backend.gate = gate;
    final callsBefore = backend.pageCalls;
    final first = notifier.loadAggregatedApps();
    // Let the facade hop into `page()`, which then parks on the gate.
    await pumpEventQueue();
    expect(backend.pageCalls, callsBefore + 1,
        reason: 'the first call must reach the backend exactly once');

    // Second call while the first is still parked on the gate: the re-entrancy
    // guard returns immediately.
    await notifier.loadAggregatedApps();
    expect(backend.pageCalls, callsBefore + 1,
        reason: 'the guarded second call must not reach the backend again');

    gate.complete();
    await first;
    expect(backend.pageCalls, callsBefore + 1,
        reason: 'no extra call appears after the first one finishes either');
  });

  test('失败刷新不推进也不重置分页游标', () async {
    final backend = _GatedPageBackend(rowCount: 40);
    AddedAppsFacade.backendOverride = backend;
    final notifier = ApplistNotifier();
    final container = await _boot(notifier);
    addTearDown(container.dispose);

    await notifier.loadAggregatedApps();
    expect(notifier.state.apps, hasLength(20), reason: 'first page is 20 rows');
    await notifier.loadMoreApps();
    expect(notifier.state.apps, hasLength(40));
    expect(notifier.hasMore, isFalse, reason: 'all 40 rows are loaded');

    backend.throwOnPage = true;
    await notifier.refreshSilently();

    expect(notifier.hasMore, isFalse,
        reason: 'a failed refresh must not reset the cursor to 0 '
            '(that would silently re-fetch page 0)');
    expect(notifier.state.apps, hasLength(40),
        reason: 'a failed silent refresh keeps the list on screen');
    expect(notifier.state.errorMessage, isEmpty,
        reason: 'a failed silent refresh with rows present must not blank '
            'the page into the error state');
  });

  testWidgets(
      '静默刷新期间旧列表仍在树中、无 LoadingState、有 LinearProgressIndicator',
      (tester) async {
    final backend = _GatedPageBackend(rowCount: 19);
    AddedAppsFacade.backendOverride = backend;

    late ApplistNotifier notifier;
    late ProviderContainer container;
    await tester.runAsync(() async {
      notifier = ApplistNotifier();
      container = await _boot(notifier);
      await notifier.loadAggregatedApps();
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ApplistPage()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(LoadingState), findsNothing);
    expect(find.textContaining('com.app.'), findsWidgets,
        reason: 'the 19 loaded rows must be rendered');

    final gate = Completer<void>();
    backend.gate = gate;
    unawaited(notifier.refreshSilently());
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget,
        reason: 'a thin top progress bar signals the silent refresh');
    expect(find.byType(LoadingState), findsNothing,
        reason: 'refreshing must never render the full-screen loading state');
    expect(find.textContaining('com.app.'), findsWidgets,
        reason: 'the previously loaded rows stay in the tree while refreshing');

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing,
        reason: 'the progress bar disappears once the refresh completes');
  });

  test('静默刷新期间滚动加载更多不会丢行/不会重复', () async {
    final backend = _GatedPageBackend(rowCount: 40);
    AddedAppsFacade.backendOverride = backend;
    final notifier = ApplistNotifier();
    final container = await _boot(notifier);
    addTearDown(container.dispose);

    // Page 0 lands: 20 rows, cursor at 20, more available.
    await notifier.loadAggregatedApps();
    expect(notifier.state.apps, hasLength(20));
    expect(notifier.hasMore, isTrue);

    // Park a silent refresh on the gate: the list keeps its 20 rows.
    final gate = Completer<void>();
    backend.gate = gate;
    final callsBefore = backend.pageCalls; // 1 (the initial load)
    final refresh = notifier.refreshSilently();
    await pumpEventQueue();
    expect(backend.pageCalls, callsBefore + 1,
        reason: 'the silent refresh reached the backend exactly once');
    expect(notifier.state.isRefreshing, isTrue);
    expect(notifier.state.apps, hasLength(20),
        reason: 'the old rows stay while the silent refresh is in flight');

    // Scroll-to-bottom during the silent refresh must be REJECTED (guard on
    // isRefreshing), never appended. Expected facade total after this block is
    // 2: 1 initial load + 1 silent refresh. The rejected loadMore adds 0.
    await notifier.loadMoreApps();
    expect(backend.pageCalls, callsBefore + 1,
        reason: 'loadMore during a silent refresh must not hit the backend');
    expect(notifier.state.apps, hasLength(20),
        reason: 'the in-flight refresh rows are untouched; nothing appended');

    gate.complete();
    await refresh;

    expect(notifier.state.apps, hasLength(20),
        reason: 'no row lost when loadMore is rejected during a refresh');
    expect(
        notifier.state.apps.map((a) => a.appInfo.appId).toSet(),
        hasLength(notifier.state.apps.length),
        reason: 'no duplicate app ids after the silent refresh');
    expect(notifier.hasMore, isTrue,
        reason: 'cursor/offset stays consistent: page 0 done, more to load');
    expect(notifier.state.isRefreshing, isFalse);
    expect(notifier.state.isLoadingMore, isFalse);

    // After the refresh settles, paging resumes exactly once from the cursor.
    await notifier.loadMoreApps();
    expect(notifier.state.apps, hasLength(40));
    expect(notifier.state.apps.map((a) => a.appInfo.appId).toSet(),
        hasLength(40), reason: 'all 40 ids are unique across the two pages');
    expect(notifier.hasMore, isFalse);
    // Total facade calls = 3 (initial + silent refresh + post-refresh loadMore).
    expect(backend.pageCalls, callsBefore + 2,
        reason: 'exactly one post-refresh loadMore call, no duplicates');
  });

  test('加载更多进行中触发的刷新会合并、不覆盖已追加行', () async {
    final backend = _GatedPageBackend(rowCount: 40);
    AddedAppsFacade.backendOverride = backend;
    final notifier = ApplistNotifier();
    final container = await _boot(notifier);
    addTearDown(container.dispose);

    await notifier.loadAggregatedApps(); // page 0, 20 rows, 1 facade call
    expect(notifier.state.apps, hasLength(20));

    // Park the loadMore's page request on the gate.
    final gate = Completer<void>();
    backend.gate = gate;
    final callsBefore = backend.pageCalls; // 1
    final more = notifier.loadMoreApps();
    await pumpEventQueue();
    expect(backend.pageCalls, callsBefore + 1,
        reason: 'loadMore reached the backend once');
    expect(notifier.state.isLoadingMore, isTrue);

    // Refresh requested while loadMore is in flight → COALESCED: no second
    // backend call, and no immediate overwrite of the list.
    await notifier.refreshSilently();
    expect(backend.pageCalls, callsBefore + 1,
        reason: 'a refresh during loadMore is deferred, not fired immediately');
    expect(notifier.state.apps, hasLength(20),
        reason: 'the in-flight loadMore rows are not overwritten');
    expect(notifier.state.isRefreshing, isFalse,
        reason: 'the deferred refresh has not started yet');

    // Let loadMore commit page 1 (40 rows); its finally then re-runs the
    // coalesced refresh exactly once.
    gate.complete();
    await more;
    await pumpEventQueue();
    await pumpEventQueue();

    // 3 facade calls total: 1 initial + 1 loadMore + 1 deferred refresh.
    expect(backend.pageCalls, callsBefore + 2,
        reason: 'exactly one deferred refresh call (coalesced, not duplicated)');
    expect(notifier.state.apps, hasLength(20),
        reason: 'the deferred refresh re-reads page 0 like a normal refresh');
    expect(notifier.state.apps.map((a) => a.appInfo.appId).toSet(),
        hasLength(20), reason: 'no duplicate ids after the deferred refresh');
    expect(notifier.hasMore, isTrue);
    expect(notifier.state.isLoadingMore, isFalse);
    expect(notifier.state.isRefreshing, isFalse);
  });
}
