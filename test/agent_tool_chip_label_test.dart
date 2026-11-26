import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/page/agent/chat_list_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('webView / httpRequest 使用独立图标和纯文字标签（无第二个 emoji）',
      (tester) async {
    final notifier = ValueNotifier<List<AgentMessage>>([
      AgentMessage(isUser: true, text: '调试页面', turnId: 't1'),
      AgentMessage(
        isUser: false,
        text: '我先打开页面。',
        turnId: 't1',
      ),
      AgentMessage(
        isUser: false,
        isToolResult: true,
        text: '',
        toolName: 'webView',
        toolType: AgentToolType.webView,
        toolStatus: AgentToolStatus.done,
        toolDetail: 'ok',
        turnId: 't1',
      ),
      AgentMessage(
        isUser: false,
        isToolResult: true,
        text: '',
        toolName: 'httpRequest',
        toolType: AgentToolType.httpRequest,
        toolStatus: AgentToolStatus.done,
        toolDetail: 'ok',
        turnId: 't1',
      ),
    ]);
    final scroll = ScrollController();
    addTearDown(() {
      notifier.dispose();
      scroll.dispose();
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AgentChatListView(
          messages: notifier,
          scrollController: scroll,
          isGenerating: false,
          hasMoreHistory: false,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('网页调试'), findsOneWidget);
    expect(find.byIcon(TablerIcons.browser), findsOneWidget);
    expect(find.text('HTTP 接口'), findsOneWidget);
    expect(find.byIcon(TablerIcons.api), findsOneWidget);

    // 标签不再带 emoji；否则胶囊里会出现“矢量图标 + emoji”两个图标。
    expect(find.textContaining('🌐'), findsNothing);
    expect(find.textContaining('🔍'), findsNothing);
    expect(find.text('联网检索'), findsNothing);
  });
}
