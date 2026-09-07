import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/module/module_toggle_config.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/page/module_manage/logic.dart';
import 'package:gstore/page/module_manage/view.dart';
import 'package:gstore/page/settings/settings_page.dart';

/// 测试用统一初始化：内存存储 + 配置注册表 + 清空模块注册中心
Future<void> initForTest() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(storages: [
    MemoryConfigStorage(),
    MemoryConfigStorage(),
  ]);
  ConfigRegistry.registerAll(ConfigService.instance);
  await ModuleManager.instance.clear();
}

/// 慢速内存存储：写入延迟 5s，模拟切换中的 in-flight 窗口（防连击测试）
class _SlowMemoryConfigStorage extends MemoryConfigStorage {
  @override
  Future<bool> setValue(String key, Object? value) async {
    await Future<void>.delayed(const Duration(seconds: 5));
    return super.setValue(key, value);
  }
}

/// 测试模块（验证 manager 上下线联动）
class ToggleTestModule extends AppModule {
  ToggleTestModule(this.name, {this.deps = const []});

  final String name;
  final List<String> deps;

  @override
  String get moduleName => name;

  @override
  List<String> get dependencies => deps;

  @override
  int get priority => 10;

  @override
  Future<void> onRegister(ModuleContext context) async {}

  @override
  Future<void> onUnregister(ModuleContext context) async {}
}

/// 指定中文名 SwitchListTile 内的 Switch
Finder _switchOf(String title) => find.descendant(
      of: find.widgetWithText(SwitchListTile, title),
      matching: find.byType(Switch),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await initForTest();
    ModuleManager.instance.bind<ThemeController>(ThemeController());
  });

  /// 铺满 17 个条目的大视口（避免 ListView 懒构建导致 offscreen 找不到）
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 包 ProviderScope 的页面挂载（ConsumerWidget 需要）
  Widget wrapApp(Widget home) => ProviderScope(child: home);

  /// 测试宿主 MaterialApp（挂载 appNavigatorKey / scaffoldMessengerKey）
  Widget appHost(Widget home) => MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: home,
      );

  group('模块管理页渲染', () {
    testWidgets('渲染 9 可开关业务模块 + 8 系统置灰模块', (tester) async {
      useTallViewport(tester);

      await tester.pumpWidget(
          wrapApp(appHost(const ModuleManagePage())));
      await tester.pumpAndSettle();

      expect(find.byType(ModuleManagePage), findsOneWidget);
      expect(find.text('模块管理'), findsOneWidget);

      // 17 个 Switch：9 可交互 + 8 置灰（onChanged null）
      final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      expect(switches.length, 17);
      expect(switches.where((s) => s.onChanged != null).length, 9);
      expect(switches.where((s) => s.onChanged == null).length, 8);

      // 业务模块中文名
      for (final title in [
        '渠道', '下载', '备份', 'WebDAV', 'F-Droid',
        '主题', '安装', '我的应用', 'Agent 助手',
      ]) {
        expect(find.text(title), findsOneWidget, reason: '缺少业务模块: $title');
      }
      // 系统模块中文名
      for (final title in ['日志', '配置', '通知', '网络', '数据库', '用户', '更新', '红点']) {
        expect(find.text(title), findsOneWidget, reason: '缺少系统模块: $title');
      }

      // 分组标题
      expect(find.text('业务模块'), findsOneWidget);
      expect(find.text('系统模块'), findsOneWidget);

      // 系统模块标注：6 个「系统模块」+ 2 个「待接口就绪」
      expect(find.textContaining(' · 系统模块'), findsNWidgets(6));
      expect(find.textContaining(' · 待接口就绪'), findsNWidgets(2));

      // 依赖展示（示例抽查）
      expect(find.textContaining('依赖: channel, config'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('切换开关', () {
    testWidgets('切换 → ModuleToggleConfig.setEnabled 被调 + 状态更新（含 re-enable）',
        (tester) async {
      useTallViewport(tester);
      final manager = ModuleManager.instance;
      // re-enable 需要从 known-modules 查实例
      manager.registerKnownModules(() => [ToggleTestModule('channel')]);

      await tester.pumpWidget(
          wrapApp(appHost(const ModuleManagePage())));
      await tester.pumpAndSettle();

      // 初始：渠道开启
      expect(tester.widget<Switch>(_switchOf('渠道')).value, true);

      // 关闭：setEnabled(false) → 配置持久化 + 运行时下线
      await tester.tap(_switchOf('渠道'));
      await tester.pumpAndSettle();
      expect(await ModuleToggleConfig.instance.isModuleEnabled('channel'), false);
      expect(manager.isModuleEnabled('channel'), false);
      expect(tester.widget<Switch>(_switchOf('渠道')).value, false);

      // 重新开启：从 known-modules 恢复 activate
      await tester.tap(_switchOf('渠道'));
      await tester.pumpAndSettle();
      expect(manager.isModuleEnabled('channel'), true);
      expect(manager.hasModule('channel'), true);
      expect(manager.isInitialized('channel'), true);
      expect(tester.widget<Switch>(_switchOf('渠道')).value, true);
      expect(tester.takeException(), isNull);
    });
  });

  group('防连击', () {
    testWidgets('切换中 Switch 置灰禁用 + 重复 toggle 被忽略', (tester) async {
      useTallViewport(tester);
      // 慢速存储：让切换保持 in-flight
      ConfigStore.instance.resetForTest();
      await ConfigStore.instance.initialize(storages: [
        _SlowMemoryConfigStorage(),
        _SlowMemoryConfigStorage(),
      ]);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: appHost(const ModuleManagePage()),
      ));
      await tester.pumpAndSettle();

      final notifier = container.read(moduleManageProvider.notifier);

      // 逻辑层：第一次 toggle 同步进入 toggling；第二次调用被忽略
      final f1 = notifier.toggle('channel', false);
      expect(
          container.read(moduleManageProvider).toggling.contains('channel'),
          isTrue);
      final f2 = notifier.toggle('channel', false);
      await f2; // 立即返回，未重复操作
      expect(
          container.read(moduleManageProvider).toggling.contains('channel'),
          isTrue);

      // 界面层：切换中 Switch 置灰（onChanged null）
      await tester.pump();
      expect(tester.widget<Switch>(_switchOf('渠道')).onChanged, isNull);

      // 推进假时钟完成切换
      await tester.pump(const Duration(seconds: 6));
      await f1;
      await tester.pump();
      expect(container.read(moduleManageProvider).toggling, isEmpty);
      expect(tester.widget<Switch>(_switchOf('渠道')).onChanged, isNotNull);
      expect(tester.widget<Switch>(_switchOf('渠道')).value, false);
      expect(tester.takeException(), isNull);
    });
  });

  group('活跃依赖者拒绝', () {
    testWidgets('关闭被拒 → AppDialogs 提示「关闭 X 将影响 Y/Z 模块」', (tester) async {
      useTallViewport(tester);
      final manager = ModuleManager.instance;
      manager.registerKnownModules(() => [
            ToggleTestModule('channel'),
            ToggleTestModule('backup', deps: ['channel']),
          ]);
      // 注册并激活：backup 依赖 channel 且已初始化 → 成为活跃依赖者
      await manager.activate(ToggleTestModule('channel'));
      await manager.activate(ToggleTestModule('backup', deps: ['channel']));
      expect(manager.isInitialized('channel'), true);
      expect(manager.isInitialized('backup'), true);

      await tester.pumpWidget(ProviderScope(
        child: appHost(const ModuleManagePage()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(_switchOf('渠道'));
      await tester.pumpAndSettle();

      // AppDialogs 警告提示
      expect(find.textContaining('关闭 渠道 将影响 备份 模块'), findsOneWidget);

      // 模块仍在线，Switch 保持开启
      expect(manager.isModuleEnabled('channel'), true);
      expect(manager.hasModule('channel'), true);
      expect(tester.widget<Switch>(_switchOf('渠道')).value, true);

      // 推进 SnackBar 3s 自动消失，避免 pending timer
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('onChange 实时刷新', () {
    testWidgets('外部上下线事件 → 列表状态实时刷新', (tester) async {
      useTallViewport(tester);
      final manager = ModuleManager.instance;
      manager.registerKnownModules(() => [ToggleTestModule('channel')]);
      await manager.activate(ToggleTestModule('channel'));

      await tester.pumpWidget(
          wrapApp(appHost(const ModuleManagePage())));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(_switchOf('渠道')).value, true);

      // 外部触发下线（unregister → unregistered 事件）→ 页面刷新
      await manager.setModuleEnabled('channel', false);
      // 事件经 broadcast 异步投递：第一次 pump 投递（markNeedsBuild），第二次绘制重建帧
      await tester.pump();
      await tester.pump();
      expect(tester.widget<Switch>(_switchOf('渠道')).value, false);

      // 外部触发上线（activate → registered 事件）→ 页面刷新
      await manager.setModuleEnabled('channel', true);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<Switch>(_switchOf('渠道')).value, true);
      expect(tester.takeException(), isNull);
    });
  });

  group('路由导航', () {
    testWidgets('AppRoute.moduleManage 路由可达 ModuleManagePage', (tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: AppRoute.moduleManage,
            routes: [
              GoRoute(
                path: AppRoute.moduleManage,
                builder: (context, state) => const ModuleManagePage(),
              ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(ModuleManagePage), findsOneWidget);
      expect(find.text('模块管理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('设置页「模块」入口点击可达模块管理页', (tester) async {
      // 设置页整体是 ListView：「模块」分组位于「数据与同步」之后，默认视口
      // 下可能未构建。这里用滚动定位入口（贴近真实用户操作），
      // 并注册 BadgeService ——「关于」组的 _DataUpdateTile 若被滚入视口，
      // 其读取 BadgeService 未注册会异常（先例见
      // install_theme_module_disable_test.putSettingsPageDeps）。
      if (!ModuleManager.instance.hasService<BadgeService>()) {
        ModuleManager.instance.bind<BadgeService>(BadgeService());
      }
      // 大视口：让「模块」分组直接可见，无需滚动也能命中
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(ProviderScope(
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: AppRoute.settings,
            routes: [
              GoRoute(
                path: AppRoute.settings,
                builder: (context, state) => const SettingsPage(),
              ),
              GoRoute(
                path: AppRoute.moduleManage,
                builder: (context, state) => const ModuleManagePage(),
              ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // 「数据与同步」分组（首屏可见，作为模块入口所在分组的锚点）
      expect(find.text('数据与同步'), findsOneWidget);

      // 「模块」入口（滚动定位，避免依赖具体视口高度）
      final moduleEntry = find.text('模块管理');
      await tester.scrollUntilVisible(moduleEntry, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(moduleEntry, findsOneWidget);

      await tester.tap(moduleEntry);
      await tester.pumpAndSettle();

      expect(find.byType(ModuleManagePage), findsOneWidget);
      expect(find.text('业务模块'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
