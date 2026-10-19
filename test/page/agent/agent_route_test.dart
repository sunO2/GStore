import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/page/agent/view.dart';

/// AgentPage 路由化回归测试（plan todo 32：route-only agent）。
///
/// AgentPage 已去掉 `isTabEmbedded` / `sourceIndex` 返回逻辑，仅作为
/// `AppRoute.agent` 独立路由页存在。覆盖：
/// ① 路由 push → `HomeTabVisibility.agentActive == true`；pop → false，
///    且**不依赖任何来源返回按钮**（sourceIndex 派生的返回按钮已移除）；
/// ② agent_tools 模块禁用（服务未注册）→ 页面守卫提示、不崩。
Future<void> _initConfig() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(storages: [
    MemoryConfigStorage(),
    MemoryConfigStorage(),
  ]);
  ConfigRegistry.registerAll(ConfigService.instance);
}

/// 路由起点：一个按钮把 `/agent` push 进栈。
class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => context.push('/agent'),
          child: const Text('go-agent'),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    await _initConfig();
    HomeTabVisibility.instance.setAgentRoute(false);
    HomeTabVisibility.instance.setHomeAgentTab(false);
  });

  tearDown(() {
    HomeTabVisibility.instance.setAgentRoute(false);
    HomeTabVisibility.instance.setHomeAgentTab(false);
  });

  testWidgets('① push → agentActive=true；pop → false（无来源返回按钮依赖）',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const _Home()),
        GoRoute(path: '/agent', builder: (_, __) => const AgentPage()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pump();

    expect(find.byType(AgentPage), findsNothing);
    expect(HomeTabVisibility.instance.agentActive, isFalse,
        reason: '未进入 Agent 路由时不可见');

    await tester.tap(find.text('go-agent'));
    await tester.pumpAndSettle();

    expect(find.byType(AgentPage), findsOneWidget);
    expect(HomeTabVisibility.instance.agentActive, isTrue,
        reason: '路由进入应标记 AI 页可见（服务层门控依赖）');

    // 来源 tab 返回按钮（sourceIndex 派生）已随 tab 脚手架移除
    expect(find.byTooltip('返回首页'), findsNothing);
    expect(find.byTooltip('返回发现'), findsNothing);
    expect(find.byTooltip('返回我的'), findsNothing);

    router.pop();
    await tester.pumpAndSettle();

    expect(find.byType(AgentPage), findsNothing);
    expect(HomeTabVisibility.instance.agentActive, isFalse,
        reason: '路由退出应复位可见性');
    expect(tester.takeException(), isNull);
  });

  testWidgets('② agent_tools 模块禁用 → 守卫提示、不崩', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AgentPage()),
      ),
    );
    await tester.pump();

    // 服务未注册（模块禁用）→ 降级提示可见，页面不崩
    expect(find.text('Agent 模块未启用'), findsWidgets);
    expect(tester.takeException(), isNull);
    // 路由页可见性仍被标记（服务层后台通知门控依赖）
    expect(HomeTabVisibility.instance.agentActive, isTrue);
  });
}
