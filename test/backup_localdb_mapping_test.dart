/// Restore mapping: old backups still carry `channelId = 'local_db'`.
///
/// `local_db` is the pre-cutover local library channel: its driver rejects
/// `add_app` (`unsupported`) and the home projection does not read it. Restore
/// must therefore map `local_db` → `gstore` for BOTH halves:
///
/// * membership (`LibraryApi.addMembership`) — otherwise the app is restored
///   into an invisible channel, and
/// * metadata (`ChannelApi.addApp`) — otherwise `channel_apps` is dropped.
///
/// The same test pins the catalog fallback: a summary whose name is just the
/// appId is completed from the catalog, and a null catalog lookup still writes
/// the summary (never drops the app).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/service/backup_service.dart';

import 'support/discovery_facade_seams.dart' show FakeFlagsBackend;
import 'support/library_api_seam.dart';

/// Catalog seam serving only `getApp`; every other member fails loudly.
class _FakeCatalogBackend implements CatalogBackend {
  _FakeCatalogBackend(this.apps);

  final Map<String, AppSummary> apps;
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

BackupData _v21Backup({
  required List<BackupAppItem> apps,
  required Map<String, List<ChannelAppBackupItem>> channelApps,
}) {
  return BackupData(
    metadata: BackupMetadata(
      version: BackupVersion.v2_1,
      exportDate: DateTime.fromMillisecondsSinceEpoch(1000),
      appVersion: '1.0.0',
      totalApps: apps.length,
      channelCounts: const <String, int>{},
      options: const BackupOptions(),
    ),
    apps: apps,
    channelApps: channelApps,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // importData 结束时会向 DatabaseEventBus 发事件（GetX 容器）。
    DatabaseEventBus.instance;
  });

  late FakeLibraryApi library;
  late FakeChannelApiBackend channels;

  setUp(() async {
    CoreFlags.installBackend(
      FakeFlagsBackend(const CoreFlagsSnapshot(channels: true)),
    );
    await CoreFlags.refresh();
    library = FakeLibraryApi();
    channels = FakeChannelApiBackend(library);
    RustChannelFacade.installBackend(channels);
    BackupService.instance.setTestInitialized();
  });

  tearDown(() {
    CoreFlags.resetBackend();
    AddedAppsFacade.backendOverride = null;
    CatalogFacade.backendOverride = null;
    RustChannelFacade.resetBackend();
  });

  test('v2.1 local_db backup restores into gstore membership + metadata',
      () async {
    const apps = <BackupAppItem>[
      BackupAppItem(
        channelId: 'local_db',
        appId: 'com.legacy.app',
        appName: 'com.legacy.app',
        addTime: 1000,
        sortOrder: 3,
      ),
    ];
    const channelApps = <String, List<ChannelAppBackupItem>>{
      'local_db': <ChannelAppBackupItem>[
        ChannelAppBackupItem(
          appId: 'com.legacy.app',
          name: 'Legacy App',
          user: 'legacy',
          repositories: 'com.legacy.app',
          icon: 'https://icons.example/legacy.png',
          description: 'Legacy description',
          addTime: 1000,
          channelCode: 'local_db',
        ),
      ],
    };

    final result = await BackupService.instance.importData(
      _v21Backup(apps: apps, channelApps: channelApps),
      mode: BackupImportMode.merge,
    );

    expect(result.success, isTrue);
    // Membership must land on gstore, never local_db.
    expect(library.addMembershipCalls, hasLength(1));
    final membership = library.addMembershipCalls.single;
    expect(membership.channel, 'gstore');
    expect(membership.appId, 'com.legacy.app');
    expect(membership.sortOrder, 3);

    // Metadata must be written through ChannelApi.addApp with key gstore.
    expect(channels.addAppCalls, hasLength(1));
    final imported = channels.addAppCalls.single;
    expect(imported.key, 'gstore');
    expect(imported.app.appId, 'com.legacy.app');
    expect(imported.app.name, 'Legacy App');
    expect(imported.app.icon, 'https://icons.example/legacy.png');

    // No local_db write of any kind.
    expect(library.addCalls, isEmpty);
    expect(
      library.addMembershipCalls.where((c) => c.channel == 'local_db'),
      isEmpty,
    );
    expect(
      channels.addAppCalls.where((c) => c.key == 'local_db'),
      isEmpty,
    );
    expect(
      library.channelApps.keys.where((k) => k.startsWith('local_db:')),
      isEmpty,
    );
  });

  test('placeholder name is completed from the catalog before writing',
      () async {
    final catalog = _FakeCatalogBackend({
      'com.catalog.app': const AppSummary(
        appId: 'com.catalog.app',
        name: 'Catalog App',
        user: 'catalog',
        repositories: 'com.catalog.app',
        icon: 'https://icons.example/catalog.png',
        des: 'From catalog',
      ),
    });
    CatalogFacade.backendOverride = catalog;

    const apps = <BackupAppItem>[
      BackupAppItem(
        channelId: 'local_db',
        appId: 'com.catalog.app',
        appName: 'com.catalog.app',
        addTime: 1000,
      ),
    ];
    // The backup's own metadata row is also a placeholder (name == appId).
    const channelApps = <String, List<ChannelAppBackupItem>>{
      'local_db': <ChannelAppBackupItem>[
        ChannelAppBackupItem(
          appId: 'com.catalog.app',
          name: 'com.catalog.app',
          user: '',
          repositories: '',
          icon: '',
          description: '',
          addTime: 1000,
          channelCode: 'local_db',
        ),
      ],
    };

    final result = await BackupService.instance.importData(
      _v21Backup(apps: apps, channelApps: channelApps),
      mode: BackupImportMode.merge,
    );

    expect(result.success, isTrue);
    expect(catalog.getAppCalls, contains('com.catalog.app'));
    final imported = channels.addAppCalls.single;
    expect(imported.key, 'gstore');
    expect(imported.app.name, 'Catalog App');
    expect(imported.app.icon, 'https://icons.example/catalog.png');
  });

  test('missing catalog entry still writes the summary (never drops)',
      () async {
    CatalogFacade.backendOverride = _FakeCatalogBackend(const {});

    const apps = <BackupAppItem>[
      BackupAppItem(
        channelId: 'local_db',
        appId: 'com.unknown.app',
        appName: 'com.unknown.app',
        addTime: 1000,
      ),
    ];
    const channelApps = <String, List<ChannelAppBackupItem>>{
      'local_db': <ChannelAppBackupItem>[
        ChannelAppBackupItem(
          appId: 'com.unknown.app',
          name: 'com.unknown.app',
          user: '',
          repositories: '',
          icon: '',
          description: '',
          addTime: 1000,
          channelCode: 'local_db',
        ),
      ],
    };

    final result = await BackupService.instance.importData(
      _v21Backup(apps: apps, channelApps: channelApps),
      mode: BackupImportMode.merge,
    );

    expect(result.success, isTrue);
    expect(channels.addAppCalls, hasLength(1),
        reason: 'a missing catalog row must not drop the app');
    expect(channels.addAppCalls.single.key, 'gstore');
    expect(channels.addAppCalls.single.app.appId, 'com.unknown.app');
  });

  // ---- Legacy backup with NO `channelApps['local_db']` entry -------------
  //
  // The legacy `LocalDbChannel.addApp` was `unsupported`, so old exports have
  // reference-only `apps` items and an empty/absent `channelApps` section for
  // `local_db`. The catalog is then the ONLY source of real metadata; restore
  // must write `channel_apps('gstore')` through `LibraryApi.add`.

  test('reference-only local_db item with empty channelApps writes gstore '
      'metadata from the catalog', () async {
    final catalog = _FakeCatalogBackend({
      'com.x': const AppSummary(
        appId: 'com.x',
        name: 'Real App',
        user: '',
        repositories: '',
        icon: 'http://i/real.png',
        des: '',
      ),
    });
    CatalogFacade.backendOverride = catalog;

    const apps = <BackupAppItem>[
      BackupAppItem(
        channelId: 'local_db',
        appId: 'com.x',
        appName: 'com.x',
        addTime: 1000,
        sortOrder: 2,
      ),
    ];

    final result = await BackupService.instance.importData(
      _v21Backup(apps: apps, channelApps: const {}),
      mode: BackupImportMode.merge,
    );

    expect(result.success, isTrue);
    expect(catalog.getAppCalls, contains('com.x'));
    // Exactly one write, carrying the catalog metadata → channel_apps('gstore').
    expect(library.addCalls, hasLength(1));
    final call = library.addCalls.single;
    expect(call.channel, 'gstore');
    expect(call.app.appId, 'com.x');
    expect(call.app.name, 'Real App');
    expect(call.app.icon, 'http://i/real.png');
    expect(call.sortOrder, 2);
    // Membership is present too (the same write created it).
    expect(await library.isAdded(channel: 'gstore', appId: 'com.x'), isTrue);
    expect(library.addMembershipCalls, isEmpty,
        reason: 'the metadata write already restores membership');
    expect(channels.addAppCalls, isEmpty,
        reason: 'Dart must not write channel_apps through ChannelApi');
  });

  test('reference-only local_db item with a null catalog falls back to '
      'membership only (never drops the app)', () async {
    CatalogFacade.backendOverride = _FakeCatalogBackend(const {});

    const apps = <BackupAppItem>[
      BackupAppItem(
        channelId: 'local_db',
        appId: 'com.unknown',
        appName: 'com.unknown',
        addTime: 1000,
      ),
    ];

    final result = await BackupService.instance.importData(
      _v21Backup(apps: apps, channelApps: const {}),
      mode: BackupImportMode.merge,
    );

    expect(result.success, isTrue);
    expect(library.addCalls, isEmpty,
        reason: 'no catalog row → no placeholder channel_apps write');
    expect(library.addMembershipCalls, hasLength(1));
    final membership = library.addMembershipCalls.single;
    expect(membership.channel, 'gstore');
    expect(membership.appId, 'com.unknown');
    expect(await library.isAdded(channel: 'gstore', appId: 'com.unknown'),
        isTrue);
  });

  test('reference-only non-gstore item stays membership-only even when the '
      'catalog has a row', () async {
    final catalog = _FakeCatalogBackend({
      'owner/repo': const AppSummary(
        appId: 'owner/repo',
        name: 'Should Not Be Written',
        user: '',
        repositories: '',
        icon: 'http://i/nope.png',
        des: '',
      ),
    });
    CatalogFacade.backendOverride = catalog;

    const apps = <BackupAppItem>[
      BackupAppItem(
        channelId: 'github',
        appId: 'owner/repo',
        appName: 'owner/repo',
        addTime: 1000,
      ),
    ];

    final result = await BackupService.instance.importData(
      _v21Backup(apps: apps, channelApps: const {}),
      mode: BackupImportMode.merge,
    );

    expect(result.success, isTrue);
    expect(catalog.getAppCalls, isEmpty,
        reason: 'the gstore catalog fallback must not leak to other channels');
    expect(library.addCalls, isEmpty,
        reason: 'non-gstore channels must not write channel_apps on restore');
    expect(library.addMembershipCalls, hasLength(1));
    expect(library.addMembershipCalls.single.channel, 'github');
    expect(library.addMembershipCalls.single.appId, 'owner/repo');
  });
}
