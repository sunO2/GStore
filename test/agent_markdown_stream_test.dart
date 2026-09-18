import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/agent/markdown_message.dart';

/// 回归测试：流式输出时未闭合代码块的高度暴涨防护。
///
/// 背景：流式 chunk 到达时 markdown 是未完成的，` ``` ` 代码块未闭合
/// 仍会被解析成 pre 元素。修复前完整代码卡片（顶栏+语言标签+粗 padding）
/// 一次性插入 → 高度瞬间暴涨 100px+ → reverse 列表中"新 chunk 一到就跳动"。
/// 修复后未闭合时用 compact 等宽文本渲染，高度随行数线性增长。
void main() {
  group('hasUnclosedCodeBlock（未闭合围栏检测）', () {
    test('纯文本/闭合代码块 → false', () {
      expect(hasUnclosedCodeBlock('普通文本'), isFalse);
      expect(hasUnclosedCodeBlock('```dart\nvoid main() {}\n```'), isFalse);
      expect(
        hasUnclosedCodeBlock('开头\n```bash\nls\n```\n结尾'),
        isFalse,
      );
    });

    test('未闭合代码块（缺闭合围栏）→ true', () {
      expect(hasUnclosedCodeBlock('```bash\nflutter pu'), isTrue);
      expect(hasUnclosedCodeBlock('用法：\n\n```dart\nvoid m'), isTrue);
    });

    test('围栏在缩进内（≤3 空格）也算', () {
      expect(hasUnclosedCodeBlock('   ```python\nprint('), isTrue);
    });

    test('多个围栏：开-闭-开 → true（最后一个未闭合）', () {
      expect(hasUnclosedCodeBlock('```a\nx\n```\n\n```b\ny'), isTrue);
    });

    test('围栏完全闭合 → false', () {
      expect(hasUnclosedCodeBlock('```a\nx\n```\n\n```b\ny\n```'), isFalse);
    });
  });

  group('AgentMarkdownMessage 流式中间态渲染', () {
    Future<double> heightOf(WidgetTester tester, String text) async {
      double? h;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final box = context.findRenderObject() as RenderBox?;
              if (box != null && box.hasSize) h = box.size.height;
            });
            return Container(
              constraints: const BoxConstraints(maxWidth: 320),
              child: AgentMarkdownMessage(text: text),
            );
          }),
        ),
      ));
      await tester.pump();
      await tester.pump();
      return h ?? 0;
    }

    testWidgets('未闭合代码块：高度增量有限（不再暴涨）', (tester) async {
      final plainH = await heightOf(tester, '这是普通文本');
      final unclosedH = await heightOf(tester, '用法示例：\n\n```bash\nflutter pu');
      // 未闭合代码块不应引入 100px+ 的卡片骨架开销
      expect(
        unclosedH,
        lessThan(plainH + 90),
        reason: '未闭合代码块高度 $unclosedH vs 普通文本 $plainH，'
            '完整卡片骨架会让差值超过 100px（修复前实测 +101px）',
      );
    });

    testWidgets('闭合代码块：渲染完整代码卡片（带语言标签）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            child: const AgentMarkdownMessage(text: '```dart\nvoid main() {}\n```'),
          ),
        ),
      ));
      await tester.pump();
      // 完整卡片：语言标签 dart 可见（compact 模式没有语言标签）
      expect(find.text('dart'), findsOneWidget);
    });

    testWidgets('未闭合代码块：不渲染语言标签卡片（compact 模式）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            child: const AgentMarkdownMessage(text: '```dart\nvoid m'),
          ),
        ),
      ));
      await tester.pump();
      // compact 等宽文本：无顶栏语言标签
      expect(find.text('dart'), findsNothing);
    });
  });
}