import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/page/download/logic.dart';
import 'package:gstore/page/installed_apps/view.dart';
import 'package:gstore/page/settings/settings_page.dart';
import 'package:gstore/page/settings/theme_settings_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// 无依赖桩模块（补齐 theme 的 config 依赖声明）
class _StubModule extends AppModule {
  _StubModule(this.moduleName);

  @override
  final String moduleName;
}

/// install（Shizuku）与 theme 模块下线降级测试
///
/// 验证：
/// ① InstallModule 上线（onRegister）后 get<InstallManager>() 返回实例（按具体类型绑定，
///    覆盖接口外方法 isShizukuAvailable/openUninstallInSystem/openAppDetailsInSystem 等）
/// ② install 禁用 → unbind → get<InstallManager>() null + 已安装应用页「安装模块未启用」占位
/// ③ 设置页 Shizuku tile 下线禁用显示「安装模块未启用」
/// ④ DownloadManagerLogic.installApp 服务 null 短路提示不抛
/// ⑤ agent installApp/installedApps 工具服务 null 降级返回提示不抛
/// ⑥ theme 下线 → 设置页主题 tile 禁用 + 主题设置页「主题模块未启用」占位
/// ⑦ 上线恢复：install 重新上线 → 已安装应用页占位恢复；theme 重新上线 → 主题设置页占位恢复
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Linux 仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final manager = ModuleManager.instance;

  /// 注入服务绑定上下文（模拟 main.dart 装配）
  void injectBindingContext() {
    manager.injectContext(ModuleContext(
      config: null,
      bindService: (type, impl) => manager.bindByType(type, impl),
      unbindService: (type) => manager.unbindByType(type),
      manager: manager,
    ));
  }

  /// 注册并初始化 install 模块（无依赖）
  Future<void> registerInstallModule() async {
    await manager.registerModule(InstallModule());
    await manager.initializeModule('install');
  }

  /// 注册并初始化 theme 模块（依赖 config 用无副作用桩模块补齐）
  Future<void> registerThemeModule() async {
    await manager.registerModule(_StubModule('config'));
    await manager.registerModule(ThemeModule());
    await manager.initializeModule('theme');
  }

  /// 设置页深滚动到「安装与权限」分组时，数据更新 tile 的 Obx 读取 BadgeService；
  /// 未注册会抛 Get.find 异常（与本次改动无关的既有依赖，注册即可）
  void putSettingsPageDeps() {
    if (!Get.isRegistered<BadgeService>()) Get.put(BadgeService());
  }

  setUp(() async {
    await manager.clear();
    manager.injectContext(null);
    Get.reset();
  });

  group('InstallModule 管理 InstallManager（按具体类型注册表化）', () {
    test('① 模块注册+初始化后 get<InstallManager>() 返回实例（bind 生效）', () async {
      injectBindingContext();
      await registerInstallModule();

      expect(manager.get<InstallManager>(), same(InstallManager.instance),
          reason: 'onRegister 应按具体类型绑定 InstallManager.instance');
      expect(manager.get<IInstallService>(), same(InstallManager.instance),
          reason: 'IInstallService 接口绑定保留');
    });

    test('② install 禁用（setModuleEnabled(false)）→ unbind → get<InstallManager>() null',
        () async {
      injectBindingContext();
      manager.registerKnownModules(() => [InstallModule()]);
      await registerInstallModule();
      expect(manager.get<InstallManager>(), isNotNull,
          reason: '上线后服务应已绑定');

      final ok = await manager.setModuleEnabled('install', false);
      expect(ok, isTrue);
      expect(manager.hasModule('install'), isFalse);
      expect(manager.get<InstallManager>(), isNull,
          reason: '下线后按类型绑定应已解绑（消费方降级）');
      expect(manager.get<IInstallService>(), isNull,
          reason: '下线后接口绑定应已解绑');
    });
  });

  group('install 下线页面降级（widget）', () {
    testWidgets('②b install 下线 → 已安装应用页显示「安装模块未启用」占位，不渲染功能内容',
        (tester) async {
      injectBindingContext();
      manager.registerKnownModules(() => [InstallModule()]);
      await registerInstallModule();
      await manager.setModuleEnabled('install', false);
      expect(manager.get<InstallManager>(), isNull);

      await tester.pumpWidget(GetMaterialApp(
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const InstalledAppsPage(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('安装模块未启用'), findsOneWidget);
      expect(find.text('搜索已安装应用...'), findsNothing,
          reason: '下线时不应渲染应用列表/搜索功能');
      expect(tester.takeException(), isNull);
    });

    testWidgets('③ install 下线 → 设置页 Shizuku tile 禁用显示「安装模块未启用」', (tester) async {
      injectBindingContext();
      manager.registerKnownModules(() => [InstallModule()]);
      await registerInstallModule();
      await manager.setModuleEnabled('install', false);
      putSettingsPageDeps();

      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 「安装与权限」分组位于设置页下部，滚动到可见（ListView 懒构建）
      await tester.scrollUntilVisible(
        find.text('安装模块未启用'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();

      expect(find.text('安装模块未启用'), findsOneWidget,
          reason: 'Shizuku tile 应显示未启用提示');
      final tile =
          tester.widget<ListTile>(find.widgetWithText(ListTile, 'Shizuku 状态'));
      expect(tile.enabled, isFalse, reason: '下线时 Shizuku tile 应为禁用态');
      expect(tile.onTap, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('install 消费方 null 短路', () {
    /// 环境：AppDialogs snackbar 需要 MaterialApp + scaffoldMessengerKey
    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const Scaffold(body: SizedBox()),
      ));
    }

  setUp(() async {
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

    testWidgets('④ 服务 null 时 DownloadManagerLogic.installApp 短路提示「安装模块未启用」不抛',
        (tester) async {
      await pumpApp(tester);

      final logic = DownloadManagerLogic();
      final status = DownloadTask(
        id: 1,
        appId: 'com.example.a',
        appName: 'App A',
        version: '1.0.0',
        fileName: 'a.apk',
        url: 'https://example.com/a.apk',
        filePath: '/tmp/a.apk',
        total: 0,
        received: 0,
        status: DownloadStatusEnum.completed,
        speedBps: 0,
        etaSec: null,
        error: null,
        segments: null,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(ModuleManager.instance.get<InstallManager>(), isNull,
          reason: '前置：未绑定 InstallManager');

      unawaited(logic.installApp(status));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('安装模块未启用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('⑤ install 服务未绑定 → agent installApp/installedApps 工具返回「安装模块未启用」不抛',
        () async {
      final agent = AgentService();
      expect(ModuleManager.instance.get<InstallManager>(), isNull,
          reason: '前置：未绑定 InstallManager');

      final installResult =
          await agent.runTool('installApp', {'savePath': '/tmp/x.apk'});
      expect(installResult, contains('安装模块未启用'));

      final manageResult = await agent.runTool('installedApps', {
        'action': 'uninstall',
        'packageName': 'com.example.app',
      });
      expect(manageResult, contains('安装模块未启用'));
    });
  });

  group('theme 下线入口级降级（widget）', () {
    testWidgets('⑥ theme 下线 → 设置页主题 tile 禁用显示「主题模块未启用」', (tester) async {
      injectBindingContext();
      manager.registerKnownModules(() => [ThemeModule()]);
      await registerThemeModule();
      await manager.setModuleEnabled('theme', false);
      expect(manager.isModuleEnabled('theme'), isFalse);
      putSettingsPageDeps();

      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('主题模块未启用'), findsOneWidget,
          reason: '主题 tile 应显示未启用提示');
      final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, '主题'));
      expect(tile.enabled, isFalse, reason: '下线时主题 tile 应为禁用态');
      expect(tile.onTap, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('⑥b theme 下线 → 主题设置页显示「主题模块未启用」占位，正常内容不渲染',
        (tester) async {
      injectBindingContext();
      manager.registerKnownModules(() => [ThemeModule()]);
      await registerThemeModule();
      await manager.setModuleEnabled('theme', false);

      await tester.pumpWidget(const MaterialApp(home: ThemeSettingsPage()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('主题模块未启用'), findsOneWidget);
      expect(find.text('主题模式'), findsNothing,
          reason: '下线时不应渲染主题功能内容');
      expect(tester.takeException(), isNull);
    });
  });

  group('上线恢复', () {
    testWidgets('⑦ install 重新上线 → 已安装应用页占位恢复', (tester) async {
      injectBindingContext();
      manager.registerKnownModules(() => [InstallModule()]);
      await registerInstallModule();
      await manager.setModuleEnabled('install', false);

      await tester.pumpWidget(GetMaterialApp(
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const InstalledAppsPage(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('安装模块未启用'), findsOneWidget);

      // 重新上线：activate → registered 事件 → 占位恢复为正常内容
      await manager.setModuleEnabled('install', true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(manager.get<InstallManager>(), isNotNull,
          reason: '上线后服务应重新绑定');
      expect(find.text('安装模块未启用'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('⑦b theme 重新上线 → 主题设置页占位恢复', (tester) async {
      injectBindingContext();
      manager.registerKnownModules(() => [ThemeModule()]);
      await registerThemeModule();
      await manager.setModuleEnabled('theme', false);

      await tester.pumpWidget(const MaterialApp(home: ThemeSettingsPage()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('主题模块未启用'), findsOneWidget);

      await manager.setModuleEnabled('theme', true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('主题模块未启用'), findsNothing);
      expect(find.text('主题模式'), findsOneWidget,
          reason: '上线后主题设置页恢复正常内容');
      expect(tester.takeException(), isNull);
    });
  });
}
