import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/agent_workspace_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/page/agent/agent_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _initMemoryConfig() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(storages: [
    MemoryConfigStorage(),
    MemoryConfigStorage(),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AgentService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AgentModelStore.resetForTest();
    await _initMemoryConfig();
    tmp = await Directory.systemTemp.createTemp('gstore_settings_tabs_');
    service = AgentService(
      workspaceService: AgentWorkspaceService(supportRoot: tmp),
    );
    await ModuleManager.instance.clear();
    ModuleManager.instance.bind<AgentService>(service);

    final store = await AgentModelStore.load();
    await store.add(AgentModel(
      id: 'model-a',
      name: '测试模型',
      provider: AgentLlmProvider.openai,
      apiKey: 'sk-test',
      model: 'gpt-4o-mini',
    ));
    await store.select('model-a');
  });

  tearDown(() async {
    await ModuleManager.instance.clear();
    service.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    // 手机尺寸：确认导航头里的分段胶囊不会挤压溢出
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AgentSettingsPage(),
                  ),
                ),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('导航头分段胶囊切换「模型 / 工具」', (tester) async {
    await pumpSettings(tester);

    expect(find.text('AI 设置'), findsOneWidget);
    expect(find.byKey(const Key('agent-settings-tab-models')), findsOneWidget);
    expect(find.byKey(const Key('agent-settings-tab-tools')), findsOneWidget);

    // 默认模型页：模型列表 + 回合记录
    expect(find.text('测试模型'), findsOneWidget);
    expect(find.text('回合记录'), findsOneWidget);
    expect(find.text('联网检索'), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);

    // 工具页：联网检索 / 文件工作区 / WebView 调试 / MCP 服务器
    await tester.tap(find.byKey(const Key('agent-settings-tab-tools')));
    await tester.pumpAndSettle();

    expect(find.text('联网检索'), findsWidgets);
    expect(find.text('文件工作区'), findsWidgets);
    expect(find.text('WebView 调试'), findsOneWidget);
    expect(find.text('MCP 服务器'), findsOneWidget);
    expect(find.text('httpRequest 携带 WebView 登录态'), findsOneWidget);
    expect(find.text('回合记录'), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);

    // 切回模型页
    await tester.tap(find.byKey(const Key('agent-settings-tab-models')));
    await tester.pumpAndSettle();

    expect(find.text('测试模型'), findsOneWidget);
    expect(find.text('回合记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('两个子页面可以在 PageView 中左右滑动切换', (tester) async {
    await pumpSettings(tester);

    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('回合记录'), findsOneWidget);

    // 左滑 → 工具页
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('联网检索'), findsWidgets);
    expect(find.text('MCP 服务器'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);

    // 右滑 → 模型页
    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(find.text('回合记录'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
