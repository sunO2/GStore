/// `LocalDbGStoreMigration` — one-time `local_db` → `gstore` move.
///
/// Pins the contract:
/// * ONLY existing `added_apps('local_db')` membership rows move — the catalog
///   is never enumerated (regression guard: an empty library with a full
///   catalog moves ZERO apps);
/// * membership + tags land on `gstore`, sort order preserved;
/// * metadata is resolved from the catalog (`CatalogFacade.getApp`) and written
///   via `ChannelManager.addAppByCode('gstore', …)`;
/// * the moved app's legacy `channel_apps('local_db')` row is removed (a failing
///   `remove_app` is tolerated);
/// * the pass is idempotent through the `localdb_gstore_v1.done` marker;
/// * progress is reported from 0 to total.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/service/localdb_gstore_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/added_apps_read_seams.dart';
import 'support/discovery_facade_seams.dart' show FakeFlagsBackend;
import 'support/library_api_seam.dart';

/// Catalog seam: only `getApp` is served (null = catalog miss).
class _FakeCatalogBackend implements CatalogBackend {
  final Map<String, AppSummary> apps = {};
  final List<String> getAppCalls = [];

  @override
  Future<AppSummary?> getApp(String appId) async {
    getAppCalls.add(appId);
    return apps[appId];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused CatalogBackend member: ${invocation.memberName}');
}

AppSummary _catalogApp(String appId, String name) => AppSummary(
      appId: appId,
      name: name,
      user: '',
      repositories: '',
      icon: 'https://icons.example/$appId.png',
      des: 'catalog row',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryAddedAppsBackend added;
  late FakeChannelApiBackend channels;
  late _FakeCatalogBackend catalog;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CoreFlags.installBackend(
      FakeFlagsBackend(const CoreFlagsSnapshot(channels: true)),
    );
    await CoreFlags.refresh();

    added = InMemoryAddedAppsBackend();
    added.seed('local_db', 'com.one', sortOrder: 7);
    added.seed('local_db', 'com.two');
    added.seedTag('local_db', 'com.one', 'tools');
    AddedAppsFacade.backendOverride = added;

    channels = FakeChannelApiBackend(FakeLibraryApi());
    channels.listAppsResult = <rust.ChannelAppInfo>[
      rust.ChannelAppInfo(
        appId: 'com.one',
        name: 'Legacy One',
        user: 'legacy',
        repositories: '',
        icon: '',
        des: '',
        category: const <String>[],
        labels: const <rust.ChannelLabel>[],
      ),
    ];
    RustChannelFacade.installBackend(channels);

    catalog = _FakeCatalogBackend();
    catalog.apps['com.one'] = _catalogApp('com.one', 'One App');
    catalog.apps['com.two'] = _catalogApp('com.two', 'Two App');
    CatalogFacade.backendOverride = catalog;
  });

  tearDown(() {
    CoreFlags.resetBackend();
    AddedAppsFacade.backendOverride = null;
    CatalogFacade.backendOverride = null;
    RustChannelFacade.resetBackend();
  });

  test('moves membership, metadata and tags from local_db to gstore', () async {
    final progress = <(int, int)>[];
    final report = await LocalDbGStoreMigration.run(
      onProgress: (done, total) => progress.add((done, total)),
    );

    expect(report.alreadyDone, isFalse);
    expect(report.moved, 2);
    expect(report.failed, 0);

    // Membership moved (with the original sort order).
    final gstore = await added.listChannel('gstore');
    expect(gstore.map((a) => a.appId).toSet(), {'com.one', 'com.two'});
    expect(gstore.firstWhere((a) => a.appId == 'com.one').sortOrder, 7);

    // Legacy membership removed.
    expect(await added.listChannel('local_db'), isEmpty);

    // Tags moved.
    expect(await added.tags('gstore', 'com.one'), ['tools']);

    // Metadata written to the gstore channel, resolved from the real catalog.
    expect(channels.addAppCalls, hasLength(2));
    expect(channels.addAppCalls.map((c) => c.key).toSet(), {'gstore'});
    final one = channels.addAppCalls
        .firstWhere((c) => c.app.appId == 'com.one');
    expect(one.app.name, 'One App');

    // Only the moved apps' legacy channel_apps('local_db') rows are removed.
    expect(
      channels.removeAppCalls.toSet(),
      {('local_db', 'com.one'), ('local_db', 'com.two')},
    );

    // Progress covers 0..total exactly once.
    expect(progress.first, (0, 2));
    expect(progress.last, (2, 2));
    expect(progress.map((p) => p.$1).toList(), [0, 1, 2]);
  });

  test('regression: empty local_db membership + non-empty catalog moves 0',
      () async {
    // Clear the library completely while the catalog still carries many rows
    // (the bug enumerated `SELECT * FROM apps` on the local driver).
    added = InMemoryAddedAppsBackend();
    AddedAppsFacade.backendOverride = added;
    for (var i = 0; i < 50; i++) {
      catalog.apps['com.catalog.$i'] = _catalogApp('com.catalog.$i', 'App $i');
    }

    final report = await LocalDbGStoreMigration.run();

    expect(report.moved, 0);
    expect(report.total, 0);
    expect(await added.listChannel('gstore'), isEmpty);
    expect(channels.addAppCalls, isEmpty);
    // The catalog must never even be queried: nothing was a library member.
    expect(catalog.getAppCalls, isEmpty);
  });

  test('catalog-only apps are never pulled into the library', () async {
    added = InMemoryAddedAppsBackend();
    added.seed('local_db', 'com.one');
    AddedAppsFacade.backendOverride = added;
    catalog.apps['com.catalog.only'] = _catalogApp('com.catalog.only', 'Bogus');

    final report = await LocalDbGStoreMigration.run();

    expect(report.moved, 1);
    final gstore = await added.listChannel('gstore');
    expect(gstore.map((a) => a.appId).toList(), ['com.one']);
    expect(channels.addAppCalls.map((c) => c.app.appId).toList(), ['com.one']);
    expect(catalog.getAppCalls, ['com.one']);
  });

  test('falls back to a minimal summary when the catalog misses', () async {
    catalog.apps.remove('com.two');

    final report = await LocalDbGStoreMigration.run();

    expect(report.moved, 2);
    expect(catalog.getAppCalls, contains('com.two'));
    final two = channels.addAppCalls.firstWhere((c) => c.app.appId == 'com.two');
    expect(two.app.name, 'com.two');
  });

  test('is idempotent: the done marker skips every later pass', () async {
    await LocalDbGStoreMigration.run();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(LocalDbGStoreMigration.markerKey), '1');

    final callsAfterFirst = channels.addAppCalls.length;
    final removalsAfterFirst = channels.removeAppCalls.length;

    final second = await LocalDbGStoreMigration.run();
    expect(second.alreadyDone, isTrue);
    expect(second.moved, 0);
    expect(channels.addAppCalls, hasLength(callsAfterFirst));
    expect(channels.removeAppCalls, hasLength(removalsAfterFirst));
  });

  test('tolerates a failing local_db remove_app (still completes)', () async {
    channels.failingRemoveKeys.add('local_db');

    final report = await LocalDbGStoreMigration.run();

    expect(report.moved, 2);
    expect(report.failed, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(LocalDbGStoreMigration.markerKey), '1');
    expect((await added.listChannel('gstore')).length, 2);
  });
}
