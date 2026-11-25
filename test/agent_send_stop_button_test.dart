import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/page/agent/agent_more_action.dart';
import 'package:gstore/page/agent/view.dart';

/// 输入栏发送按钮状态切换回归测试：
/// 空闲 → 发送按钮；生成中 → 停止按钮（不再是禁用 loading）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);

    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(storages: [
      MemoryConfigStorage(),
      MemoryConfigStorage(),
    ]);
    ConfigRegistry.registerAll(ConfigService.instance);

    final manager = ModuleManager.instance;
    manager.injectContext(ModuleContext(
      config: ConfigService.instance,
      bindService: (type, impl) => manager.bindByType(type, impl),
      unbindService: (type) => manager.unbindByType(type),
      manager: manager,
    ));
    await manager.registerModule(_StubModule('config'));
    await manager.registerModule(_StubModule('channel'));
    await manager.registerModule(AgentToolsModule());
    await manager.initializeModule('agent_tools');
  });

  testWidgets('生成中切换为停止按钮，结束后恢复发送按钮', (tester) async {
    final svc = ModuleManager.instance.get<AgentService>();
    expect(svc, isNotNull);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AgentPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('agent-send-button')), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget);

    // 生成中：停止按钮可用（不是禁用态）
    svc!.busy.value = true;
    await tester.pump();

    expect(find.byKey(const Key('agent-stop-button')), findsOneWidget);
    expect(find.byIcon(TablerIcons.player_stop), findsOneWidget);
    expect(find.byTooltip('停止生成'), findsOneWidget);
    final stopButton =
        tester.widget<IconButton>(find.byKey(const Key('agent-stop-button')));
    expect(stopButton.onPressed, isNotNull);

    // 点击停止不抛异常
    await tester.tap(find.byKey(const Key('agent-stop-button')));
    await tester.pump();

    // 生成结束：恢复发送按钮
    svc.busy.value = false;
    await tester.pump();
    expect(find.byKey(const Key('agent-send-button')), findsOneWidget);
  });

  testWidgets('键盘收起时输入栏平滑回落，不在最后一帧跳变', (tester) async {
    addTearDown(tester.view.reset);
    // TestFlutterView 的 viewInsets/viewPadding 是物理像素，需乘 dpr
    final dpr = tester.view.devicePixelRatio;
    tester.view.viewPadding = FakeViewPadding(bottom: 24 * dpr);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AgentPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final send = find.byKey(const Key('agent-send-button'));
    final closedBottom = tester.getRect(send).bottom;
    final list = find.byType(ListView);
    double listBottom() =>
        (tester.widget<ListView>(list).padding as EdgeInsets).bottom;

    // 完全收起：列表 padding 包含安全区（24）+ 胶囊占位（64+8）
    expect(listBottom(), closeTo(108, 1e-9));

    // 弹出键盘：等待动画结束
    tester.view.viewInsets = FakeViewPadding(bottom: 200 * dpr);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final openBottom = tester.getRect(send).bottom;
    expect(openBottom, lessThan(closedBottom - 150),
        reason: '键盘弹出后输入栏应贴键盘上方');
    expect(listBottom(), closeTo(84, 1e-9),
        reason: '键盘完全弹出时列表只需避让输入胶囊');

    // 收起键盘：动画中途应处于两端之间
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final middleBottom = tester.getRect(send).bottom;
    expect(middleBottom, greaterThan(openBottom));
    expect(middleBottom, lessThan(closedBottom));

    // 动画尾段（键盘已快归零）：列表 padding 应已开始补安全区，
    // 而不是等到最后一帧才从 84 跳到 108。
    await tester.pump(const Duration(milliseconds: 50));
    expect(listBottom(), greaterThan(84));
    expect(listBottom(), lessThan(108));

    // 动画结束后回到收起位置
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(send).bottom, closeTo(closedBottom, 0.5));
    expect(listBottom(), closeTo(108, 1e-9));
  });

  testWidgets('右上角更多菜单与上下文进度环', (tester) async {
    final svc = ModuleManager.instance.get<AgentService>();
    expect(svc, isNotNull);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AgentPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 旧的 3 个 action 不再直接出现在导航栏
    expect(find.byKey(AgentMoreAction.buttonKey), findsOneWidget);
    expect(find.byKey(AgentMoreAction.ringKey), findsOneWidget);
    expect(find.byIcon(TablerIcons.message_plus), findsNothing);
    expect(find.byIcon(TablerIcons.history), findsNothing);
    expect(find.byIcon(TablerIcons.settings), findsNothing);

    // 50% 上下文 → 进度环一半
    svc!.sessionTokens.value = const AgentSessionTokenStats(
      inputTokens: 2000,
      outputTokens: 1000,
      contextTokens: 500000,
      compactCount: 2,
    );
    await tester.pump();

    final ring = tester.widget<AgentSessionTokenRing>(
      find.byKey(AgentMoreAction.ringKey),
    );
    expect(ring.progress, closeTo(0.5, 1e-9));

    await tester.tap(find.byKey(AgentMoreAction.buttonKey));
    await tester.pumpAndSettle();

    expect(find.text('新建会话'), findsOneWidget);
    expect(find.text('会话列表'), findsOneWidget);
    expect(find.text('模型设置'), findsOneWidget);
    expect(find.text('压缩上下文'), findsOneWidget);
    expect(find.text('本会话 Tokens'), findsOneWidget);
    // 输入/输出用箭头胶囊表示
    expect(find.text('2.0k'), findsOneWidget);
    expect(find.text('1.0k'), findsOneWidget);
    // 已用 / 上限分别用胶囊
    expect(find.text('500.0k'), findsOneWidget);
    expect(find.text('1.0M'), findsOneWidget);
    expect(find.text('/'), findsOneWidget);
    // 自动压缩次数移入“压缩上下文”区域的 [图标 + N次] 胶囊
    expect(find.text('2次'), findsOneWidget);

    // 关闭菜单
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });
}

/// 无依赖桩模块（补齐 agent_tools 的 config/channel 依赖声明）
class _StubModule extends AppModule {
  _StubModule(this.moduleName);

  @override
  final String moduleName;
}
