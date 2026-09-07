import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/webdav/webdav_task_manager.dart';
import 'package:gstore/page/backup/logic.dart';
import 'package:gstore/page/backup/view.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// 测试用 webdav 模块（绑定假服务，避免触碰真实 WebDavService 单例）
class FakeWebDavModule extends AppModule {
  @override
  String get moduleName => 'webdav';

  @override
  List<String> get dependencies => const [];

  @override
  int get priority => 40;

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IWebDavService, FakeWebDavService());
    context.bindService?.call(IWebDavTaskManager, WebDavTaskManager.instance);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IWebDavService);
    context.unbindService?.call(IWebDavTaskManager);
  }
}

/// 测试用 WebDAV 服务（仅需可绑定，本测试不实际调用）
class FakeWebDavService implements IWebDavService {
  @override
  Future<bool> testWebDavConnection(WebDavConfig config) async => true;

  @override
  Future<List<WebDavFile>> listFiles(String dirPath, {String? pattern}) async =>
      const [];

  @override
  Future<String> uploadToWebDav({
    required WebDavConfig config,
    bool compressed = true,
    BackupOptions? options,
    List<ChannelType>? channels,
    bool includeAppConfig = false,
    BackupLogCallback? onLog,
  }) async =>
      'ok';

  @override
  Future<BackupImportResult> downloadFromWebDav({
    required WebDavConfig config,
    required String remotePath,
    BackupImportMode mode = BackupImportMode.merge,
    bool restoreAppConfig = true,
    BackupLogCallback? onLog,
  }) async {
    throw UnimplementedError();
  }
}

/// 备份页 webdav 卡片随模块上下线测试
///
/// 验证（todo 11，契约 8/9）：
/// - webdav 模块下线（未注册/未初始化）→ 卡片不展示（含上传/下载/配置入口）
/// - 上线（注册+初始化）→ 卡片展示上传/下载
/// - 再下线 → 卡片隐藏
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  setUp(() async {
    // 重置模块注册中心（webdav 默认下线）+ 隔离 BackupLogic
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    Get.delete<BackupLogic>(force: true);

    // 注入测试数据库（BackupLogic 初始化/统计走测试 DB，不触碰 path_provider）
    final dbFile = p.join(
        await databaseFactory.getDatabasesPath(), 'backup_webdav_card_test.db');
    await databaseFactory.deleteDatabase(dbFile);
    aggregatorDb = await AppAddedDatabase.create(dbPath: dbFile);
    BackupService.instance.setTestDatabases(aggregatorDb);
  });

  /// 铺满卡片的大视口（避免 ListView 懒构建导致 offscreen 找不到）
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 等待 BackupLogic 异步初始化（统计加载 + webdav 检查）完成
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('webdav 模块下线：卡片不展示上传/下载', (tester) async {
    useTallViewport(tester);

    await tester.pumpWidget(const GetMaterialApp(home: BackupPage()));
    await settle(tester);

    expect(find.text('WebDAV 云端备份'), findsNothing);
    expect(find.text('备份到网盘'), findsNothing);
    expect(find.text('从网盘恢复备份'), findsNothing);
  });

  testWidgets('webdav 模块上线展示卡片，再下线隐藏', (tester) async {
    useTallViewport(tester);

    await tester.pumpWidget(const GetMaterialApp(home: BackupPage()));
    await settle(tester);
    expect(find.text('WebDAV 云端备份'), findsNothing);

    // 上线
    await ModuleManager.instance.registerModule(FakeWebDavModule());
    await ModuleManager.instance.initializeModule('webdav');
    await tester.pump();

    expect(find.text('WebDAV 云端备份'), findsOneWidget);
    expect(find.text('备份到网盘'), findsOneWidget);
    expect(find.text('从网盘恢复备份'), findsOneWidget);

    // 下线
    await ModuleManager.instance.unregisterModule('webdav');
    await tester.pump();

    expect(find.text('WebDAV 云端备份'), findsNothing);
    expect(find.text('备份到网盘'), findsNothing);
    expect(find.text('从网盘恢复备份'), findsNothing);
  });
}
