import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_animation.dart';
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

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final canToggle = widget.collapsible;
    final hasSubtitle = widget.subtitle != null && widget.subtitle!.isNotEmpty;

    return Opacity(
      opacity: widget.dimmed ? 0.6 : 1,
      child: AppCard(
        // 页面级左右边距：与设置页等既有卡片一致（AppSpacing.allLG 的横向部分），
        // 原来只给底部间距，导致分区内容贴屏幕两侧
        margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 整个标题区（含副标题）都可点：点击区域不再只有那个小箭头
            InkWell(
              onTap: canToggle ? _toggle : null,
              borderRadius: AppRadius.allLG,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Expanded 让右侧控件稳定贴右（不再依赖 Spacer 分配空白）
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.title,
                                // 卡片标题按设计系统用 titleMedium(16sp)；
                                // 之前用 titleSmall(14sp) 明显偏小
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (widget.count != null) ...[
                              const SizedBox(width: AppSpacing.sm),
                              Text(
                                '· ${widget.count}',
                                style: theme.textTheme.labelMedium
                                    ?.copyWith(color: muted),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (widget.badge != null) ...[
                        _Badge(
                          text: widget.badge!,
                          highlight: widget.badgeHighlight,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                      ],
                      if (widget.trailing != null) widget.trailing!,
                      if (canToggle)
                        // 用 IconButton：自带 ≥48×48 点击区域 + 展开/收起 tooltip，
                        // 与详情页 SectionCard 的既有做法一致
                        IconButton(
                          onPressed: _toggle,
                          tooltip: _expanded ? '收起' : '展开',
                          icon: AnimatedRotation(
                            turns: _expanded ? 0.5 : 0.0,
                            duration: AppAnimation.fast,
                            curve: AppAnimation.curve,
                            child: Icon(
                              _expanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: AppTypography.iconLG,
                              color: muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (hasSubtitle)
                    Padding(
                      padding: const EdgeInsets.only(
                        top: AppSpacing.xs,
                        // 右侧留出箭头宽度，副标题不会顶到按钮下面
                        right: AppSpacing.xxxl,
                      ),
                      child: Text(
                        widget.subtitle!,
                        style:
                            theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ),
                ],
              ),
            ),
            if (!canToggle || _expanded) ...[
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
