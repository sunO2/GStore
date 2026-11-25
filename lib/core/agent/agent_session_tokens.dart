/// 单个会话的 token 统计与上下文上限。
///
/// 统计口径：
/// - [inputTokens]/[outputTokens]：本会话所有模型调用（含工具循环每一步）由
///   provider 返回的 usage 累计，用于展示“会话累计 token”。
/// - [contextTokens]：当前会话上下文大小的估算（全部消息 + 滚动摘要 +
///   系统提示），用于更多按钮周围的进度环和 1M 自动压缩判断。
/// - [compactCount]：自动压缩次数。
library;

/// 会话上下文硬上限：超过后自动压缩历史并保留摘要。
const int kAgentSessionContextLimitTokens = 1000000;

/// 会话 token 统计快照（不可变，便于 ValueNotifier 通知 UI）。
class AgentSessionTokenStats {
  const AgentSessionTokenStats({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.contextTokens = 0,
    this.compactCount = 0,
    this.updatedAt = 0,
  });

  static const AgentSessionTokenStats empty = AgentSessionTokenStats();

  /// 累计输入 token（provider usage）
  final int inputTokens;

  /// 累计输出 token（provider usage）
  final int outputTokens;

  /// 当前上下文估算 token
  final int contextTokens;

  /// 自动压缩次数
  final int compactCount;

  /// 最后更新时间（毫秒时间戳）
  final int updatedAt;

  int get totalTokens => inputTokens + outputTokens;

  /// 上下文占上限的比例（0~1，超过上限钳制为 1）
  double ratio([int limit = kAgentSessionContextLimitTokens]) {
    if (limit <= 0) return 0;
    return (contextTokens / limit).clamp(0.0, 1.0).toDouble();
  }

  /// 原始比例（可超过 1，用于文案展示）
  double rawRatio([int limit = kAgentSessionContextLimitTokens]) {
    if (limit <= 0) return 0;
    return contextTokens / limit;
  }

  bool isOverLimit([int limit = kAgentSessionContextLimitTokens]) =>
      limit > 0 && contextTokens >= limit;

  AgentSessionTokenStats copyWith({
    int? inputTokens,
    int? outputTokens,
    int? contextTokens,
    int? compactCount,
    int? updatedAt,
  }) {
    return AgentSessionTokenStats(
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      contextTokens: contextTokens ?? this.contextTokens,
      compactCount: compactCount ?? this.compactCount,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'contextTokens': contextTokens,
        'compactCount': compactCount,
        'updatedAt': updatedAt,
      };

  factory AgentSessionTokenStats.fromJson(Map<String, dynamic> json) {
    int asInt(Object? value) => value is num ? value.toInt() : 0;
    return AgentSessionTokenStats(
      inputTokens: asInt(json['inputTokens']),
      outputTokens: asInt(json['outputTokens']),
      contextTokens: asInt(json['contextTokens']),
      compactCount: asInt(json['compactCount']),
      updatedAt: asInt(json['updatedAt']),
    );
  }

  @override
  String toString() =>
      'AgentSessionTokenStats(in=$inputTokens, out=$outputTokens, '
      'context=$contextTokens, compact=$compactCount)';
}
