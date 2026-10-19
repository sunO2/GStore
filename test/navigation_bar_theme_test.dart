import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/theme/theme_data_builder.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/page/home/view.dart';

/// 底部导航胶囊与页面背景层次测试（深色模式融合修复回归）
///
/// 覆盖：
/// ① 深色主题 navigationBarTheme.backgroundColor 存在，且与 scaffoldBackgroundColor
///    的相对亮度（computeLuminance）差值 > 0.02（胶囊比页面底提升一档层次，不再融合）
/// ② 浅色主题 navigationBarTheme.backgroundColor 存在（磨砂 surface@82% 收编全局主题）
/// ③ 首页 NavigationBar 的局部 64px 高度覆盖必须「合并」而非「替换」应用主题，
///    保证 indicatorColor/iconTheme/labelTextStyle/elevation/backgroundColor 仍在。
/// ④ 四个 tab 图标中心与等分中心对齐（几何偏移测量）。

/// 测试用 agent_tools 模块（无依赖、无副作用，不绑定服务）
class TestAgentToolsModule extends AppModule {
  @override
  String get moduleName => 'agent_tools';

  @override
  int get priority => 10;

  @override
  Future<void> onRegister(ModuleContext context) async {}

  @override
  Future<void> onUnregister(ModuleContext context) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('navigationBarTheme 与 scaffold 背景层次', () {
    test('深色：导航底色存在且与页面背景亮度差 > 0.02（有层次）', () {
      final dark = ThemeDataBuilder.buildDarkTheme(null);

      final navBg = dark.navigationBarTheme.backgroundColor;
      expect(navBg, isNotNull, reason: '深色主题必须显式提供导航栏底色');

      final navLuminance = navBg!.computeLuminance();
      final scaffoldLuminance = dark.scaffoldBackgroundColor.computeLuminance();
      final delta = (navLuminance - scaffoldLuminance).abs();

      expect(
        delta,
        greaterThan(0.02),
        reason: '深色下导航胶囊底色与 scaffold 背景亮度差 $delta ≤ 0.02，'
            '会导致悬浮胶囊与页面内容背景融层',
      );
    });

    test('浅色：导航底色存在（surface 磨砂收编全局主题）', () {
      final light = ThemeDataBuilder.buildLightTheme(null);

      final navBg = light.navigationBarTheme.backgroundColor;
      expect(navBg, isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // 挂载真实首页（PageView 四页），测量底部 NavigationBar。
  //
  // 背景：home/view.dart 内层用 Theme(copyWith(navigationBarTheme: ...)) 局部压缩
  // 胶囊高度到 64。若直接 new 一个 NavigationBarThemeData(height: 64)，会整体替换
  // 掉应用主题里已定义的 backgroundColor/elevation/indicatorColor/iconTheme/
  // labelTextStyle，导致选中态退回 M3 默认（secondaryContainer + 弱化图标色）。
  // 本组测试锁定该合并语义，并测量四个 tab 的几何中心是否等分对齐。
  // ---------------------------------------------------------------------------
  group('首页 NavigationBar 局部主题合并 + tab 几何对齐', () {
    final manager = ModuleManager.instance;
    late ProviderContainer container;

    setUp(() async {
      await manager.clear();
      manager.injectContext(null);
      manager.registerKnownModules(() => [TestAgentToolsModule()]);
      await manager.activate(TestAgentToolsModule());
      expect(manager.isModuleEnabled('agent_tools'), isTrue);

      container = ProviderContainer();
      addTearDown(container.dispose);

      manager.bind<GithubRestClient>(GithubRestClient(DioClient().get()));
      manager.bind<UserManager>(UserManager.instance);
      manager.bind<ThemeController>(ThemeController());
      manager.bind<BadgeService>(BadgeService());
      FlutterSecureStoragePlatform.instance =
          TestFlutterSecureStoragePlatform(const {});
    });

    Future<void> pumpHome(WidgetTester tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeDataBuilder.buildLightTheme(null),
            home: const HomePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 取 NavigationBar 内部实际的 NavigationBarTheme（含局部 height: 64 覆盖）
    NavigationBarThemeData effectiveNavTheme(WidgetTester tester) {
      final navBarElement = tester.element(find.byType(NavigationBar));
      return Theme.of(navBarElement).navigationBarTheme;
    }

    testWidgets('③ 局部 height 覆盖后仍保留应用主题的 indicator/icon/label/elevation',
        (tester) async {
      await pumpHome(tester);

      final theme = effectiveNavTheme(tester);

      // 应用主题（buildLightTheme）里定义的关键属性不得被局部覆盖抹掉
      expect(theme.height, 64, reason: '局部仍应把高度压缩到 64');
      expect(theme.elevation, 0, reason: 'elevation 不应退回 M3 默认');
      expect(theme.indicatorColor, isNotNull,
          reason: 'indicatorColor 不应被替换为空（否则选中 pill 退回 secondaryContainer）');
      expect(theme.backgroundColor, isNotNull, reason: '背景色不应被替换为空');
      expect(theme.iconTheme, isNotNull, reason: 'iconTheme 不应被替换为空');
      expect(theme.labelTextStyle, isNotNull, reason: 'labelTextStyle 不应被替换为空');

      // 选中态图标色必须是主题的 primary（而非 M3 默认弱化色）
      final scheme = Theme.of(tester.element(find.byType(NavigationBar))).colorScheme;
      final selectedIcon = theme.iconTheme!.resolve({WidgetState.selected});
      expect(selectedIcon?.color, scheme.primary,
          reason: '选中图标色应为 colorScheme.primary（主题 iconTheme 生效）');
      final unselectedIcon = theme.iconTheme!.resolve(const {});
      expect(unselectedIcon?.color, scheme.onSurfaceVariant,
          reason: '未选中图标色应为 colorScheme.onSurfaceVariant');
      expect(theme.indicatorColor, scheme.primaryContainer,
          reason: '选中 pill 底色应为 colorScheme.primaryContainer');
      expect(tester.takeException(), isNull);
    });

    testWidgets('④ 四个 tab 图标中心与等分中心对齐（偏移测量）', (tester) async {
      // 固定视口，消除设备尺寸对等分中心的影响
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpHome(tester);

      final bar = tester.getRect(find.byType(NavigationBar));
      // 当前选中 tab 0：其图标为 home_filled，其余为各自未选中图标
      final glyphs = <IconData>[
        TablerIcons.home_filled,
        TablerIcons.compass,
        TablerIcons.message_chatbot,
        TablerIcons.user,
      ];

      for (var i = 0; i < glyphs.length; i++) {
        final centerDx = tester.getCenter(find.byIcon(glyphs[i])).dx;
        final expected = bar.left + bar.width * (2 * i + 1) / 8;
        final delta = centerDx - expected;
        debugPrint(
            '[navbar-measure] tab $i center=$centerDx expected=$expected delta=$delta');
        expect(delta.abs(), lessThan(1.0),
            reason: 'tab $i 图标中心偏移 $delta px（|Δ|>1 视为真实几何错位）');
      }
      expect(tester.takeException(), isNull);
    });
  });
}
