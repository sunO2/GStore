import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:gstore/core/agent/openai_reasoning_model.dart';

void main() {
  group('openAiDeltaToParts（流式 delta → genkit chunk parts）', () {
    test('只有正文 → 单个 TextPart', () {
      final parts = openAiDeltaToParts(content: '你好');
      expect(parts, isNotNull);
      expect(parts!.length, 1);
      expect(parts.first.isText, true);
      expect(parts.first.text, '你好');
      expect(parts.first.isReasoning, false);
    });

    test('只有 reasoningContent → 单个 ReasoningPart（DeepSeek 系）', () {
      final parts = openAiDeltaToParts(reasoningContent: '先推理一下');
      expect(parts, isNotNull);
      expect(parts!.length, 1);
      expect(parts.first.isReasoning, true);
      expect(parts.first.reasoning, '先推理一下');
    });

    test('只有 reasoning → 单个 ReasoningPart（OpenRouter 等）', () {
      final parts = openAiDeltaToParts(reasoning: 'summary');
      expect(parts, isNotNull);
      expect(parts!.single.isReasoning, true);
      expect(parts.single.reasoning, 'summary');
    });

    test('思考优先于正文，且两者同时保留', () {
      final parts = openAiDeltaToParts(content: '答案', reasoningContent: '思考');
      expect(parts, isNotNull);
      expect(parts!.length, 2);
      // 顺序：先思考后正文
      expect(parts[0].isReasoning, true);
      expect(parts[0].reasoning, '思考');
      expect(parts[1].isText, true);
      expect(parts[1].text, '答案');
    });

    test('reasoningContent 优先于 reasoning（同一 delta 两者都有时）', () {
      final parts = openAiDeltaToParts(
        reasoningContent: 'RC',
        reasoning: 'R',
      );
      expect(parts, isNotNull);
      expect(parts!.single.reasoning, 'RC');
    });

    test('空 delta（如首包只有 role）→ null', () {
      expect(openAiDeltaToParts(), isNull);
      expect(openAiDeltaToParts(content: ''), isNull);
      expect(openAiDeltaToParts(reasoningContent: ''), isNull);
      expect(openAiDeltaToParts(content: '', reasoningContent: ''), isNull);
    });
  });
}
