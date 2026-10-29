import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/aggregate/added_app_types.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_facade.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;

class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    snapshot = CoreFlagsSnapshot(
      channels: patch.channel ?? snapshot.channels,
      catalog: patch.catalog ?? snapshot.catalog,
      update: patch.update ?? snapshot.update,
      download: patch.download ?? snapshot.download,
      install: patch.install ?? snapshot.install,
      jsChannel: patch.jsChannel ?? snapshot.jsChannel,
      coreWrites: snapshot.coreWrites,
    );
  }
}

const _app = AppSummary(
  appId: 'com.example.alpha',
  packageName: 'com.example.alpha',
  name: 'Alpha',
  user: 'example',
  repositories: 'alpha',
  icon: 'icon.png',
  des: 'Fast alpha',
  category: <String>['Tools'],
);

class _FakeCatalogBackend implements CatalogBackend {
  _FakeCatalogBackend(this.label, {this.eventsJson = 'null'});

  final String label;
  final String eventsJson;
  final List<String> calls = <String>[];

  @override
  Future<List<AppSummary>> list() async {
    calls.add('$label.list');
    return const <AppSummary>[_app];
  }

  @override
  Future<CatalogPageData> listPage(
      {required int offset, required int limit}) async {
    calls.add('$label.listPage:$offset:$limit');
    return const CatalogPageData(apps: <AppSummary>[_app], total: 1);
  }

  @override
  Future<List<AppSummary>> search(String keyword) async {
    calls.add('$label.search:$keyword');
    return const <AppSummary>[_app];
  }

  @override
  Future<AppSummary?> getApp(String appId) async {
    calls.add('$label.getApp:$appId');
    return _app;
  }

  @override
  Future<List<db.AppCategory>> categories() async {
    calls.add('$label.categories');
    return <db.AppCategory>[db.AppCategory('Tools', '工具', 'tool.png')];
  }

  @override
  Future<List<AppSummary>> byCategory(String categoryId) async {
    calls.add('$label.byCategory:$categoryId');
    return const <AppSummary>[_app];
  }

  @override
  Future<AppDetailInfo?> getAppDetail(String appId) async {
    calls.add('$label.getAppDetail:$appId');
    return null;
  }

  @override
  Future<CatalogRefreshOutcome> refresh(String url) async {
    calls.add('$label.refresh:$url');
    return CatalogRefreshOutcome(
        changed: eventsJson != 'null', eventsJson: eventsJson);
  }

  // 新增的版本仓库方法本文件未使用；由 noSuchMethod 兜底（否则接口新增成员会编译失败）。
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(
          'unused CatalogBackend member: ${invocation.memberName}');

}

class _FakeAddedAppsBackend implements AddedAppsBackend {
  _FakeAddedAppsBackend(this.label);

  final String label;
  final List<String> calls = <String>[];

  @override
  Future<void> add(String channel, String appId,
      {int? sortOrder, AppSummary? appInfo}) async {
    calls.add('$label.add:$channel:$appId:$sortOrder');
  }

  @override
  Future<void> addMembership(String channel, String appId,
      {int? sortOrder}) async {
    calls.add('$label.addMembership:$channel:$appId:$sortOrder');
  }

  @override
  Future<bool> remove(String channel, String appId) async {
    calls.add('$label.remove:$channel:$appId');
    return true;
  }

  @override
  Future<void> rename(String channel, String oldAppId, String newAppId) async {
    calls.add('$label.rename:$channel:$oldAppId:$newAppId');
  }

  @override
  Future<void> setOrder(String channel, String appId, int sortOrder) async {
    calls.add('$label.setOrder:$channel:$appId:$sortOrder');
  }

  @override
  Future<bool> toggle(String channel, String appId,
      {AppSummary? appInfo}) async {
    calls.add('$label.toggle:$channel:$appId');
    return true;
  }

  @override
  Future<void> clearChannel(String channel) async {
    calls.add('$label.clearChannel:$channel');
  }

  @override
  Future<void> clearAll() async {
    calls.add('$label.clearAll');
  }

  @override
  Future<List<AddedAppInfo>> list() async {
    calls.add('$label.list');
    return <AddedAppInfo>[
      AddedAppInfo(id: 1, channelId: 'github', appId: 'owner/repo', addTime: 5),
    ];
  }

  @override
  Future<List<AddedAppInfo>> listChannel(String channel) async {
    calls.add('$label.listChannel:$channel');
    return list();
  }

  @override
  Future<(List<AggregatedAppInfo>, int)> page({
    required int offset,
    required int limit,
  }) =>
      throw UnimplementedError('page not used by this test');

  @override
  Future<AddedAppInfo?> get(String channel, String appId) async {
    calls.add('$label.get:$channel:$appId');
    return null;
  }

  @override
  Future<bool> isAdded(String channel, String appId) async {
    calls.add('$label.isAdded:$channel:$appId');
    return true;
  }

  @override
  Future<int> totalCount() async {
    calls.add('$label.totalCount');
    return 1;
  }

  @override
  Future<int> countChannel(String channel) async {
    calls.add('$label.countChannel:$channel');
    return 1;
  }

  @override
  Future<void> setTags(String channel, String appId, List<String> tags) async {
    calls.add('$label.setTags:$channel:$appId:${tags.join(",")}');
  }

  @override
  Future<void> addTag(String channel, String appId, String tag) async {
    calls.add('$label.addTag:$channel:$appId:$tag');
  }

  @override
  Future<void> removeTag(String channel, String appId, String tag) async {
    calls.add('$label.removeTag:$channel:$appId:$tag');
  }

  @override
  Future<List<String>> tags(String channel, String appId) async {
    calls.add('$label.tags:$channel:$appId');
    return const <String>['favorite'];
  }

  @override
  Future<Map<String, List<String>>> tagsIndex() async {
    calls.add('$label.tagsIndex');
    return <String, List<String>>{
      "github:owner/repo": <String>['favorite'],
    };
  }

  @override
  Future<void> notifyChanged() async {
    calls.add('$label.notifyChanged');
  }
}

AppUpdateInfo _update() => AppUpdateInfo(
      channelId: 'github',
      appId: 'owner/repo',
      appName: 'Example',
      packageName: 'com.example.app',
      installedVersion: '1.0.0',
      latestVersion: '2.0.0',
      latestDownload: DownloadInfo(
        url: 'https://example.test/app.apk',
        name: 'app.apk',
      ),
      checkedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

class _FakeUpdateBackend implements UpdateBackend {
  _FakeUpdateBackend(this.label);

  final String label;
  final List<String> calls = <String>[];

  @override
  Future<List<AppUpdateInfo>> check({required bool force}) async {
    calls.add('$label.check:$force');
    return <AppUpdateInfo>[_update()];
  }

  @override
  Future<List<AppUpdateInfo>> run() async {
    calls.add('$label.run');
    return <AppUpdateInfo>[_update()];
  }

  @override
  Future<List<AppUpdateInfo>> list() async {
    calls.add('$label.list');
    return <AppUpdateInfo>[_update()];
  }

  @override
  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode}) async {
    calls.add('$label.checkApp:$appId:${channelCode ?? ''}');
    return _update();
  }

  @override
  Future<bool> markUpdated(String appId) async {
    calls.add('$label.markUpdated:$appId');
    return true;
  }

  @override
  Future<bool> hasUpdate(String appId) async {
    calls.add('$label.hasUpdate:$appId');
    return true;
  }

  @override
  Future<int> count() async {
    calls.add('$label.count');
    return 1;
  }

  @override
  Future<bool> cacheValid() async {
    calls.add('$label.cacheValid');
    return true;
  }
}

void main() {
  tearDown(() {
    CoreFlags.resetBackend();
    CatalogFacade.backendOverride = null;
    AddedAppsFacade.backendOverride = null;
    UpdateFacade.backendOverride = null;
  });

  test('catalog/added/update are core-only (the legacy lanes were deleted)',
      () async {
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot()),
    );
    await CoreFlags.refresh();

    final frbCatalog = _FakeCatalogBackend('frb');
    final frbAdded = _FakeAddedAppsBackend('frb');
    final frbUpdate = _FakeUpdateBackend('frb');

    final catalog = CatalogFacade(frb: frbCatalog);
    final added = AddedAppsFacade(frb: frbAdded);
    // The legacy Dart update engine was removed: the update facade always runs
    // on the core backend, independent of the flag.
    final update = UpdateFacade(frb: frbUpdate);

    expect((await catalog.list()).single.appId, 'com.example.alpha');
    expect((await catalog.search('alpha')).length, 1);
    expect((await catalog.categories()).single.id, 'Tools');
    expect(await catalog.getAppDetail('com.example.alpha'), isNull);
    expect((await catalog.refresh('https://example.test/apps.db')).eventsJson,
        'null');
    await added.add('github', 'owner/repo', sortOrder: 3);
    expect((await added.list()).single.appId, 'owner/repo');
    await added.setOrder('github', 'owner/repo', 9);
    await added.setTags('github', 'owner/repo', <String>['favorite']);
    expect(
        (await added.tagsIndex())['github:owner/repo'], <String>['favorite']);
    expect((await update.check(force: true)).single.appId, 'owner/repo');
    expect((await update.run()).single.appId, 'owner/repo');
    expect(await update.count(), 1);

    // The catalog store no longer has a legacy lane: even with the flag off the
    // facade consults the core backend.
    expect(
      frbCatalog.calls,
      containsAll(<String>[
        'frb.list',
        'frb.search:alpha',
        'frb.categories',
        'frb.getAppDetail:com.example.alpha',
        'frb.refresh:https://example.test/apps.db',
      ]),
    );
    // Added apps are core-only too: the legacy Dart store was deleted.
    expect(frbAdded.calls, contains('frb.setOrder:github:owner/repo:9'));
    expect(frbAdded.calls, contains('frb.add:github:owner/repo:3'));
    expect(frbAdded.calls, contains('frb.setTags:github:owner/repo:favorite'));
    // Update no longer has a legacy lane: even with the flag off the facade
    // consults the core backend.
    expect(frbUpdate.calls, contains('frb.check:true'));
    expect(frbUpdate.calls, contains('frb.run'));
  });

  test('catalog/added/update route to the FRB backends', () async {
    CoreFlags.installBackend(
      _FakeFlagsBackend(
        const CoreFlagsSnapshot(catalog: true, update: true),
      ),
    );
    await CoreFlags.refresh();

    final frbCatalog = _FakeCatalogBackend('frb');
    final frbAdded = _FakeAddedAppsBackend('frb');
    final frbUpdate = _FakeUpdateBackend('frb');

    final catalog = CatalogFacade(frb: frbCatalog);
    final added = AddedAppsFacade(frb: frbAdded);
    final update = UpdateFacade(frb: frbUpdate);

    expect((await catalog.list()).single.appId, 'com.example.alpha');
    expect((await catalog.listPage(offset: 0, limit: 10)).total, 1);
    expect((await catalog.getApp('com.example.alpha'))?.name, 'Alpha');
    expect((await catalog.byCategory('Tools')).length, 1);
    expect((await catalog.refresh('https://example.test/apps.db')).eventsJson,
        'null');
    await added.add('github', 'owner/repo');
    expect((await added.list()).single.appId, 'owner/repo');
    expect(await added.totalCount(), 1);
    expect((await update.check(force: false)).single.appId, 'owner/repo');
    expect((await update.run()).single.appId, 'owner/repo');
    expect(await update.markUpdated('owner/repo'), isTrue);
    expect(await update.cacheValid(), isTrue);

    expect(frbCatalog.calls, contains('frb.list'));
    expect(frbAdded.calls, contains('frb.add:github:owner/repo:null'));
    expect(frbUpdate.calls, contains('frb.run'));
    expect(frbUpdate.calls, contains('frb.markUpdated:owner/repo'));
  });

  test('catalog.changed event JSON from CatalogApi.refresh is forwarded',
      () async {
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(catalog: true)),
    );
    await CoreFlags.refresh();

    const eventJson =
        '{"event":"catalog.changed","payload":{"key":"local_db","app_id":null,"removed":false}}';
    final catalog = CatalogFacade(
      frb: _FakeCatalogBackend('frb', eventsJson: eventJson),
    );

    final outcome = await catalog.refresh('https://example.test/apps.db');

    expect(outcome.changed, isTrue);
    expect(outcome.eventsJson, eventJson);
    expect(outcome.eventsJson, contains('"event":"catalog.changed"'));
  });

  test('core backend errors surface instead of silently falling back',
      () async {
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(catalog: true)),
    );
    await CoreFlags.refresh();

    final catalog = CatalogFacade(
      frb: _ThrowingCatalogBackend(),
    );

    await expectLater(catalog.list(), throwsStateError);
  });
}

class _ThrowingCatalogBackend implements CatalogBackend {
  static Never _fail() =>
      throw StateError('serialization: malformed extra_json');

  @override
  Future<List<AppSummary>> list() async => _fail();

  @override
  Future<CatalogPageData> listPage(
          {required int offset, required int limit}) async =>
      _fail();

  @override
  Future<List<AppSummary>> search(String keyword) async => _fail();

  @override
  Future<AppSummary?> getApp(String appId) async => _fail();

  @override
  Future<List<db.AppCategory>> categories() async => _fail();

  @override
  Future<List<AppSummary>> byCategory(String categoryId) async => _fail();

  @override
  Future<AppDetailInfo?> getAppDetail(String appId) async => _fail();

  @override
  Future<CatalogRefreshOutcome> refresh(String url) async => _fail();

  // 新增的版本仓库方法本文件未使用；由 noSuchMethod 兜底（否则接口新增成员会编译失败）。
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(
          'unused CatalogBackend member: ${invocation.memberName}');

}
