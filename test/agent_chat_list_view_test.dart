import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/page/agent/chat_list_view.dart';

/// 自绘消息列表核心行为测试：
/// 1. reverse 列表顺序：index 0 = 底部最新
/// 2. 流式更新：消息内容变化可见（item 缓存 + 签名 diff）
/// 3. 新增消息出现在底部
void main() {
  group('消息顺序（reverse 列表）', () {
    testWidgets('最新消息在底部渲染', (tester) async {
      final controller = ScrollController();
      final messages = ValueNotifier<List<AgentMessage>>([
        _userMsg(id: 'old', text: '最早'),
        _userMsg(id: 'mid', text: '中间'),
        _userMsg(id: 'new', text: '最新'),
      ]);
      addTearDown(controller.dispose);
      addTearDown(messages.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AgentChatListView(
            messages: messages,
            scrollController: controller,
            isGenerating: false,
            hasMoreHistory: false,
          ),
        ),
      ));
      await tester.pump();

      // reverse 列表：最新消息在视觉底部（Y 坐标最大）
      final oldY = tester.getTopLeft(find.text('最早')).dy;
      final newY = tester.getTopLeft(find.text('最新')).dy;
      expect(newY, greaterThan(oldY),
          reason: 'reverse 列表最新消息应在底部（Y 更大）');
    });

    testWidgets('空消息显示欢迎页', (tester) async {
      final controller = ScrollController();
      final messages = ValueNotifier<List<AgentMessage>>([]);
      addTearDown(controller.dispose);
      addTearDown(messages.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AgentChatListView(
            messages: messages,
            scrollController: controller,
            isGenerating: false,
            hasMoreHistory: false,
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('GStore AI 助手'), findsOneWidget);
    });
  });

  group('签名 diff（item 级更新）', () {
    testWidgets('流式更新后内容可见，历史消息保留', (tester) async {
      final controller = ScrollController();
      final m1 = _userMsg(id: 'm1', text: '用户问题');
      final a1 = _agentMsg(id: 'a1', text: '初始回复');
      final messages = ValueNotifier<List<AgentMessage>>([m1, a1]);
      addTearDown(controller.dispose);
      addTearDown(messages.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AgentChatListView(
            messages: messages,
            scrollController: controller,
            isGenerating: false,
            hasMoreHistory: false,
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('用户问题'), findsOneWidget);
      expect(find.text('初始回复'), findsOneWidget);

      // 流式更新：a1 文本变长（模拟 chunk 到达——消息对象可变字段变化）
      a1.text = '初始回复 加上更多内容';
      messages.value = List.of(messages.value);
      await tester.pump();

      expect(find.text('初始回复 加上更多内容'), findsOneWidget);
      expect(find.text('用户问题'), findsOneWidget);
    });

    testWidgets('新增助手回复出现在消息列表底部', (tester) async {
      final controller = ScrollController();
      final messages = ValueNotifier<List<AgentMessage>>([
        _userMsg(id: 'm1', text: '问题'),
      ]);
      addTearDown(controller.dispose);
      addTearDown(messages.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AgentChatListView(
            messages: messages,
            scrollController: controller,
            isGenerating: false,
            hasMoreHistory: false,
          ),
        ),
      ));
      await tester.pump();

      messages.value = [
        _userMsg(id: 'm1', text: '问题'),
        _agentMsg(id: 'a1', text: '回复'),
      ];
      await tester.pump();

      expect(find.text('问题'), findsOneWidget);
      expect(find.text('回复'), findsOneWidget);
      final qY = tester.getTopLeft(find.text('问题')).dy;
      final aY = tester.getTopLeft(find.text('回复')).dy;
      expect(aY, greaterThan(qY));
    });

    testWidgets('未变化的 item 不重建（缓存实例保持同一 identity）', (tester) async {
      final controller = ScrollController();
      final m1 = _userMsg(id: 'm1', text: '问题');
      final a1 = _agentMsg(id: 'a1', text: '```dart\nvoid main(){}\n```', turnId: 't1');
      final messages = ValueNotifier<List<AgentMessage>>([m1, a1]);
      addTearDown(controller.dispose);
      addTearDown(messages.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AgentChatListView(
            messages: messages,
            scrollController: controller,
            isGenerating: false,
            hasMoreHistory: false,
          ),
        ),
      ));
      await tester.pump();

      // 拿到 State 检查内部缓存
      final state = tester.state<AgentChatListViewState>(
        find.byType(AgentChatListView),
      );
      // 通过公开的调试 getter 读取缓存（测试专用）
      final cachedBefore = state.debugWidgetCacheSnapshot();
      // 单条 agent 消息被 _groupTimeline 收进 turnMsgs → key 为 timeline_ 前缀
      final a1Key = cachedBefore.keys.firstWhere((k) => k.contains('a1'));

      // 流式更新：新增一条助手回复（历史 a1 未变化）
      messages.value = [
        m1,
        a1,
        _agentMsg(id: 'a2', text: '新增回复', turnId: 't2'),
      ];
      await tester.pump();

      // 历史 a1 的 widget 缓存实例应保持同一 identity（未重建）
      final cachedAfter = state.debugWidgetCacheSnapshot();
      final a1AfterKey = cachedAfter.keys.firstWhere((k) => k.contains('a1'));
      expect(identical(cachedAfter[a1AfterKey], cachedBefore[a1Key]), isTrue,
          reason: 'item 缓存：历史消息未变化不应重建（否则 markdown 重复解析）');
      // 新增 a2 进入缓存
      expect(cachedAfter.keys.any((k) => k.contains('a2')), isTrue);
      expect(find.text('新增回复'), findsOneWidget);
    });
  });

  group('流式 UI 挂起（uiPaused 冻结/恢复）', () {
    /// 挂一个固定消息列表，返回 messages 控制器
    Future<ValueNotifier<List<AgentMessage>>> pump(
      WidgetTester tester,
      ScrollController controller,
      bool uiPaused,
    ) async {
      final messages = ValueNotifier<List<AgentMessage>>([
        _userMsg(id: 'm1', text: '用户问题'),
        _agentMsg(id: 'a1', text: '初始回复', turnId: 't1'),
      ]);
      addTearDown(messages.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AgentChatListView(
            messages: messages,
            scrollController: controller,
            isGenerating: false,
            hasMoreHistory: false,
            uiPaused: uiPaused,
          ),
        ),
      ));
      await tester.pump();
      return messages;
    }

    testWidgets('挂起时 chunk 更新不上屏（内容冻结）', (tester) async {
      final controller = ScrollController();
      final messages = await pump(tester, controller, true); // uiPaused=true

      // 初始渲染正常
      expect(find.text('初始回复'), findsOneWidget);

      // 流式更新：a1 文本变长（模拟 chunk 到达）
      final a1 = messages.value[1];
      a1.text = '初始回复 加上更多内容';
      messages.value = List.of(messages.value);
      await tester.pump();

      // 挂起态：UI 冻结，不显示新内容
      expect(find.text('初始回复'), findsOneWidget,
          reason: '挂起时 chunk 只进数据不更新 UI（读历史零打扰）');
      expect(find.text('初始回复 加上更多内容'), findsNothing);
    });

    testWidgets('解除挂起（uiPaused=true→false）后一次性渲染积攒内容', (tester) async {
      final controller = ScrollController();
      final messages = await pump(tester, controller, true); // 先挂起

      // 挂起期间 chunk 累积
      final a1 = messages.value[1];
      a1.text = '初始回复 加上大量积攒的内容';
      messages.value = List.of(messages.value);
      await tester.pump();
      expect(find.text('初始回复 加上大量积攒的内容'), findsNothing,
          reason: '挂起期间不上屏');

      // 解除挂起（重建 widget 传 uiPaused=false）
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AgentChatListView(
            messages: messages,
            scrollController: controller,
            isGenerating: false,
            hasMoreHistory: false,
            uiPaused: false,
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('初始回复 加上大量积攒的内容'), findsOneWidget,
          reason: '解除挂起后一次性渲染积攒的 chunk');
    });

    testWidgets('挂起时新增消息也不上屏，解除后出现', (tester) async {
      final controller = ScrollController();
      final messages = await pump(tester, controller, true);

      // 挂起期间新增一条回复
      messages.value = [
        messages.value[0],
        messages.value[1],
        _agentMsg(id: 'a2', text: '新增回复', turnId: 't2'),
      ];
      await tester.pump();
      expect(find.text('新增回复'), findsNothing,
          reason: '挂起时新增消息不上屏');

      // 解除挂起
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AgentChatListView(
            messages: messages,
            scrollController: controller,
            isGenerating: false,
            hasMoreHistory: false,
            uiPaused: false,
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('新增回复'), findsOneWidget);
    });
  });
}

AgentMessage _userMsg({required String id, required String text}) =>
    AgentMessage(id: id, isUser: true, text: text, seq: 1);

AgentMessage _agentMsg(
        {required String id, required String text, String? turnId}) =>
    AgentMessage(id: id, isUser: false, text: text, seq: 2, turnId: turnId);