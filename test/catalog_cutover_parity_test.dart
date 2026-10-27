import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart';

import 'support/added_apps_read_seams.dart';

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

const AppSummary _app = AppSummary(
  appId: 'com.example.alpha',
  packageName: 'com.example.alpha',
  name: 'Alpha',
  user: 'example',
  repositories: 'alpha',
  icon: 'icon-a',
  des: 'first',
  category: <String>['Tools'],
);

final List<db.AppCategory> _categories = <db.AppCategory>[
  db.AppCategory('Tools', '工具', 'tool.png'),
];

/// Records every call so a routing assertion can prove which lane ran.
class _RecordingCatalog implements CatalogBackend {
  _RecordingCatalog(this.label);

  final String label;
  final List<String> calls = <String>[];

  @override
  Future<List<AppSummary>> list() async {
    calls.add('$label.list');
    return const <AppSummary>[_app];
  }

  @override
  Future<CatalogPageData> listPage(
      {required int offset, required int limit}) async {
    calls.add('$label.listPage');
    return const CatalogPageData(apps: <AppSummary>[_app], total: 1);
  }

  @override
  Future<List<AppSummary>> search(String keyword) async {
    calls.add('$label.search');
    return const <AppSummary>[_app];
  }

  @override
  Future<AppSummary?> getApp(String appId) async {
    calls.add('$label.getApp');
    return _app;
  }

  @override
  Future<List<db.AppCategory>> categories() async {
    calls.add('$label.categories');
    return _categories;
  }

  @override
  Future<List<AppSummary>> byCategory(String categoryId) async {
    calls.add('$label.byCategory');
    return const <AppSummary>[_app];
  }

  @override
  Future<AppDetailInfo?> getAppDetail(String appId) async {
    calls.add('$label.getAppDetail');
    return null;
  }

  @override
  Future<CatalogRefreshOutcome> refresh(String url) async {
    calls.add('$label.refresh');
    return const CatalogRefreshOutcome(changed: false, eventsJson: 'null');
  }
}

class _RecordingAddedApps implements AddedAppsBackend {
  _RecordingAddedApps(this.label);

  final String label;
  final List<String> calls = <String>[];

  @override
  Future<List<AddedAppInfo>> list() async {
    calls.add('$label.list');
    return <AddedAppInfo>[
      AddedAppInfo(channelId: 'github', appId: 'owner/alpha', addTime: 1000),
    ];
  }

  @override
  Future<List<AddedAppInfo>> listChannel(String channel) async {
    calls.add('$label.listChannel');
    return <AddedAppInfo>[
      AddedAppInfo(channelId: channel, appId: 'owner/alpha', addTime: 1000),
    ];
  }

  @override
  Future<Map<String, List<String>>> tagsIndex() async {
    calls.add('$label.tagsIndex');
    return <String, List<String>>{
      'github:owner/alpha': <String>['favorite'],
    };
  }

  @override
  Future<void> notifyChanged() async => calls.add('$label.notifyChanged');

  @override
  Future<void> add(String channel, String appId,
          {int? sortOrder, AppSummary? appInfo}) async =>
      calls.add('$label.add');

  @override
  Future<bool> remove(String channel, String appId) async {
    calls.add('$label.remove');
    return false;
  }

  @override
  Future<void> rename(String channel, String oldAppId, String newAppId) async =>
      calls.add('$label.rename');

  @override
  Future<void> setOrder(String channel, String appId, int sortOrder) async =>
      calls.add('$label.setOrder');

  @override
  Future<bool> toggle(String channel, String appId) async {
    calls.add('$label.toggle');
    return false;
  }

  @override
  Future<void> clearChannel(String channel) async =>
      calls.add('$label.clearChannel');

  @override
  Future<void> clearAll() async => calls.add('$label.clearAll');

  @override
  Future<AddedAppInfo?> get(String channel, String appId) async {
    calls.add('$label.get');
    return null;
  }

  @override
  Future<bool> isAdded(String channel, String appId) async {
    calls.add('$label.isAdded');
    return false;
  }

  @override
  Future<int> totalCount() async {
    calls.add('$label.totalCount');
    return 1;
  }

  @override
  Future<int> countChannel(String channel) async {
    calls.add('$label.countChannel');
    return 1;
  }

  @override
  Future<List<String>> tags(String channel, String appId) async {
    calls.add('$label.tags');
    return const <String>[];
  }

  @override
  Future<void> setTags(String channel, String appId, List<String> tags) async =>
      calls.add('$label.setTags');

  @override
  Future<void> addTag(String channel, String appId, String tag) async =>
      calls.add('$label.addTag');

  @override
  Future<void> removeTag(String channel, String appId, String tag) async =>
      calls.add('$label.removeTag');
}

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
  // Test-seam only: `setTestDatabases` binds the injected test DB to the legacy
  // manager's flag-off lane so flag-routed backup restores stay testable. It is
  // not a production caller of the legacy manager.
  'lib/core/service/backup_service.dart',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppAddedDatabase addedDb;

  setUpAll(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final factory = createDatabaseFactoryFfi(
      ffiInit: () => open.overrideFor(OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0')),
    );
    sqflite.databaseFactory = factory;
  });

  setUp(() async {
    final dbFile = p.join(await sqflite.databaseFactory.getDatabasesPath(),
        'catalog_cutover_parity_test.db');
    await sqflite.databaseFactory.deleteDatabase(dbFile);
    addedDb = await AppAddedDatabase.create(dbPath: dbFile);

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
    ModuleManager.instance.unbindByType(IBackupService);
    BackupService.instance.debugChannelsDirectory = null;
    await addedDb.close();
    final dbFile = p.join(await sqflite.databaseFactory.getDatabasesPath(),
        'catalog_cutover_parity_test.db');
    await sqflite.databaseFactory.deleteDatabase(dbFile);
  });

  /// Dart can honestly prove the CUTOVER ROUTING: when the flag is off the
  /// facade must consult only the legacy backend, and when it is on it must
  /// consult only the core backend. Actual row equality is owned by the Rust
  /// golden test (`rust/gstore_core/tests/catalog_parity_golden.rs`), not by a
  /// Dart fake that would just echo the seed data back.
  test('flag_routing_consults_exactly_one_lane', () async {
    // ---- Flag off: legacy only -------------------------------------------
    final legacyAdded = _RecordingAddedApps('legacy');
    final coreAdded = _RecordingAddedApps('facade');
    final legacyCatalog = _RecordingCatalog('legacy');
    final coreCatalog = _RecordingCatalog('facade');

    var added = AddedAppsFacade(legacy: legacyAdded, frb: coreAdded);
    var catalog = CatalogFacade(legacy: legacyCatalog, frb: coreCatalog);

    await added.list();
    await added.tagsIndex();
    await catalog.list();
    await catalog.categories();

    expect(legacyAdded.calls,
        containsAll(<String>['legacy.list', 'legacy.tagsIndex']));
    expect(legacyCatalog.calls,
        containsAll(<String>['legacy.list', 'legacy.categories']));
    expect(coreAdded.calls, isEmpty,
        reason: 'flag off must not consult the core backend');
    expect(coreCatalog.calls, isEmpty,
        reason: 'flag off must not consult the core backend');

    // ---- Flag on: core only ----------------------------------------------
    CoreFlags.resetBackend();
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(catalog: true)),
    );
    await CoreFlags.refresh();

    final legacyAddedOn = _RecordingAddedApps('legacy');
    final coreAddedOn = _RecordingAddedApps('facade');
    final legacyCatalogOn = _RecordingCatalog('legacy');
    final coreCatalogOn = _RecordingCatalog('facade');

    added = AddedAppsFacade(legacy: legacyAddedOn, frb: coreAddedOn);
    catalog = CatalogFacade(legacy: legacyCatalogOn, frb: coreCatalogOn);

    await added.list();
    await added.tagsIndex();
    await catalog.list();
    await catalog.categories();

    expect(coreAddedOn.calls,
        containsAll(<String>['facade.list', 'facade.tagsIndex']));
    expect(coreCatalogOn.calls,
        containsAll(<String>['facade.list', 'facade.categories']));
    expect(legacyAddedOn.calls, isEmpty,
        reason: 'flag on must make zero legacy-manager calls');
    expect(legacyCatalogOn.calls, isEmpty,
        reason: 'flag on must make zero legacy-manager calls');
  });

  test('cutover_callers_do_not_touch_the_legacy_manager', () async {
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

  test('catalog_restores_through_core_and_a_channel_block_is_a_warning',
      () async {
    // The catalog domain is restored through the flag-routed facade (core lane);
    // a channel-domain block is a typed WARNING on the result — never a thrown
    // exception and never a whole-restore failure. The core lane is made
    // deterministic by injecting a recording core backend; the legacy lane is
    // replaced by a backend whose every member throws, so reaching it fails.
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(catalog: true)),
    );
    await CoreFlags.refresh();

    final core = _RecordingAddedApps('core');
    final legacy = ThrowingAddedApps();
    AddedAppsFacade.backendOverride = core;
    AddedAppsFacade.legacyBackendOverride = legacy;

    // Only the channel marker is armed: the catalog write proceeds, the channel
    // write is refused (fail-closed) and surfaced as a warning.
    LegacyWriteGuard.probeOverride =
        (String domain) async => domain == 'channel';

    BackupService.instance.setTestDatabases(addedDb);
    ModuleManager.instance.bindByType(IBackupService, BackupService.instance);

    final channelsDir = Directory.systemTemp.createTempSync('restore_core_lane');
    addTearDown(() => channelsDir.deleteSync(recursive: true));
    BackupService.instance.debugChannelsDirectory = channelsDir;

    const evilName = 'evil.zip';
    final zipBytes = _buildZip();
    final backupBytes = _buildBackupArchive(
      zipBytes,
      apps: const <BackupAppItem>[
        BackupAppItem(
          channelId: 'github',
          appId: 'owner/beta',
          appName: 'owner/beta',
          addTime: 1000,
        ),
      ],
      channelApps: const <String, List<ChannelAppBackupItem>>{
        'github': <ChannelAppBackupItem>[
          ChannelAppBackupItem(
            appId: 'owner/alpha',
            name: 'alpha',
            user: 'owner',
            repositories: 'alpha',
            icon: '',
            description: '',
            addTime: 1000,
            channelCode: 'github',
          ),
        ],
      },
    );

    final backupFile = File(p.join(channelsDir.path, 'backup.tar.gz'));
    await backupFile.writeAsBytes(backupBytes);

    // ---- File path (BackupService.importFromFile) ------------------------
    final fileLogs = <({String text, bool isError})>[];
    final fileResult = await BackupService.instance.importFromFile(
      backupFile.path,
      onLog: (String message, {bool isError = false}) =>
          fileLogs.add((text: message, isError: isError)),
    );
    expect(fileResult.success, isTrue,
        reason: 'a channel block must be a warning, not a whole-restore failure');
    expect(fileResult.writeWarnings, hasLength(1));
    expect(fileResult.writeWarnings.single.domain, 'channel');
    expect(fileResult.writeWarnings.single.code, 'CORE_E_WRITE_BLOCKED');
    expect(fileLogs.any((log) => log.text.contains('恢复完成')), isTrue,
        reason: 'the file-path restore must complete, not abort');
    expect(core.calls, contains('core.add'),
        reason: 'the catalog portion must restore through the core backend');
    expect(legacy.calls, isEmpty,
        reason: 'catalog on must never reach the legacy manager lane');
    expect(File(p.join(channelsDir.path, evilName)).existsSync(), isFalse,
        reason: '_restoreChannelPackages must fail closed on a channel block');

    // ---- Bytes path (BackupService.importBackupBytes) --------------------
    final byteLogs = <({String text, bool isError})>[];
    final byteResult = await BackupService.instance.importBackupBytes(
      Uint8List.fromList(backupBytes),
      onLog: (String message, {bool isError = false}) =>
          byteLogs.add((text: message, isError: isError)),
    );
    expect(byteResult.success, isTrue);
    expect(byteResult.writeWarnings, hasLength(1));
    expect(byteResult.writeWarnings.single.domain, 'channel');
    expect(
      byteLogs.any((log) => log.text.contains('CORE_E_WRITE_BLOCKED')),
      isTrue,
    );
    expect(File(p.join(channelsDir.path, evilName)).existsSync(), isFalse);

    // ---- Agent path (AgentService.runTool('backup')) ---------------------
    final agentResult = await AgentService().runTool(
      AgentService.backupToolName,
      <String, dynamic>{'action': 'import', 'filePath': backupFile.path},
    );
    expect(agentResult, contains('已从'),
        reason: 'a catalog restore that only warns on the channel domain is a '
            'success for the agent');
    expect(agentResult, isNot(contains('恢复失败')));
    expect(File(p.join(channelsDir.path, evilName)).existsSync(), isFalse);
  });
}

Uint8List _buildZip() {
  final archive = Archive()
    ..addFile(ArchiveFile.string(
      'entry.js',
      'function main(method, params) { return null; }',
    ));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

List<int> _buildBackupArchive(
  Uint8List zipBytes, {
  List<BackupAppItem> apps = const <BackupAppItem>[],
  Map<String, List<ChannelAppBackupItem>> channelApps =
      const <String, List<ChannelAppBackupItem>>{},
}) {
  final data = BackupData(
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
  final appsJson = utf8.encode(jsonEncode(data.toJson()));
  final archive = Archive()
    ..addFile(ArchiveFile('apps.json', appsJson.length, appsJson))
    ..addFile(ArchiveFile('channels/evil.zip', zipBytes.length, zipBytes));
  final tar = TarEncoder().encode(archive);
  return GZipEncoder().encode(tar)!;
}
