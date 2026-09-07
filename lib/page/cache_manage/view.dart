import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/core.dart';

import 'download_clean_page.dart';
import 'logic.dart';
import 'state.dart';

/// 缓存管理页：分组展示各缓存占用，支持单项清理与一键清理。
class CacheManagePage extends ConsumerWidget {
  const CacheManagePage({super.key});

  /// 扩展 icon 映射（下载文件等）。
  static const _iconMap = <String, IconData>{
    'image': Icons.image_outlined,
    'article': Icons.article_outlined,
    'android': Icons.android,
    'database': Icons.storage_outlined,
    'memory': Icons.memory_outlined,
    'cleaning': Icons.cleaning_services_outlined,
    'download': Icons.download_done_outlined,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cacheManageProvider);
    final notifier = ref.read(cacheManageProvider.notifier);

    final hasCache = state.groups.isNotEmpty;
    final hasDownloads = state.downloads.isNotEmpty;
    final bothEmpty = !hasCache && !hasDownloads;
    // 首次加载（缓存与下载统计都未就绪）时展示 loading
    final initialLoading =
        state.loading && state.downloadsLoading && bothEmpty;
    if (initialLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('缓存管理')),
        body: const LoadingState(message: '正在统计…'),
      );
    }
    if (bothEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('缓存管理')),
        body: const Center(child: Text('暂无缓存与下载数据')),
      );
    }

    final clearing = state.clearing;
    return Scaffold(
      appBar: AppBar(title: const Text('缓存管理')),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            notifier.reload(),
            notifier.loadDownloads(),
          ]);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: AppSpacing.xl),
          children: [
            _buildSummaryCard(context, state, notifier),
            // 已下载入口始终可见（空目录也可进入查看）
            _buildDownloadEntry(context, state, notifier),
            for (final group in state.groups) ...[
              _buildGroupHeader(context, notifier, group),
              _buildGroupCard(context, notifier, group, clearing),
            ],
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }

  /// 已下载文件入口卡片（点击进入多选清理页）。
  Widget _buildDownloadEntry(
    BuildContext context,
    CacheManageState state,
    CacheManageNotifier notifier,
  ) {
    final theme = Theme.of(context);
    final count = state.downloads.length;
    return Card(
      margin: AppSpacing.allLG,
      child: ListTile(
        leading: Icon(Icons.download_done_outlined,
            color: theme.colorScheme.primary),
        title: const Text('已下载文件'),
        subtitle: Text(
          state.downloadsLoading && count == 0
              ? '正在统计…'
              : count == 0
                  ? '暂无已完成的下载文件'
                  : '$count 个文件 · ${notifier.formatSize(state.downloadTotalSize)}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          // 进入前确保数据最新
          notifier.loadDownloads();
          Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const DownloadCleanPage(),
          ));
        },
      ),
    );
  }

  Widget _buildSummaryCard(
    BuildContext context,
    CacheManageState state,
    CacheManageNotifier notifier,
  ) {
    final theme = Theme.of(context);
    // 总占用 = 缓存 + 已下载文件（合并展示，一键清理同时清两者）
    final cacheSize = state.totalSize;
    final downloadSize = state.downloadTotalSize;
    final combined = cacheSize + downloadSize;
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Row(
          children: [
            Icon(Icons.cleaning_services_outlined,
                color: theme.colorScheme.primary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('总占用', style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    notifier.formatSize(combined),
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '缓存 ${notifier.formatSize(cacheSize)}'
                    '${state.downloads.isNotEmpty ? ' · 已下载 ${state.downloads.length} 个文件 ${notifier.formatSize(downloadSize)}' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            AppButton(
              text: '一键清理',
              style: AppButtonStyle.danger,
              size: AppButtonSize.small,
              isDisabled: combined <= 0,
              isLoading: state.clearing == '_all',
              onPressed: () async {
                final ok = await notifier.clearAll();
                if (ok) {
                  AppDialogs.showSuccess('已清理全部缓存与下载文件');
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupHeader(
    BuildContext context,
    CacheManageNotifier notifier,
    CacheGroup group,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Row(
        children: [
          Text(
            group.title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: AppTypography.weightMedium,
            ),
          ),
          const Spacer(),
          Text(
            notifier.formatSize(group.totalSize),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildGroupCard(
    BuildContext context,
    CacheManageNotifier notifier,
    CacheGroup group,
    String clearing,
  ) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          for (var i = 0; i < group.items.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _buildCacheRow(context, notifier, group.items[i], clearing),
          ],
        ],
      ),
    );
  }

  Widget _buildCacheRow(
    BuildContext context,
    CacheManageNotifier notifier,
    CacheItem item,
    String clearing,
  ) {
    final theme = Theme.of(context);
    final isClearingThis = clearing == item.id;
    return ListTile(
      leading: Icon(_iconMap[item.icon] ?? Icons.folder_outlined,
          color: theme.colorScheme.primary),
      title: Text(item.name),
      subtitle: Text(
        '${notifier.formatSize(item.size)} · ${item.description}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: isClearingThis
          ? const AppLoading(size: AppLoadingSize.small)
          : TextButton(
              onPressed: () async {
                final ok = await notifier.clearOne(item.id);
                if (ok) {
                  AppDialogs.showSuccess('已清理 ${item.name}');
                } else {
                  AppDialogs.showError('清理 ${item.name} 失败');
                }
              },
              child: const Text('清理'),
            ),
    );
  }
}
