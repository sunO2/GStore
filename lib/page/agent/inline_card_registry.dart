/// Agent 内联原生卡片注册表（实验特性 · 阶段一）
///
/// 页面层薄封装：把一条**显式** `showConfigControl` / `showConfigSwitch`
/// 工具消息映射为可在对话列表中内联渲染的原生配置控件卡片。白名单与解析逻辑位于
/// `lib/core/agent/agent_inline_cards.dart`。
///
/// 本文件只负责「从消息派生卡片规格」的纯逻辑，不包含任何 Flutter Widget，
/// 也不再基于用户文本或 `configManager` 做任何自动派生。
library;

import 'package:gstore/core/agent/agent_inline_cards.dart';
import 'package:gstore/core/agent/agent_service.dart';

export 'package:gstore/core/agent/agent_inline_cards.dart';

/// 仅当 Agent 显式调用了 showConfigControl/showConfigSwitch 时返回卡片规格。
AgentInlineSwitchSpec? controlForInlineCard(AgentMessage msg) {
  if (!kAgentInlineCardsEnabled) return null;
  if (!msg.isToolResult) return null;
  if (msg.toolStatus != AgentToolStatus.done) return null;
  final isSwitchTool = msg.toolName == AgentService.showConfigSwitchToolName;
  final isControlTool = msg.toolName == AgentService.showConfigControlToolName;
  if (!isSwitchTool && !isControlTool) return null;
  final type = isSwitchTool
      ? 'switch'
      : msg.toolArgs?['type']?.toString();
  return AgentInlineCards.controlForKey(
    msg.toolArgs?['key']?.toString(),
    kind: (type == null || type.isEmpty) ? null : type,
  );
}

/// Wave 3 兼容：仅返回开关类控件规格。
AgentInlineSwitchSpec? switchForInlineCard(AgentMessage msg) {
  final spec = controlForInlineCard(msg);
  return spec?.kind == AgentInlineControlKind.switchControl ? spec : null;
}
