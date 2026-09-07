import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/page/home/logic.dart';
import 'package:gstore/page/home/view.dart';
import 'package:gstore/page/home/tab/mine/view.dart';

/// AI 助手入口随 agent_tools 模块上下线隐藏测试
///
/// 验证：
/// ① agent_tools 上线 → 底部 NavigationBar 含 'AI 助手' destination，raw==display
/// ② agent_tools 下线 → destination 隐藏、display 映射（raw3 → display2）
/// ③ 下线时点 display2（我的）→ 实际切到 raw3（我的页）
/// ④ 我的页 quick action：下线隐藏 'AI 助手'、上线恢复
/// ⑤ 运行中下线且当前在 AI tab（raw2）→ 自动跳回来源 tab（防困在无入口页面）
///
/// 状态流转：ModuleManager 事件 → _HomePageState._agentModuleEnabled /
/// _MinePageState._agentModuleOnline → 入口显示/隐藏（rawIndex 0-3 语义不变）。
/// 首页 tab 状态由 Riverpod homeProvider 管理。

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

  final manager = ModuleManager.instance;

  late ProviderContainer container;

  setUp(() async {
    await manager.clear();
    manager.injectContext(null);
    // agent_tools 模块初始在线（registered + initialized）
    manager.registerKnownModules(() => [TestAgentToolsModule()]);
    await manager.activate(TestAgentToolsModule());
    expect(manager.isModuleEnabled('agent_tools'), isTrue);
    expect(manager.isInitialized('agent_tools'), isTrue);

    // Riverpod 容器（homeProvider 首读即建）
    container = ProviderContainer();
    addTearDown(container.dispose);

    // 绑定页面依赖服务（GithubRestClient/UserManager/ThemeController/BadgeService
    // 经 ModuleManager 注册表取用；unbind 由 setUp 的 manager.clear() 清理）
    manager.bind<GithubRestClient>(GithubRestClient(DioClient().get()));
    manager.bind<UserManager>(UserManager.instance);
    manager.bind<ThemeController>(ThemeController());
    manager.bind<BadgeService>(BadgeService());
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(const {});
  });

  tearDown(() {
  });

  /// NavigationBar 内指定 label 的 destination
  Finder navBarDest(String label) => find.descendant(
      of: find.byType(NavigationBar), matching: find.text(label));

  /// 首页 tab 控制器（homeProvider）
  HomeNotifier homeNotifier() => container.read(homeProvider.notifier);

  /// 泵起首页（PageView 四页：首页/发现/AI 助手/我的）并等异步初始化完成
  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 下线 agent_tools 并等 broadcast 事件投递 + 重建帧
  Future<void> disableAgent(WidgetTester tester) async {
    await manager.setModuleEnabled('agent_tools', false);
    await tester.pump();
    await tester.pump();
    expect(manager.isModuleEnabled('agent_tools'), isFalse);
  }

  group('首页底部 tab（agent_tools 上下线）', () {
    testWidgets('① 上线 → NavigationBar 含 AI 助手 destination，raw==display 映射',
        (tester) async {
      await pumpHome(tester);

      expect(navBarDest('AI 助手'), findsOneWidget);
      expect(navBarDest('首页'), findsOneWidget);
      expect(navBarDest('发现'), findsOneWidget);
      expect(navBarDest('我的'), findsOneWidget);

      var navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 0);

      // raw3（我的）→ display3（上线时 raw==display）
      homeNotifier().jumpToPage(3);
      await tester.pumpAndSettle();
      navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 3, reason: '上线时 raw3 应映射到 display3');
      expect(container.read(homeProvider).index, 3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('② 下线 → AI 助手 destination 隐藏，display 映射（raw3→display2）',
        (tester) async {
      await pumpHome(tester);
      expect(navBarDest('AI 助手'), findsOneWidget);

      await disableAgent(tester);

      expect(navBarDest('AI 助手'), findsNothing);
      expect(navBarDest('首页'), findsOneWidget);
      expect(navBarDest('发现'), findsOneWidget);
      expect(navBarDest('我的'), findsOneWidget);

      // raw3（我的）→ display2
      homeNotifier().jumpToPage(3);
      await tester.pumpAndSettle();
      final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 2, reason: '下线后 raw3 应映射到 display2');
      expect(container.read(homeProvider).index, 3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('③ 下线时点 display2（我的）→ 实际切到 raw3（我的页）',
        (tester) async {
      await pumpHome(tester);
      await disableAgent(tester);

      await tester.tap(navBarDest('我的'));
      await tester.pumpAndSettle();

      expect(container.read(homeProvider).index, 3,
          reason: 'display2 应映射到 raw3（我的页）');
      final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('⑤ 运行中下线且当前在 AI tab → 自动跳回来源 tab', (tester) async {
      await pumpHome(tester);

      // 进入 AI tab（raw2），sourceIndex 记录 0（首页）
      homeNotifier().jumpToPage(2);
      await tester.pumpAndSettle();
      expect(container.read(homeProvider).index, 2);

      await disableAgent(tester);

      expect(container.read(homeProvider).index, 0,
          reason: '下线时应自动跳回来源 tab（首页 raw0）');
      expect(navBarDest('AI 助手'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('我的页 quick action（agent_tools 上下线）', () {
    Future<void> pumpMinePage(WidgetTester tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: MinePage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('④ 下线 → AI 助手入口隐藏；上线恢复 → 重新可见', (tester) async {
      await pumpMinePage(tester);
      expect(find.text('AI 助手'), findsOneWidget);
      expect(find.text('已安装应用'), findsOneWidget);

      await disableAgent(tester);
      expect(find.text('AI 助手'), findsNothing);
      expect(find.text('已安装应用'), findsOneWidget,
          reason: '其余 quick action 不受影响');

      // 上线：activate → registered 事件 → 入口恢复
      await manager.setModuleEnabled('agent_tools', true);
      await tester.pump();
      await tester.pump();
      expect(manager.isModuleEnabled('agent_tools'), isTrue);
      expect(find.text('AI 助手'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('④b 下线后 AI ListTile 与其下方 Divider 一并隐藏（视觉无残留分割线）',
        (tester) async {
      await pumpMinePage(tester);
      await disableAgent(tester);

      // 卡片内剩余 ListTile 之间的 Divider 数量 = 2（已安装/设置 之间）
      final quickCard = find.ancestor(
          of: find.text('已安装应用'), matching: find.byType(Card));
      expect(find.descendant(of: quickCard, matching: find.byType(Divider)),
          findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });
}
