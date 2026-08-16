import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/page/download/logic.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// 测试用统一初始化：全部使用内存存储（避免插件依赖）
Future<void> initForTest() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(storages: [
    MemoryConfigStorage(),
    MemoryConfigStorage(),
  ]);
  ConfigRegistry.registerAll(ConfigService.instance);
}

/// 下载消费方注册表化 + app_core 配置保留测试（todo 14）
///
/// 验证：
/// - `ModuleManager.get<IDownloadService>()` 未绑定（download 模块下线）时
///   DownloadManagerLogic.retryDownload / agent downloadApp 降级提示不抛
/// - DownloadModule.onUnregister 不再注销 app_core 配置：
///   关 download 后 ConfigService.get(themeMode) 仍返回注册值
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Linux 仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    await initForTest();
    // DownloadManagerLogic 构造时经 "gstore".repoDB 取 DbManager 仓库；
    // DB 构建放 setUp（真实 zone），避免 testWidgets FakeAsync 下真实 I/O 挂起
    Get.put(GithubRestClient(DioClient().get()));
    final dm = DbManager();
    dm.dbRepositroies['gstore'] = DBRepository(
      'gstore',
      'sunO2',
      'GStore-Repositorys',
      await ($FloorAppInfoDatabase.inMemoryDatabaseBuilder()).build(),
    );
    Get.put(dm);
  });

  /// 环境：AppDialogs snackbar 需要 MaterialApp + scaffoldMessengerKey
  Future<BuildContext> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const Scaffold(body: SizedBox()),
    ));
    return tester.element(find.byType(Scaffold));
  }

  group('下载消费点 null 降级（IDownloadService 未绑定 → 提示不抛）', () {
    testWidgets('DownloadManagerLogic.retryDownload：showWarning「下载模块未启用」不抛',
        (tester) async {
      final context = await pumpApp(tester);
      final logic = DownloadManagerLogic();
      final status = DownloadStatus(
        'com.example.a',
        'App A',
        '1.0.0',
        'a.apk',
        'https://example.com/a.apk',
        '/tmp/a.apk',
      );

      // 模块下线（GREEN）：方法立即降级提示；旧实现（RED）Get.find 抛异常。
      // restartCount: 1 跳过 File.exists 真实 I/O（FakeAsync 下不恢复）
      logic.retryDownload(status, restartCount: 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('下载模块未启用'), findsOneWidget);
    });

    test('agent downloadApp：服务未绑定 → 降级提示不抛', () async {
      final agent = AgentService();
      final result = await agent.runTool('downloadApp', {
        'appId': 'com.example.a',
        'channel': 'github',
        'url': 'https://example.com/a.apk',
        'name': 'App A',
        'version': '1.0.0',
      });

      expect(result, contains('下载模块未启用'));
    });
  });

  group('app_core 配置不随 download 下线注销', () {
    test('DownloadModule.onUnregister 后 themeMode 等全局 key 仍可读', () async {
      // 复刻 DownloadModule.onRegister：注册 AppCoreConfigModule
      ConfigService.instance.registerModule(AppCoreConfigModule());
      final setResult =
          await ConfigService.instance.set(ConfigKeys.themeMode, 1);
      expect(setResult.success, true, reason: 'theme_mode 应已注册');

      // 模拟 download 模块下线（unbindService 联动 manager）
      final manager = ModuleManager.instance;
      await DownloadModule().onUnregister(ModuleContext(
        config: ConfigService.instance,
        unbindService: (type) => manager.unbindByType(type),
      ));

      // 配置是全局的，不随 download 下线注销：themeMode 仍返回注册值
      final value = await ConfigService.instance.getT<int>(ConfigKeys.themeMode);
      expect(value, 1, reason: 'app_core 配置不随 download 模块下线注销');
    });
  });
}