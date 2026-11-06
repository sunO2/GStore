// 集成测试：对话列表仅对 Agent 显式调用 showConfigSwitch 的工具消息渲染
// 内联开关卡片，并通过真实的内存配置后端完成一次读写闭环。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_inline_cards.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/page/agent/chat_list_view.dart';
import 'package:gstore/page/agent/widgets/agent_switch_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = ConfigStore.instance;

  ValueNotifier<List<AgentMessage>>? notifier;
  ScrollController? scroll;

  tearDown(() async {
    notifier?.dispose();
    scroll?.dispose();
    notifier = null;
    scroll = null;
    await ConfigService.instance.resetForTest();
    store.resetForTest();
  });

  // 配置后端在 testWidgets 的 fake-async zone 内初始化：
  // 若在 setUp 中初始化，其就绪 Future 属于外层 zone，测试体直接 await 会挂起。
  Future<void> initStore() async {
    store.resetForTest();
    await store.initialize(storages: <ConfigStorage>[MemoryConfigStorage()]);
    await ConfigService.instance.ensureReady();
  }

  Future<void> pumpList(
    WidgetTester tester,
    List<AgentMessage> messages, {
    bool settle = true,
  }) async {
    scroll = ScrollController();
    notifier = ValueNotifier<List<AgentMessage>>(messages);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AgentChatListView(
          messages: notifier!,
          scrollController: scroll!,
          isGenerating: false,
          hasMoreHistory: false,
        ),
      ),
    ));
    // 运行中的工具胶囊含持续旋转的 loading，pumpAndSettle 会超时。
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('showConfigSwitch 工具消息渲染为内联开关卡片并可写回配置', (tester) async {
    await initStore();

    await pumpList(tester, [
      AgentMessage(
        isUser: true,
        text: '查询多段下载开关状态',
        turnId: 't1',
      ),
      AgentMessage(
        isUser: false,
        isToolResult: true,
        text: '',
        toolName: 'showConfigSwitch',
        toolType: AgentToolType.config,
        toolStatus: AgentToolStatus.done,
        toolDetail: 'done',
        toolArgs: <String, dynamic>{
          'key': ConfigKeys.downloadMultiSegmentEnabled,
        },
        turnId: 't1',
      ),
    ]);

    expect(find.text('多段下载'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);

    // 注册表默认 true：开关初始为开。
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(
      await ConfigService.instance.getT<bool>(
        ConfigKeys.downloadMultiSegmentEnabled,
      ),
      isFalse,
    );
  });

  testWidgets('configManager get 不会自动渲染卡片', (tester) async {
    await initStore();

    await pumpList(tester, [
      AgentMessage(
        isUser: true,
        text: '查询分段下载开关配置',
        turnId: 't2',
      ),
      AgentMessage(
        isUser: false,
        isToolResult: true,
        text: '',
        toolName: 'configManager',
        toolType: AgentToolType.config,
        toolStatus: AgentToolStatus.done,
        toolArgs: <String, dynamic>{
          'action': 'get',
          'key': ConfigKeys.downloadMultiSegmentEnabled,
        },
        turnId: 't2',
      ),
    ]);

    expect(find.byType(Switch), findsNothing);
    expect(find.text('多段下载'), findsNothing);
  });

  testWidgets('showConfigSwitch 支持人类别名 key', (tester) async {
    await initStore();

    await pumpList(tester, [
      AgentMessage(
        isUser: true,
        text: '打开分段下载',
        turnId: 't3',
      ),
      AgentMessage(
        isUser: false,
        isToolResult: true,
        text: '',
        toolName: 'showConfigSwitch',
        toolType: AgentToolType.config,
        toolStatus: AgentToolStatus.done,
        toolArgs: <String, dynamic>{'key': '分段下载'},
        turnId: 't3',
      ),
    ]);

    expect(find.byType(Switch), findsOneWidget);
    expect(find.text('多段下载'), findsOneWidget);
  });

  testWidgets('showConfigSwitch 运行中不渲染卡片', (tester) async {
    await initStore();

    await pumpList(tester, [
      AgentMessage(
        isUser: true,
        text: '打开分段下载',
        turnId: 't4',
      ),
      AgentMessage(
        isUser: false,
        isToolResult: true,
        text: '',
        toolName: 'showConfigSwitch',
        toolType: AgentToolType.config,
        toolStatus: AgentToolStatus.running,
        toolArgs: <String, dynamic>{
          'key': ConfigKeys.downloadMultiSegmentEnabled,
        },
        turnId: 't4',
      ),
    ], settle: false);

    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('showConfigControl 渲染滑块卡片', (tester) async {
    await initStore();

    await pumpList(tester, [
      AgentMessage(
        isUser: true,
        text: '调整最大并发下载数',
        turnId: 't5',
      ),
      AgentMessage(
        isUser: false,
        isToolResult: true,
        text: '',
        toolName: 'showConfigControl',
        toolType: AgentToolType.config,
        toolStatus: AgentToolStatus.done,
        toolArgs: <String, dynamic>{
          'key': ConfigKeys.downloadMaxConcurrent,
        },
        turnId: 't5',
      ),
    ]);

    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('最大并发下载数'), findsOneWidget);
  });

  testWidgets('showConfigControl 渲染分段选择卡片', (tester) async {
    await initStore();

    await pumpList(tester, [
      AgentMessage(
        isUser: true,
        text: '设置自动更新策略',
        turnId: 't6',
      ),
      AgentMessage(
        isUser: false,
        isToolResult: true,
        text: '',
        toolName: 'showConfigControl',
        toolType: AgentToolType.config,
        toolStatus: AgentToolStatus.done,
        toolArgs: <String, dynamic>{
          'key': ConfigKeys.updateAutoUpdatePolicy,
        },
        turnId: 't6',
      ),
    ]);

    expect(find.byType(SegmentedButton<String>), findsOneWidget);
    expect(find.text('仅 Wi-Fi'), findsOneWidget);
    expect(find.text('从不'), findsOneWidget);
    expect(find.text('总是'), findsOneWidget);
  });

  testWidgets('showConfigControl 的 type 与配置类型不匹配时不渲染卡片', (tester) async {
    await initStore();

    await pumpList(tester, [
      AgentMessage(
        isUser: true,
        text: '把并发下载数当成开关',
        turnId: 't7',
      ),
      AgentMessage(
        isUser: false,
        isToolResult: true,
        text: '',
        toolName: 'showConfigControl',
        toolType: AgentToolType.config,
        toolStatus: AgentToolStatus.done,
        toolArgs: <String, dynamic>{
          'key': ConfigKeys.downloadMaxConcurrent,
          'type': 'switch',
        },
        turnId: 't7',
      ),
    ]);

    expect(find.byType(Slider), findsNothing);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('同一 key 的多张卡片会联动更新', (tester) async {
    await initStore();
    final spec = AgentInlineCards.switchSpecs.first;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            AgentSwitchCard(spec: spec),
            AgentSwitchCard(spec: spec),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(
      tester.widgetList<Switch>(find.byType(Switch)).every((s) => s.value),
      isTrue,
    );

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(
      tester.widgetList<Switch>(find.byType(Switch)).every((s) => !s.value),
      isTrue,
      reason: '同一 key 的其它卡片必须通过配置变更监听同步',
    );
  });

  testWidgets('历史列表中同 key 的两张卡片会联动更新', (tester) async {
    await initStore();

    AgentMessage turnTool(String turnId) => AgentMessage(
          isUser: false,
          isToolResult: true,
          text: '',
          toolName: 'showConfigSwitch',
          toolType: AgentToolType.config,
          toolStatus: AgentToolStatus.done,
          toolArgs: <String, dynamic>{
            'key': ConfigKeys.downloadMultiSegmentEnabled,
          },
          turnId: turnId,
        );

    await pumpList(tester, [
      AgentMessage(isUser: true, text: '第一次查询多段下载', turnId: 'h1'),
      turnTool('h1'),
      AgentMessage(isUser: true, text: '第二次查询多段下载', turnId: 'h2'),
      turnTool('h2'),
    ]);

    expect(find.byType(Switch), findsNWidgets(2));

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    final switches =
        tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(
      switches.every((s) => s.value == false),
      isTrue,
      reason: '历史列表中同一 key 的其它卡片必须联动',
    );
  });

  testWidgets('模型只回文字时出现“显示控件”兜底入口，点击后渲染卡片', (tester) async {
    await initStore();

    await pumpList(tester, [
      AgentMessage(
        isUser: true,
        text: '分段下载开关配置',
        turnId: 'm1',
      ),
      AgentMessage(
        isUser: false,
        text: '多段下载当前是开启状态。',
        turnId: 'm1',
      ),
    ]);

    expect(find.text('显示控件：多段下载'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);

    await tester.tap(find.text('显示控件：多段下载'));
    await tester.pumpAndSettle();

    expect(find.byType(Switch), findsOneWidget);
    expect(find.text('多段下载'), findsOneWidget);
  });

  testWidgets('已有工具卡片时不重复出现同一 key 的兜底入口', (tester) async {
    await initStore();

    await pumpList(tester, [
      AgentMessage(
        isUser: true,
        text: '多段下载开关',
        turnId: 'm2',
      ),
      AgentMessage(
        isUser: false,
        isToolResult: true,
        text: '',
        toolName: 'showConfigControl',
        toolType: AgentToolType.config,
        toolStatus: AgentToolStatus.done,
        toolArgs: <String, dynamic>{
          'key': ConfigKeys.downloadMultiSegmentEnabled,
        },
        turnId: 'm2',
      ),
    ]);

    expect(find.byType(Switch), findsOneWidget);
    expect(find.text('显示控件：多段下载'), findsNothing);
  });

  testWidgets('用户提到多个控件且模型未出卡时出现多个兜底入口', (tester) async {
    await initStore();

    await pumpList(tester, [
      AgentMessage(
        isUser: true,
        text: '多段下载和最大并发下载数',
        turnId: 'm3',
      ),
      AgentMessage(
        isUser: false,
        text: '当前配置如下。',
        turnId: 'm3',
      ),
    ]);

    expect(find.text('显示控件：多段下载'), findsOneWidget);
    expect(find.text('显示控件：最大并发下载数'), findsOneWidget);

    await tester.tap(find.text('显示控件：最大并发下载数'));
    await tester.pumpAndSettle();

    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('用户追问未点名控件时，助手文本中的控件名也能出现兜底入口', (tester) async {
    await initStore();

    await pumpList(tester, [
      AgentMessage(
        isUser: true,
        text: '把配置通过 UI 组件给我',
        turnId: 'm4',
      ),
      AgentMessage(
        isUser: false,
        text: '多段下载当前是开启状态。',
        turnId: 'm4',
      ),
    ]);

    expect(find.text('显示控件：多段下载'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);

    await tester.tap(find.text('显示控件：多段下载'));
    await tester.pumpAndSettle();

    expect(find.byType(Switch), findsOneWidget);
  });
}
