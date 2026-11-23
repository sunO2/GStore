/// Agent 单回合执行轨迹（P0 可观测性）
///
/// 一次 `chat()` = 一回合。记录模型、提示规模、首 token 延迟、工具调用数、
/// token 用量与耗时，落一条结构化日志（`AIAgentResponse` tag），并保留
/// `lastTurnTrace` 供页面/测试读取。
///
/// 只做数据记录，不参与编排；不依赖 AgentService，便于单测。
library;

class AgentTurnTrace {
  AgentTurnTrace({
    required this.turnId,
    required this.provider,
    required this.model,
    required this.toolsEnabled,
    required this.promptChars,
    required this.messageCount,
    required this.toolsOffered,
    DateTime? startedAt,
  })  : startedAt = startedAt ?? DateTime.now();

  final String turnId;
  final String provider;
  final String model;
  final bool toolsEnabled;

  /// 发给模型的提示字符数（system + 历史 + 本轮用户消息）
  final int promptChars;

  /// 发给模型的消息条数
  final int messageCount;

  /// 本轮下发给模型的工具数量（toolNames.length）
  final int toolsOffered;

  final DateTime startedAt;
  DateTime? firstTokenAt;
  DateTime? finishedAt;

  /// 本回合模型调用步数（tool loop 的一步 = 一次模型调用）
  int modelSteps = 0;

  int textChunks = 0;
  int reasoningChunks = 0;
  int responseChars = 0;
  int reasoningChars = 0;

  /// 模型请求的工具调用次数
  int toolRequests = 0;

  /// 工具执行结果回传次数
  int toolResponses = 0;

  /// 工具执行失败次数
  int toolErrors = 0;

  bool cancelled = false;
  String? error;
  String? finishReason;

  int? inputTokens;
  int? outputTokens;
  int? totalTokens;

  /// 首个可见 token（正文或思考）的延迟；未产生任何 token 时为 null
  int? get firstTokenMs => firstTokenAt?.difference(startedAt).inMilliseconds;

  /// 回合总耗时；未结束时按当前时间计算
  int get totalMs =>
      (finishedAt ?? DateTime.now()).difference(startedAt).inMilliseconds;

  /// 标记首个可见 token（重复调用只记一次）
  void markFirstToken() {
    firstTokenAt ??= DateTime.now();
  }

  /// 记录一次流式分片（正文/思考）
  void addChunk({int textChars = 0, int reasoningChars = 0}) {
    if (textChars > 0) {
      textChunks++;
      responseChars += textChars;
      markFirstToken();
    }
    if (reasoningChars > 0) {
      reasoningChunks++;
      this.reasoningChars += reasoningChars;
      markFirstToken();
    }
  }

  /// 结构化输出（日志/调试页可直接展示）
  Map<String, dynamic> toJson() => {
        'turnId': turnId,
        'provider': provider,
        'model': model,
        'toolsEnabled': toolsEnabled,
        'promptChars': promptChars,
        'messageCount': messageCount,
        'toolsOffered': toolsOffered,
        'modelSteps': modelSteps,
        'firstTokenMs': firstTokenMs,
        'totalMs': totalMs,
        'textChunks': textChunks,
        'reasoningChunks': reasoningChunks,
        'responseChars': responseChars,
        'reasoningChars': reasoningChars,
        'toolRequests': toolRequests,
        'toolResponses': toolResponses,
        'toolErrors': toolErrors,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'totalTokens': totalTokens,
        'finishReason': finishReason,
        'cancelled': cancelled,
        if (error != null) 'error': error,
      };
}
