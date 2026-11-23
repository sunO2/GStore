import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:gstore/core/agent/agent_context_budget.dart';
import 'package:gstore/core/agent/agent_history_selector.dart';

Message _user(String text) =>
    Message(role: Role.user, content: [TextPart(text: text)]);

Message _assistant(String text) =>
    Message(role: Role.model, content: [TextPart(text: text)]);

int tokensOf(Message m) {
  var n = 0;
  for (final part in m.content) {
    n += AgentContextBudget.estimateTokens(part.text ?? '');
  }
  return n;
}

void main() {
  group('AgentContextBudget', () {
    test('token 估算：中文按字、英文按 4 字符、空串为 0', () {
      expect(AgentContextBudget.estimateTokens(''), 0);
      expect(AgentContextBudget.estimateTokens('你好'), 2);
      expect(AgentContextBudget.estimateTokens('hell'), 1);
      expect(AgentContextBudget.estimateTokens('hello'), 2);
      expect(AgentContextBudget.estimateTokens('hello world'), 3);
      // 中文比英文"贵"：同一段信息量占更多预算
      expect(
        AgentContextBudget.estimateTokens('这是一个测试'),
        greaterThan(AgentContextBudget.estimateTokens('this is a test')),
      );
    });

    test('预算：未配置窗口用默认值，配置后按 60% 折算并取下限', () {
      expect(
        AgentContextBudget.promptTokensFor(
          contextWindow: 0,
          local: false,
          toolsEnabled: true,
        ),
        AgentContextBudget.defaultCloudPromptTokens,
      );
      expect(
        AgentContextBudget.promptTokensFor(
          contextWindow: 0,
          local: true,
          toolsEnabled: true,
        ),
        AgentContextBudget.defaultLocalToolsPromptTokens,
      );
      expect(
        AgentContextBudget.promptTokensFor(
          contextWindow: 128000,
          local: false,
          toolsEnabled: true,
        ),
        76800,
      );
      expect(
        AgentContextBudget.promptTokensFor(
          contextWindow: 400,
          local: false,
          toolsEnabled: true,
        ),
        512,
        reason: '极小窗口也要留出最小提示预算',
      );
    });
  });

  group('AgentHistorySelector', () {
    List<Message> conversation() => [
          _user('第一轮：帮我找一个下载器'),
          _assistant('推荐 Gopeed'),
          _user('第二轮：它支持多线程吗'),
          _assistant('支持'),
          _user('第三轮：怎么设置代理'),
          _assistant('在设置里'),
          _user('第四轮：如何更新应用'),
          _assistant('打开更新页'),
          _user('第五轮：现在几点了'),
          _assistant('不知道'),
        ];

    test('预算充足：全部保留，不做检索', () {
      final messages = conversation();
      final plan = AgentHistorySelector.plan(
        messages: messages,
        budgetTokens: 100000,
        query: '现在几点了',
        tokensOf: tokensOf,
      );
      expect(plan.keptIndexes, List.generate(messages.length, (i) => i));
      expect(plan.droppedIndexes, isEmpty);
      expect(plan.hasRetrieval, isFalse);
    });

    test('超预算：保留最近回合，早期回合按相关度回填', () {
      final messages = [
        _user('下载器 Gopeed'),
        _assistant('推荐'),
        _user('多线程'),
        _assistant('支持'),
        _user('代理设置'),
        _assistant('在设置里'),
        _user('几点'),
        _assistant('不知道'),
      ];
      final plan = AgentHistorySelector.plan(
        messages: messages,
        budgetTokens: 15,
        query: 'Gopeed 下载器',
        tokensOf: tokensOf,
        recentTurns: 1,
      );
      // 最近回合必须在
      expect(plan.keptIndexes, containsAll([6, 7]));
      // 相关的最早回合（Gopeed / 下载器）应被回填
      expect(plan.retrievedIndexes, contains(0));
      expect(plan.hasRetrieval, isTrue);
      // 保留的消息按原顺序
      final sorted = [...plan.keptIndexes]..sort();
      expect(plan.keptIndexes, sorted);
    });

    test('不相关时不回填，只保留无相关性的最近回合', () {
      final messages = conversation();
      final plan = AgentHistorySelector.plan(
        messages: messages,
        budgetTokens: 12,
        query: 'zzz 无关词',
        tokensOf: tokensOf,
      );
      expect(plan.hasRetrieval, isFalse);
      expect(plan.droppedIndexes, isNotEmpty);
      expect(plan.keptIndexes, contains(8));
    });

    test('空历史返回空计划', () {
      final plan = AgentHistorySelector.plan(
        messages: const [],
        budgetTokens: 100,
        query: 'x',
        tokensOf: tokensOf,
      );
      expect(plan.keptIndexes, isEmpty);
      expect(plan.droppedIndexes, isEmpty);
      expect(plan.keptTokens, 0);
    });
  });
}
