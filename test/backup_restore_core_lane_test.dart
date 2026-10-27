/// Post-wave06 fix (write leg): backup RESTORE must route the catalog domain
/// through the core `AddedAppsFacade` (the runtime path), not the legacy
/// `_aggregatorDb`. Before the fix `importData` asserted
/// `LegacyWriteGuard.assertAllowed('catalog')` and threw `LegacyWriteBlocked`
/// the moment the core owned the catalog domain — the user report.
///
/// This test pins the core lane deterministically with a recording core backend
/// injected via `AddedAppsFacade.backendOverride`. It uses a v1.0 backup (no
/// channel apps) so no channel/`_channelDb` work happens.
///
/// The legacy Dart added-apps lane was deleted (Increment 4), so there is no
/// legacy backend to guard against here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_app_types.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/service/backup_service.dart';

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

/// Recording core backend: implements the write/read surface `importData`
/// exercises and records every call. Any other member is unexpected and throws.
class _RecordingCoreBackend implements AddedAppsBackend {
  final List<String> calls = <String>[];
  final List<({String channel, String appId, int? sortOrder})> added = [];
  final List<({String channel, String appId})> toggled = [];
  int clearAllCount = 0;

  @override
  Future<void> add(String channel, String appId,
      {int? sortOrder, AppSummary? appInfo}) async {
    calls.add('add:$channel:$appId');
    added.add((channel: channel, appId: appId, sortOrder: sortOrder));
  }

  @override
  Future<void> clearAll() async {
    calls.add('clearAll');
    clearAllCount++;
  }

  @override
  Future<bool> toggle(String channel, String appId) async {
    calls.add('toggle:$channel:$appId');
    toggled.add((channel: channel, appId: appId));
    return true;
  }

  @override
  Future<List<AddedAppInfo>> list() async {
    calls.add('list');
    return const <AddedAppInfo>[];
  }

  @override
  Future<int> totalCount() async {
    calls.add('totalCount');
    return added.length;
  }

  @override
  Future<Map<String, List<String>>> tagsIndex() async {
    calls.add('tagsIndex');
    return const <String, List<String>>{};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused core backend member: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(catalog: true)),
    );
    await CoreFlags.refresh();
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    AddedAppsFacade.backendOverride = null;
  });

  test('replace_restore_routes_the_catalog_domain_through_the_core_backend',
      () async {
    final core = _RecordingCoreBackend();
    AddedAppsFacade.backendOverride = core;

    BackupService.instance.setTestInitialized();

    const apps = <BackupAppItem>[
      BackupAppItem(
          channelId: 'github', appId: 'owner/a', appName: 'a', addTime: 1000),
      BackupAppItem(
        channelId: 'github',
        appId: 'owner/b',
        appName: 'b',
        addTime: 2000,
        isEnabled: false,
      ),
      BackupAppItem(
        channelId: 'fdroid',
        appId: 'com.c',
        appName: 'c',
        addTime: 3000,
        sortOrder: 5,
      ),
    ];

    final data = BackupData(
      metadata: BackupMetadata(
        version: BackupVersion.v1_0,
        exportDate: DateTime.fromMillisecondsSinceEpoch(1000),
        appVersion: '1.0.0',
        totalApps: apps.length,
        channelCounts: const <String, int>{},
        options: const BackupOptions(),
      ),
      apps: apps,
    );

    final result = await BackupService.instance
        .importData(data, mode: BackupImportMode.replace);

    expect(result.success, isTrue,
        reason: 'a catalog restore on the core lane must not throw/abort');
    expect(core.clearAllCount, 1,
        reason: 'replace mode must clear the core added-apps table');
    expect(core.added, hasLength(3),
        reason: 'every backup app must be added through the core backend');
    expect(
      core.added.map((a) => '${a.channel}:${a.appId}').toSet(),
      {'github:owner/a', 'github:owner/b', 'fdroid:com.c'},
    );
    // Reversed add order is the best-effort add_time fidelity (core stamps
    // add_time=now): the last backup row is added first.
    expect(core.added.first.channel, 'fdroid');
    expect(core.added.last.channel, 'github');
    // The disabled row must be toggled exactly once; enabled rows never.
    expect(core.toggled, hasLength(1));
    expect(core.toggled.single.channel, 'github');
    expect(core.toggled.single.appId, 'owner/b');
    // sortOrder is preserved on the add call.
    final sorted =
        core.added.firstWhere((a) => a.appId == 'com.c');
    expect(sorted.sortOrder, 5);
  });
}
