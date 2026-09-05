import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_manager.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/providers/theme_config_provider.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/page/download/download_page_providers.dart';
import 'package:gstore/page/download/download_status_utils.dart';
import 'package:gstore/page/download/view.dart';
import 'package:gstore/page/home/tab/discovery/logic.dart';
import 'package:gstore/page/home/tab/discovery/view.dart';
import 'package:gstore/page/home/tab/mine/view.dart';
import 'package:gstore/page/installed_apps/view.dart';
import 'package:gstore/page/settings/theme_settings_page.dart';

// ---------------------------------------------------------------------------
// 主题边框一致性 Wave 2：其他页面边框响应主题 borderStyle（AppBorders）
//
// 验证点：
// ① 发现页应用卡片边框宽度随 cardTheme（bold 1.5）
// ② 我的页外观卡 Divider 不指定 color（继承 dividerTheme）
// ③ 下载分组卡片边框宽度随主题
// ④ 已安装应用卡片侧边宽度随主题
// ⑤ 主题设置页色块边框用 outlineVariant 系（非 Colors.grey）
// ---------------------------------------------------------------------------

/// 测试用 webdav 模块（无依赖、无副作用）
class TestWebDavModule extends AppModule {
  @override
  String get moduleName => 'webdav';

  @override
  int get priority => 10;

  @override
  Future<void> onRegister(ModuleContext context) async {}

  @override
  Future<void> onUnregister(ModuleContext context) async {}
}

/// 注册 ThemeConfigProvider（内存存储预置 useCustomColors=true 配置），
/// 使 ThemeController 加载到自定义颜色配置（Obx 依赖真实 Rx 可观察值）。
Future<void> _registerCustomColorConfig() async {
  final storage = MemoryConfigStorage();
  await storage.setString(
    'theme_config',
    jsonEncode(const AppThemeConfig(useCustomColors: true).toJson()),
  );
  ConfigManager.instance.registerProvider(ThemeConfigProvider(storage));
}

/// 下载逻辑测试替身（同 download_manager_view_test.dart 模式）：
/// 不订阅真实数据库，数据由测试手动注入。
class _TestDownloadNotifier extends DownloadManagerNotifier {
  List<List<DownloadTask>> _seedGroups = [];

  @override
  Future<void> load() async {}

  @override
  DownloadPageState build() {
    return DownloadPageState(
      filter: DownloadFilter.all,
      latestGroups: List.of(_seedGroups),
      groups: List.of(_seedGroups),
    );
  }

  void seed(List<List<DownloadTask>> groups) {
    _seedGroups = List.of(groups);
  }
}

/// 构造 DownloadTask（状态由枚举直接指定）
DownloadTask _item(
  DownloadStatusEnum status, {
  required String appId,
  String appName = '测试应用',
  String version = '1.0.0',
  String fileName = 'app.apk',
}) {
  return DownloadTask(
    id: appId.hashCode,
    appId: appId,
    appName: appName,
    version: version,
    fileName: fileName,
    url: 'https://example.com/$fileName',
    filePath: '/data/media/0/Download/$fileName',
    total: 1000,
    received: 500,
    status: status,
    speedBps: 0,
    etaSec: null,
    error: null,
    segments: null,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

/// 放大测试视口，确保 ListView 懒构建范围内包含目标内容
void _useTallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 主题：cardTheme 侧边宽度 1.5（模拟 borderStyle bold）
ThemeData _boldTheme() => ThemeData(
      cardTheme: const CardThemeData(
        shape: RoundedRectangleBorder(
          side: BorderSide(width: 1.5, color: Colors.red),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('① 发现页应用卡片边框宽度随 cardTheme', () {
    testWidgets('应用卡片边框宽度随主题（bold 1.5）', (tester) async {
      Get.reset();
      final logic = DiscoveryLogic();
      Get.put<DiscoveryLogic>(logic);
      logic.state.channelApps['github'] = [
        const AppSummary(
          appId: 'com.example.test',
          name: '测试应用',
          user: 'user',
          repositories: 'repo',
          icon: '',
          des: '',
        ),
      ];

      await tester.pumpWidget(GetMaterialApp(
        theme: _boldTheme(),
        home: const DiscoveryPage(),
      ));
      await tester.pump();

      // 应用卡片：应用名最近的带边框 Container 祖先
      final appCard = find.ancestor(
        of: find.text('测试应用'),
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).border is Border),
      );
      expect(appCard, findsOneWidget);
      final container = tester.widget<Container>(appCard);
      final border = (container.decoration! as BoxDecoration).border! as Border;
      expect(border.top.width, 1.5,
          reason: '应用卡片边框宽度应随主题 borderStyle（bold=1.5）');
      expect(
        border.top.color,
        Theme.of(tester.element(find.text('测试应用'))).colorScheme.outlineVariant,
        reason: '未选中/未添加卡片边框颜色应保持 outlineVariant 系',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('② 我的页 Divider 继承 dividerTheme', () {
    testWidgets('外观卡展开后 Divider 不指定 color（继承 dividerTheme）', (tester) async {
      Get.reset();
      FlutterSecureStoragePlatform.instance =
          TestFlutterSecureStoragePlatform(const {});
      Get.put(ThemeController());
      Get.put(UserManager.instance);

      final manager = ModuleManager.instance;
      await manager.clear();
      manager.registerKnownModules(() => [TestWebDavModule()]);
      await manager.activate(TestWebDavModule());

      await tester.pumpWidget(
          const ProviderScope(child: GetMaterialApp(home: MinePage())));
      await tester.pumpAndSettle();

      final appearanceCard =
          find.ancestor(of: find.text('外观'), matching: find.byType(Card));
      expect(appearanceCard, findsOneWidget);

      // 展开外观卡（SizeTransition 内的 Divider 才可见）
      await tester.tap(find.descendant(
        of: appearanceCard,
        matching: find.byIcon(Icons.expand_more),
      ));
      await tester.pumpAndSettle();

      final dividers = tester.widgetList<Divider>(find.descendant(
        of: appearanceCard,
        matching: find.byType(Divider),
      ));
      expect(dividers, isNotEmpty);
      for (final d in dividers) {
        expect(d.color, isNull,
            reason: 'Divider 不应手写 color，应继承 dividerTheme（随主题 borderStyle）');
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('③ 下载分组卡片边框宽度随主题', () {
    testWidgets('分组卡片边框宽度随主题（bold 1.5）', (tester) async {
      Get.reset();
      final notifier = _TestDownloadNotifier();
      notifier.seed([
        [
          _item(DownloadStatusEnum.paused,
              appId: 'com.example.a', appName: '下载应用'),
        ],
      ]);

      await tester.pumpWidget(ProviderScope(
        overrides: [downloadManagerProvider.overrideWith(() => notifier)],
        child: GetMaterialApp(
          theme: _boldTheme(),
          home: const DownloadManager(),
        ),
      ));
      await tester.pump();

      final appCard = find.byType(AppCard);
      expect(appCard, findsOneWidget);
      final card = tester.widget<Card>(
          find.descendant(of: appCard, matching: find.byType(Card)));
      final shape = card.shape! as RoundedRectangleBorder;
      expect(shape.side.width, 1.5,
          reason: '下载分组卡片边框宽度应随主题 borderStyle（bold=1.5）');
      expect(tester.takeException(), isNull);
    });
  });

  group('④ 已安装应用卡片侧边宽度随主题', () {
    testWidgets('卡片侧边宽度随主题（bold 1.5）', (tester) async {
      Get.reset();
      // mock 平台通道：installed_apps 返回假应用列表；shizuku 无 binder
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('installed_apps'),
        (call) async {
          if (call.method == 'getInstalledApps') {
            return [
              {
                'name': '测试应用',
                'package_name': 'com.example.test',
                'version_name': '1.0.0',
                'version_code': 1,
                'built_with': 'flutter',
                'installed_timestamp': 0,
              },
            ];
          }
          return null;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('shizuku_api'),
        (call) async {
          if (call.method == 'pingBinder') return false;
          return null;
        },
      );

      final manager = ModuleManager.instance;
      await manager.clear();
      manager.injectContext(ModuleContext(
        config: null,
        bindService: (type, impl) => manager.bindByType(type, impl),
        unbindService: (type) => manager.unbindByType(type),
        manager: manager,
      ));
      await manager.registerModule(InstallModule());
      await manager.initializeModule('install');

      await tester.pumpWidget(GetMaterialApp(
        theme: _boldTheme(),
        home: const InstalledAppsPage(),
      ));
      await tester.pumpAndSettle();

      final tileCard =
          find.ancestor(of: find.text('测试应用'), matching: find.byType(Card));
      expect(tileCard, findsOneWidget);
      final card = tester.widget<Card>(tileCard);
      final shape = card.shape! as RoundedRectangleBorder;
      expect(shape.side.width, 1.5,
          reason: '已安装应用卡片侧边宽度应随主题 borderStyle（bold=1.5）');
      expect(
        shape.side.color,
        Theme.of(tester.element(tileCard)).colorScheme.outlineVariant,
        reason: '已安装应用卡片侧边颜色应保持 outlineVariant 系',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('⑤ 主题设置页色块边框用 outlineVariant 系', () {
    testWidgets('ColorPicker 色块边框用 outlineVariant（非 Colors.grey）',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ColorPicker(color: Colors.red, onColorChanged: (_) {}),
        ),
      ));

      final swatches = tester.widgetList<Container>(find.byWidgetPredicate((w) {
        if (w is! Container) return false;
        final deco = w.decoration;
        return deco is BoxDecoration && deco.border is Border;
      })).toList();
      expect(swatches, isNotEmpty);

      final expected = Theme.of(tester.element(find.byType(ColorPicker)))
          .colorScheme
          .outlineVariant
          .withValues(alpha: 0.3);
      for (final c in swatches) {
        final border = (c.decoration! as BoxDecoration).border! as Border;
        if (border.top.color == Colors.white) continue; // 选中态白色对比边框
        expect(border.top.color, expected,
            reason: '色块边框应使用 outlineVariant 系（非 Colors.grey）');
      }
    });

    testWidgets('主题设置页自定义色块边框用 outlineVariant（非 Colors.grey）', (tester) async {
      _useTallView(tester);
      Get.reset();
      await _registerCustomColorConfig();
      Get.put(ThemeController());

      await tester.pumpWidget(
          const ProviderScope(child: MaterialApp(home: ThemeSettingsPage())));
      await tester.pumpAndSettle();

      // 自定义色块：24x24 带边框 Container（主色/次要色/第三色预览）
      final swatches = tester.widgetList<Container>(find.byWidgetPredicate((w) {
        if (w is! Container) return false;
        final deco = w.decoration;
        if (deco is! BoxDecoration || deco.border is! Border) return false;
        final c = w.constraints;
        return c is BoxConstraints && c.maxWidth == 24 && c.maxHeight == 24;
      })).toList();
      expect(swatches, isNotEmpty);

      final expected = Theme.of(tester.element(find.byType(ThemeSettingsPage)))
          .colorScheme
          .outlineVariant
          .withValues(alpha: 0.3);
      for (final c in swatches) {
        final border = (c.decoration! as BoxDecoration).border! as Border;
        expect(border.top.color, expected,
            reason: '自定义色块边框应使用 outlineVariant 系（非 Colors.grey）');
      }
      expect(tester.takeException(), isNull);
    });
  });
}
