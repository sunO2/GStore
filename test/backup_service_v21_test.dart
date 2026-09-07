import 'dart:convert';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// BackupService v2.1 扩展测试（真实聚合数据库 + ConfigService）
///
/// 验证：
/// - exportData 导出用户分类标签（appTagDao.getAllTags → BackupData.tags）
/// - exportData 将代理配置并入 appConfig（proxy_url，B 轨 ConfigService）
/// - exportData metadata.version = v2_1，JSON 序列化往返不丢
/// - importData 恢复标签（insertTags 幂等追加）
/// - importData 恢复代理配置（ConfigService.set）
/// - v2.0 数据导入（无 tags / proxy_url）不崩
void main() {
  setUpAll(() {
    // Linux 仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PackageInfo.setMockInitialValues(
      appName: 'GStore',
      packageName: 'com.gstore',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
      installerStore: null,
    );
    // importData 结束时 DatabaseEventBus.instance 走 GetX 容器，需预注册
    DatabaseEventBus.instance;
  });

  late AppAddedDatabase aggregatorDb;
  late BackupService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ConfigStore.instance.initialize();
    ConfigService.instance.registerModule(AppCoreConfigModule());

    // 独享文件路径（避免共享 :memory: 的多 isolate 竞态，见 added_app_tags_test 说明）
    final dbFile = p.join(
        await databaseFactory.getDatabasesPath(), 'backup_service_v21_test.db');
    await databaseFactory.deleteDatabase(dbFile);
    aggregatorDb = await AppAddedDatabase.create(dbPath: dbFile);

    service = BackupService.instance;
    service.setTestDatabases(aggregatorDb);
  });

  tearDown(() async {
    await aggregatorDb.close();
    final dbFile = p.join(
        await databaseFactory.getDatabasesPath(), 'backup_service_v21_test.db');
    await databaseFactory.deleteDatabase(dbFile);
  });

  BackupAppItem makeAppItem(String channelId, String appId) {
    return BackupAppItem(
      channelId: channelId,
      appId: appId,
      appName: appId,
      addTime: 1000,
      sortOrder: 0,
      isEnabled: true,
    );
  }

  BackupMetadata makeMetadata(BackupVersion version) {
    return BackupMetadata(
      version: version,
      exportDate: DateTime(2026, 1, 1),
      appVersion: '1.0.0',
      totalApps: 1,
      channelCounts: {'github': 1},
      options: const BackupOptions(),
    );
  }

  group('exportData v2.1', () {
    test('导出标签 + 代理配置，metadata.version = v2_1', () async {
      await aggregatorDb.addedAppDao.insertApp(
        AddedAppInfo(channelId: 'github', appId: 'termux/termux-app', addTime: 1000),
      );
      await aggregatorDb.appTagDao.insertTags([
        AddedAppTag(
            channelId: 'github', appId: 'termux/termux-app', tag: '效率工具', addTime: 1),
        AddedAppTag(
            channelId: 'github', appId: 'termux/termux-app', tag: '我的标签', addTime: 2),
      ]);
      await ConfigService.instance.set(ConfigKeys.proxyUrl, 'https://gh-proxy.org/');

      final data = await service.exportData();

      expect(data.metadata.version, BackupVersion.v2_1);
      expect(data.tags, hasLength(2));
      expect(data.tags!.every((t) => t.channelId == 'github'), isTrue);
      expect(data.tags!.every((t) => t.appId == 'termux/termux-app'), isTrue);
      expect(data.tags!.map((t) => t.tag).toSet(), {'效率工具', '我的标签'});
      expect(data.appConfig!['proxy_url'], 'https://gh-proxy.org/');

      // 真实备份文件链路：jsonEncode → jsonDecode → fromJson 不丢
      final json = jsonDecode(jsonEncode(data.toJson())) as Map<String, dynamic>;
      final restored = BackupData.fromJson(json);
      expect(restored.metadata.version, BackupVersion.v2_1);
      expect(restored.tags, hasLength(2));
      expect(restored.tags!.map((t) => t.tag).toSet(), {'效率工具', '我的标签'});
      expect(restored.appConfig!['proxy_url'], 'https://gh-proxy.org/');
    });

    test('无标签/无代理时 tags 为 null、appConfig 无 proxy_url', () async {
      final data = await service.exportData();

      expect(data.tags, isNull);
      expect(data.appConfig == null || !data.appConfig!.containsKey('proxy_url'),
          isTrue,
          reason: '代理未设置时不写入 proxy_url');
    });
  });

  group('importData v2.1', () {
    test('恢复标签（幂等追加）与代理配置', () async {
      await aggregatorDb.addedAppDao.insertApp(
        AddedAppInfo(channelId: 'github', appId: 'termux/termux-app', addTime: 1000),
      );

      final data = BackupData(
        metadata: makeMetadata(BackupVersion.v2_1),
        apps: [makeAppItem('github', 'termux/termux-app')],
        tags: const [
          BackupTagItem(channelId: 'github', appId: 'termux/termux-app', tag: '效率工具'),
          BackupTagItem(channelId: 'github', appId: 'termux/termux-app', tag: '游戏'),
        ],
        appConfig: {'proxy_url': 'https://gh-proxy.org/'},
      );

      final result = await service.importData(data, mode: BackupImportMode.merge);
      expect(result.success, isTrue);

      final tags = await aggregatorDb.appTagDao.getAllTags();
      expect(tags, hasLength(2));
      expect(tags.map((t) => t.tag).toSet(), {'效率工具', '游戏'});

      final proxy = await ConfigService.instance.getRaw(ConfigKeys.proxyUrl);
      expect(proxy, 'https://gh-proxy.org/');
    });

    test('v2.0 数据导入（无 tags / proxy_url）不崩', () async {
      final data = BackupData(
        metadata: makeMetadata(BackupVersion.v2_0),
        apps: [makeAppItem('github', 'termux/termux-app')],
      );

      final result = await service.importData(data, mode: BackupImportMode.merge);
      expect(result.success, isTrue);
      expect(await aggregatorDb.addedAppDao.getTotalCount(), 1);
      expect(await aggregatorDb.appTagDao.getAllTags(), isEmpty);
    });
  });
}
