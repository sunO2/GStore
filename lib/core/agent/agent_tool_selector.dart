/// 按本轮意图检索工具子集（P1）
///
/// 工具全量下发（20+ 个）会带来两个问题：
/// 1. function-calling schema 占用大量 prompt token；
/// 2. 模型在过多工具中选错的概率上升（rig/业界经验：>10~20 个开始下降）。
///
/// 这里用**确定性词法检索**（中文 bigram/trigram + 英文单词）给工具打分，
/// 保留一组"总是可用"的核心工具，再取分数最高的若干个。纯函数、可单测。
///
/// 设计取舍：
/// - 不做语义/向量检索，避免额外依赖与延迟；先解决"明显不相关工具"。
/// - 分数全为 0（寒暄/闲聊）时只保留核心工具，不塞满工具表。
/// - 工具名被用户直接提及时给最高权重（如"用 backup 导出"）。
library;

import 'package:gstore/core/agent/agent_tool_spec.dart';

/// 一次工具选择的结果
class AgentToolSelection {
  const AgentToolSelection({
    required this.names,
    required this.scores,
    required this.alwaysOn,
  });

  /// 本轮下发给模型的工具名（按注册表顺序，保证提示词稳定）
  final List<String> names;

  /// name → 词法得分（仅用于调试/测试）
  final Map<String, int> scores;

  /// 命中的"总是可用"核心工具
  final Set<String> alwaysOn;

  /// 是否对工具集做了裁剪（false = 全量）
  bool get isFiltered => names.isNotEmpty;
}

/// 工具检索器
class AgentToolSelector {
  AgentToolSelector._();

  /// 核心工具：任何一轮都可用，避免"闲聊时模型连基础工具都没有"。
  ///
  /// 只放最基础的应用发现/下载/安装/更新/确认，以及协议读取元工具。
  static const Set<String> alwaysOnNames = <String>{
    'searchApp',
    'getAppInfo',
    'updateApps',
    'downloadApp',
    'installApp',
    'installedApps',
    'manageDownload',
    'confirmAction',
    'loadProtocol',
    'remember',
    'forget',
    'webSearch',
    'webFetch',
  };

  /// 单轮最多下发的工具数（含核心工具）。
  static const int maxTools = 16;

  /// 选择本轮工具。
  ///
  /// [userText] 本轮用户输入；[recentTexts] 最近对话（仅低权重参考，可空）。
  static AgentToolSelection select({
    required String userText,
    Iterable<String> recentTexts = const <String>[],
    required List<AgentToolSpec> all,
  }) {
    final enabled = all.where((s) => s.enabled).toList(growable: false);
    if (enabled.length <= maxTools) {
      return AgentToolSelection(
        names: [for (final s in enabled) s.name],
        scores: const {},
        alwaysOn: {
          for (final s in enabled)
            if (alwaysOnNames.contains(s.name)) s.name,
        },
      );
    }

    final userTokens = tokenize(userText);
    final recentTokens = <String>{
      for (final text in recentTexts) ...tokenize(text),
    };
    final lowerText = userText.toLowerCase();

    final scores = <String, int>{};
    for (final spec in enabled) {
      final userScore = _score(spec, userTokens, lowerText, explicit: true);
      final recentScore =
          _score(spec, recentTokens, '', explicit: false) ~/ 2;
      scores[spec.name] = userScore + recentScore;
    }

    // 核心工具 + 分数为正的候选；按分数降序、注册表顺序升序
    final indexed = <(int, AgentToolSpec)>[
      for (var i = 0; i < enabled.length; i++) (i, enabled[i]),
    ];
    indexed.sort((a, b) {
      final sa = scores[a.$2.name] ?? 0;
      final sb = scores[b.$2.name] ?? 0;
      if (sa != sb) return sb.compareTo(sa);
      return a.$1.compareTo(b.$1);
    });

    final selected = <String>{};
    for (final spec in enabled) {
      if (alwaysOnNames.contains(spec.name)) selected.add(spec.name);
    }
    for (final (_, spec) in indexed) {
      if (selected.length >= maxTools) break;
      // 阈值过滤：只靠一个通用词（如"应用"）命中的工具不进候选
      if ((scores[spec.name] ?? 0) >= 4) selected.add(spec.name);
    }

    // 按注册表顺序输出（提示词与 schema 顺序稳定）
    final names = <String>[
      for (final spec in enabled)
        if (selected.contains(spec.name)) spec.name,
    ];
    return AgentToolSelection(
      names: names,
      scores: scores,
      alwaysOn: {
        for (final name in names)
          if (alwaysOnNames.contains(name)) name,
      },
    );
  }

  /// 中文 bigram/trigram + 英文/数字单词
  static Set<String> tokenize(String text) {
    final lower = text.toLowerCase();
    final out = <String>{};
    for (final m in RegExp(r'[a-z0-9_]{2,}').allMatches(lower)) {
      out.add(m.group(0)!);
    }
    for (final m in RegExp(r'[\u4e00-\u9fff]+').allMatches(lower)) {
      final run = m.group(0)!;
      for (var i = 0; i < run.length; i++) {
        if (i + 1 < run.length) out.add(run.substring(i, i + 2));
        if (i + 2 < run.length) out.add(run.substring(i, i + 3));
      }
    }
    return out;
  }

  static int _score(
    AgentToolSpec spec,
    Set<String> tokens,
    String lowerText, {
    required bool explicit,
  }) {
    var score = 0;
    final name = spec.name.toLowerCase();
    // 用户直接说出工具名（如 "backup"）→ 强命中
    if (explicit && lowerText.contains(name)) score += 20;
    final label = spec.label.toLowerCase();
    final brief = spec.brief.toLowerCase();
    for (final token in tokens) {
      if (name.contains(token)) score += 8;
      if (label.contains(token)) score += 6;
      if (brief.contains(token)) score += 3;
    }
    return score;
  }
}
