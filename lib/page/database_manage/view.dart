import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/core.dart';

import 'logic.dart';
import 'state.dart';

/// 数据库管理页：列出应用全部 SQLite 库，逐库→逐表→逐行浏览与删除。
class DatabaseManagePage extends ConsumerWidget {
  const DatabaseManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(databaseManageProvider);
    final notifier = ref.read(databaseManageProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('数据库管理')),
      body: state.loading && state.dbs.isEmpty
          ? const LoadingState(message: '正在扫描数据库…')
          : state.dbs.isEmpty
              ? const Center(child: Text('未发现数据库文件'))
              : RefreshIndicator(
                  onRefresh: notifier.reload,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                    children: [
                      _buildHint(context),
                      for (final db in state.dbs)
                        _DbCard(
                          db: db,
                          onTap: () {
                            notifier.loadTables(db);
                            Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => const _DbTablesPage(),
                            ));
                          },
                        ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildHint(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Text(
        '数据库由 App 自动维护，删除记录前请确认影响',
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}

class _DbCard extends ConsumerWidget {
  const _DbCard({required this.db, required this.onTap});

  final DbEntry db;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(databaseManageProvider.notifier);
    return Card(
      margin: AppSpacing.allLG,
      child: ListTile(
        leading: Icon(
          db.managed ? Icons.lock_outline : Icons.storage_outlined,
          color: db.managed
              ? theme.colorScheme.tertiary
              : theme.colorScheme.primary,
        ),
        title: Text('${db.displayName}  ·  ${db.fileName}'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: AppSpacing.xs),
            Text(
              db.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '版本 ${db.version} · ${notifier.formatSize(db.size)}'
              '${db.totalRows != null ? ' · ${db.totalRows} 行' : ''}'
              '${db.managed ? ' · 受管' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// 库详情页：展示表列表。
class _DbTablesPage extends ConsumerWidget {
  const _DbTablesPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(databaseManageProvider);
    final notifier = ref.read(databaseManageProvider.notifier);
    final db = state.selectedDb;

    return Scaffold(
      appBar: AppBar(title: Text('${db?.displayName ?? '数据库'} · 表')),
      body: state.tablesLoading
          ? const LoadingState(message: '正在读取表…')
          : state.tables.isEmpty
              ? const Center(child: Text('该数据库没有可浏览的表'))
              : ListView(
                  children: [
                    for (final table in state.tables)
                      ListTile(
                        leading: Icon(
                          table.readonly
                              ? Icons.lock_outline
                              : Icons.table_rows_outlined,
                          color: table.readonly
                              ? Theme.of(context).colorScheme.tertiary
                              : Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(table.displayName != null
                            ? '${table.displayName}  ·  ${table.name}'
                            : table.name),
                        subtitle: Text(
                          '${table.count} 行${table.readonly ? ' · 受 App 管理，只读' : ' · 可删除记录'}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          notifier.loadRows(table.name);
                          Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => const _DbRowsPage(),
                          ));
                        },
                      ),
                  ],
                ),
    );
  }
}

/// 行浏览页：分页展示表数据，支持行级删除。
class _DbRowsPage extends ConsumerWidget {
  const _DbRowsPage();

  int _totalPages(DatabaseManageState state) {
    final total = state.tableTotal;
    if (total <= 0) return 1;
    return (total / state.pageSize).ceil();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(databaseManageProvider);
    final notifier = ref.read(databaseManageProvider.notifier);
    final totalPages = _totalPages(state);
    final canPrev = state.page > 0;
    final canNext = state.page < totalPages - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text('${state.selectedDb?.displayName ?? ''} · ${state.browsingTable}'),
        actions: [
          if (state.rowsLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: AppLoading(size: AppLoadingSize.small),
            )
          else
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: canPrev ? notifier.prevPage : null,
                ),
                Center(
                  child: Text(
                    '${state.page + 1} / $totalPages 页',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: canNext ? notifier.nextPage : null,
                ),
              ],
            ),
        ],
      ),
      body: state.rowsLoading && state.rows.isEmpty
          ? const LoadingState(message: '正在读取数据…')
          : state.columns.isEmpty || state.rows.isEmpty
              ? const Center(child: Text('该表暂无数据'))
              : Column(
                  children: [
                    // 操作提示
                    Padding(
                      padding: AppSpacing.onlyVerticalSM,
                      child: Text(
                        '左右滑动查看字段 · 点按行选中，选中后可查看详情 / 删除',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: _DbTableBody(columns: state.columns, rows: state.rows),
                    ),
                  ],
                ),
      // 底部固定操作栏：删除入口不随横向滚动移动，字段再多也始终可见
      bottomNavigationBar: _DbBottomBar(
        canDelete: state.selectedRowIndex >= 0 &&
            state.selectedRowIndex < state.rows.length,
      ),
    );
  }
}

/// 表头 + 行（横向滚动）。行内按选中态细粒度重建（Consumer 行）。
class _DbTableBody extends ConsumerWidget {
  const _DbTableBody({required this.columns, required this.rows});

  final List<String> columns;
  final List<Map<String, Object?>> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: columns.length * 140.0,
        child: Column(
          children: [
            // 表头
            Container(
              color: theme.colorScheme.secondaryContainer,
              padding: AppSpacing.allSM,
              child: Row(
                children: [
                  for (final col in columns)
                    SizedBox(
                      width: 140,
                      child: Text(
                        col,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            // 数据行
            Expanded(
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  return _DbRow(
                    index: index,
                    columns: columns,
                    row: rows[index],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单行（自身 watch selectedRowIndex，仅选中变化时重建该行）。
class _DbRow extends ConsumerWidget {
  const _DbRow({
    required this.index,
    required this.columns,
    required this.row,
  });

  final int index;
  final List<String> columns;
  final Map<String, Object?> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selected = ref.watch(
      databaseManageProvider.select((s) => s.selectedRowIndex == index),
    );
    final notifier = ref.read(databaseManageProvider.notifier);

    return InkWell(
      onTap: () => notifier.selectRow(index),
      child: Container(
        color: selected
            ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.5)
            : null,
        padding: AppSpacing.allSM,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            for (final col in columns)
              SizedBox(
                width: 140,
                child: Text(
                  _valueToString(row[col]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 底部固定操作栏（详情/删除）。
class _DbBottomBar extends ConsumerWidget {
  const _DbBottomBar({required this.canDelete});

  final bool canDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(databaseManageProvider);
    final notifier = ref.read(databaseManageProvider.notifier);
    if (state.rows.isEmpty) return const SizedBox.shrink();

    final idx = state.selectedRowIndex;
    final hasSelection = canDelete;
    final row = hasSelection ? state.rows[idx] : null;

    return SafeArea(
      child: Container(
        padding: AppSpacing.onlyHorizontalLG,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                hasSelection ? '已选中第 ${idx + 1} 行' : '点按行以选中',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (hasSelection) ...[
              TextButton.icon(
                onPressed: () => _showRowDetail(context, ref, row!),
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('详情'),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
                backgroundColor:
                    Theme.of(context).colorScheme.errorContainer,
              ),
              onPressed: hasSelection
                  ? () async {
                      final ok = await notifier.deleteRow(
                        state.browsingTable,
                        row!,
                      );
                      if (ok) {
                        AppDialogs.showSuccess('已删除该记录');
                        await notifier.afterDelete(state.browsingTable);
                      }
                    }
                  : null,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除'),
            ),
          ],
        ),
      ),
    );
  }

  /// 弹出完整行内容（固定高度可滚动，内含删除入口）。
  void _showRowDetail(
    BuildContext context,
    WidgetRef ref,
    Map<String, Object?> row,
  ) {
    final theme = Theme.of(context);
    final notifier = ref.read(databaseManageProvider.notifier);
    final maxHeight = MediaQuery.of(context).size.height * 0.55;
    AppDialogs.showDialog(
      title: '记录详情',
      confirmText: '关闭',
      content: SizedBox(
        height: maxHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 字段列表（固定区域内滚动，避免字段过多撑高弹窗）
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in row.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 110,
                              child: Text(
                                entry.key,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              child:
                                  SelectableText(_valueToString(entry.value)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            // 删除入口（不依赖横向滚动，始终可见）
            Builder(
              builder: (dialogContext) => TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                icon: const Icon(Icons.delete_outline, size: 20),
                label: const Text('删除此记录'),
                onPressed: row['_rowid_'] == null
                    ? null
                    : () async {
                        final ok = await notifier.deleteRow(
                          ref.read(databaseManageProvider).browsingTable,
                          row,
                        );
                        if (ok) {
                          AppDialogs.showSuccess('已删除该记录');
                          await notifier.afterDelete(
                            ref.read(databaseManageProvider).browsingTable,
                          );
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                        }
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _valueToString(Object? v) {
  if (v == null) return 'null';
  return v.toString();
}
