/// F-Droid 仓库管理页面 UI
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/page/fdroid_repo/logic.dart';
import 'package:gstore/page/fdroid_repo/state.dart';

/// F-Droid 仓库管理页面
class FdroidRepoPage extends ConsumerStatefulWidget {
  const FdroidRepoPage({super.key});

  @override
  ConsumerState<FdroidRepoPage> createState() => _FdroidRepoPageState();
}

class _FdroidRepoPageState extends ConsumerState<FdroidRepoPage> {
  /// 页面控制器与状态（build 时从 ref 取，供各构建子方法使用）
  FdroidRepoNotifier get notifier => ref.read(fdroidRepoProvider.notifier);
  FdroidRepoState get state => ref.watch(fdroidRepoProvider);

  @override
  void initState() {
    super.initState();
    // 首次挂载初始化（等价原 GetX onInit；幂等，重复调用自动跳过）
    Future.microtask(
      () => ref.read(fdroidRepoProvider.notifier).start(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('F-Droid 仓库管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _showSearchDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: state.isLoading ? null : notifier.checkAndUpdate,
          ),
        ],
      ),
      body: state.isLoading && state.loadingProgress < 100
          ? _buildLoadingView(state)
          : _buildContentView(context),
    );
  }

  /// 构建加载视图
  Widget _buildLoadingView(FdroidRepoState state) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const AppLoading(size: AppLoadingSize.medium),
          SizedBox(height: AppSpacing.lg),
          Text('加载中... ${state.loadingProgress.toInt()}%'),
        ],
      ),
    );
  }

  /// 构建内容视图
  Widget _buildContentView(BuildContext context) {
    final state = this.state;
    return RefreshIndicator(
      onRefresh: notifier.checkAndUpdate,
      child: ListView(
        padding: AppSpacing.allLG,
        children: [
          // 统计信息卡片
          _buildStatisticsCard(context, state),

          SizedBox(height: AppSpacing.lg),

          // 操作按钮
          _buildActionButtons(context, state),

          SizedBox(height: AppSpacing.lg),

          // 源列表
          _buildSourcesList(context, state),

          SizedBox(height: AppSpacing.lg),

          // 搜索结果
          if (state.searchResults.isNotEmpty)
            _buildSearchResults(context, state),
        ],
      ),
    );
  }

  /// 构建数据统计卡片：**按源**列出（多源下"合计"会掩盖哪个源没同步/没数据）
  ///
  /// 每源同时给出该源**自己的**最近一次同步结果（时间/增量还是全量/实际地址）——
  /// 多源下不存在"整体上次同步"，单开一个区域只会显示成"最后一个完成的源"。
  /// 颜色一律取自主题（`colorScheme`），不写死浅色，深色模式下同样正确。
  Widget _buildStatisticsCard(BuildContext context, FdroidRepoState state) {
    final theme = Theme.of(context);
    final stats = state.statistics;

    return Card(
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('数据统计', style: theme.textTheme.titleMedium),
                if (stats.isNotEmpty)
                  Text(
                    '${state.syncedSourcesCount}/${stats.length} 个源有数据',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            SizedBox(height: AppSpacing.sm),
            if (stats.isEmpty)
              Text('暂无源', style: theme.textTheme.bodySmall)
            else
              for (final stat in stats) _buildStatRow(theme, stat),
            if (stats.length > 1) ...[
              const Divider(height: 1),
              Padding(
                padding: AppSpacing.onlyVerticalSM,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('合计', style: theme.textTheme.titleSmall),
                    Text('${state.totalAppCount} 个应用',
                        style: theme.textTheme.titleSmall),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 单个源的统计行：名称 / 地址 / 应用数 + 该源自己的上次同步
  ///
  /// 不套 ListTile：地址与同步详情可能较长，ListTile 的 subtitle 最多 3 行会截断，
  /// 这里用 Column 让它自然换行（长文本宁可换行也不省略）。
  Widget _buildStatRow(ThemeData theme, FdroidSourceStat stat) {
    final sync = stat.lastSync;
    final detail = <String>[
      [
        stat.source.repoUrl,
        if (!stat.enabled) '未启用',
      ].join(' · '),
      if (sync != null)
        '上次同步 ${_formatSyncTime(sync.at)} · ${sync.incremental ? '增量' : '全量'}'
            '${sync.totalApps != null ? ' · ${sync.totalApps} 个应用' : ''}'
            '${sync.elapsedMs != null ? ' · ${sync.elapsedMs}ms' : ''}'
            '${sync.resolvedUrl != null && sync.resolvedUrl!.isNotEmpty ? '\n实际地址 ${sync.resolvedUrl}' : ''}'
      else
        '本次会话未同步',
    ].join('\n');

    return Padding(
      padding: AppSpacing.onlyVerticalSM,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(stat.source.name, style: theme.textTheme.bodyMedium),
                SizedBox(height: AppSpacing.xs),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          SizedBox(width: AppSpacing.sm),
          Text(
            '${stat.appCount} 个应用',
            style: theme.textTheme.titleMedium?.copyWith(
              color: stat.appCount > 0 ? null : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 同步时间：今天只显示时分，跨天补上日期
  String _formatSyncTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final hm = '${two(t.hour)}:${two(t.minute)}';
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? hm : '${two(t.month)}-${two(t.day)} $hm';
  }

  /// 构建操作按钮
  Widget _buildActionButtons(BuildContext context, FdroidRepoState state) {
    return Card(
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.download),
              label: const Text('加载/重新加载数据'),
              onPressed: state.isLoading ? null : notifier.loadAllSources,
            ),
            SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: const Text('清空数据'),
              onPressed: state.isLoading ? null : notifier.clearData,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建源列表
  Widget _buildSourcesList(BuildContext context, FdroidRepoState state) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: AppSpacing.allLG,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '可用源',
                  style: TextStyle(fontSize: AppTypography.sizeLG, fontWeight: AppTypography.weightBold),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => notifier.addSource(context),
                  tooltip: '添加自定义源',
                ),
              ],
            ),
          ),
          Divider(height: 1),
          ...state.sources.map((source) {
            // 副标题展示地址 + （有则）镜像数/已固定指纹：第三方源的身份与可用性一眼可见
            final meta = <String>[
              source.repoUrl,
              if (source.mirrors.isNotEmpty) '镜像 ${source.mirrors.length}',
              if (source.fingerprint != null && source.fingerprint!.isNotEmpty)
                '指纹已固定 ${_shortFingerprint(source.fingerprint!)}',
            ].join(' · ');
            return ListTile(
              title: Text(source.name),
              subtitle: Text(meta),
              isThreeLine: source.fingerprint != null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 多源：勾选 = 是否启用（可同时启用多个），不再单选
                  Checkbox(
                    value: source.enabled,
                    onChanged: (v) => notifier.setSourceEnabled(source, v ?? false),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    onSelected: (v) {
                      if (v == 'mirrors') {
                        notifier.configureMirrors(context, source);
                      } else if (v == 'edit') {
                        notifier.editSource(context, source);
                      } else if (v == 'delete') {
                        notifier.deleteSource(context, source);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'mirrors', child: Text('配置镜像')),
                      PopupMenuItem(value: 'edit', child: Text('编辑源')),
                      PopupMenuItem(value: 'delete', child: Text('删除源')),
                    ],
                  ),
                ],
              ),
              // 多源：不再有"当前源"概念，条目点击不做切换（操作走右侧菜单）
            );
          }).toList(),
        ],
      ),
    );
  }

  /// 构建搜索结果
  Widget _buildSearchResults(BuildContext context, FdroidRepoState state) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: AppSpacing.allLG,
            child: Text(
              '搜索结果 (${state.searchResults.length})',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          if (notifier.availableCategories.isNotEmpty ||
              notifier.onlyCompatible ||
              notifier.hideAntiFeature ||
              notifier.categoryFilter != null)
            Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
              child: Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  FilterChip(
                    label: const Text('仅兼容本机'),
                    selected: notifier.onlyCompatible,
                    onSelected: notifier.setOnlyCompatible,
                  ),
                  FilterChip(
                    label: const Text('隐藏含抗特性'),
                    selected: notifier.hideAntiFeature,
                    onSelected: notifier.setHideAntiFeature,
                  ),
                  for (final c in notifier.availableCategories)
                    FilterChip(
                      label: Text(c),
                      selected: notifier.categoryFilter == c,
                      onSelected: (on) =>
                          notifier.setCategoryFilter(on ? c : null),
                    ),
                ],
              ),
            ),
          Divider(height: 1),
          ...state.searchResults.map((app) {
            return ListTile(
              title: Text(app.name),
              subtitle: Text(app.packageName),
              trailing: Text(app.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => notifier.openAppDetail(app),
            );
          }).toList(),
        ],
      ),
    );
  }

  /// 显示搜索弹层（统一底部 sheet 风格）
  void _showSearchDialog(BuildContext context) {
    AppSheet.show<void>(
      context: context,
      title: '搜索应用',
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: TextField(
        controller: notifier.searchController,
        decoration: const InputDecoration(
          hintText: '输入应用名称或包名',
          prefixIcon: Icon(Icons.search),
        ),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            notifier.searchApps(notifier.searchController.text);
            Navigator.of(context).pop();
          },
          child: const Text('搜索'),
        ),
      ],
    );
  }

  /// 指纹短展示（完整值在「添加源」对话框里核对；此处只做身份提示）
  String _shortFingerprint(String fp) {
    final clean = fp.replaceAll(':', '').toUpperCase();
    if (clean.length <= 16) return clean;
    return '${clean.substring(0, 8)}…${clean.substring(clean.length - 8)}';
  }
}