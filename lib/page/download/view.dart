import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/compent/entrance_list.dart';
import 'package:gstore/compent/pressable_scale.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/page/download/download_status_utils.dart';
import 'package:gstore/page/download/logic.dart';

class DownloadManager extends StatefulWidget {
  const DownloadManager({super.key});

  @override
  State<DownloadManager> createState() => _DownloadManagerState();
}

class _DownloadManagerState extends State<DownloadManager> {
  /// 多文件组的展开状态（key: appId_version，与 logic 分组 key 一致）
  final Set<String> _expandedKeys = {};

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(DownloadManagerLogic());
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
          // 更多操作
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
              PopupMenuItem(
                value: 'clear_all',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_sweep,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Text(
                      '清空全部',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 筛选标签（筛选语义见 download_status_utils.dart 的 matchesFilter）
          _buildFilterChips(context, logic),
          const SizedBox(height: AppSpacing.md),

          // 下载列表
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Obx(() {
                final downloadList = logic.downloadGroups.value;

                if (downloadList.isEmpty) {
                  return _buildEmptyState(context);
                }

                return EntranceList(
                  key: ValueKey(downloadList.length),
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  itemCount: downloadList.length,
                  itemBuilder: (context, index) {
                    final item = downloadList[index];
                    final info = logic.getCachedAppInfo(item[0].appId);
                    return _buildDownloadGroup(
                      context,
                      logic,
                      item,
                      info,
                    );
                  },
                );
              }),
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
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
        ),
        height: AppSpacing.xl * 2,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: DownloadFilter.values.map((filter) {
            final isSelected = logic.currentFilter.value == filter;
            return Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
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
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
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

  /// 构建下载分组卡片
  Widget _buildDownloadGroup(
    BuildContext context,
    DownloadManagerLogic logic,
    List<DownloadStatus> items,
    AppInfo? info,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final isMulti = items.length > 1;
    final groupKey = '${items[0].appId}_${items[0].version}';
    final isExpanded = _expandedKeys.contains(groupKey);
    // 组内进行中的文件（LOADING，或 READY 且已下载部分字节）
    final activeItem = _activeDownloadItem(items);

    // 外层 PressableScale 仅做按压反馈；多文件组展开/收起由内部 header
    // GestureDetector 承接，单文件组无点击动作
    return PressableScale(
      child: AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: EdgeInsets.zero,
      borderRadius: AppRadius.allMD,
      border: Border.all(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 卡片首行：图标 + 应用名 + 版本 + 聚合状态徽标
          _buildGroupHeader(
            context,
            logic,
            items,
            info,
            isMulti: isMulti,
            groupKey: groupKey,
            isExpanded: isExpanded,
          ),

          // 进行中实时进度条（多文件组收起时也直接显示在卡片上）
          if (isMulti && !isExpanded && activeItem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: StreamBuilder<DownloadStatus>(
                stream: activeItem.observer,
                builder: (context, snap) {
                  return _buildProgressBar(context, snap.data ?? activeItem);
                },
              ),
            ),

          // 文件行：多文件组点击卡片头展开显示；单文件组直接显示
          if (!isMulti || isExpanded)
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                  indent: AppSpacing.lg,
                  endIndent: AppSpacing.lg,
                ),
              _buildDownloadItem(context, logic, items[i]),
            ],
        ],
      ),
      ),
    );
  }

  /// 卡片首行：应用图标 + 应用名 + 版本 + 状态徽标（聚合组内主文件状态）
  Widget _buildGroupHeader(
    BuildContext context,
    DownloadManagerLogic logic,
    List<DownloadStatus> items,
    AppInfo? info, {
    required bool isMulti,
    required String groupKey,
    required bool isExpanded,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final appName = info?.name ?? items[0].appName;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        isMulti ? AppSpacing.sm : AppSpacing.md,
      ),
      child: Row(
        children: [
          _buildAppIcon(context, info),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onSurface,
                      ),
                ),
                Text(
                  items[0].version,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // 聚合组内主文件状态（实时监听）
          StreamBuilder<DownloadStatus>(
            stream: items[0].observer,
            builder: (context, snap) {
              return _buildStatusBadge(context, snap.data ?? items[0]);
            },
          ),
          // 多文件组：展开指示
          if (isMulti) ...[
            const SizedBox(width: AppSpacing.xs),
            Icon(
              isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: AppTypography.iconMD,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );

    // 单文件组无需展开，直接显示
    if (!isMulti) return header;

    // 多文件组：点击卡片头展开/收起文件行
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() {
          if (!_expandedKeys.remove(groupKey)) {
            _expandedKeys.add(groupKey);
          }
        });
      },
      child: header,
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
          placeholder: (context, url) =>
              const AppLoading(size: AppLoadingSize.small),
          errorWidget: (context, url, error) => Container(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: const Icon(
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
      key: Key(downStatus.id?.toString() ??
          '${downStatus.appId}-${downStatus.version}-${downStatus.fileName}'),
      direction: DismissDirection.endToStart,
      // 删除前先确认
      confirmDismiss: (_) => _confirmDelete(context, downStatus),
      onDismissed: (_) {
        logic.deleteDownload(downStatus);
      },
      background: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.error,
          borderRadius: AppRadius.allSM,
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.delete,
              size: AppTypography.iconSM,
              color: Theme.of(context).colorScheme.onError,
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              '删除',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onError,
                    fontWeight: AppTypography.weightMedium,
                  ),
            ),
          ],
        ),
      ),
      child: StreamBuilder<DownloadStatus>(
        stream: downStatus.observer,
        builder: (context, snap) {
          final data = snap.data ?? downStatus;
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 文件名（完整信息见 info 弹窗；状态徽标保留在卡片头，避免重复）
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        data.fileName,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: AppTypography.weightMedium,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
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

                // 主操作按钮 + 辅助操作
                Row(
                  children: [
                    _buildPrimaryAction(context, logic, data),
                    const Spacer(),
                    IconButton(
                      tooltip: '重新下载',
                      icon: const Icon(
                        Icons.refresh,
                        size: AppTypography.iconSM,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => logic.retryDownload(data),
                    ),
                    IconButton(
                      tooltip: '删除',
                      icon: const Icon(
                        Icons.delete_outline,
                        size: AppTypography.iconSM,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        if (await _confirmDelete(context, data)) {
                          logic.deleteDownload(data);
                        }
                      },
                    ),
                    IconButton(
                      tooltip: '下载信息',
                      icon: const Icon(
                        Icons.info_outline,
                        size: AppTypography.iconSM,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _showDownloadInfo(context, data),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 主操作按钮（由 download_status_utils.dart 的 primaryActionFor 决定）
  Widget _buildPrimaryAction(
    BuildContext context,
    DownloadManagerLogic logic,
    DownloadStatus item,
  ) {
    final action = primaryActionFor(item);
    if (action == null) return const SizedBox.shrink();

    final (label, icon) = switch (action) {
      DownloadAction.pause => ('暂停', Icons.pause),
      DownloadAction.resume => ('继续', Icons.play_arrow),
      DownloadAction.retry => ('重试', Icons.refresh),
      DownloadAction.install => ('安装', Icons.install_mobile),
    };
    final onPressed = switch (action) {
      DownloadAction.pause => () => logic.pauseDownload(item),
      DownloadAction.resume => () => logic.resumeDownload(item),
      DownloadAction.retry => () => logic.retryDownload(item),
      DownloadAction.install => () => logic.installApp(item),
    };

    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon, size: AppTypography.iconSM),
      label: Text(label),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: AppTypography.weightMedium,
            ),
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.allSM,
        ),
      ),
    );
  }

  /// 删除确认（危险操作，红色确认按钮）
  Future<bool> _confirmDelete(BuildContext context, DownloadStatus item) async {
    final confirmed = await AppDialogs.showDialog(
      title: '删除下载',
      content: '确定要删除「${item.fileName}」的下载记录吗？此操作不可恢复。',
      confirmText: '删除',
      cancelText: '取消',
      isDangerous: true,
    );
    return confirmed == true;
  }

  /// 下载信息弹窗（文件名/链接/渠道等完整信息，不受列表截断影响）
  Future<void> _showDownloadInfo(
    BuildContext context,
    DownloadStatus item,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    final channel = inferChannelLabel(item.downloadUrl);

    Widget infoRow(String label, String value) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: AppSpacing.xxxl * 2,
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }

    await AppDialogs.showBottomSheet(
      title: '下载信息',
      // children 无水平 padding（标题才带），内容整体补左右边距避免贴边
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              infoRow('文件名', item.fileName),
              infoRow('应用', '${item.appName}（${item.version}）'),
              infoRow('应用标识', item.appId),
              if (item.total > 0) infoRow('文件大小', _formatFileSize(item.total)),
              infoRow('保存路径', item.savePath),
              infoRow('创建时间', _formatCreateTime(item.createTime)),
              if (channel != null) infoRow('来源渠道', channel),
              // 下载链接（可复制）
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: AppSpacing.xxxl * 2,
                      child: Text(
                        '下载链接',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        item.downloadUrl,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: '复制链接',
                      icon: Icon(
                        Icons.copy,
                        size: AppTypography.iconSM,
                        color: scheme.primary,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        await Clipboard.setData(
                            ClipboardData(text: item.downloadUrl));
                        AppDialogs.showSuccess('已复制下载链接');
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 创建时间格式化（毫秒时间戳 → yyyy-MM-dd HH:mm；0/未知显示"未知"）
  String _formatCreateTime(int millis) {
    if (millis <= 0) return '未知';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} '
        '${pad(dt.hour)}:${pad(dt.minute)}';
  }

  /// 构建状态标签（颜色全部取自主题）
  Widget _buildStatusBadge(BuildContext context, DownloadStatus item) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color, icon) = switch (statusKindOf(item)) {
      DownloadStatusKind.downloading => (
          '下载中',
          scheme.primary,
          Icons.downloading,
        ),
      DownloadStatusKind.completed => (
          '已完成',
          scheme.tertiary,
          Icons.check_circle,
        ),
      DownloadStatusKind.failed => ('失败', scheme.error, Icons.error),
      DownloadStatusKind.waiting => (
          '等待中',
          scheme.onSurfaceVariant,
          Icons.schedule,
        ),
    };

    return Chip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: AppTypography.iconSM),
          const SizedBox(width: AppSpacing.xs),
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
        // 进度条容器
        Container(
          height: AppSpacing.sm,
          decoration: const BoxDecoration(
            borderRadius: AppRadius.allSM,
          ),
          child: ClipRRect(
            borderRadius: AppRadius.allSM,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: AppSpacing.sm,
              // 轨道颜色（未填充部分）
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              // 进度颜色使用主题色
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
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

  /// 获取组内进行中的文件（LOADING 优先，其次 READY 且已下载部分字节）
  DownloadStatus? _activeDownloadItem(List<DownloadStatus> items) {
    for (final item in items) {
      if (item.status == DownloadStatus.DOWNLOAD_LOADING) return item;
    }
    for (final item in items) {
      if (item.status == DownloadStatus.DOWNLOAD_READY &&
          item.total > 0 &&
          item.count > 0 &&
          item.count < item.total) {
        return item;
      }
    }
    return null;
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
