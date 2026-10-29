/// GStore 页「检查更新」按钮的 Dart 侧门禁测试。
///
/// 验证：
/// 1. 已配置 `catalog_url` 时点击 → `repoDownload(url)` → `repoMaterialize()`
///    → 重新加载列表（`listPage` 再跑一次）→ 版本刷新；
/// 2. 地址为空 → 弹出输入弹层（`设置目录地址`），不发起下载；
/// 3. 下载失败 → 显示错误、不物化、不重载、保留当前版本。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/page/home/tab/discovery/gstore_browse_page.dart';
import 'package:gstore/page/home/tab/discovery/gstore_catalog_update.dart';

import 'support/added_apps_read_seams.dart';

const AppSummary _app = AppSummary(
  appId: 'com.example.catalog',
  name: 'Catalog App',
  user: '',
  repositories: '',
  icon: '',
  des: '目录应用',
);

/// 记录版本仓库调用顺序；未用到的成员由 noSuchMethod 兜底。
class _FakeRepoBackend implements CatalogBackend {
  final List<String> calls = <String>[];
  int listPageCalls = 0;
  String? version = '0.0.12';
  Object? downloadError;

  @override
  Future<rust.CatalogRepoStatus> repoStatus() async {
    calls.add('status');
    return _status(version);
  }

  @override
  Future<rust.CatalogRepoDownload> repoDownload({required String url}) async {
    calls.add('download:$url');
    final error = downloadError;
    if (error != null) throw error;
    version = '0.0.14';
    return rust.CatalogRepoDownload(
      version: version,
      changed: true,
      status: _status(version),
    );
  }

  @override
  Future<rust.CatalogMaterializeResult> repoMaterialize() async {
    calls.add('materialize');
    return rust.CatalogMaterializeResult(
      materialized: true,
      version: version,
      apps: 17,
      categories: 13,
    );
  }

  @override
  Future<CatalogPageData> listPage(
      {required int offset, required int limit}) async {
    listPageCalls++;
    calls.add('listPage');
    return const CatalogPageData(apps: <AppSummary>[_app], total: 1);
  }

  @override
  Future<rust.CatalogRepoStatus> repoEnsureSeed({required String path}) =>
      throw UnimplementedError('repoEnsureSeed not used');

  @override
  Future<rust.CatalogRepoStatus> repoSelect({required String version}) =>
      throw UnimplementedError('repoSelect not used');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused CatalogBackend member: ${invocation.memberName}');
}

rust.CatalogRepoStatus _status(String? version) => rust.CatalogRepoStatus(
      currentVersion: version,
      currentFile: version == null ? null : 'seed/abc.db',
      apps: 17,
      categories: 13,
      entries: const <rust.CatalogRepoEntry>[],
    );

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true),
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

Future<void> _configureUrl(String url) async {
  final result = await ConfigService.instance.set(ConfigKeys.catalogUrl, url);
  expect(result.success, isTrue, reason: 'catalog_url must be writable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // 内存配置存储：无需 shared_preferences 插件。
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(
      storages: <ConfigStorage>[MemoryConfigStorage(), MemoryConfigStorage()],
    );
    ConfigRegistry.registerAll(ConfigService.instance);
  });

  tearDown(() {
    CatalogFacade.backendOverride = null;
    AddedAppsFacade.backendOverride = null;
    CatalogUrlSetting.releasesOverride = null;
  });

  testWidgets(
      'check-update downloads, materializes and reloads when URL is configured',
      (tester) async {
    await _configureUrl('https://example.com/catalog.db');
    final backend = _FakeRepoBackend();
    CatalogFacade.backendOverride = backend;
    AddedAppsFacade.backendOverride = InMemoryAddedAppsBackend();

    await tester.pumpWidget(_host(const GStoreBrowsePage()));
    await tester.pumpAndSettle();

    expect(backend.listPageCalls, 1, reason: 'initial load happens once');
    expect(find.text('版本 0.0.12'), findsOneWidget,
        reason: 'the current catalog version must be shown');

    await tester.tap(find.byTooltip('检查更新'));
    await tester.pumpAndSettle();

    expect(backend.calls, contains('download:https://example.com/catalog.db'),
        reason: 'repoDownload must receive the configured URL');

    final downloadIndex =
        backend.calls.indexOf('download:https://example.com/catalog.db');
    final materializeIndex = backend.calls.indexOf('materialize');
    expect(materializeIndex, greaterThan(downloadIndex),
        reason: 'materialize must run after a successful download');
    expect(backend.listPageCalls, 2,
        reason: 'the list must reload after the update');
    expect(find.text('版本 0.0.14'), findsOneWidget,
        reason: 'the version must refresh after the update');
  });

  testWidgets('an empty URL opens the input sheet and does not download',
      (tester) async {
    // 显式清空配置（区别于「未配置」默认仓库地址）保留手动录入路径。
    await _configureUrl('');
    final backend = _FakeRepoBackend();
    CatalogFacade.backendOverride = backend;
    AddedAppsFacade.backendOverride = InMemoryAddedAppsBackend();

    await tester.pumpWidget(_host(const GStoreBrowsePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('设置目录地址'), findsOneWidget,
        reason: 'an empty catalog_url must prompt for input');
    expect(
      backend.calls.where((call) => call.startsWith('download:')),
      isEmpty,
      reason: 'no download may start without a URL',
    );
    expect(backend.listPageCalls, 1, reason: 'the list must not reload');
  });

  testWidgets('a download failure shows an error and keeps the version',
      (tester) async {
    await _configureUrl('https://example.com/broken.db');
    final backend = _FakeRepoBackend()
      ..downloadError = StateError('invalid catalog database');
    CatalogFacade.backendOverride = backend;
    AddedAppsFacade.backendOverride = InMemoryAddedAppsBackend();

    await tester.pumpWidget(_host(const GStoreBrowsePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('检查更新'));
    await tester.pumpAndSettle();

    expect(backend.calls, contains('download:https://example.com/broken.db'));
    expect(backend.calls, isNot(contains('materialize')),
        reason: 'a failed download must not materialize');
    expect(backend.listPageCalls, 1,
        reason: 'a failed download must not reload the list');
    expect(find.text('版本 0.0.12'), findsOneWidget,
        reason: 'the current version must be kept on failure');
    expect(find.textContaining('检查更新失败'), findsOneWidget,
        reason: 'the failure must surface via AppDialogs.showError');
  });

  testWidgets(
      'a GitHub repo URL that cannot be resolved shows an error and does not download',
      (tester) async {
    await _configureUrl('https://github.com/sunO2/GStore-Repositorys');
    CatalogUrlSetting.releasesOverride = (owner, repo) async =>
        throw StateError('releases unavailable');
    final backend = _FakeRepoBackend();
    CatalogFacade.backendOverride = backend;
    AddedAppsFacade.backendOverride = InMemoryAddedAppsBackend();

    await tester.pumpWidget(_host(const GStoreBrowsePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('检查更新失败：无法解析目录地址'), findsOneWidget,
        reason: 'an unresolvable catalog URL must surface a clear error');
    expect(
      backend.calls.where((call) => call.startsWith('download:')),
      isEmpty,
      reason: 'no download may start when the URL cannot be resolved',
    );
    expect(backend.listPageCalls, 1, reason: 'the list must not reload');
    expect(find.text('版本 0.0.12'), findsOneWidget,
        reason: 'the current version must be kept');
  });
}
