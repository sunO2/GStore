/// Regression: backup RESTORE must also restore the `channel_apps` metadata
/// (name/icon), not just the home-list reference (`added_apps`).
///
/// S3 removed the Dart-side `_restoreChannelMetadata` (`ChannelApi.addApp`).
/// The restore now forwards the backup item's `appName`/`iconUrl` as the
/// `appInfo` of `AddedAppsFacade.add`, so the Rust `LibraryService` writes the
/// metadata row in the same call that writes membership. This test drives the
/// production facade against a fake `rust.LibraryApi` and asserts the payload.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/service/backup_service.dart';

import 'support/discovery_facade_seams.dart' show FakeFlagsBackend;
import 'support/library_api_seam.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    CoreFlags.installBackend(
      FakeFlagsBackend(const CoreFlagsSnapshot(channels: true)),
    );
    await CoreFlags.refresh();
  });

  tearDown(() {
    CoreFlags.resetBackend();
    AddedAppsFacade.backendOverride = null;
    RustChannelFacade.resetBackend();
  });

  test(
      'restoring a non-js app passes the backup name/icon to LibraryApi.add',
      () async {
    final library = FakeLibraryApi();
    final channels = FakeChannelApiBackend(library);
    RustChannelFacade.installBackend(channels);
    BackupService.instance.setTestInitialized();

    const apps = <BackupAppItem>[
      BackupAppItem(
        channelId: 'github',
        appId: 'owner/real',
        appName: 'Real App Name',
        iconUrl: 'https://icons.example/real.png',
        description: 'A real description',
        addTime: 1000,
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
        .importData(data, mode: BackupImportMode.merge);

    expect(result.success, isTrue);
    // The home list still restores and the metadata rides the same call.
    expect(library.addCalls, hasLength(1),
        reason: 'restore must go through the Rust library add');
    final call = library.addCalls.single;
    expect(call.channel, 'github');
    expect(call.app.appId, 'owner/real');
    expect(call.app.name, 'Real App Name',
        reason: 'the backup appName must become the channel_apps name');
    expect(call.app.icon, 'https://icons.example/real.png',
        reason: 'the backup iconUrl must become the channel_apps icon');
    expect(channels.addAppCalls, isEmpty,
        reason: 'Dart must no longer write channel_apps through ChannelApi');
  });

  test(
      'v2.1 restore imports channelApps metadata into the core channel_apps',
      () async {
    final library = FakeLibraryApi();
    final channels = FakeChannelApiBackend(library);
    RustChannelFacade.installBackend(channels);
    BackupService.instance.setTestInitialized();

    // The aggregated `apps` section only carries a reference (appName == appId);
    // the REAL name/icon live in the `channelApps` section.
    const apps = <BackupAppItem>[
      BackupAppItem(
        channelId: 'github',
        appId: 'owner/repo',
        appName: 'owner/repo',
        addTime: 1000,
      ),
    ];
    const channelApps = <String, List<ChannelAppBackupItem>>{
      'github': <ChannelAppBackupItem>[
        ChannelAppBackupItem(
          appId: 'owner/repo',
          name: 'Real App Name',
          user: 'owner',
          repositories: 'repo',
          icon: 'https://icons.example/real.png',
          description: 'Real description',
          category: 'Tools,Games',
          addTime: 0,
          channelCode: 'github',
          extra: '{"packageName":"com.real.app"}',
        ),
      ],
    };

    final data = BackupData(
      metadata: BackupMetadata(
        version: BackupVersion.v2_1,
        exportDate: DateTime.fromMillisecondsSinceEpoch(1000),
        appVersion: '1.0.0',
        totalApps: apps.length,
        channelCounts: const <String, int>{'github': 1},
        options: const BackupOptions(),
      ),
      apps: apps,
      channelApps: channelApps,
    );

    final result = await BackupService.instance
        .importData(data, mode: BackupImportMode.merge);

    expect(result.success, isTrue);
    // Membership restored through the membership-only path; the placeholder
    // `apps` item must NOT be routed through `LibraryApi.add`.
    expect(library.addMembershipCalls, hasLength(1));
    expect(library.addCalls, isEmpty,
        reason: 'a reference-only backup item must not write channel_apps');
    final membership = library.addMembershipCalls.single;
    expect(membership.channel, 'github');
    expect(membership.appId, 'owner/repo');
    // Metadata restored through the core channel_apps writer with the REAL
    // name/icon from `channelApps` (not the `apps` placeholder).
    expect(channels.addAppCalls, hasLength(1));
    final imported = channels.addAppCalls.single;
    expect(imported.key, 'github');
    expect(imported.app.appId, 'owner/repo');
    expect(imported.app.name, 'Real App Name');
    expect(imported.app.icon, 'https://icons.example/real.png');
    expect(imported.app.des, 'Real description');
    expect(imported.app.category, <String>['Tools', 'Games']);
  });

  test(
      'placeholder apps item with empty channelApps restores membership only',
      () async {
    final library = FakeLibraryApi();
    final channels = FakeChannelApiBackend(library);
    RustChannelFacade.installBackend(channels);
    BackupService.instance.setTestInitialized();

    const apps = <BackupAppItem>[
      BackupAppItem(
        channelId: 'github',
        appId: 'owner/repo',
        appName: 'owner/repo',
        addTime: 1000,
        sortOrder: 4,
      ),
    ];

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
    );

    final result = await BackupService.instance
        .importData(data, mode: BackupImportMode.merge);

    expect(result.success, isTrue);
    expect(library.addMembershipCalls, hasLength(1));
    expect(library.addMembershipCalls.single.appId, 'owner/repo');
    expect(library.addMembershipCalls.single.sortOrder, 4);
    expect(library.addCalls, isEmpty,
        reason: 'no channel_apps metadata write for a placeholder item');
    expect(library.channelApps, isEmpty,
        reason: 'restore must not create/downgrade a channel_apps row');
    expect(channels.addAppCalls, isEmpty);
  });
}
