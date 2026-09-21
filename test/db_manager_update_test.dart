import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'support/db_update_fakes.dart';

/// Linux 仅有 libsqlite3.so.0，显式指定（同 channel_db_floor_roundtrip_test）。
void _ffiInit() {
  open.overrideFor(OperatingSystem.linux,
      () => DynamicLibrary.open('libsqlite3.so.0'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late PathProviderPlatform originalProvider;

  setUpAll(() {
    sqflite.databaseFactory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  });

  setUp(() async {
    await ModuleManager.instance.clear();
    DbManager.resetInstanceForTest();
    docsDir = await Directory.systemTemp.createTemp('dbm_update');
    await Directory('${docsDir.path}/gstore').create(recursive: true);
    originalProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(docsDir.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalProvider;
    await ModuleManager.instance.clear();
    DbManager.resetInstanceForTest();
    if (await docsDir.exists()) await docsDir.delete(recursive: true);
  });

  /// 绑定 DbManager + GithubRestClient + BadgeService。
  FakeAppInfoDao bindManager({required String Function() releaseJson}) {
    final dao = FakeAppInfoDao(version: '1.0.0');
    final dm = DbManager();
    dm.dbRepositroies['gstore'] = DBRepository(
      'gstore',
      'sunO2',
      'GStore-Repositorys',
      FakeAppInfoDatabase(dao),
    );
    ModuleManager.instance.bind<GithubRestClient>(fakeGithubClient(releaseJson));
    ModuleManager.instance.bind<DbManager>(dm);
    ModuleManager.instance.bind<BadgeService>(BadgeService());
    return dao;
  }

  /// 写一个真实有效的 SQLite 文件（含 apps/config 表），供数据库替换路径使用。
  Future<void> writeValidSqlite(String path) async {
    final db = await sqflite.databaseFactory.openDatabase(
      path,
      options: sqflite.OpenDatabaseOptions(
        version: 1,
        onCreate: (db, v) async {
          await db.execute(
              'CREATE TABLE apps (appId TEXT, name TEXT, user TEXT, repositories TEXT, icon TEXT, des TEXT, category TEXT)');
          await db.execute('CREATE TABLE config (version TEXT, proxy TEXT)');
        },
      ),
    );
    await db.close();
  }

  String downloadPath() => '${docsDir.path}/gstore/apps.db.download';
  String targetPath() => '${docsDir.path}/gstore/apps.db';

  group('DbUpdateResult 契约', () {
    test('数值常量固定为 success=3 / noUpdate=-2 / error=-1（勿改动）', () {
      expect(DbUpdateResult.success, 3);
      expect(DbUpdateResult.noUpdate, -2);
      expect(DbUpdateResult.error, -1);
    });
  });

  group('_checkUpdateDBOfRepositroy 结果码', () {
    test('下载完成 + 有效 SQLite ⇒ success，且清除更新红点', () async {
      bindManager(releaseJson: () => releaseJson(version: '9.9.9'));
      final service = FakeDownloadService(
        onDownload: (savePath) => writeValidSqlite(savePath),
      );
      ModuleManager.instance.bind<IDownloadService>(service);
      BadgeService.instance.setBadge(BadgeKey.dbUpdate, 1);

      final result = await "gstore".checkUpdate();

      expect(result, DbUpdateResult.success);
      expect(BadgeService.instance.hasBadge(BadgeKey.dbUpdate), isFalse,
          reason: '成功更新后应清除红点');
      expect(File(targetPath()).existsSync(), isTrue,
          reason: '新数据库文件已就位');
      expect(service.downloadCalls, 1);
      await service.dispose();
    });

    test('下载完成但文件头无效 ⇒ error，且不清除红点', () async {
      bindManager(releaseJson: () => releaseJson(version: '9.9.9'));
      final service = FakeDownloadService(onDownload: (savePath) async {
        await File(savePath).writeAsBytes(List<int>.filled(32, 0x41));
      });
      ModuleManager.instance.bind<IDownloadService>(service);
      BadgeService.instance.setBadge(BadgeKey.dbUpdate, 1);

      final result = await "gstore".checkUpdate();

      expect(result, DbUpdateResult.error, reason: '无效文件必须报失败，不能报成功');
      expect(BadgeService.instance.hasBadge(BadgeKey.dbUpdate), isTrue,
          reason: '失败时必须保留红点');
      await service.dispose();
    });

    test('下载完成但临时文件缺失 ⇒ error，且不清除红点', () async {
      bindManager(releaseJson: () => releaseJson(version: '9.9.9'));
      final service = FakeDownloadService(); // 不写文件
      ModuleManager.instance.bind<IDownloadService>(service);
      BadgeService.instance.setBadge(BadgeKey.dbUpdate, 1);

      final result = await "gstore".checkUpdate();

      expect(result, DbUpdateResult.error);
      expect(BadgeService.instance.hasBadge(BadgeKey.dbUpdate), isTrue);
      await service.dispose();
    });

    test('重命名覆盖失败（目标为目录）⇒ error，且不清除红点', () async {
      bindManager(releaseJson: () => releaseJson(version: '9.9.9'));
      final service = FakeDownloadService(
        onDownload: (savePath) => writeValidSqlite(savePath),
      );
      ModuleManager.instance.bind<IDownloadService>(service);
      // 目标路径被目录占用 → File.rename 抛异常
      await Directory(targetPath()).create(recursive: true);
      BadgeService.instance.setBadge(BadgeKey.dbUpdate, 1);

      final result = await "gstore".checkUpdate();

      expect(result, DbUpdateResult.error, reason: '覆盖失败必须报失败');
      expect(BadgeService.instance.hasBadge(BadgeKey.dbUpdate), isTrue);
      await service.dispose();
    });

    test('无更新 ⇒ noUpdate（-2），且不触发下载', () async {
      // release 版本与当前一致 → compareVersion == 0 → 无更新
      bindManager(releaseJson: () => releaseJson(version: '1.0.0'));
      final service = FakeDownloadService();
      ModuleManager.instance.bind<IDownloadService>(service);

      final result = await "gstore".checkUpdate();

      expect(result, DbUpdateResult.noUpdate);
      expect(result, isNot(DbUpdateResult.success));
      expect(result, isNot(DbUpdateResult.error));
      expect(service.downloadCalls, 0, reason: '无更新不应发起下载');
      await service.dispose();
    });

    test('数据库下载显式传 installAfterDownload=false（不误装 apps.db）', () async {
      bindManager(releaseJson: () => releaseJson(version: '9.9.9'));
      final service = FakeDownloadService(); // 缺失文件 → error 无妨
      ModuleManager.instance.bind<IDownloadService>(service);

      await "gstore".checkUpdate();

      expect(service.capturedInstallAfterDownload, isFalse,
          reason: '数据库文件不是 APK，禁止走 onApkReady 安装');
      await service.dispose();
    });
  });

  group('awaitDownloadTerminal', () {
    test('终态事件到达即完成（远早于超时）', () async {
      final service = FakeDownloadService(autoComplete: false);
      final task = buildTask(id: 42);
      final stopwatch = Stopwatch()..start();

      final future = DbManager.awaitDownloadTerminal(
        service,
        task,
        timeout: const Duration(seconds: 5),
      );
      service.emitTerminal();
      final done = await future;
      stopwatch.stop();

      expect(done.status, DownloadStatusEnum.completed);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)),
          reason: '应由终态事件完成，而不是等到注入的超时');
      await service.dispose();
    });

    test('无终态事件时超时返回原任务（不永久卡住）', () async {
      final service = FakeDownloadService(autoComplete: false);
      final task = buildTask(id: 7);

      final done = await DbManager.awaitDownloadTerminal(
        service,
        task,
        timeout: const Duration(milliseconds: 30),
      );

      expect(done.status, DownloadStatusEnum.queued);
      await service.dispose();
    });
  });
}
