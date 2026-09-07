/// AI 助手页 UI 状态（Riverpod 不可变 state）。
class AgentState {
  /// 是否正在生成回复（由 AgentService.busy 驱动）。
  final bool isGenerating;

  /// 是否已初始化（已配置 API Key / 模块可用）。
  final bool isInitialized;

  /// 降级提示（Agent 模块未启用等）。
  final String errorMessage;

  /// 当前消息条数（service.messages 每次变更同步；
  /// 供页面重建"空态/欢迎页"依赖——0 ↔ 非 0 变化）。
  final int messageCount;

  const AgentState({
    this.isGenerating = false,
    this.isInitialized = false,
    this.errorMessage = '',
    this.messageCount = 0,
  });

  AgentState copyWith({
    bool? isGenerating,
    bool? isInitialized,
    String? errorMessage,
    int? messageCount,
  }) {
    return AgentState(
      isGenerating: isGenerating ?? this.isGenerating,
      isInitialized: isInitialized ?? this.isInitialized,
      errorMessage: errorMessage ?? this.errorMessage,
      messageCount: messageCount ?? this.messageCount,
    );
  }
}
