import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/agent/step_text.dart';

/// 自定义 step 时间轴的「文本节点」渲染测试
///
/// 重点保护两件事：
/// 1. 思考内容必须在**自定义 step UI**里被显式渲染（框架不会代劳）；
/// 2. 原有的 step 文本展示（Markdown 正文）不能被改没。
void main() {
  Future<void> pumpBlock(
    WidgetTester tester, {
    required String text,
    String reasoning = '',
    bool reasoningDone = true,
    bool showReasoning = true,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentStepTextBlock(
            text: text,
            reasoning: reasoning,
            reasoningDone: reasoningDone,
            showReasoning: showReasoning,
          ),
        ),
      ),
    );
  }

  group('AgentStepTextBlock（step 文本节点）', () {
    testWidgets('正文照常渲染（Markdown 步骤内容未被改没）', (tester) async {
      await pumpBlock(tester, text: '这是正文内容');
      expect(find.textContaining('这是正文内容', findRichText: true), findsOneWidget);
      // 无思考时不出现思考块
      expect(find.text('思考过程'), findsNothing);
    });

    testWidgets('有思考内容时渲染思考块 + 正文；流式中也默认折叠', (tester) async {
      await pumpBlock(
        tester,
        text: '正文内容',
        reasoning: '推理细节：先看签名',
        reasoningDone: false, // 流式中
      );
      expect(find.text('思考中…'), findsOneWidget);
      // 默认折叠：思考正文不可见（不再流式自动展开）
      expect(find.textContaining('推理细节：先看签名'), findsNothing);
      expect(find.textContaining('正文内容', findRichText: true), findsOneWidget);

      // 手动展开后可看到（流式中也能看）
      await tester.tap(find.text('思考中…'));
      await tester.pump(); // 展开是直接切换（无需 settle：流式转圈是无限动画）
      expect(find.textContaining('推理细节：先看签名'), findsOneWidget);
    });

    testWidgets('思考结束后默认折叠，点击标题可展开', (tester) async {
      await pumpBlock(
        tester,
        text: '正文内容',
        reasoning: '推理细节：先看签名',
        reasoningDone: true,
      );
      expect(find.text('思考过程'), findsOneWidget);
      // 折叠态：思考正文不可见
      expect(find.textContaining('推理细节：先看签名'), findsNothing);

      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();
      expect(find.textContaining('推理细节：先看签名'), findsOneWidget);
    });

    testWidgets('showReasoning=false 时不渲染思考块，正文照常', (tester) async {
      await pumpBlock(
        tester,
        text: '正文内容',
        reasoning: '推理细节',
        showReasoning: false,
      );
      expect(find.text('思考过程'), findsNothing);
      expect(find.text('思考中…'), findsNothing);
      expect(find.textContaining('正文内容', findRichText: true), findsOneWidget);
    });

    testWidgets('无正文但有思考时仍渲染思考块（不丢内容，展开后可见）', (tester) async {
      await pumpBlock(
        tester,
        text: '   ',
        reasoning: '只有思考',
        reasoningDone: false,
      );
      // 默认折叠：先只有标题栏
      expect(find.text('思考中…'), findsOneWidget);
      expect(find.textContaining('只有思考'), findsNothing);

      await tester.tap(find.text('思考中…'));
      await tester.pump();
      expect(find.textContaining('只有思考'), findsOneWidget);
    });

    testWidgets('正文与思考都为空 → 不渲染任何内容', (tester) async {
      await pumpBlock(tester, text: '  ', reasoning: '  ');
      expect(find.byType(Text), findsNothing);
      expect(find.text('思考过程'), findsNothing);
    });
  });
}
