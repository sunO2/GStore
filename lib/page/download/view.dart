import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/page/download/logic.dart';

class DownloadManager extends StatelessWidget {
  const DownloadManager({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(DownloadManagerLogic());
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
          // 清理已完成按钮
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多操作',
            onSelected: (value) {
              switch (value) {
                case 'clear_completed':
                  logic.clearCompleted();
                  break;
                case 'clear_all':
                  logic.clearAll();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'clear_completed',
                child: Row(
                  children: [
                    Icon(Icons.cleaning_services),
                    SizedBox(width: AppSpacing.md),
                    Text('清理已完成'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear_all',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep, color: AppColors.error),
                    SizedBox(width: AppSpacing.md),
                    Text('清空全部', style: TextStyle(color: AppColors.error)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 筛选标签
          _buildFilterChips(context, logic),
          const SizedBox(height: AppSpacing.md),

          // 下载列表
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: StreamBuilder<List<List<DownloadStatus>>>(
                stream: logic.controller.stream,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.active) {
                    return const Center(child: AppLoading(size: AppLoadingSize.medium));
                  }

                  final downloadList = snap.data;

                  if (downloadList == null || downloadList.isEmpty) {
                    return _buildEmptyState(context);
                  }

                  return ListView.builder(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    itemCount: downloadList.length,
                    itemBuilder: (context, index) {
                      final item = downloadList[index];
                      return FutureBuilder<AppInfo?>(
                        future: logic.getAppInfo(item[0].appId),
                        builder: (context, snap) {
                          final info = snap.data;
                          return _buildDownloadGroup(
                            context,
                            logic,
                            item,
                            info,
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建筛选标签
  Widget _buildFilterChips(BuildContext context, DownloadManagerLogic logic) {
    return Obx(() {
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
        ),
        height: AppSpacing.xl * 2,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: DownloadFilter.values.map((filter) {
            final isSelected = logic.currentFilter.value == filter;
            return Padding(
              padding: EdgeInsets.only(right: AppSpacing.md),
              child: FilterChip(
                label: Text(_getFilterLabel(filter)),
                selected: isSelected,
                onSelected: (_) => logic.setFilter(filter),
                selectedColor: Theme.of(context).colorScheme.primaryContainer,
                checkmarkColor: Theme.of(context).colorScheme.primary,
                side: BorderSide(
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline,
                ),
              ),
            );
          }).toList(),
        ),
      );
    });
  }

  /// 构建空状态
  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.download_outlined,
            size: AppTypography.iconHuge * 2,
            color: Theme.of(context).colorScheme.primary.withAlpha(AppColors.withAlphaLower),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '暂无下载记录',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '下载的应用会显示在这里',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建下载分组
  Widget _buildDownloadGroup(
    BuildContext context,
    DownloadManagerLogic logic,
    List<DownloadStatus> items,
    AppInfo? info,
  ) {
    final appName = info?.name ?? items[0].appName;

    return Container(
      margin: EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context)
              .colorScheme
              .primary
              .withAlpha(AppColors.withAlphaLow),
        ),
        borderRadius: AppRadius.allMD,
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent,
          splashColor: Colors.transparent,
        ),
        child: ExpansionTile(
          enableFeedback: false,
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.allMD,
          ),
          collapsedShape: RoundedRectangleBorder(
            borderRadius: AppRadius.allMD,
          ),
          leading: _buildAppIcon(context, info),
          title: Text(
            appName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.titleMedium.copyWith(
              color: AppColors.textPrimary,
            ),
          ),
          subtitle: Text(
            items[0].version,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          childrenPadding: EdgeInsets.all(AppSpacing.lg),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: items.map((downStatus) {
            return _buildDownloadItem(context, logic, downStatus);
          }).toList(),
        ),
      ),
    );
  }

  /// 构建应用图标
  Widget _buildAppIcon(BuildContext context, AppInfo? info) {
    return SizedBox(
      width: AppTypography.iconLG + AppSpacing.sm,
      height: AppTypography.iconLG + AppSpacing.sm,
      child: ClipRRect(
        borderRadius: AppRadius.allSM,
        child: CachedNetworkImage(
          imageUrl: info?.icon ?? '',
          errorWidget: (context, url, error) => Container(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Icon(
              Icons.document_scanner,
              size: AppTypography.iconMD,
            ),
          ),
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  /// 构建下载项
  Widget _buildDownloadItem(
    BuildContext context,
    DownloadManagerLogic logic,
    DownloadStatus downStatus,
  ) {
    return Dismissible(
      key: Key(downStatus.id?.toString() ?? '${downStatus.appId}-${downStatus.version}-${downStatus.fileName}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) {
        logic.deleteDownload(downStatus);
      },
      background: Container(
        margin: EdgeInsets.only(top: AppSpacing.sm),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.error,
          borderRadius: AppRadius.allMD,
        ),
        alignment: Alignment.centerRight,
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: const Icon(
          Icons.delete,
          color: Colors.white,
        ),
      ),
      child: Container(
        margin: EdgeInsets.only(top: AppSpacing.sm),
        padding: EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          borderRadius: AppRadius.allMD,
          border: Border.all(
            color: Theme.of(context)
                .colorScheme
                .primary
                .withAlpha(AppColors.withAlphaLow),
          ),
          color: Theme.of(context).colorScheme.surface,
        ),
        child: StreamBuilder<DownloadStatus>(
          stream: downStatus.observer,
          builder: (context, snap) {
            final data = snap.data ?? downStatus;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 文件名和状态
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        downStatus.fileName,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: AppTypography.weightMedium,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _buildStatusChip(context, data.status),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),

                // 进度条或文件大小
                if (data.status == DownloadStatus.DOWNLOAD_LOADING ||
                    (data.total > 0 && data.count < data.total))
                  _buildProgressBar(context, data)
                else if (data.total > 0)
                  Text(
                    '文件大小: ${_formatFileSize(data.total)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),

                const SizedBox(height: AppSpacing.sm),

                // 操作按钮
                _buildActionButtons(context, logic, data),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 构建状态标签
  Widget _buildStatusChip(BuildContext context, int status) {
    String label;
    Color? color;
    IconData? icon;

    switch (status) {
      case DownloadStatus.DOWNLOAD_LOADING:
        label = '下载中';
        color = Theme.of(context).colorScheme.primary;
        icon = Icons.downloading;
        break;
      case DownloadStatus.DOWNLOAD_SUCCESS:
        label = '已完成';
        color = Colors.green;
        icon = Icons.check_circle;
        break;
      case DownloadStatus.DOWNLOAD_ERROR:
        label = '失败';
        color = Colors.red;
        icon = Icons.error;
        break;
      case DownloadStatus.DOWNLOAD_READY:
      default:
        label = '等待中';
        color = Colors.orange;
        icon = Icons.schedule;
        break;
    }

    return Chip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: AppTypography.iconSM),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(label),
        ],
      ),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      labelStyle: TextStyle(
        fontSize: AppTypography.sizeXS,
        color: color,
        fontWeight: AppTypography.weightMedium,
      ),
      side: BorderSide(color: color),
    );
  }

  /// 构建进度条
  Widget _buildProgressBar(BuildContext context, DownloadStatus data) {
    final progress = data.total > 0 ? data.count / data.total : 0.0;
    final percent = (progress * 100).toInt();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: progress,
          minHeight: AppSpacing.sm,
          borderRadius: AppRadius.allSM,
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${_formatFileSize(data.count)} / ${_formatFileSize(data.total)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              '$percent%',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: AppTypography.weightMedium,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 构建操作按钮
  Widget _buildActionButtons(
    BuildContext context,
    DownloadManagerLogic logic,
    DownloadStatus data,
  ) {
    return Wrap(
      spacing: AppSpacing.sm,
      children: [
        // 安装按钮
        if (data.status == DownloadStatus.DOWNLOAD_SUCCESS &&
            data.fileName.endsWith('.apk'))
          IconButton(
            tooltip: '安装',
            icon: const Icon(Icons.install_mobile),
            iconSize: AppTypography.iconMD,
            onPressed: () => logic.installApp(data),
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            ),
          ),

        // 开始/继续按钮
        if (data.status == DownloadStatus.DOWNLOAD_READY ||
            data.status == DownloadStatus.DOWNLOAD_ERROR)
          IconButton(
            tooltip: '开始下载',
            icon: const Icon(Icons.play_arrow),
            iconSize: AppTypography.iconMD,
            onPressed: () => logic.resumeDownload(data),
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            ),
          ),

        // 暂停按钮
        if (data.status == DownloadStatus.DOWNLOAD_LOADING)
          IconButton(
            tooltip: '暂停下载',
            icon: const Icon(Icons.pause),
            iconSize: AppTypography.iconMD,
            onPressed: () => logic.pauseDownload(data),
            style: IconButton.styleFrom(
              backgroundColor: Colors.orange.withAlpha(AppColors.withAlphaLower),
            ),
          ),

        // 重新下载按钮
        IconButton(
          tooltip: '重新下载',
          icon: const Icon(Icons.refresh),
          iconSize: AppTypography.iconMD,
          onPressed: () => logic.retryDownload(data),
          style: IconButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
          ),
        ),

        // 删除按钮
        IconButton(
          tooltip: '删除',
          icon: const Icon(Icons.delete_outline),
          iconSize: AppTypography.iconMD,
          onPressed: () => logic.deleteDownload(data),
          style: IconButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        ),
      ],
    );
  }

  /// 获取筛选标签文本
  String _getFilterLabel(DownloadFilter filter) {
    switch (filter) {
      case DownloadFilter.all:
        return '全部';
      case DownloadFilter.downloading:
        return '下载中';
      case DownloadFilter.completed:
        return '已完成';
      case DownloadFilter.failed:
        return '失败';
    }
  }

  /// 格式化文件大小
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
