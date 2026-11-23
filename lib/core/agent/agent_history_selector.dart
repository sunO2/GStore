/// 检索式历史选择（P3-2）
///
/// 超预算时不再"从最旧开始整段丢"，而是：
/// 1. 先保最近的若干个完整回合（当前问题的上下文必须完整）；
/// 2. 用剩余预算按**词法相关度**回填更早的回合（与当前问题共享词/字面片段），
///    相关度相同看新旧；
/// 3. 被丢掉的回合交给调用方压成摘要。
///
/// 纯函数、以「回合」为最小单位，避免把工具调用链切成半截。
library;

import 'package:genkit/genkit.dart';
import 'package:gstore/core/agent/agent_tool_selector.dart';

/// 一次选择的结果（索引均相对传入的非 system 消息列表）。
class AgentHistoryPlan {
  const AgentHistoryPlan({
    required this.keptIndexes,
    required this.droppedIndexes,
    required this.retrievedIndexes,
    required this.keptTokens,
  });

  final List<int> keptIndexes;
  final List<int> droppedIndexes;

  /// 因相关度被回填的早期消息索引（debug/日志用）。
  final List<int> retrievedIndexes;

  final int keptTokens;

  bool get hasRetrieval => retrievedIndexes.isNotEmpty;
}

/// 一个"回合"：从一条 user 消息开始，到下一个 user 消息之前。
class AgentHistoryTurn {
  AgentHistoryTurn({required this.start, required this.end, required this.tokens});

  final int start;
  final int end; // exclusive
  final int tokens;
}

class AgentHistorySelector {
  AgentHistorySelector._();

  /// 默认保留的最近回合数（超出预算时优先压缩更早的）。
  static const int defaultRecentTurns = 4;

  static List<AgentHistoryTurn> _turns(
    List<Message> messages,
    int Function(Message) tokensOf,
  ) {
    final turns = <AgentHistoryTurn>[];
    var start = 0;
    var tokens = 0;
    var started = false;
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].role == Role.user) {
        if (started) {
          turns.add(AgentHistoryTurn(start: start, end: i, tokens: tokens));
          start = i;
          tokens = 0;
        }
        started = true;
      }
      tokens += tokensOf(messages[i]);
    }
    if (started || messages.isNotEmpty) {
      turns.add(
        AgentHistoryTurn(start: start, end: messages.length, tokens: tokens),
      );
    }
    return turns;
  }

  static String _textOf(Message message) {
    final buf = StringBuffer();
    for (final part in message.content) {
      final text = part.text;
      if (text != null && text.isNotEmpty) {
        buf.write(text);
        buf.write(' ');
      }
    }
    return buf.toString();
  }

  /// 选择保留哪些消息。
  ///
  /// - [budgetTokens]：本回合可用提示 token（system 已扣除）。
  /// - [query]：本轮用户输入，用于相关度打分。
  /// - [recentTurns]：最近保留的回合数上限（软限制：超预算时也会继续往前收，
  ///   因为最近回合不能被丢掉，宁可超一点预算）。
  static AgentHistoryPlan plan({
    required List<Message> messages,
    required int budgetTokens,
    required String query,
    required int Function(Message) tokensOf,
    int recentTurns = defaultRecentTurns,
  }) {
    if (messages.isEmpty) {
      return const AgentHistoryPlan(
        keptIndexes: [],
        droppedIndexes: [],
        retrievedIndexes: [],
        keptTokens: 0,
      );
    }
    final turns = _turns(messages, tokensOf);
    if (turns.isEmpty) {
      return const AgentHistoryPlan(
        keptIndexes: [],
        droppedIndexes: [],
        retrievedIndexes: [],
        keptTokens: 0,
      );
    }

    // 1) 最后一个回合（当前问题）必须保留；随后尽量多保留最近的回合。
    final keptTurns = <int>{turns.length - 1};
    var used = turns.last.tokens;
    for (var i = turns.length - 2;
        i >= 0 && turns.length - 1 - i < recentTurns;
        i--) {
      final turn = turns[i];
      if (used + turn.tokens > budgetTokens) break;
      keptTurns.add(i);
      used += turn.tokens;
    }

    // 2) 预算余量按相关度回填更早的回合。
    final remaining = budgetTokens - used;
    final queryTokens = AgentToolSelector.tokenize(query);
    final candidates = <({int index, int score})>[];
    if (remaining > 0 && queryTokens.isNotEmpty) {
      for (var i = 0; i < turns.length; i++) {
        if (keptTurns.contains(i)) continue;
        final turn = turns[i];
        if (turn.tokens > remaining) continue;
        final seen = <String>{};
        for (var m = turn.start; m < turn.end; m++) {
          seen.addAll(AgentToolSelector.tokenize(_textOf(messages[m])));
        }
        final overlap = seen.intersection(queryTokens).length;
        if (overlap > 0) candidates.add((index: i, score: overlap));
      }
    }
    candidates.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return b.index.compareTo(a.index); // 同分取较新的
    });

    final retrieved = <int>[];
    for (final candidate in candidates) {
      final turn = turns[candidate.index];
      if (used + turn.tokens > budgetTokens) continue;
      keptTurns.add(candidate.index);
      used += turn.tokens;
      for (var m = turn.start; m < turn.end; m++) {
        retrieved.add(m);
      }
    }

    // 3) 仍有预算：按新旧顺序补满（相关度不高的老回合也比没有强）。
    for (var i = turns.length - 2; i >= 0; i--) {
      if (keptTurns.contains(i)) continue;
      final turn = turns[i];
      if (used + turn.tokens > budgetTokens) continue;
      keptTurns.add(i);
      used += turn.tokens;
    }

    final keptIndexes = <int>[];
    final droppedIndexes = <int>[];
    for (var t = 0; t < turns.length; t++) {
      final turn = turns[t];
      for (var m = turn.start; m < turn.end; m++) {
        if (keptTurns.contains(t)) {
          keptIndexes.add(m);
        } else {
          droppedIndexes.add(m);
        }
      }
    }
    return AgentHistoryPlan(
      keptIndexes: keptIndexes,
      droppedIndexes: droppedIndexes,
      retrievedIndexes: retrieved..sort(),
      keptTokens: used,
    );
  }
}
