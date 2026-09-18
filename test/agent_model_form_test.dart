import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/agent/openai_model_catalog.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/page/agent/agent_settings_page.dart';

/// 放大测试视口，保证表单全部字段被布局出来（可断言相对位置）
void _useTallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 渲染「添加/编辑模型」表单
Future<void> pumpSheet(
  WidgetTester tester, {
  AgentModel? existing,
  Future<List<String>> Function({
    required String baseUrl,
    required String apiKey,
  })? fetchModels,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(
        body: ModelEditSheet(
          store: AgentModelStore(),
          existing: existing,
          fetchModels: fetchModels,
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 定位模型名称输入框
Finder modelField() => find.ancestor(
      of: find.text('模型名称'),
      matching: find.byType(TextField),
    );

/// 读取模型名称输入框当前文本
String modelFieldText(WidgetTester tester) =>
    tester.widget<TextField>(modelField()).controller!.text;

/// 内存配置存储（模型列表缓存的落库环境）
Future<void> initMemoryConfig() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(storages: [
    MemoryConfigStorage(),
    MemoryConfigStorage(),
  ]);
}

/// 输入 API Key 并点刷新按钮
Future<void> tapRefresh(WidgetTester tester, {String apiKey = 'sk-test'}) async {
  await tester.enterText(find.byType(TextField).at(1), apiKey); // API Key
  await tester.tap(find.byTooltip('拉取可用模型列表'));
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    // 每个用例从「未初始化配置」开始：既保证读到空缓存，也避免缓存串场
    ConfigStore.instance.resetForTest();
  });

  testWidgets('OpenAI 兼容：Base URL 排在模型名称之前，模型框右侧有拉取按钮', (tester) async {
    _useTallView(tester);
    await pumpSheet(tester);

    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('模型名称'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Base URL')).dy,
      lessThan(tester.getTopLeft(find.text('模型名称')).dy),
      reason: '先填服务地址，再据此拉取/选择模型',
    );

    // 刷新按钮挂在模型输入框内、靠右（suffixIcon）
    final refresh = find.byTooltip('拉取可用模型列表');
    expect(modelField(), findsOneWidget);
    expect(refresh, findsOneWidget);

    final fieldRect = tester.getRect(modelField());
    final refreshCenter = tester.getCenter(refresh);
    expect(
      refreshCenter.dy,
      inInclusiveRange(fieldRect.top, fieldRect.bottom),
      reason: '刷新按钮应与模型输入框同一行',
    );
    expect(
      refreshCenter.dx,
      greaterThan(fieldRect.center.dx),
      reason: '刷新按钮在输入框右侧',
    );
    // 双箭头图标（不是单箭头的 Icons.refresh）
    expect(find.byIcon(Icons.sync), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('使用 app 统一弹层骨架：AppSheetScaffold + 标题 + 底部固定操作区', (tester) async {
    _useTallView(tester);
    await pumpSheet(tester);

    // 骨架而非自绘 Padding/SingleChildScrollView
    expect(find.byType(AppSheetScaffold), findsOneWidget);
    expect(find.text('添加模型'), findsOneWidget);

    // 取消/保存属于固定操作区：在滚动区之外
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('保存'),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
      reason: '操作按钮应固定在弹层底部，不随内容滚动',
    );
    expect(
      find.ancestor(
        of: find.text('模型名称'),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
      reason: '表单项在内容滚动区里',
    );
    // 操作区在表单内容下方
    expect(
      tester.getCenter(find.text('保存')).dy,
      greaterThan(tester.getCenter(find.text('模型名称')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑模式：骨架标题为「编辑模型」', (tester) async {
    _useTallView(tester);
    await pumpSheet(
      tester,
      existing: AgentModel(
        id: '1',
        provider: AgentLlmProvider.openai,
        apiKey: 'sk-x',
        baseUrl: 'https://proxy.example.com/v1',
      ),
    );

    expect(find.byType(AppSheetScaffold), findsOneWidget);
    expect(find.text('编辑模型'), findsOneWidget);
    expect(find.text('添加模型'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('页面点「添加模型」→ 弹出的是统一弹层骨架（不再是自绘 bottom sheet）',
      (tester) async {
    _useTallView(tester);
    await initMemoryConfig();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const AgentSettingsPage(),
      ),
    );
    await tester.pump(); // AgentModelStore.load()
    await tester.pump();
    // 等 FAB 入场缩放动画结束，否则点击点会落在缩放后的实际区域之外
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 统一骨架（拖拽条 + 标题 + 固定操作区）
    expect(find.byType(AppSheetScaffold), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切到 Google Gemini：不显示拉取按钮（接口语义不同）', (tester) async {
    _useTallView(tester);
    await pumpSheet(tester);

    expect(find.byTooltip('拉取可用模型列表'), findsOneWidget);

    await tester.tap(find.text('Google Gemini'));
    await tester.pump();

    expect(find.byTooltip('拉取可用模型列表'), findsNothing);
    // Base URL 字段本身仍在（Gemini 可留空走官方接口）
    expect(find.text('Base URL'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未填 API Key 点拉取 → 直接提示，不发请求', (tester) async {
    _useTallView(tester);
    await pumpSheet(tester);

    await tester.tap(find.byTooltip('拉取可用模型列表'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('请先填写 API Key'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑已有模型：回填 Base URL / 模型名称，且 Base URL 仍在前', (tester) async {
    _useTallView(tester);
    await pumpSheet(
      tester,
      existing: AgentModel(
        id: '1',
        provider: AgentLlmProvider.openai,
        apiKey: 'sk-x',
        model: 'deepseek-reasoner',
        baseUrl: 'https://api.deepseek.com/v1',
      ),
    );

    expect(find.text('https://api.deepseek.com/v1'), findsOneWidget);
    expect(find.text('deepseek-reasoner'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Base URL')).dy,
      lessThan(tester.getTopLeft(find.text('模型名称')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('拉取成功：预设模型被接口返回列表整块替换，不弹二级选择弹层', (tester) async {
    _useTallView(tester);
    await pumpSheet(
      tester,
      fetchModels: ({required baseUrl, required apiKey}) async =>
          ['my-model-a', 'my-model-b'],
    );

    // 初始为内置预设
    expect(find.text('常用模型'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'gpt-4o'), findsOneWidget);

    await tapRefresh(tester);

    // 预设被替换，且没有弹出选择弹层
    expect(find.widgetWithText(ActionChip, 'my-model-a'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'my-model-b'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'gpt-4o'), findsNothing);
    expect(find.text('可用模型（接口返回 2 个）'), findsOneWidget);
    expect(find.text('选择模型（共 2 个）'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('替换后的模型 chip 点选即回填模型名称', (tester) async {
    _useTallView(tester);
    await pumpSheet(
      tester,
      fetchModels: ({required baseUrl, required apiKey}) async =>
          ['my-model-a', 'my-model-b'],
    );

    await tapRefresh(tester);

    expect(modelFieldText(tester), isEmpty);

    await tester.tap(find.widgetWithText(ActionChip, 'my-model-b'));
    await tester.pump();

    expect(modelFieldText(tester), 'my-model-b');
    expect(tester.takeException(), isNull);
  });

  testWidgets('拉取到空列表：不替换预设，给出警告', (tester) async {
    _useTallView(tester);
    await pumpSheet(
      tester,
      fetchModels: ({required baseUrl, required apiKey}) async => const [],
    );

    await tapRefresh(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('接口未返回任何模型，请检查 Base URL'), findsOneWidget);
    // 预设仍在（没有被空列表替换掉）
    expect(find.text('常用模型'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'gpt-4o'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拉取失败：提示错误，预设保持不变，且不写缓存', (tester) async {
    _useTallView(tester);
    await initMemoryConfig();
    await pumpSheet(
      tester,
      fetchModels: ({required baseUrl, required apiKey}) async =>
          throw Exception('401 Unauthorized'),
    );

    await tapRefresh(tester, apiKey: 'sk-bad');
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('拉取模型列表失败'), findsOneWidget);
    expect(find.text('常用模型'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'gpt-4o'), findsOneWidget);
    expect(await loadModelCatalogCache(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拉取成功写缓存：下次打开表单直接用缓存替换预设', (tester) async {
    _useTallView(tester);
    await initMemoryConfig();

    // 第一次：拉取成功并按端点写入缓存
    await pumpSheet(
      tester,
      existing: AgentModel(
        id: '1',
        provider: AgentLlmProvider.openai,
        apiKey: 'sk-x',
        baseUrl: 'https://proxy.example.com/v1',
      ),
      fetchModels: ({required baseUrl, required apiKey}) async =>
          ['my-model-a', 'my-model-b'],
    );
    await tapRefresh(tester);

    expect(find.widgetWithText(ActionChip, 'my-model-a'), findsOneWidget);
    expect(
      await loadModelCatalogCache(),
      containsPair('https://proxy.example.com/v1', ['my-model-a', 'my-model-b']),
    );

    // 模拟「下次编辑」：卸载后重新打开同一配置
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await pumpSheet(
      tester,
      existing: AgentModel(
        id: '1',
        provider: AgentLlmProvider.openai,
        apiKey: 'sk-x',
        baseUrl: 'https://proxy.example.com/v1',
      ),
    );
    await tester.pump();

    // 未再点刷新，缓存列表已直接替换预设
    expect(find.widgetWithText(ActionChip, 'my-model-a'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'my-model-b'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'gpt-4o'), findsNothing);
    expect(find.text('可用模型（接口返回 2 个）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存按端点区分：换 Base URL 后回到该端点的状态，不会串用别的端点模型',
      (tester) async {
    _useTallView(tester);
    await initMemoryConfig();

    // 只缓存 A 端点
    await cacheModelIds('https://a.example.com/v1', ['model-a1', 'model-a2']);

    await pumpSheet(
      tester,
      existing: AgentModel(
        id: '1',
        provider: AgentLlmProvider.openai,
        apiKey: 'sk-x',
        baseUrl: 'https://a.example.com/v1',
      ),
    );
    await tester.pump();

    expect(find.widgetWithText(ActionChip, 'model-a1'), findsOneWidget);

    // 切到未缓存的 B 端点 → 回落预设，不显示 A 的模型
    await tester.enterText(
        find.byType(TextField).at(2), 'https://b.example.com/v1');
    await tester.pump();

    expect(find.widgetWithText(ActionChip, 'model-a1'), findsNothing);
    expect(find.text('常用模型'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'gpt-4o'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
