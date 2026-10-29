/// GStore 目录浏览页（分页 + 搜索 + 加入）的 Dart 侧门禁测试。
///
/// 验证：
/// 1. `CatalogFacade.listPage` 分页（每页 25，滚动到底加载下一页）；
/// 2. 搜索走 `CatalogFacade.search`；
/// 3. 点「加入」→ `ChannelManager.addAppByCode('gstore', summary)`（经
///    `RustChannelFacade` 的 fake backend 记录 key/payload）+ 写成员关系，
///    行状态翻转为「已加入」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/page/home/tab/discovery/gstore_browse_page.dart';

import 'support/added_apps_read_seams.dart';
import 'support/discovery_facade_seams.dart';
import 'support/library_api_seam.dart';

/// 内存 catalog backend：按 offset/limit 切页，记录请求。
class _FakeCatalog implements CatalogBackend {
  _FakeCatalog(this.apps);

  final List<AppSummary> apps;
  final List<(int offset, int limit)> pageRequests = [];
  final List<String> searchCalls = [];

  @override
  Future<CatalogPageData> listPage(
      {required int offset, required int limit}) async {
    pageRequests.add((offset, limit));
    final total = apps.length;
    if (offset >= total || limit <= 0) {
      return CatalogPageData(apps: const [], total: total);
    }
    final end = offset + limit > total ? total : offset + limit;
    return CatalogPageData(apps: apps.sublist(offset, end), total: total);
  }

  @override
  Future<List<AppSummary>> search(String keyword) async {
    searchCalls.add(keyword);
    final lower = keyword.toLowerCase();
    return apps
        .where((app) => app.name.toLowerCase().contains(lower))
        .toList(growable: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused catalog backend member: ${invocation.memberName}');
}

/// 在内存 added-apps backend 之上记录 `addMembership` 调用。
class _RecordingAdded extends InMemoryAddedAppsBackend {
  final List<(String channel, String appId)> membershipCalls = [];

  @override
  Future<void> addMembership(String channel, String appId,
      {int? sortOrder}) async {
    membershipCalls.add((channel, appId));
    await super.addMembership(channel, appId, sortOrder: sortOrder);
  }
}

AppSummary _app(int index) => AppSummary(
      appId: 'com.app$index',
      name: 'App $index',
      user: '',
      repositories: '',
      icon: '',
      des: '描述 $index',
    );

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: child,
    );

Future<void> _setFlags({required bool channels}) async {
  CoreFlags.installBackend(
    FakeFlagsBackend(CoreFlagsSnapshot(channels: channels)),
  );
  await CoreFlags.refresh();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    CoreFlags.resetBackend();
    CatalogFacade.backendOverride = null;
    AddedAppsFacade.backendOverride = null;
    RustChannelFacade.resetBackend();
  });

  testWidgets('catalog listPage is paged 25 at a time and loads more on scroll',
      (tester) async {
    final catalog = _FakeCatalog(List.generate(45, _app));
    CatalogFacade.backendOverride = catalog;
    AddedAppsFacade.backendOverride = _RecordingAdded();

    await tester.pumpWidget(_host(const GStoreBrowsePage()));
    await tester.pumpAndSettle();

    expect(catalog.pageRequests, [(0, 25)],
        reason: 'first page must be 0..25');
    expect(find.text('App 0'), findsOneWidget);

    // 滚到底部触发下一页
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();

    expect(catalog.pageRequests, contains((25, 25)),
        reason: 'scrolling to the bottom must request the next page');
    expect(catalog.pageRequests.length, 2,
        reason: 'a 45-row catalog is two pages, no third request');
  });

  testWidgets('search uses CatalogFacade.search', (tester) async {
    final catalog = _FakeCatalog([
      _app(1),
      const AppSummary(
          appId: 'com.other',
          name: 'Other',
          user: '',
          repositories: '',
          icon: '',
          des: ''),
    ]);
    CatalogFacade.backendOverride = catalog;
    AddedAppsFacade.backendOverride = _RecordingAdded();

    await tester.pumpWidget(_host(const GStoreBrowsePage()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'App 1');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(catalog.searchCalls, contains('App 1'));
    expect(
        find.descendant(
            of: find.byType(ListView), matching: find.text('App 1')),
        findsOneWidget,
        reason: 'the search result row must be rendered');
    expect(find.text('Other'), findsNothing);
  });

  testWidgets(
      'tapping 加入 calls addAppByCode(gstore) with the right summary and keeps encoded membership',
      (tester) async {
    final library = FakeLibraryApi();
    final channels = FakeChannelApiBackend(library);
    RustChannelFacade.installBackend(channels);
    final added = _RecordingAdded();
    AddedAppsFacade.backendOverride = added;
    CatalogFacade.backendOverride = _FakeCatalog([
      const AppSummary(
        appId: 'com.catalog',
        name: 'Catalog App',
        user: '',
        repositories: '',
        icon: 'icons/catalog.png',
        des: 'A catalog app',
      ),
    ]);

    await tester.runAsync(() => _setFlags(channels: true));
    await tester.pumpWidget(_host(const GStoreBrowsePage()));
    await tester.pumpAndSettle();

    expect(find.text('Catalog App'), findsOneWidget);
    expect(find.text('加入'), findsOneWidget);

    await tester.tap(find.text('加入'));
    await tester.pumpAndSettle();

    expect(channels.addAppCalls, hasLength(1),
        reason: '加入 must write through ChannelManager.addAppByCode');
    final call = channels.addAppCalls.single;
    expect(call.key, 'gstore');
    expect(call.app.appId, 'com.catalog');
    expect(call.app.name, 'Catalog App');
    expect(call.app.icon, 'icons/catalog.png');

    expect(added.membershipCalls, contains(('gstore', 'com.catalog')),
        reason: 'the added_apps membership row must be written');

    expect(find.text('已加入'), findsOneWidget,
        reason: 'the row must flip to the added state');
    expect(find.text('加入'), findsNothing);
  });
}
