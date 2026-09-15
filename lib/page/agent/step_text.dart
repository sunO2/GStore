/// Agent 时间轴「文本步骤」渲染组件（自定义 step UI 专用）
///
/// 为什么单独抽出来：对话用的是**自定义 step 时间轴**（`_TurnTimeline` +
/// `customBuilder`），不是聊天框架自带的纯文本气泡。思考内容必须在这里
/// 显式渲染，否则框架不会帮忙显示。
///
/// 组合关系（保持 step 结构不变）：
/// ```
/// StepText 节点
/// ├── [可选] AgentReasoningBlock   思考折叠块（受 showReasoning 开关控制）
/// └── AgentMarkdownMessage         正文 Markdown（原有行为）
/// ```
library;

import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/page/agent/markdown_message.dart';

/// 思考过程折叠块（reasoning / 内联 think 内容）
///
/// 展示策略：流式进行中默认展开（便于实时观察推理过程），
/// 生成结束后默认折叠；标题栏点击可手动展开/收起。
class AgentReasoningBlock extends StatefulWidget {
  const AgentReasoningBlock({
    super.key,
    required this.reasoning,
    required this.done,
  });

  /// 思考正文
  final String reasoning;

  /// 思考是否已结束（结束后默认折叠）
  final bool done;

  @override
  State<AgentReasoningBlock> createState() => _AgentReasoningBlockState();
}

class _AgentReasoningBlockState extends State<AgentReasoningBlock> {
  /// 用户手动覆盖的展开态（null = 按 done 自动决定）
  bool? _expanded;

  bool get _isExpanded => _expanded ?? !widget.done;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = widget.reasoning.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏（整行可点，点击区域充足）
          InkWell(
            onTap: () => setState(() => _expanded = !_isExpanded),
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: AppTypography.iconSM,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      widget.done ? '思考过程' : '思考中…',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: AppTypography.weightSemiBold,
                          ),
                    ),
                  ),
                  if (!widget.done) ...[
                    const AppLoading(size: AppLoadingSize.small),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                  Icon(
                    _isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: AppTypography.iconSM,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: SelectableText(
                text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 时间轴「文本步骤」内容：可选思考折叠块 + Markdown 正文
///
/// 正文节点原有行为（Markdown 渲染）保持不变，思考块是**附加**在正文之上，
/// 因此不会改变 step 的既有展示方式。
class AgentStepTextBlock extends StatelessWidget {
  const AgentStepTextBlock({
    super.key,
    required this.text,
    this.reasoning = '',
    this.reasoningDone = true,
    this.showReasoning = true,
  });

  /// 正文（Markdown）
  final String text;

  /// 思考正文
  final String reasoning;

  /// 思考是否已结束
  final bool reasoningDone;

  /// 是否渲染思考块（模型配置开关）
  final bool showReasoning;

  @override
  Widget build(BuildContext context) {
    final hasReasoning = showReasoning && reasoning.trim().isNotEmpty;
    if (!hasReasoning && text.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasReasoning)
          AgentReasoningBlock(reasoning: reasoning, done: reasoningDone),
        if (text.trim().isNotEmpty) AgentMarkdownMessage(text: text),
      ],
    );
  }
}
