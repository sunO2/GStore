import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/webdav/webdav_config.dart';
import 'package:gstore/core/webdav/webdav_service.dart';
import 'package:gstore/core/webdav/webdav_task_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// WebDavService 上传 onLog 回调测试
///
/// 验证：
/// - uploadToWebDav 各阶段 onLog 旁路输出（开始导出/已添加应用/打包压缩/连接 WebDAV）
/// - 网络失败 → onLog error 日志（isError: true）+ 异常语义不变（仍 rethrow）
/// - 不传 onLog 时行为不变（空安全旁路）
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
  late WebDavService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ConfigStore.instance.initialize();
    ConfigService.instance.registerModule(AppCoreConfigModule());

    final dbFile = p.join(
        await databaseFactory.getDatabasesPath(), 'backup_service_onlog_test.db');
    await databaseFactory.deleteDatabase(dbFile);
    aggregatorDb = await AppAddedDatabase.create(dbPath: dbFile);

    BackupService.instance.setTestDatabases(aggregatorDb);
    service = WebDavService(BackupService.instance);
  });

  tearDown(() async {
    await aggregatorDb.close();
    final dbFile = p.join(
        await databaseFactory.getDatabasesPath(), 'backup_service_onlog_test.db');
    await databaseFactory.deleteDatabase(dbFile);
    // 复位任务管理器（finally 已复位，此处兜底）
    WebDavTaskManager.instance.finish(WebDavTaskManager.instance.isBusy
        ? WebDavTaskType.upload
        : WebDavTaskType.download);
  });

  group('uploadToWebDav onLog', () {
    test('导出阶段日志 + 网络失败 error 日志，异常语义不变', () async {
      await aggregatorDb.addedAppDao.insertApp(
        AddedAppInfo(
            channelId: 'github', appId: 'termux/termux-app', addTime: 1000),
      );

      final logs = <({String text, bool isError})>[];

      void onLog(String message, {bool isError = false}) {
        logs.add((text: message, isError: isError));
      }

      // 不可达地址：连接立即失败（端口 1 拒绝连接），快速触发 catch 分支
      final config = WebDavConfig(
        url: 'http://127.0.0.1:1',
        username: 'test',
        password: 'test',
        backupPath: '/GStore',
      );

      await expectLater(
        service.uploadToWebDav(
          config: config,
          onLog: onLog,
        ),
        throwsA(anything),
      );

      // 阶段日志（旁路输出）
      expect(logs.any((l) => l.text.contains('开始导出数据')), isTrue);
      expect(logs.any((l) => l.text.contains('已添加应用 1 个')), isTrue);
      expect(logs.any((l) => l.text.contains('打包压缩')), isTrue);
      expect(logs.any((l) => l.text.contains('连接 WebDAV')), isTrue);

      // 失败日志（isError: true）
      expect(logs.any((l) => l.isError && l.text.contains('上传失败')), isTrue);
      // 无成功日志
      expect(logs.any((l) => l.text.contains('上传成功')), isFalse);
    });

    test('不传 onLog：行为不变（旁路空安全）', () async {
      await aggregatorDb.addedAppDao.insertApp(
        AddedAppInfo(channelId: 'github', appId: 'a/b', addTime: 1000),
      );
      final config = WebDavConfig(
        url: 'http://127.0.0.1:1',
        username: 'test',
        password: 'test',
        backupPath: '/GStore',
      );
      // 不传 onLog 只应抛连接错误，不抛 onLog 相关异常
      await expectLater(
        service.uploadToWebDav(config: config),
        throwsA(anything),
      );
    });
  });
}
