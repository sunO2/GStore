import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/snapshot/snapshot_diff_engine.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';
import 'package:gstore/page/app_snapshot/widgets.dart';

/// 两份快照的对比结果（分节展示 新增 / 移除 / 变化）
class AppSnapshotComparePage extends StatelessWidget {
  const AppSnapshotComparePage({
    super.key,
    required this.oldRecord,
    required this.newRecord,
  });

  final SnapshotRecord oldRecord;
  final SnapshotRecord newRecord;

  @override
  Widget build(BuildContext context) {
    final diff = SnapshotDiffEngine.compare(oldRecord, newRecord);
    final sections = diff.changedSections.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('快照对比')),
      body: ListView(
        padding: AppSpacing.onlyVerticalSM,
        children: [
          _header(context, diff),
          if (diff.payloadVersionMismatch) _mismatchBanner(context),
          if (sections.isEmpty)
            const SnapshotEmptyHint(
              text: '两份快照没有差异',
              icon: Icons.check_circle_outline,
            )
          else
            for (final section in sections) _section(context, section),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, SnapshotDiff diff) {
    final theme = Theme.of(context);
    return SnapshotSectionCard(
      title:
          'v${oldRecord.versionName} → v${newRecord.versionName}',
      subtitle: '${formatTime(oldRecord.createdAt)}  →  '
          '${formatTime(newRecord.createdAt)}',
      child: Row(
        children: [
          _countChip(theme, '新增', diff.added, SnapshotDiffKind.added),
          const SizedBox(width: AppSpacing.sm),
          _countChip(theme, '移除', diff.removed, SnapshotDiffKind.removed),
          const SizedBox(width: AppSpacing.sm),
          _countChip(theme, '变化', diff.changed, SnapshotDiffKind.changed),
          const Spacer(),
          Text(
            '共 ${diff.total} 处差异',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _countChip(
    ThemeData theme,
    String label,
    int count,
    SnapshotDiffKind kind,
  ) {
    final color = _kindColor(theme, kind);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        '$label $count',
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }

  Widget _mismatchBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: AppSpacing.onlyHorizontalMD.add(AppSpacing.onlyBottomSM),
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        '两份快照的采集版本不同（v${oldRecord.payloadVersion} → '
        'v${newRecord.payloadVersion}），带「?」的条目可能来自采集能力变化而非应用本身。',
        style: theme.textTheme.bodySmall,
      ),
    );
  }

  Widget _section(BuildContext context, SnapshotDiffSection section) {
    return SnapshotSectionCard(
      title: section.title,
      dimmed: !section.comparable,
      trailing: Wrap(
        spacing: AppSpacing.sm,
        children: [
          if (section.added > 0) _plainCount('+${section.added}'),
          if (section.removed > 0) _plainCount('-${section.removed}'),
          if (section.changed > 0) _plainCount('~${section.changed}'),
        ],
      ),
      subtitle: section.comparable ? null : '该节在旧快照中不存在，无法比较',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in section.entries) _entry(context, entry),
        ],
      ),
    );
  }

  Widget _plainCount(String text) => Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
      );

  Widget _entry(BuildContext context, SnapshotDiffEntry entry) {
    final theme = Theme.of(context);
    final color = _kindColor(theme, entry.kind);
    final marker = switch (entry.kind) {
      SnapshotDiffKind.added => '+',
      SnapshotDiffKind.removed => '-',
      SnapshotDiffKind.changed => '~',
    };
    // 单条变化合并成一行（`字段: from → to`）；多条字段变化则逐行列出
    final lines = <String>[
      if (entry.fieldChanges.isNotEmpty)
        for (final f in entry.fieldChanges) '${f.field}: ${f.from} → ${f.to}'
      else if (entry.oldValue != null || entry.newValue != null)
        '${entry.oldValue ?? '—'} → ${entry.newValue ?? '—'}',
    ];
    final subtitleStyle = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Padding(
      padding: AppSpacing.onlyBottomXS,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 14,
            child: Text(
              entry.uncertain ? '?' : marker,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: lines.length <= 1
                ? Text(
                    lines.isEmpty
                        ? entry.key
                        : '${entry.key}: ${lines.first}',
                    style: theme.textTheme.bodySmall,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.key, style: theme.textTheme.bodySmall),
                      for (final line in lines)
                        Text(line, style: subtitleStyle),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  static Color _kindColor(ThemeData theme, SnapshotDiffKind kind) =>
      switch (kind) {
        SnapshotDiffKind.added => Colors.green.shade600,
        SnapshotDiffKind.removed => theme.colorScheme.error,
        SnapshotDiffKind.changed => Colors.orange.shade700,
      };
}
