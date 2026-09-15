import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/think_parser.dart';

void main() {
  group('splitThink 内联 think 解析', () {
    test('无 think 标签：全部为正文', () {
      const raw = '你好，这是回答。';
      final (reasoning, visible) = splitThink(raw);
      expect(reasoning, '');
      expect(visible, raw);
    });

    test('完整 think 块：块内为思考，块后为正文', () {
      const raw = '<think>先搜索一下</think>找到了 Termux。';
      final (reasoning, visible) = splitThink(raw);
      expect(reasoning, '先搜索一下');
      expect(visible, '找到了 Termux。');
    });

    test('标签前有正文：正文保留在前', () {
      const raw = '好的<think>推理</think>结论如下';
      final (reasoning, visible) = splitThink(raw);
      expect(reasoning, '推理');
      expect(visible, contains('好的'));
      expect(visible, contains('结论如下'));
    });

    test('只有开始标签（流式中）：正文为空，全部归思考', () {
      const raw = '<think>正在思考中';
      final (reasoning, visible) = splitThink(raw);
      expect(reasoning, '正在思考中');
      expect(visible, '');
    });

    test('开始标签尚未接收完整：扣住标签前缀，正文照常展示', () {
      const raw = '正文<thi';
      final (reasoning, visible) = splitThink(raw);
      expect(reasoning, '');
      expect(visible, '正文');
    });

    test('大小写不敏感', () {
      const raw = '<THINK>推理</THINK>结果';
      final (reasoning, visible) = splitThink(raw);
      expect(reasoning, '推理');
      expect(visible, '结果');
    });

    test('多段 think：合并思考，保留全部正文', () {
      const raw = '<think>第一段</think>中间<think>第二段</think>结尾';
      final (reasoning, visible) = splitThink(raw);
      expect(reasoning, isNotEmpty);
      expect(visible, contains('结尾'));
    });

    test('空字符串', () {
      final (reasoning, visible) = splitThink('');
      expect(reasoning, '');
      expect(visible, '');
    });
  });

  group('reasoningFromOpenAiRaw（OpenAI 兼容端点事后补取）', () {
    test('取 reasoning_content（DeepSeek 系）', () {
      final raw = {
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': '答案',
              'reasoning_content': '先分析一下……',
            }
          }
        ]
      };
      expect(reasoningFromOpenAiRaw(raw), '先分析一下……');
    });

    test('兼容 reasoning 字段（OpenRouter 等）', () {
      final raw = {
        'choices': [
          {
            'message': {'content': '答案', 'reasoning': 'thinking text'}
          }
        ]
      };
      expect(reasoningFromOpenAiRaw(raw), 'thinking text');
    });

    test('无思考内容时返回空串', () {
      final raw = {
        'choices': [
          {
            'message': {'content': '普通回答'}
          }
        ]
      };
      expect(reasoningFromOpenAiRaw(raw), '');
    });

    test('结构异常/空值不抛异常', () {
      expect(reasoningFromOpenAiRaw(null), '');
      expect(reasoningFromOpenAiRaw('not a map'), '');
      expect(reasoningFromOpenAiRaw({'choices': []}), '');
      expect(reasoningFromOpenAiRaw({'choices': ['x']}), '');
      expect(
        reasoningFromOpenAiRaw({
          'choices': [
            {'message': 'x'}
          ]
        }),
        '',
      );
      // reasoning_content 非字符串时忽略
      expect(
        reasoningFromOpenAiRaw({
          'choices': [
            {
              'message': {'reasoning_content': 123}
            }
          ]
        }),
        '',
      );
    });
  });
}
