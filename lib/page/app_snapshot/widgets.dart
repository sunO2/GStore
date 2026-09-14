import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';

/// 快照页面共用的分节卡片（基于应用设计系统的 [AppCard]）
///
/// 支持**折叠**：详情页与对比页的分区都很多（详情 10 节 / 对比 21 节），
/// 全部展开会变成一条极长的滚动列表。因此默认折叠，标题右侧给出
/// 「条目计数 + 变化角标」，点标题展开——概览优先，需要细节时再摊开。
class SnapshotSectionCard extends StatefulWidget {
  const SnapshotSectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.subtitle,
    this.dimmed = false,
    this.collapsible = false,
    this.initiallyExpanded = true,
    this.count,
    this.badge,
    this.badgeHighlight = false,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  /// 数据不可比等降级状态：整卡降低对比度
  final bool dimmed;

  /// 是否可折叠（详情 / 对比页开启）
  final bool collapsible;

  /// 初始是否展开（对比页默认折叠，详情页只有概览展开）
  final bool initiallyExpanded;

  /// 条目计数（折叠状态下也能看出规模）
  final int? count;

  /// 角标文案（如「+1 −2 ~3」「无变化」）
  final String? badge;

  /// 角标是否用强调色（有变化时）
  final bool badgeHighlight;

  @override
  State<SnapshotSectionCard> createState() => _SnapshotSectionCardState();
}

class _SnapshotSectionCardState extends State<SnapshotSectionCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Opacity(
      opacity: widget.dimmed ? 0.6 : 1,
      child: AppCard(
        margin: AppSpacing.onlyBottomSM,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: widget.collapsible
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (widget.count != null) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      '· ${widget.count}',
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                  ],
                  const Spacer(),
                  if (widget.badge != null)
                    _Badge(
                      text: widget.badge!,
                      highlight: widget.badgeHighlight,
                    ),
                  if (widget.trailing != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    widget.trailing!,
                  ],
                  if (widget.collapsible) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: AppTypography.iconSM,
                      color: muted,
                    ),
                  ],
                ],
              ),
            ),
            if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                widget.subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
            if (!widget.collapsible || _expanded) ...[
              const SizedBox(height: AppSpacing.sm),
              widget.child,
            ],
          ],
        ),
      ),
    );
  }
}

/// 分区角标：折叠时也能一眼看出该节有没有变化
class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.highlight = false});

  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        highlight ? theme.colorScheme.tertiary : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// 键值行：长值换行不截断（mono 用于包名/类名/指纹这类标识符）
class SnapshotInfoRow extends StatelessWidget {
  const SnapshotInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = mono
        ? AppTypography.code.copyWith(color: theme.colorScheme.onSurface)
        : theme.textTheme.bodySmall;
    return Padding(
      padding: AppSpacing.onlyBottomXS,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value.isEmpty ? '—' : value, style: style)),
        ],
      ),
    );
  }
}

/// 列表型数据行
class SnapshotTextRow extends StatelessWidget {
  const SnapshotTextRow({
    super.key,
    required this.text,
    this.subtitle,
    this.tags = const [],
    this.mono = false,
  });

  final String text;
  final String? subtitle;
  final List<String> tags;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: AppSpacing.onlyBottomXS,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: mono
                ? AppTypography.code.copyWith(color: theme.colorScheme.onSurface)
                : theme.textTheme.bodySmall,
          ),
          if (subtitle != null && subtitle!.isNotEmpty)
            Text(
              subtitle!,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          if (tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Wrap(
                children: [for (final t in tags) SnapshotTag(text: t)],
              ),
            ),
        ],
      ),
    );
  }
}

/// 小标签
class SnapshotTag extends StatelessWidget {
  const SnapshotTag({super.key, required this.text, this.emphasized = false});

  final String text;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(right: 6, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: emphasized
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: emphasized
              ? theme.colorScheme.onPrimaryContainer
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 空态（复用设计系统 [EmptyState]）
class SnapshotEmptyHint extends StatelessWidget {
  const SnapshotEmptyHint({super.key, required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) =>
      EmptyState(message: text, icon: icon ?? Icons.inbox_outlined);
}
