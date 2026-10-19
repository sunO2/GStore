import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/page/home/tab/mine/view.dart';

/// AI 助手入口随 agent_tools 模块上下线隐藏测试（设置 tab / `MinePage`）。
///
/// **plan todo 5 重写**：首页底部导航由四 tab（首页/发现/AI 助手/我的）改为
/// Scene 经典三 tab（功能/首页/设置）后，原「首页底部 tab」用例组依赖的 4-tab
/// `destination`（含 `AI 助手`）、`_displayIndex`/`_rawIndex` 映射与运行中下线
/// 的 `sourceIndex` 自动返回语义均已随 AI tab 移除，故整组删除。仍有效的
/// 「我的页 quick action」门禁（`_MinePageState._agentModuleOnline`）保留验证。
///
/// 覆盖：
/// ④ 我的页 quick action：下线隐藏 'AI 助手'、上线恢复，其余入口不受影响；
/// ④b 下线后 AI ListTile 与其下方 Divider 一并隐藏（视觉无残留分割线）。
///
/// 状态流转：ModuleManager 事件 → `_MinePageState._agentModuleOnline` → 入口显隐。

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

    // Riverpod 容器（MinePage 为 ConsumerStatefulWidget，需 ProviderScope 祖先）
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

  /// 下线 agent_tools 并等 broadcast 事件投递 + 重建帧
  Future<void> disableAgent(WidgetTester tester) async {
    await manager.setModuleEnabled('agent_tools', false);
    await tester.pump();
    await tester.pump();
    expect(manager.isModuleEnabled('agent_tools'), isFalse);
  }

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

      // 上线态：AI/已安装/设置 三个 tile → 2 个 Divider
      expect(
          find.descendant(
              of: find.ancestor(
                  of: find.text('已安装应用'), matching: find.byType(Card)),
              matching: find.byType(Divider)),
          findsNWidgets(2));

      await disableAgent(tester);

      // 下线态：已安装/设置 两个 tile → 恰好 1 个 Divider（AI 与其 Divider 一并隐藏；
      // 若 Divider 残留会检出 2 个）
      final quickCard = find.ancestor(
          of: find.text('已安装应用'), matching: find.byType(Card));
      expect(find.descendant(of: quickCard, matching: find.byType(Divider)),
          findsNWidgets(1));
      expect(tester.takeException(), isNull);
    });
  });
}
