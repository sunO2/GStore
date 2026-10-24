import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/impl/LocalDbChannel.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/service/apk_info_service.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart';

/// Flags backend that only toggles `catalog` (the B4 gate).
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

const String _kChannel = 'github';

/// Canonical added-apps fixture shared by both parity lanes.
List<AddedAppInfo> _addedFixture() => <AddedAppInfo>[
      AddedAppInfo(
        id: 1,
        channelId: _kChannel,
        appId: 'owner/alpha',
        addTime: 1000,
        sortOrder: 0,
      ),
      AddedAppInfo(
        id: 2,
        channelId: _kChannel,
        appId: 'owner/beta',
        addTime: 2000,
        sortOrder: 3,
        isEnabled: false,
      ),
      AddedAppInfo(
        id: 3,
        channelId: 'local_db',
        appId: 'com.example.gamma',
        addTime: 3000,
        sortOrder: 1,
      ),
    ];

const Map<String, List<String>> _tagsFixture = <String, List<String>>{
  'github:owner/alpha': <String>['favorite', 'work'],
  'github:owner/beta': <String>['archive'],
  'local_db:com.example.gamma': <String>['tools'],
};

final List<db.AppCategory> _categoriesFixture = <db.AppCategory>[
  db.AppCategory('Tools', '工具', 'tool.png'),
  db.AppCategory('Proxy', '代理', 'proxy.png'),
];

List<AppSummary> _catalogFixture() => const <AppSummary>[
      AppSummary(
        appId: 'com.example.alpha',
        packageName: 'com.example.alpha',
        name: 'Alpha',
        user: 'example',
        repositories: 'alpha',
        icon: 'icon-a',
        des: 'first',
        category: <String>['Tools'],
      ),
      AppSummary(
        appId: 'com.example.beta',
        packageName: 'com.example.beta',
        name: 'Beta',
        user: 'example',
        repositories: 'beta',
        icon: 'icon-b',
        des: 'second',
        category: <String>['Proxy'],
      ),
      AppSummary(
        appId: 'com.example.gamma',
        packageName: 'com.example.gamma',
        name: 'Gamma',
        user: 'example',
        repositories: 'gamma',
        icon: 'icon-c',
        des: 'third',
        category: <String>['Tools'],
      ),
    ];

/// Legacy catalog lane: production `LocalDbChannel` reads served from a stub.
class _StubLocalDbChannel extends LocalDbChannel {
  _StubLocalDbChannel(AppInfoDatabase database) : super(database: database);

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps(
          {bool forceRefresh = false}) async =>
      ChannelResult.success(
          data: _catalogFixture(), from: ChannelType.localDb);

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
          String appId,
          {bool forceRefresh = false}) async =>
      ChannelResult.success(
        data: _catalogFixture()
            .where((app) => app.appId == appId)
            .cast<AppSummary?>()
            .firstOrNull,
        from: ChannelType.localDb,
      );

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories(
          {bool forceRefresh = false}) async =>
      ChannelResult.success(
          data: _categoriesFixture, from: ChannelType.localDb);

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(
          String categoryId,
          {bool forceRefresh = false}) async =>
      ChannelResult.success(
        data: _catalogFixture()
            .where((app) => app.category?.contains(categoryId) ?? false)
            .toList(),
        from: ChannelType.localDb,
      );
}

/// Facade (flag-on) lane: the same observable catalog payload.
class _FakeCatalogBackend implements CatalogBackend {
  final List<String> calls = <String>[];

  @override
  Future<List<AppSummary>> list() async {
    calls.add('list');
    return _catalogFixture();
  }

  @override
  Future<CatalogPageData> listPage(
          {required int offset, required int limit}) async =>
      CatalogPageData(apps: _catalogFixture(), total: _catalogFixture().length);

  @override
  Future<List<AppSummary>> search(String keyword) async {
    calls.add('search:$keyword');
    return _catalogFixture();
  }

  @override
  Future<AppSummary?> getApp(String appId) async {
    calls.add('getApp:$appId');
    for (final app in _catalogFixture()) {
      if (app.appId == appId) return app;
    }
    return null;
  }

  @override
  Future<List<db.AppCategory>> categories() async {
    calls.add('categories');
    return _categoriesFixture;
  }

  @override
  Future<List<AppSummary>> byCategory(String categoryId) async {
    calls.add('byCategory:$categoryId');
    return _catalogFixture()
        .where((app) => app.category?.contains(categoryId) ?? false)
        .toList();
  }

  @override
  Future<AppDetailInfo?> getAppDetail(String appId) async => null;

  @override
  Future<CatalogRefreshOutcome> refresh(String url) async =>
      const CatalogRefreshOutcome(changed: false, eventsJson: 'null');
}

/// Facade (flag-on) lane: the same observable added-apps payload.
class _FakeAddedAppsBackend implements AddedAppsBackend {
  _FakeAddedAppsBackend([List<AddedAppInfo>? apps])
      : _apps = apps ?? _addedFixture();

  final List<AddedAppInfo> _apps;
  final List<String> calls = <String>[];

  /// The Rust core lists `add_time DESC`; the fixture must mirror that so the
  /// diff is not a storage-order artefact.
  List<AddedAppInfo> _ordered() =>
      <AddedAppInfo>[..._apps]..sort((a, b) => b.addTime.compareTo(a.addTime));

  @override
  Future<List<AddedAppInfo>> list() async {
    calls.add('list');
    return _ordered();
  }

  @override
  Future<List<AddedAppInfo>> listChannel(String channel) async {
    calls.add('listChannel:$channel');
    return _ordered().where((app) => app.channelId == channel).toList();
  }

  @override
  Future<List<String>> tags(String channel, String appId) async =>
      _tagsFixture['$channel:$appId'] ?? const <String>[];

  @override
  Future<Map<String, List<String>>> tagsIndex() async => _tagsFixture;

  @override
  Future<void> notifyChanged() async {
    calls.add('notifyChanged');
  }

  @override
  Future<void> add(String channel, String appId,
      {int? sortOrder, AppSummary? appInfo}) async {}

  @override
  Future<bool> remove(String channel, String appId) async => false;

  @override
  Future<void> rename(String channel, String oldAppId, String newAppId) async {}

  @override
  Future<void> setOrder(String channel, String appId, int sortOrder) async {}

  @override
  Future<bool> toggle(String channel, String appId) async => false;

  @override
  Future<void> clearChannel(String channel) async {}

  @override
  Future<void> clearAll() async {}

  @override
  Future<AddedAppInfo?> get(String channel, String appId) async {
    for (final app in _apps) {
      if (app.channelId == channel && app.appId == appId) return app;
    }
    return null;
  }

  @override
  Future<bool> isAdded(String channel, String appId) async =>
      _apps.any((app) => app.channelId == channel && app.appId == appId);

  @override
  Future<int> totalCount() async => _apps.length;

  @override
  Future<int> countChannel(String channel) async =>
      _apps.where((app) => app.channelId == channel).length;

  @override
  Future<void> setTags(String channel, String appId, List<String> tags) async {}

  @override
  Future<void> addTag(String channel, String appId, String tag) async {}

  @override
  Future<void> removeTag(String channel, String appId, String tag) async {}
}

List<Map<String, Object?>> _appRows(List<AppSummary> apps) => <Map<String, Object?>>[
      for (final app in apps)
        <String, Object?>{
          'appId': app.appId,
          'packageName': app.packageName,
          'name': app.name,
          'user': app.user,
          'repositories': app.repositories,
          'icon': app.icon,
          'des': app.des,
          'category': app.category,
        },
    ];

Map<String, Object?> _catalogSnapshot(
  List<AppSummary> list,
  List<db.AppCategory> categories,
  List<AppSummary> byCategory,
  AppSummary? one,
) =>
    <String, Object?>{
      'list': _appRows(list),
      'categories': <List<String>>[
        for (final category in categories)
          <String>[category.id, category.description, category.icon],
      ],
      'byCategory': _appRows(byCategory),
      'one': one == null ? null : _appRows(<AppSummary>[one]).single,
    };

Map<String, Object?> _addedSnapshot(
  List<AddedAppInfo> apps,
  Map<String, List<String>> tags,
) =>
    <String, Object?>{
      'apps': <Map<String, Object?>>[
        for (final app in apps)
          <String, Object?>{
            'channel': app.channelId,
            'appId': app.appId,
            'addTime': app.addTime,
            'sortOrder': app.sortOrder,
            'isEnabled': app.isEnabled,
          },
      ],
      'tags': tags,
    };

/// Collects the exact set of production files that may still name
/// `AppAggregatorManager` (DI / exports / type-only references / the legacy
/// implementation itself).
const Set<String> _aggregatorAllowlist = <String>{
  'lib/core/module/app_modules.dart',
  'lib/core/module/interfaces/service_interfaces.dart',
  'lib/core/aggregate/aggregate.dart',
  'lib/core/model/AppIdentity.dart',
  'lib/page/home/tab/applist/widgets/horizontal_app_row.dart',
  'lib/core/aggregate/AppAggregatorManager.dart',
  'lib/core/aggregate/added_apps_facade.dart',
  'lib/core/channel/impl/GitHubChannel.dart',
  'lib/core/channel/impl/VivoChannel.dart',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppAddedDatabase addedDb;
  late AppInfoDatabase catalogDb;
  late String addedDbFile;
  late sqflite.DatabaseFactory factory;

  setUpAll(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    factory = createDatabaseFactoryFfi(
      ffiInit: () => open.overrideFor(OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0')),
    );
    sqflite.databaseFactory = factory;
  });

  setUp(() async {
    addedDbFile = p.join(await factory.getDatabasesPath(),
        'catalog_cutover_parity_test.db');
    await factory.deleteDatabase(addedDbFile);
    addedDb = await AppAddedDatabase.create(dbPath: addedDbFile);
    await addedDb.addedAppDao.insertApps(_addedFixture());
    await addedDb.appTagDao.insertTags(<AddedAppTag>[
      for (final entry in _tagsFixture.entries)
        for (final tag in entry.value)
          AddedAppTag(
            channelId: entry.key.split(':').first,
            appId: entry.key.split(':').sublist(1).join(':'),
            tag: tag,
            addTime: 1000,
          ),
    ]);

    catalogDb = await $FloorAppInfoDatabase.inMemoryDatabaseBuilder().build();

    final manager = AppAggregatorManager.instance;
    manager.debugDatabase = addedDb;

    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(catalog: false)),
    );
    await CoreFlags.refresh();
  });

  tearDown(() async {
    LegacyWriteGuard.resetForTest();
    CoreFlags.resetBackend();
    AddedAppsFacade.backendOverride = null;
    AddedAppsFacade.legacyBackendOverride = null;
    CatalogFacade.backendOverride = null;
    CatalogFacade.legacyBackendOverride = null;
    await addedDb.close();
    await catalogDb.close();
    await factory.deleteDatabase(addedDbFile);
  });

  test('catalog_cutover_parity_diff_empty', () async {
    final manager = AppAggregatorManager.instance;
    final legacyAdded = LegacyAddedAppsBackend(manager: manager, database: addedDb);
    final legacyCatalog =
        LegacyCatalogBackend(channel: _StubLocalDbChannel(catalogDb));

    // ---- Legacy lane (flag off) -------------------------------------------
    final legacyAddedFacade = AddedAppsFacade(
      legacy: legacyAdded,
      frb: _FakeAddedAppsBackend(),
    );
    final legacyCatalogFacade = CatalogFacade(
      legacy: legacyCatalog,
      frb: _FakeCatalogBackend(),
    );

    final legacySnapshot = <String, Object?>{
      'added': _addedSnapshot(
        await legacyAddedFacade.list(),
        await legacyAddedFacade.tagsIndex(),
      ),
      'catalog': _catalogSnapshot(
        await legacyCatalogFacade.list(),
        await legacyCatalogFacade.categories(),
        await legacyCatalogFacade.byCategory('Tools'),
        await legacyCatalogFacade.getApp('com.example.alpha'),
      ),
    };

    // Reset every mutable singleton between the two lanes.
    CoreFlags.resetBackend();
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(catalog: true)),
    );
    await CoreFlags.refresh();
    AddedAppsFacade.backendOverride = null;
    AddedAppsFacade.legacyBackendOverride = null;
    CatalogFacade.backendOverride = null;
    CatalogFacade.legacyBackendOverride = null;

    // ---- Facade lane (flag on) --------------------------------------------
    final frbAdded = _FakeAddedAppsBackend();
    final frbCatalog = _FakeCatalogBackend();
    final facadeAdded = AddedAppsFacade(
      legacy: LegacyAddedAppsBackend(manager: manager, database: addedDb),
      frb: frbAdded,
    );
    final facadeCatalog = CatalogFacade(
      legacy: LegacyCatalogBackend(channel: _StubLocalDbChannel(catalogDb)),
      frb: frbCatalog,
    );

    final facadeSnapshot = <String, Object?>{
      'added': _addedSnapshot(
        await facadeAdded.list(),
        await facadeAdded.tagsIndex(),
      ),
      'catalog': _catalogSnapshot(
        await facadeCatalog.list(),
        await facadeCatalog.categories(),
        await facadeCatalog.byCategory('Tools'),
        await facadeCatalog.getApp('com.example.alpha'),
      ),
    };

    // Fixtures must be non-empty on BOTH sides (an empty-vs-empty diff is a
    // false pass).
    final legacyAddedRows =
        (legacySnapshot['added'] as Map<String, Object?>)['apps'] as List;
    final facadeAddedRows =
        (facadeSnapshot['added'] as Map<String, Object?>)['apps'] as List;
    expect(legacyAddedRows, hasLength(_addedFixture().length));
    expect(facadeAddedRows, hasLength(_addedFixture().length));
    final legacyTags =
        (legacySnapshot['added'] as Map<String, Object?>)['tags'] as Map;
    final facadeTags =
        (facadeSnapshot['added'] as Map<String, Object?>)['tags'] as Map;
    expect(legacyTags, isNotEmpty);
    expect(facadeTags, isNotEmpty);
    expect((legacySnapshot['catalog'] as Map<String, Object?>)['list'],
        isNotEmpty);
    expect((facadeSnapshot['catalog'] as Map<String, Object?>)['list'],
        isNotEmpty);

    final legacyJson = jsonEncode(legacySnapshot);
    final facadeJson = jsonEncode(facadeSnapshot);
    final diff = legacyJson == facadeJson ? '' : '$facadeJson != $legacyJson';
    debugPrint('catalog parity diff (legacy vs facade) = "$diff"');
    expect(diff, isEmpty,
        reason: 'legacy 与 facade 的 added-apps/catalog 读结果 diff 必须为空');

    expect(frbAdded.calls, contains('list'));
    expect(frbCatalog.calls, contains('list'));

    // ---- Cutover surface ---------------------------------------------------
    // `notifyAppsChanged` must exist on the facade and ApkInfoService must be a
    // real caller. A facade method nobody invokes is a misleading success.
    final facadeSource =
        File('lib/core/aggregate/added_apps_facade.dart').readAsStringSync();
    expect(facadeSource, contains('Future<void> notifyAppsChanged()'));
    expect(facadeSource, contains('notifyChanged'));

    for (final path in const <String>[
      'lib/core/service/apk_info_service.dart',
      'lib/core/agent/agent_service.dart',
      'lib/core/update/update_manager.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('AppAggregatorManager')),
          reason: '$path 必须改走 facade');
    }
    expect(
      File('lib/core/service/apk_info_service.dart').readAsStringSync(),
      contains('AddedAppsFacade.instance.notifyAppsChanged'),
      reason: 'post-install refresh must go through the facade',
    );

    // Grep gate: no real caller of the legacy manager remains outside the
    // documented allowlist.
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (!entity.readAsStringSync().contains('AppAggregatorManager')) continue;
      if (_aggregatorAllowlist.contains(entity.path)) continue;
      offenders.add(entity.path);
    }
    expect(offenders, isEmpty,
        reason: 'unexpected AppAggregatorManager references: $offenders');
  });

  test('post_install_blocked_write_is_typed', () async {
    final apkSource =
        File('lib/core/service/apk_info_service.dart').readAsStringSync();
    expect(apkSource, contains('LegacyWriteBlocked'),
        reason: 'post-install blocked writes must catch the guard');
    expect(apkSource, contains('CoreWriteBlockedWarning'),
        reason: 'post-install blocked writes must surface a typed warning');

    final backupSource =
        File('lib/core/service/backup_service.dart').readAsStringSync();
    expect(backupSource, contains('LegacyWriteBlocked'),
        reason: 'restore blocked writes must catch the guard');
    expect(backupSource, contains('CoreWriteBlockedWarning'),
        reason: 'restore blocked writes must surface a typed warning');

    // Behavioural (post-install): the facade path used by ApkInfoService
    // returns a typed warning instead of leaking the raw guard exception.
    LegacyWriteGuard.probeOverride = (_) async => true;
    final postInstallWarning =
        await ApkInfoService.instance.renameAggregateAfterInstall(
      oldAppId: 'owner/old',
      newPackageName: 'com.example.new',
    );
    expect(postInstallWarning, isNotNull,
        reason: 'blocked post-install rename must surface a typed warning');
    expect(postInstallWarning!.code, 'CORE_E_WRITE_BLOCKED');
    expect(postInstallWarning.domain, 'catalog');

    // Behavioural (post-install refresh): the production notify helper must
    // actually invoke `AddedAppsFacade.notifyAppsChanged`, not a dead method.
    final originalFacade = AddedAppsFacade.instance;
    final notifyFake = _FakeAddedAppsBackend();
    AddedAppsFacade.instance = AddedAppsFacade(legacy: notifyFake, frb: notifyFake);
    final notifyWarning =
        await ApkInfoService.instance.notifyAggregateAfterInstall('owner/alpha');
    AddedAppsFacade.instance = originalFacade;
    expect(notifyWarning, isNull);
    expect(notifyFake.calls, contains('notifyChanged'),
        reason: 'post-install refresh must call the facade');

    // Behavioural: a blocked restore returns a typed result instead of
    // leaking the raw LegacyWriteBlocked exception.
    BackupService.instance.setTestDatabases(addedDb);
    final logs = <({String text, bool isError})>[];
    final data = BackupData(
      metadata: BackupMetadata(
        version: BackupVersion.v2_1,
        exportDate: DateTime.fromMillisecondsSinceEpoch(1000),
        appVersion: '1.0.0',
        totalApps: 0,
        channelCounts: const <String, int>{},
        options: const BackupOptions(),
      ),
      apps: const <BackupAppItem>[],
    );

    Object? thrown;
    BackupImportResult? result;
    try {
      result = await BackupService.instance.importData(
        data,
        onLog: (String message, {bool isError = false}) =>
            logs.add((text: message, isError: isError)),
      );
    } catch (error) {
      thrown = error;
    }

    expect(thrown, isNull,
        reason: 'a blocked restore must not leak a raw exception');
    expect(result, isNotNull);
    expect(result!.success, isFalse);
    expect(result.error, contains('CORE_E_WRITE_BLOCKED'));
    expect(
      logs.any((log) => log.isError && log.text.contains('CORE_E_WRITE_BLOCKED')),
      isTrue,
      reason: 'the typed warning must be surfaced through onLog',
    );
    expect(await addedDb.addedAppDao.getTotalCount(), _addedFixture().length,
        reason: 'blocked restore must write nothing');
  });
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
