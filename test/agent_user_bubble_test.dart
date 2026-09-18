import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/agent/user_bubble.dart';

/// 用户消息气泡：正文必须可长按选中复制
///
/// agent 侧正文（AgentMarkdownMessage）已是 selectable；用户自己发的消息
/// 之前是裸 Text，长按无法复制 —— 这里锁住"可选中"这个能力不被改没。
void main() {
  Future<void> pumpBubble(
    WidgetTester tester, {
    String text = '帮我找一个截图工具',
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentUserBubble(
            text: text,
            timeLabel: '12:34',
            maxWidth: 320,
          ),
        ),
      ),
    );
  }

  testWidgets('正文用可选中文本（长按可复制），且内容完整', (tester) async {
    const text = '帮我找一个截图工具';
    await pumpBubble(tester, text: text);

    final selectable = find.byType(SelectableText);
    expect(selectable, findsOneWidget);
    expect(tester.widget<SelectableText>(selectable).data, text);
  });

  testWidgets('长按会选中文本（可复制的前提）', (tester) async {
    await pumpBubble(tester, text: '帮我找一个截图工具');

    // SelectableText 内部是 readOnly 的 EditableText
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.textEditingValue.selection.isCollapsed, isTrue,
        reason: '长按前无选区');

    await tester.longPress(find.byType(SelectableText));
    await tester.pumpAndSettle();

    expect(
      editable.textEditingValue.selection.isCollapsed,
      isFalse,
      reason: '长按应产生选区（随后即可复制）',
    );
  });

  testWidgets('时间文案照常展示', (tester) async {
    await pumpBubble(tester);
    expect(find.text('12:34'), findsOneWidget);
  });

  testWidgets('多行长文本完整渲染（不截断）', (tester) async {
    const long = '第一行内容\n第二行内容\n第三行内容';
    await pumpBubble(tester, text: long);

    final widget = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(widget.data, long);
    expect(widget.maxLines, isNull, reason: '不应限制行数');
  });
}
