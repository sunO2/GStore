import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// BackupService exportCompressedBackup / importBackupBytes 测试
///
/// 验证：
/// - exportCompressedBackup 返回 tar.gz 字节（gzip magic 头）
/// - 导出 → 导入字节往返：应用数据恢复
/// - includeAppConfig=true 时归档含 app_config.json，导入可恢复配置
/// - includeAppConfig=false 时归档不含 app_config.json，导入不崩
/// - 非 tar.gz 字节导入抛异常
void main() {
  setUpAll(() {
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
    DatabaseEventBus.instance;
  });

  late AppAddedDatabase aggregatorDb;
  late BackupService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ConfigStore.instance.initialize();
    ConfigService.instance.registerModule(AppCoreConfigModule());

    final dbFile = p.join(await databaseFactory.getDatabasesPath(),
        'backup_service_compressed_test.db');
    await databaseFactory.deleteDatabase(dbFile);
    aggregatorDb = await AppAddedDatabase.create(dbPath: dbFile);

    service = BackupService.instance;
    service.setTestDatabases(aggregatorDb);
  });

  tearDown(() async {
    await aggregatorDb.close();
    final dbFile = p.join(await databaseFactory.getDatabasesPath(),
        'backup_service_compressed_test.db');
    await databaseFactory.deleteDatabase(dbFile);
  });

  /// 从 tar.gz 字节中提取指定归档文件内容
  Uint8List? extractArchiveFile(Uint8List bytes, String name) {
    final decompressed = gzip.decode(bytes);
    final archive = TarDecoder().decodeBytes(decompressed);
    for (final f in archive.files) {
      if (f.name == name) return Uint8List.fromList(f.content as List<int>);
    }
    return null;
  }

  group('exportCompressedBackup', () {
    test('返回 tar.gz 字节（gzip magic），包含 apps.json', () async {
      await aggregatorDb.addedAppDao.insertApp(
        AddedAppInfo(channelId: 'github', appId: 'termux/termux-app', addTime: 1000),
      );

      final bytes = await service.exportCompressedBackup();

      // gzip magic 头 1f 8b
      expect(bytes[0], 0x1f);
      expect(bytes[1], 0x8b);
      expect(bytes, isNotEmpty);

      final appsJson = extractArchiveFile(bytes, 'apps.json');
      expect(appsJson, isNotNull);
      expect(utf8.decode(appsJson!), contains('termux/termux-app'));
      // includeAppConfig 默认 false：不附带 app_config.json
      expect(extractArchiveFile(bytes, 'app_config.json'), isNull);
    });

    test('includeAppConfig=true 时归档含 app_config.json', () async {
      await ConfigService.instance.set(ConfigKeys.proxyUrl, 'https://gh-proxy.org/');

      final bytes = await service.exportCompressedBackup(includeAppConfig: true);

      expect(extractArchiveFile(bytes, 'app_config.json'), isNotNull);
    });

    test('onLog 旁路输出各阶段', () async {
      await aggregatorDb.addedAppDao.insertApp(
        AddedAppInfo(channelId: 'github', appId: 'a/b', addTime: 1000),
      );
      final logs = <String>[];
      await service.exportCompressedBackup(
        onLog: (msg, {isError = false}) => logs.add(msg),
      );
      expect(logs.any((l) => l.contains('开始导出数据')), isTrue);
      expect(logs.any((l) => l.contains('已添加应用 1 个')), isTrue);
      expect(logs.any((l) => l.contains('打包压缩')), isTrue);
    });
  });

  group('importBackupBytes', () {
    test('导出 → 导入字节往返恢复应用数据', () async {
      await aggregatorDb.addedAppDao.insertApp(
        AddedAppInfo(channelId: 'github', appId: 'termux/termux-app', addTime: 1000),
      );
      final bytes = await service.exportCompressedBackup();

      // 清空后从字节导入（merge 模式）
      await aggregatorDb.addedAppDao.clearAll();
      final result = await service.importBackupBytes(bytes);

      expect(result.success, isTrue);
      expect(result.totalCount, 1);
      expect(await aggregatorDb.addedAppDao.getTotalCount(), 1);
    });

    test('includeAppConfig 往返：导入恢复代理配置', () async {
      await ConfigService.instance.set(ConfigKeys.proxyUrl, 'https://gh-proxy.org/');
      await aggregatorDb.addedAppDao.insertApp(
        AddedAppInfo(channelId: 'github', appId: 'a/b', addTime: 1000),
      );
      final bytes = await service.exportCompressedBackup(includeAppConfig: true);

      final result = await service.importBackupBytes(bytes);
      expect(result.success, isTrue);

      final proxy = await ConfigService.instance.getRaw(ConfigKeys.proxyUrl);
      expect(proxy, 'https://gh-proxy.org/');
    });

    test('restoreAppConfig=false 时不恢复 app_config.json 配置', () async {
      await ConfigService.instance.set(ConfigKeys.proxyUrl, 'https://gh-proxy.org/');
      final bytes = await service.exportCompressedBackup(includeAppConfig: true);

      final result = await service.importBackupBytes(
        bytes,
        restoreAppConfig: false,
      );
      expect(result.success, isTrue);
    });

    test('非 tar.gz 字节抛异常', () async {
      await expectLater(
        service.importBackupBytes(Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsA(anything),
      );
    });
  });
}
