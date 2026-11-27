import 'package:a2ui_agent/a2ui_agent.dart';
import 'package:a2ui_core/a2ui_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/a2ui_inline.dart';
import 'package:gstore/page/agent/a2ui_inline_card.dart';

/// 阶段 B：内联 A2UI 提示词触发与流式解析。

const _express = '''
<a2ui>
surface("main")
root = Card(column)
column = Column([title, btn])
title = Text("你好，A2UI")
btn = Button(btnLabel, action=Event("tap"))
btnLabel = Text("点我")
</a2ui>''';

/// 把完整响应切成若干块，模拟模型流式输出。
List<List<Map<String, Object?>>> _parseChunks(List<String> chunks) {
  final processor = A2uiInlineService.instance.createProcessor();
  final stream = processor.openContinuingStream(
    state: processor.createState(),
  );
  final out = <List<Map<String, Object?>>>[];
  for (final chunk in chunks) {
    for (final part in stream.feed(chunk)) {
      if (part is A2uiPart) {
        out.add([for (final m in part.a2ui) m.toJson()]);
      }
    }
  }
  for (final part in stream.close()) {
    if (part is A2uiPart) {
      out.add([for (final m in part.a2ui) m.toJson()]);
    }
  }
  return out;
}

void main() {
  group('A2uiInlineService', () {
    test('只在出现界面意图时注入提示词', () {
      final service = A2uiInlineService.instance;
      expect(service.shouldEnable('帮我生成一个表单'), isTrue);
      expect(service.shouldEnable('show me a card'), isTrue);
      expect(service.shouldEnable('这个应用怎么用'), isFalse);
      expect(service.shouldEnable('今天天气怎么样'), isFalse);
    });

    test('提示词包含 A2UI 契约与基本组件', () {
      final section = A2uiInlineService.instance.promptSection();
      expect(section, contains('A2UI Express'));
      expect(section, contains('Card'));
      expect(section, contains('<a2ui>'));
      expect(section, contains('confirmAction'));
    });

    test('整块响应可解析出 createSurface', () {
      final blocks = _parseChunks([_express]);
      expect(blocks, isNotEmpty);
      final message = blocks.first.first;
      expect(message['createSurface'], isNotNull);
      final surface = message['createSurface'] as Map;
      expect(surface['surfaceId'], 'main');
    });

    test('响应被切成任意小块也能解析', () {
      // 逐字符投喂，覆盖标签与 JSON 边界被切断的情况。
      final chunks = [for (final rune in _express.split('')) rune];
      final blocks = _parseChunks(chunks);
      expect(blocks, isNotEmpty);
      expect(blocks.first.first['createSurface'], isNotNull);
    });
  });

  group('A2uiInlineCodec', () {
    test('原始消息编码后可还原', () {
      final messages = _parseChunks([_express]).expand((e) => e).toList();
      final encoded = A2uiInlineCodec.encode(messages);
      final decoded = A2uiInlineCodec.decode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.length, messages.length);
      expect(decoded.first['createSurface'], isNotNull);
    });

    test('非 A2UI 内容返回 null', () {
      expect(A2uiInlineCodec.decode(null), isNull);
      expect(A2uiInlineCodec.decode('普通文本'), isNull);
      expect(A2uiInlineCodec.decode('@a2ui:v1:not-json'), isNull);
    });
  });

  group('A2uiInlineCard', () {
    testWidgets('渲染解析后的 surface 并回传 action', (tester) async {
      final messages = _parseChunks([_express]).expand((e) => e).toList();
      A2uiRendererAction? action;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: A2uiInlineCard(
              messages: messages,
              revision: messages.length,
              onAction: (value) => action = value,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('生成式界面'), findsOneWidget);
      expect(find.text('你好，A2UI'), findsOneWidget);
      final button = find.text('点我');
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(action?.name, 'tap');
      expect(find.textContaining('已提交'), findsOneWidget);
    });

    testWidgets('解析失败时展示错误并保持可用', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: A2uiInlineCard(
            messages: [
              {'notA2ui': true},
            ],
            revision: 1,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('生成式界面'), findsOneWidget);
    });
  });
}
