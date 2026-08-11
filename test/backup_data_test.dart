import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/BackupData.dart';

/// 模拟真实序列化链路：jsonEncode → jsonDecode（嵌套对象在编码时才展开）
Map<String, dynamic> roundTripJson(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

BackupOptions defaultOptions() => const BackupOptions();

BackupAppItem makeAppItem({
  String channelId = 'github',
  String appId = 'termux/termux-app',
  String appName = 'Termux',
  String? category,
  int addTime = 1000,
}) {
  return BackupAppItem(
    channelId: channelId,
    appId: appId,
    appName: appName,
    iconUrl: 'https://example.com/icon.png',
    description: '描述',
    category: category,
    addTime: addTime,
    sortOrder: 2,
    isEnabled: true,
    extra: '{"k":"v"}',
  );
}

void main() {
  group('BackupOptions', () {
    test('默认值', () {
      final o = defaultOptions();
      expect(o.includeIconUrls, true);
      expect(o.includeDescription, true);
      expect(o.includeCategory, true);
      expect(o.includeExtra, true);
      expect(o.compressed, false);
      expect(o.enabledOnly, false);
      expect(o.includeAppConfig, false);
    });

    test('toJson / fromJson 往返', () {
      const o = BackupOptions(
        includeIconUrls: false,
        includeDescription: true,
        includeCategory: false,
        includeExtra: true,
        compressed: true,
        enabledOnly: true,
        includeAppConfig: true,
      );
      final restored = BackupOptions.fromJson(o.toJson());
      expect(restored.includeIconUrls, false);
      expect(restored.includeDescription, true);
      expect(restored.includeCategory, false);
      expect(restored.includeExtra, true);
      expect(restored.compressed, true);
      expect(restored.enabledOnly, true);
      expect(restored.includeAppConfig, true);
    });

    test('copyWith 只改部分字段', () {
      const o = BackupOptions();
      final updated = o.copyWith(compressed: true, enabledOnly: true);
      expect(updated.compressed, true);
      expect(updated.enabledOnly, true);
      expect(updated.includeIconUrls, true);
      expect(updated.includeAppConfig, false);
    });
  });

  group('BackupMetadata', () {
    test('toJson / fromJson 往返（v2.0）', () {
      final meta = BackupMetadata(
        version: BackupVersion.v2_0,
        exportDate: DateTime(2026, 1, 2, 3, 4, 5),
        appVersion: '1.0.0',
        totalApps: 10,
        channelCounts: {'github': 6, 'fdroid': 4},
        options: const BackupOptions(),
        extraInfo: '备注',
      );
      final json = roundTripJson(meta.toJson());
      expect(json['version'], '2.0');
      expect(json['totalApps'], 10);
      expect(json['channelCounts'], {'github': 6, 'fdroid': 4});
      expect(json['extraInfo'], '备注');

      final restored = BackupMetadata.fromJson(json);
      expect(restored.version, BackupVersion.v2_0);
      expect(restored.exportDate, DateTime(2026, 1, 2, 3, 4, 5));
      expect(restored.appVersion, '1.0.0');
      expect(restored.totalApps, 10);
      expect(restored.channelCounts, {'github': 6, 'fdroid': 4});
      expect(restored.options.compressed, false);
      expect(restored.extraInfo, '备注');
    });

    test('v1.0 版本序列化', () {
      final meta = BackupMetadata(
        version: BackupVersion.v1_0,
        exportDate: DateTime(2026, 1, 1),
        appVersion: '1.0.0',
        totalApps: 1,
        channelCounts: {},
        options: const BackupOptions(),
      );
      expect(meta.toJson()['version'], '1.0');
    });

    test('copyWith', () {
      final meta = BackupMetadata(
        version: BackupVersion.v1_0,
        exportDate: DateTime(2026, 1, 1),
        appVersion: '1.0.0',
        totalApps: 1,
        channelCounts: {},
        options: const BackupOptions(),
      );
      final updated = meta.copyWith(totalApps: 5, version: BackupVersion.v2_0);
      expect(updated.totalApps, 5);
      expect(updated.version, BackupVersion.v2_0);
      expect(updated.appVersion, '1.0.0');
    });
  });

  group('BackupAppItem', () {
    test('toJson / fromJson 往返', () {
      final item = makeAppItem();
      final json = item.toJson();
      expect(json['channelId'], 'github');
      expect(json['appId'], 'termux/termux-app');
      expect(json['appName'], 'Termux');
      expect(json['sortOrder'], 2);
      expect(json['isEnabled'], true);
      expect(json['extra'], '{"k":"v"}');

      final restored = BackupAppItem.fromJson(json);
      expect(restored.channelId, 'github');
      expect(restored.appId, 'termux/termux-app');
      expect(restored.appName, 'Termux');
      expect(restored.iconUrl, 'https://example.com/icon.png');
      expect(restored.description, '描述');
      expect(restored.category, isNull);
      expect(restored.addTime, 1000);
      expect(restored.sortOrder, 2);
      expect(restored.isEnabled, true);
      expect(restored.extra, '{"k":"v"}');
    });

    test('fromAddedAppInfo：聚合库只存引用（v3），应用信息用 appId 占位', () {
      final app = AddedAppInfo(
        channelId: 'github',
        appId: 'termux/termux-app',
        addTime: 123,
        sortOrder: 1,
        isEnabled: true,
      );
      final full = BackupAppItem.fromAddedAppInfo(app, const BackupOptions());
      expect(full.iconUrl, isNull);
      expect(full.description, isNull);
      expect(full.category, isNull);
      expect(full.channelId, 'github');
      expect(full.appName, 'termux/termux-app');

      const noIcons = BackupOptions(
        includeIconUrls: false,
        includeDescription: false,
        includeCategory: false,
      );
      final filtered = BackupAppItem.fromAddedAppInfo(app, noIcons);
      expect(filtered.iconUrl, isNull);
      expect(filtered.description, isNull);
      expect(filtered.category, isNull);
    });

    test('fromChannelAddedApp：extra 按选项包含', () {
      final channelApp = ChannelAddedApp(
        appId: 'com.a',
        name: 'A',
        user: 'user',
        repositories: 'owner/repo',
        icon: 'https://i.png',
        description: 'desc',
        category: '工具',
        addTime: 123,
        channelCode: 'github',
        extra: '{"k":"v"}',
      );
      final full = BackupAppItem.fromChannelAddedApp(channelApp, const BackupOptions());
      expect(full.extra, '{"k":"v"}');
      expect(full.channelId, 'github');

      const noExtra = BackupOptions(includeExtra: false);
      final filtered = BackupAppItem.fromChannelAddedApp(channelApp, noExtra);
      expect(filtered.extra, isNull);
    });

    test('toAddedAppInfo 转换（只写引用字段）', () {
      final item = makeAppItem();
      final app = item.toAddedAppInfo();
      expect(app.appId, 'termux/termux-app');
      expect(app.channelId, 'github');
      expect(app.addTime, 1000);
      expect(app.sortOrder, 2);
      expect(app.isEnabled, true);
    });

    test('toChannelAddedApp 转换', () {
      final item = makeAppItem();
      final app = item.toChannelAddedApp();
      expect(app.appId, 'termux/termux-app');
      expect(app.channelCode, 'github');
      expect(app.name, 'Termux');
      expect(app.icon, 'https://example.com/icon.png');
    });
  });

  group('ChannelAppBackupItem', () {
    test('toJson / fromJson 往返', () {
      final item = ChannelAppBackupItem(
        appId: 'com.a',
        name: 'A',
        user: 'user',
        repositories: 'owner/repo',
        icon: 'https://i.png',
        description: 'desc',
        category: '工具',
        addTime: 123,
        channelCode: 'github',
        extra: '{"k":"v"}',
      );
      final json = item.toJson();
      expect(json['appId'], 'com.a');
      expect(json['channelCode'], 'github');
      expect(json['repositories'], 'owner/repo');

      final restored = ChannelAppBackupItem.fromJson(json);
      expect(restored.appId, 'com.a');
      expect(restored.name, 'A');
      expect(restored.user, 'user');
      expect(restored.repositories, 'owner/repo');
      expect(restored.category, '工具');
      expect(restored.addTime, 123);
      expect(restored.channelCode, 'github');
      expect(restored.extra, '{"k":"v"}');
    });

    test('fromChannelAddedApp / toChannelAddedApp 往返', () {
      final channelApp = ChannelAddedApp(
        appId: 'com.a',
        name: 'A',
        user: 'user',
        repositories: 'owner/repo',
        icon: 'https://i.png',
        description: 'desc',
        category: '工具',
        addTime: 123,
        channelCode: 'fdroid',
        extra: '{"k":"v"}',
      );
      final item = ChannelAppBackupItem.fromChannelAddedApp(channelApp);
      final back = item.toChannelAddedApp();
      expect(back.appId, 'com.a');
      expect(back.name, 'A');
      expect(back.user, 'user');
      expect(back.repositories, 'owner/repo');
      expect(back.channelCode, 'fdroid');
      expect(back.category, '工具');
      expect(back.extra, '{"k":"v"}');
    });
  });

  group('BackupData', () {
    BackupData makeBackupData() {
      return BackupData(
        metadata: BackupMetadata(
          version: BackupVersion.v2_0,
          exportDate: DateTime(2026, 1, 1),
          appVersion: '1.0.0',
          totalApps: 3,
          channelCounts: {'github': 2, 'fdroid': 1},
          options: const BackupOptions(),
        ),
        apps: [
          makeAppItem(),
          makeAppItem(channelId: 'github', appId: 'a/b', appName: 'B'),
          makeAppItem(channelId: 'fdroid', appId: 'com.c', appName: 'C'),
        ],
        channelApps: {
          'github': [
            ChannelAppBackupItem(
              appId: 'a/b',
              name: 'B',
              user: 'a',
              repositories: 'a/b',
              icon: '',
              description: '',
              addTime: 1,
              channelCode: 'github',
            ),
          ],
        },
        appConfig: {'theme': {'mode': 'dark'}},
        extras: {'fdroid_sources': []},
      );
    }

    test('v2.0 toJson / fromJson 往返', () {
      final data = makeBackupData();
      final json = roundTripJson(data.toJson());
      expect(json['metadata']['version'], '2.0');
      expect((json['apps'] as List).length, 3);
      expect((json['channelApps'] as Map)['github'], isA<List>());
      expect(json['appConfig'], {'theme': {'mode': 'dark'}});
      expect(json['extras'], {'fdroid_sources': []});

      final restored = BackupData.fromJson(json);
      expect(restored.metadata.version, BackupVersion.v2_0);
      expect(restored.apps.length, 3);
      expect(restored.channelApps['github']!.length, 1);
      expect(restored.appConfig, {'theme': {'mode': 'dark'}});
      expect(restored.extras, {'fdroid_sources': []});
    });

    test('v1.0 兼容：无 channelApps 字段', () {
      final v1Json = {
        'metadata': {
          'version': '1.0',
          'exportDate': '2026-01-01T00:00:00.000',
          'appVersion': '1.0.0',
          'totalApps': 1,
          'channelCounts': <String, int>{},
          'options': <String, dynamic>{},
        },
        'apps': [
          {
            'channelId': 'github',
            'appId': 'a/b',
            'appName': 'A',
            'addTime': 1,
            'sortOrder': 0,
            'isEnabled': true,
          },
        ],
      };
      final restored = BackupData.fromJson(v1Json);
      expect(restored.metadata.version, BackupVersion.v1_0);
      expect(restored.apps.length, 1);
      expect(restored.channelApps, isEmpty);
    });

    test('getAppsByChannel 过滤', () {
      final data = makeBackupData();
      final github = data.getAppsByChannel('github');
      expect(github.length, 2);
      final fdroid = data.getAppsByChannel('fdroid');
      expect(fdroid.length, 1);
      expect(data.getAppsByChannel('vivo'), isEmpty);
    });

    test('getChannelCounts 统计', () {
      final data = makeBackupData();
      final counts = data.getChannelCounts();
      expect(counts['github'], 2);
      expect(counts['fdroid'], 1);
    });

    test('getChannelAppsByChannel', () {
      final data = makeBackupData();
      expect(data.getChannelAppsByChannel('github').length, 1);
      expect(data.getChannelAppsByChannel('fdroid'), isEmpty);
    });

    test('getChannelAppCounts', () {
      final data = makeBackupData();
      final counts = data.getChannelAppCounts();
      expect(counts['github'], 1);
    });

    test('copyWith', () {
      final data = makeBackupData();
      final updated = data.copyWith(
        apps: data.apps.sublist(0, 1),
      );
      expect(updated.apps.length, 1);
      expect(updated.metadata, data.metadata);
      expect(updated.channelApps, data.channelApps);
    });
  });

  group('ChannelType 辅助', () {
    test('fromCode 正确解析', () {
      expect(ChannelType.fromCode('github'), ChannelType.github);
      expect(ChannelType.fromCode('fdroid'), ChannelType.fdroid);
      expect(ChannelType.fromCode('vivo'), ChannelType.vivo);
      expect(ChannelType.fromCode('local_db'), ChannelType.localDb);
      expect(ChannelType.fromCode('http'), ChannelType.http);
      expect(ChannelType.fromCode('custom'), ChannelType.custom);
    });

    test('未知 code 返回 null', () {
      expect(ChannelType.fromCode('unknown'), isNull);
    });

    test('code 与描述', () {
      expect(ChannelType.github.code, 'github');
      expect(ChannelType.github.description, isNotEmpty);
    });
  });
}
