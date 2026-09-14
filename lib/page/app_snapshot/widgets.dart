import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';

/// 快照页面共用的分节卡片（基于应用设计系统的 [AppCard]）
class SnapshotSectionCard extends StatelessWidget {
  const SnapshotSectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.subtitle,
    this.dimmed = false,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  /// 数据不可比等降级状态：整卡降低对比度
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: dimmed ? 0.6 : 1,
      child: AppCard(
        margin: AppSpacing.onlyBottomSM,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitle!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ),
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
