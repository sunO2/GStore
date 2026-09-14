import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/snapshot/snapshot_diff_engine.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';
import 'package:gstore/page/app_snapshot/widgets.dart';

/// 两份快照的对比结果
///
/// 布局取舍：分区多（21 节）且条目可能上百，全部平铺会变成一条极长的滚动列表。
/// 因此分为「概览（哪些节变了）」+「分区列表（默认折叠、只列有变化的节）」，
/// 需要时再逐个展开看条目级差异。
class AppSnapshotComparePage extends StatefulWidget {
  const AppSnapshotComparePage({
    super.key,
    required this.oldRecord,
    required this.newRecord,
  });

  final SnapshotRecord oldRecord;
  final SnapshotRecord newRecord;

  @override
  State<AppSnapshotComparePage> createState() => _AppSnapshotComparePageState();
}

class _AppSnapshotComparePageState extends State<AppSnapshotComparePage> {
  /// 只看有变化的分区（默认开：对比页的目的是找差异）
  bool _changedOnly = true;

  /// 对比方向：默认「较早 → 较晚」，用户可一键互换
  ///
  /// 选两份快照时**不按勾选顺序**决定方向（那样难以预期），而是默认早→晚；
  /// 需要反过来看（例如回看"从新版回到旧版"的差异）时点标题栏的互换按钮。
  bool _swapped = false;

  SnapshotRecord get _old => _swapped ? widget.newRecord : widget.oldRecord;
  SnapshotRecord get _new => _swapped ? widget.oldRecord : widget.newRecord;

  /// 关键字过滤：资源级 diff 可能出现上千条，靠搜索定位而不是滚动
  String _query = '';
  final TextEditingController _queryCtrl = TextEditingController();

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  /// 按关键字筛选分区内的条目（命中 key / 新旧值 / 字段级变化任一处）
  List<SnapshotDiffEntry> _filteredEntries(SnapshotDiffSection section) {
    if (_query.isEmpty) return section.entries;
    final q = _query.toLowerCase();
    return section.entries.where((e) {
      bool hit(String v) => v.toLowerCase().contains(q);
      if (hit(e.key)) return true;
      if (e.oldValue != null && hit(e.oldValue!)) return true;
      if (e.newValue != null && hit(e.newValue!)) return true;
      for (final f in e.fieldChanges) {
        if (hit(f.field) || hit(f.from) || hit(f.to)) return true;
      }
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final diff = SnapshotDiffEngine.compare(_old, _new);
    final changed = diff.changedSections.toList();
    // 搜索时跨全部分区找命中项；否则按"只看有变化"过滤空节
    final searching = _query.isNotEmpty;
    final sections = (searching || !_changedOnly) ? diff.sections : changed;
    return Scaffold(
      appBar: AppBar(
        title: const Text('快照对比'),
        actions: [
          IconButton(
            tooltip: '互换对比方向（旧↔新）',
            icon: const Icon(Icons.swap_horiz),
            onPressed: () => setState(() => _swapped = !_swapped),
          ),
        ],
      ),
      body: ListView(
        padding: AppSpacing.onlyVerticalSM,
        children: [
          _header(context, diff),
          if (diff.payloadVersionMismatch) _mismatchBanner(context),
          _filterBar(context, changed.length, diff.sections.length),
          _searchBar(context),
          if (searching)
            for (final section in sections)
              if (_filteredEntries(section).isNotEmpty)
                _section(context, section, entries: _filteredEntries(section))
              else
                const SizedBox.shrink()
          else if (changed.isEmpty)
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

  /// 概览条：变化节数 + 是否只看有变化
  Widget _filterBar(BuildContext context, int changedCount, int totalCount) {
    final theme = Theme.of(context);
    return Padding(
      padding: AppSpacing.onlyHorizontalMD.add(AppSpacing.onlyBottomSM),
      child: Row(
        children: [
          Text(
            '$changedCount / $totalCount 个分区有变化',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const Spacer(),
          Text('只看有变化', style: theme.textTheme.bodySmall),
          Switch(
            value: _changedOnly,
            onChanged: (v) => setState(() => _changedOnly = v),
          ),
        ],
      ),
    );
  }

  /// 关键字搜索（资源级/条目级差异可能有上千条）
  Widget _searchBar(BuildContext context) {
    return Padding(
      padding: AppSpacing.onlyHorizontalMD.add(AppSpacing.onlyBottomSM),
      child: TextField(
        controller: _queryCtrl,
        onChanged: (v) => setState(() => _query = v.trim()),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索资源名 / 库名 / 字段（如 app_name）',
          prefixIcon: const Icon(Icons.search, size: AppTypography.iconSM),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: AppTypography.iconSM),
                  onPressed: () {
                    _queryCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, SnapshotDiff diff) {
    final theme = Theme.of(context);
    final verdict = diff.verdict;
    return SnapshotSectionCard(
      title: 'v${_old.versionName} → v${_new.versionName}',
      subtitle: '旧 ${formatTime(_old.createdAt)} → '
          '新 ${formatTime(_new.createdAt)}'
          '${_swapped ? '（已互换方向）' : ''}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 结论摘要：先把"整体变了什么"讲清楚，再往下看分节细节
          if (verdict.title.isNotEmpty) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  verdict.hasChange
                      ? Icons.change_circle_outlined
                      : Icons.check_circle_outline,
                  size: AppTypography.iconSM,
                  color: verdict.hasChange
                      ? theme.colorScheme.tertiary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    verdict.title,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (verdict.labels.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final l in verdict.labels) SnapshotTag(text: l),
                ],
              ),
            ],
            const Divider(height: AppSpacing.lg),
          ],
          Row(
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
        '两份快照的采集版本不同（v${_old.payloadVersion} → '
        'v${_new.payloadVersion}），带「?」的条目可能来自采集能力变化而非应用本身。',
        style: theme.textTheme.bodySmall,
      ),
    );
  }

  Widget _section(
    BuildContext context,
    SnapshotDiffSection section, {
    List<SnapshotDiffEntry>? entries,
  }) {
    final hasDiff = section.hasDiff;
    final shown = entries ?? section.entries;
    return SnapshotSectionCard(
      title: section.title,
      dimmed: !section.comparable,
      // 折叠：一屏先看到"哪些节变了"，需要细节再展开
      collapsible: true,
      // 搜索时直接展开，省去逐节点开
      initiallyExpanded: _query.isNotEmpty,
      count: shown.length,
      badge: !section.comparable
          ? '不可比'
          : hasDiff
              ? '+${section.added} −${section.removed} ~${section.changed}'
              : '无变化',
      badgeHighlight: section.comparable && hasDiff,
      subtitle: section.comparable ? null : '该节在旧快照中不存在，无法比较',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 条目级清单可能上千条（大包 .so/assets）：只渲染前 N 条，
          // 其余给出计数提示——数据仍完整保留在 diff 里，只是不一次性建满 widget。
          for (final entry in shown.take(_maxRenderedEntries))
            _entry(context, entry),
          if (shown.length > _maxRenderedEntries)
            Padding(
              padding: AppSpacing.onlyVerticalXS,
              child: Text(
                '还有 ${shown.length - _maxRenderedEntries} 条未显示'
                '（共 ${shown.length} 条）',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
        ],
      ),
    );
  }

  /// 单个分区最多渲染的条目数（超出部分只提示计数）
  static const int _maxRenderedEntries = 200;

  /// 一条差异
  ///
  /// 展示取舍：原来把变化压成一行 `字段: 旧 → 新`，条目一多就满屏箭头、难以扫读。
  /// 现在按「条目 →（结论）→ 字段 → 旧值 −／新值 +」分行，
  /// 体积类字段还会给出**差值**（+2.2 MB / −1.0 KB），不用自己减。
  Widget _entry(BuildContext context, SnapshotDiffEntry entry) {
    final theme = Theme.of(context);
    final color = _kindColor(theme, entry.kind);
    final muted = theme.colorScheme.onSurfaceVariant;
    final marker = switch (entry.kind) {
      SnapshotDiffKind.added => '+',
      SnapshotDiffKind.removed => '−',
      SnapshotDiffKind.changed => '~',
    };
    return Padding(
      padding: AppSpacing.onlyBottomXS,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                child: Text(entry.key, style: theme.textTheme.bodySmall),
              ),
              if (entry.sameContent != null)
                _contentChip(theme, entry.sameContent!),
            ],
          ),
          // 内容指纹结论：直接回答"是不是同一个文件"，不用去比 hex
          if (entry.sameContent != null)
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 2),
              child: Text(
                entry.sameContent!
                    ? '内容一致（是同一个文件）'
                    : '内容已变（同名但不是同一个文件）',
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
            ),
          for (final f in entry.fieldChanges)
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.field,
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                  ..._beforeAfter(theme, f.from, f.to),
                ],
              ),
            ),
          // 无字段级差异的**变化**条目（标量节）：分行给出旧/新。
          // 新增/删除条目不再重复打印一遍名字（key 已经显示了，重复反而更乱）。
          if (entry.kind == SnapshotDiffKind.changed &&
              entry.fieldChanges.isEmpty &&
              (entry.oldValue != null || entry.newValue != null))
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _beforeAfter(theme, entry.oldValue, entry.newValue),
              ),
            ),
        ],
      ),
    );
  }

  /// 旧值 `−` / 新值 `+` 各占一行（体积类附差值）
  List<Widget> _beforeAfter(ThemeData theme, String? before, String? after) {
    final hasBefore = before != null && before.isNotEmpty && before != '—';
    final hasAfter = after != null && after.isNotEmpty && after != '—';
    final delta = (hasBefore && hasAfter) ? formatBytesDelta(before, after) : null;
    final style = theme.textTheme.bodySmall;
    return [
      if (hasBefore)
        Text(
          '− $before',
          style: style?.copyWith(color: _kindColor(theme, SnapshotDiffKind.removed)),
        ),
      if (hasAfter)
        Text(
          '+ $after${delta == null ? '' : '  ($delta)'}',
          style: style?.copyWith(color: _kindColor(theme, SnapshotDiffKind.added)),
        ),
    ];
  }

  /// 内容指纹标记：一眼看出"是否同一个文件"
  Widget _contentChip(ThemeData theme, bool sameContent) {
    final color = sameContent
        ? _kindColor(theme, SnapshotDiffKind.added)
        : theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        sameContent ? '同一文件' : '内容不同',
        style: theme.textTheme.labelSmall?.copyWith(color: color),
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
