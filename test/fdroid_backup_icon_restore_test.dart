/// F-Droid home-icon matrix, Dart half: the backup EXPORT and RESTORE paths.
///
/// The Rust half (`rust/gstore_core/tests/fdroid_icon_matrix.rs`) covers a new
/// add, the cutover import, and the row a restore writes. This file pins the
/// Dart side that produces that row:
///
/// * export must lift `extraJson['sourceId']` into `ChannelAppBackupItem.sourceId`
///   (the core `ChannelAppInfo` has no dedicated `sourceId` field);
/// * restore must merge that identity into the summary's `extra.sourceId`
///   without overwriting an existing value, and must resolve a repo-relative
///   icon (`icons/<pkg>.png`) against the source so the written row never
///   depends on `source_id` to render.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/service/backup_service.dart';

import 'support/added_apps_read_seams.dart' show InMemoryAddedAppsBackend;
import 'support/discovery_facade_seams.dart' show FakeFlagsBackend;
import 'support/library_api_seam.dart';

const String source = 'https://fdroid.test/repo';
const String appId = 'com.example.app';
const String relativeIcon = 'icons/com.example.app.png';
const String absoluteIcon = 'https://fdroid.test/repo/icons/com.example.app.png';

rust.ChannelAppInfo channelInfo({
  String icon = absoluteIcon,
  String? extraJson = '{"sourceId":"https://fdroid.test/repo"}',
}) =>
    rust.ChannelAppInfo(
      appId: appId,
      name: 'Example App',
      user: '',
      repositories: appId,
      icon: icon,
      des: 'short description',
      category: const <String>['Tools'],
      extraJson: extraJson,
      labels: const <rust.ChannelLabel>[],
    );

BackupMetadata metadata(BackupVersion version, {int totalApps = 1}) =>
    BackupMetadata(
      version: version,
      exportDate: DateTime.fromMillisecondsSinceEpoch(1000),
      appVersion: '1.0.0',
      totalApps: totalApps,
      channelCounts: const <String, int>{'fdroid': 1},
      options: const BackupOptions(),
    );

ChannelAppBackupItem channelItem({
  String? sourceId,
  String? extra,
  String icon = relativeIcon,
}) =>
    ChannelAppBackupItem(
      appId: appId,
      name: 'Example App',
      user: '',
      repositories: appId,
      icon: icon,
      description: 'short description',
      category: 'Tools',
      addTime: 0,
      channelCode: 'fdroid',
      extra: extra,
      sourceId: sourceId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryApi library;
  late FakeChannelApiBackend channels;

  setUp(() async {
    CoreFlags.installBackend(
      FakeFlagsBackend(
        const CoreFlagsSnapshot(channels: true, jsChannel: false),
      ),
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
    RustChannelFacade.resetBackend();
  });

  group('export', () {
    test('lifts extraJson.sourceId into the item and keeps extra/icon', () async {
      channels.listAppsResult = <rust.ChannelAppInfo>[channelInfo()];
      AddedAppsFacade.backendOverride = InMemoryAddedAppsBackend();

      final data = await BackupService.instance
          .exportData(includeAppConfig: false);

      final item = data.channelApps['fdroid']!.single;
      expect(item.sourceId, source,
          reason: 'the source identity must be exported as its own field');
      expect(item.extra, contains('sourceId'),
          reason: 'extra stays verbatim');
      expect(item.icon, absoluteIcon,
          reason: 'the core lane exports the already-resolved icon');
    });

    test('leaves sourceId null when the row carries no source', () async {
      channels.listAppsResult = <rust.ChannelAppInfo>[
        channelInfo(extraJson: '{"packageName":"com.example.app"}'),
      ];
      AddedAppsFacade.backendOverride = InMemoryAddedAppsBackend();

      final data = await BackupService.instance
          .exportData(includeAppConfig: false);

      expect(data.channelApps['fdroid']!.single.sourceId, isNull);
    });
  });

  group('restore channelApps', () {
    Future<BackupImportResult> restore(List<ChannelAppBackupItem> items) {
      final data = BackupData(
        metadata: metadata(BackupVersion.v2_1),
        apps: const <BackupAppItem>[
          BackupAppItem(
            channelId: 'fdroid',
            appId: appId,
            appName: appId,
            addTime: 1000,
          ),
        ],
        channelApps: <String, List<ChannelAppBackupItem>>{'fdroid': items},
      );
      return BackupService.instance
          .importData(data, mode: BackupImportMode.merge);
    }

    test('relative icon is resolved against a URL sourceId', () async {
      final result = await restore(<ChannelAppBackupItem>[
        channelItem(sourceId: source),
      ]);

      expect(result.success, isTrue);
      final call = channels.addAppCalls.single;
      expect(call.app.icon, absoluteIcon,
          reason: 'a repo-relative key must not reach channel_apps as-is');
      expect(
        (jsonDecode(call.app.extraJson!) as Map<String, dynamic>)['sourceId'],
        source,
        reason: 'the restored row must know which source it belongs to',
      );
    });

    test('legacy url: identity is normalized to the source URL', () async {
      final result = await restore(<ChannelAppBackupItem>[
        channelItem(sourceId: 'url:$source/'),
      ]);

      expect(result.success, isTrue);
      final call = channels.addAppCalls.single;
      expect(call.app.icon, absoluteIcon);
      expect(
        (jsonDecode(call.app.extraJson!) as Map<String, dynamic>)['sourceId'],
        source,
      );
    });

    test('an existing extra.sourceId is never overwritten', () async {
      final result = await restore(<ChannelAppBackupItem>[
        channelItem(
          sourceId: 'https://item.test/repo',
          extra: '{"sourceId":"https://extra.test/repo"}',
        ),
      ]);

      expect(result.success, isTrue);
      final call = channels.addAppCalls.single;
      expect(
        (jsonDecode(call.app.extraJson!) as Map<String, dynamic>)['sourceId'],
        'https://extra.test/repo',
      );
      expect(call.app.icon, 'https://extra.test/repo/icons/com.example.app.png',
          reason: 'the icon follows the source that actually wins');
    });

    test('an unresolvable identity keeps the app and the raw identity', () async {
      final result = await restore(<ChannelAppBackupItem>[
        channelItem(sourceId: 'fp:DEADBEEF'),
      ]);

      expect(result.success, isTrue,
          reason: 'metadata gaps must never drop an app');
      final call = channels.addAppCalls.single;
      expect(call.app.icon, relativeIcon,
          reason: 'no source is guessed for an unknown identity');
      expect(
        (jsonDecode(call.app.extraJson!) as Map<String, dynamic>)['sourceId'],
        'fp:DEADBEEF',
        reason: 'the raw identity is preserved for a later repair',
      );
    });

    test('an already absolute icon is left untouched', () async {
      final result = await restore(<ChannelAppBackupItem>[
        channelItem(sourceId: source, icon: 'https://cdn.test/x.png'),
      ]);

      expect(result.success, isTrue);
      expect(channels.addAppCalls.single.app.icon, 'https://cdn.test/x.png');
    });
  });

  group('restore apps', () {
    test('a metadata-carrying app item resolves its icon and keeps the source',
        () async {
      final data = BackupData(
        metadata: metadata(BackupVersion.v1_0),
        apps: const <BackupAppItem>[
          BackupAppItem(
            channelId: 'fdroid',
            appId: appId,
            appName: 'Example App',
            iconUrl: relativeIcon,
            description: 'short description',
            addTime: 1000,
            sourceId: source,
          ),
        ],
      );

      final result = await BackupService.instance
          .importData(data, mode: BackupImportMode.merge);

      expect(result.success, isTrue);
      final call = library.addCalls.single;
      expect(call.channel, 'fdroid');
      expect(call.app.icon, absoluteIcon);
      expect(
        (jsonDecode(call.app.extraJson!) as Map<String, dynamic>)['sourceId'],
        source,
      );
    });
  });
}
