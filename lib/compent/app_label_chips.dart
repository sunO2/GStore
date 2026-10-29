import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/model/AppDetailInfo.dart' show AppLabel;

/// 应用卡片上的动态标签条（跨渠道统一）。
///
/// 渲染 `AppSummary.labels`（渠道 typed DTO 逐字段透传的 `{key,label,value,icon?}`）。
///
/// 约定：
/// - **有界**：最多展示 [maxVisible] 个标签，其余折叠为 `+N` 溢出指示，
///   标签数量再多也不会撑破卡片布局（无 RenderFlex overflow）。
/// - **空安全**：`labels` 为空时不渲染任何内容（`SizedBox.shrink`），卡片不报错。
/// - **主题令牌**：仅用 `Theme.of(context)` 的 colorScheme/textTheme + AppSpacing /
///   AppRadius，无硬编码颜色/字号。
///
/// `icon` 在卡片这种紧凑区域不渲染（详情信息区由详情页负责展示图标），
/// 仅以 `label value` 文本呈现。
class AppLabelChips extends StatelessWidget {
  /// 待渲染的标签列表（来自 `AppSummary.labels`）。
  final List<AppLabel> labels;

  /// 最多可见的标签数；超出的折叠为 `+N`。
  final int maxVisible;

  /// 标签行在主轴上的对齐方式（卡片多为居中，列表项多为左对齐）。
  final MainAxisAlignment alignment;

  const AppLabelChips({
    super.key,
    required this.labels,
    this.maxVisible = 2,
    this.alignment = MainAxisAlignment.center,
  });

  @override
  Widget build(BuildContext context) {
    // 空标签：什么都不渲染（卡片安全）。
    if (labels.isEmpty) return const SizedBox.shrink();

    final visible = labels.take(maxVisible).toList(growable: false);
    final overflow = labels.length - visible.length;

    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: alignment,
      children: [
        for (var i = 0; i < visible.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.xs),
          // Flexible + ellipsis：宽度不足时收缩省略，绝不溢出。
          Flexible(child: _LabelChip(label: visible[i])),
        ],
        if (overflow > 0) ...[
          const SizedBox(width: AppSpacing.xs),
          _OverflowChip(count: overflow),
        ],
      ],
    );
  }
}

class _LabelChip extends StatelessWidget {
  final AppLabel label;

  const _LabelChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.allSM,
      ),
      child: Text(
        '${label.label} ${label.value}',
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _OverflowChip extends StatelessWidget {
  final int count;

  const _OverflowChip({required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: AppRadius.allSM,
      ),
      child: Text(
        '+$count',
        maxLines: 1,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
            ),
      ),
    );
  }
}
