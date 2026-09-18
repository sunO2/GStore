/// 用户消息气泡（Agent 对话页）
///
/// 为什么单独抽出来：用户消息走聊天库的 `bubbleBuilder` 自绘气泡，逻辑在
/// 页面 State 里拿不到；抽成组件后可直接单测，也能保证「文本可长按复制」
/// 这类行为不被后续改动改没。
///
/// 与 agent 侧一致的可复制能力：agent 正文用 `AgentMarkdownMessage`
/// （`selectable: true`），用户正文这里用 [SelectableText]，
/// 长按即可选中并复制。
library;

import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';

class AgentUserBubble extends StatelessWidget {
  const AgentUserBubble({
    super.key,
    required this.text,
    required this.timeLabel,
    required this.maxWidth,
  });

  /// 消息正文
  final String text;

  /// 右下角时间文案（调用方负责格式化）
  final String timeLabel;

  /// 气泡最大宽度
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: scheme.onPrimary,
          height: 1.4,
        );

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primary,
              scheme.primary.withValues(alpha: 0.85),
            ],
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(AppRadius.lg),
            topRight: Radius.circular(AppRadius.lg),
            bottomLeft: Radius.circular(AppRadius.lg),
            bottomRight: Radius.circular(AppRadius.sm),
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.25),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            // SelectableText：长按选中并复制（与 agent 正文一致）
            SelectableText(
              text,
              style: textStyle,
              // 气泡底色是主色，选区用 onPrimary 半透明保证可见
              selectionColor: scheme.onPrimary.withValues(alpha: 0.35),
              cursorColor: scheme.onPrimary,
            ),
            const SizedBox(height: 2),
            Text(
              timeLabel,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimary.withValues(alpha: 0.8),
                    fontSize: 10,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
