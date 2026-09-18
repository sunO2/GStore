import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/app_borders.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/compent/entrance_list.dart';
import 'package:gstore/compent/pressable_scale.dart';
import 'package:gstore/page/download/download_status_utils.dart';
import 'package:gstore/page/download/download_page_providers.dart';

class DownloadManager extends ConsumerStatefulWidget {
  const DownloadManager({super.key});

  @override
  ConsumerState<DownloadManager> createState() => _DownloadManagerState();
}

class _DownloadManagerState extends ConsumerState<DownloadManager> {
  /// 多文件组的展开状态（key: appId_version，与分组 key 一致）
  final Set<String> _expandedKeys = {};

  /// 页面控制器与状态（build 时从 ref 取，供各构建子方法使用）
  DownloadManagerNotifier get notifier =>
      ref.read(downloadManagerProvider.notifier);
  DownloadPageState get state => ref.watch(downloadManagerProvider);

  @override
  void initState() {
    super.initState();
    // 首次挂载加载任务（等价原 GetxController.onReady）
    Future.microtask(
      () => ref.read(downloadManagerProvider.notifier).load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
          // 批量操作（暂停全部/取消排队/重试失败）+ 清理：放入导航头部，
          // 避免 body 中条件显示整行导致布局跳动。
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多操作',
            onSelected: (value) {
              switch (value) {
                case 'pause_all':
                  notifier.pauseAll();
                  break;
                case 'cancel_queued':
                  notifier.cancelAllQueued();
                  break;
                case 'retry_failed':
                  notifier.retryAllFailed();
                  break;
                case 'clear_completed':
                  notifier.clearCompleted();
                  break;
                case 'clear_all':
                  notifier.clearAll();
                  break;
              }
            },
            itemBuilder: (context) => _buildMoreMenuItems(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // 筛选标签（筛选语义见 download_status_utils.dart 的 matchesFilter）
          _buildFilterChips(context),
          const SizedBox(height: AppSpacing.md),

          // 下载列表
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Builder(builder: (context) {
                final downloadList = state.groups;

                if (downloadList.isEmpty) {
                  return _buildEmptyState(context);
                }

                return EntranceList(
                  key: ValueKey(downloadList.length),
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  itemCount: downloadList.length,
                  itemBuilder: (context, index) {
                    final item = downloadList[index];
                    final info = state.cachedAppInfo(item[0].appId);
                    return _buildDownloadGroup(
                      context,
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
  Widget _buildFilterChips(BuildContext context) {
    final currentFilter = state.filter;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
      ),
      height: AppSpacing.xl * 2,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: DownloadFilter.values.map((filter) {
          final isSelected = currentFilter == filter;
          return Padding(
            padding: const EdgeInsets.only(right: AppSpacing.md),
            child: FilterChip(
              label: Text(_getFilterLabel(filter)),
              selected: isSelected,
              onSelected: (_) => notifier.setFilter(filter),
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
    List<DownloadTask> items,
    AppInfo? info,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final isMulti = items.length > 1;
    final groupKey = '${items[0].appId}_${items[0].version}';
    final isExpanded = _expandedKeys.contains(groupKey);
    // 组聚合状态：折叠态展示条数/总大小/聚合进度/失败数，不再用组内第一条代表整组
    final summary = summarizeGroup(items, state.missingFileIds);

    // 外层 PressableScale 仅做按压反馈；多文件组展开/收起由内部 header
    // GestureDetector 承接，单文件组无点击动作
    return PressableScale(
      child: AppCard(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        padding: EdgeInsets.zero,
        borderRadius: AppRadius.allMD,
        border: AppBorders.all(context, color: scheme.outlineVariant),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 卡片首行：图标 + 应用名 + 版本 + 聚合状态徽标 + 展开箭头
            _buildGroupHeader(
              context,
              items,
              info,
              summary: summary,
              isExpanded: isExpanded,
            ),

            // 折叠区：收起显示组聚合摘要、展开显示组内每条文件行，二者互斥。
            // 共用一个 AnimatedSize，让高度切换有过渡（原来直接替换，很生硬）。
            AnimatedSize(
              duration: AppAnimation.medium,
              curve: AppAnimation.curve,
              alignment: Alignment.topCenter,
              child: (!isMulti || isExpanded)
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 文件行：多文件组点击卡片头展开显示；单文件组直接显示
                        for (var i = 0; i < items.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 1,
                              thickness: 1,
                              color:
                                  scheme.outlineVariant.withValues(alpha: 0.4),
                              indent: AppSpacing.lg,
                              endIndent: AppSpacing.lg,
                            ),
                          _buildDownloadItem(context, items[i]),
                        ],
                      ],
                    )
                  : _buildGroupSummary(context, items, summary),
            ),
          ],
        ),
      ),
    );
  }

  /// 多文件组收起时的聚合摘要：进度条（可下载时）+ 状态/计数/大小一行。
  ///
  /// 按聚合状态分形态，保证收起时也能看出「几个文件、下到哪了、有没有失败」：
  /// - 下载中：聚合进度条 + 合计速度 + 已完成计数 + 剩余时间
  /// - 排队/等待：进度条（有已下字节时）+ 状态文案 + 已完成计数
  /// - 失败：已完成数 + 失败数（红）+「重试失败」快捷按钮
  /// - 全部完成：总大小 + 来源渠道 + 已删除提示 +「安装」快捷按钮
  Widget _buildGroupSummary(
    BuildContext context,
    List<DownloadTask> items,
    DownloadGroupSummary summary,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final groupKey = '${items[0].appId}_${items[0].version}';
    final failedItems = items
        .where((item) => item.status == DownloadStatusEnum.failed)
        .toList();
    // 组内唯一可安装的 apk：多个 apk 不猜，交给展开后逐个操作
    final installables = items
        .where((item) =>
            item.status == DownloadStatusEnum.completed &&
            item.fileName.endsWith('.apk') &&
            !isCompletedFileMissing(item, state.missingFileIds))
        .toList();

    final action = switch (summary.kind) {
      DownloadGroupKind.failed when failedItems.isNotEmpty => _actionButton(
          context,
          label: '重试失败',
          icon: Icons.refresh,
          onPressed: () => _retryFailedInGroup(failedItems),
        ),
      DownloadGroupKind.completed when installables.length == 1 =>
        _actionButton(
          context,
          label: '安装',
          icon: Icons.install_mobile,
          onPressed: () => notifier.installApp(installables.first),
        ),
      _ => null,
    };

    // (文案, 图标, 颜色覆盖)
    final metas = <(String, IconData?, Color?)>[];
    switch (summary.kind) {
      case DownloadGroupKind.downloading:
        if (summary.speedBps > 0) {
          metas.add(('合计 ${formatSpeed(summary.speedBps)}', Icons.speed, null));
        }
        metas.add(('${summary.completed}/${summary.total} 已完成', null, null));
        if ((summary.etaSec ?? 0) > 0) {
          metas.add((formatDuration(summary.etaSec!), Icons.schedule, null));
        }
      case DownloadGroupKind.queued:
        metas.add(('等待下载槽位', Icons.queue, null));
        metas.add(('${summary.completed}/${summary.total} 已完成', null, null));
      case DownloadGroupKind.waiting:
        metas.add(('已暂停', Icons.pause_circle_outline, null));
        metas.add(('${summary.completed}/${summary.total} 已完成', null, null));
      case DownloadGroupKind.failed:
        if (summary.completed > 0) {
          metas.add((
            '${summary.completed} 个已完成',
            Icons.check_circle_outline,
            null,
          ));
        }
        metas.add(('${summary.failed} 个失败', Icons.error, scheme.error));
      case DownloadGroupKind.completed:
        if (summary.totalBytes > 0) {
          metas.add((
            _formatFileSize(summary.totalBytes),
            Icons.folder_outlined,
            null,
          ));
        }
        final channel = inferChannelLabel(items.first.url);
        if (channel != null) {
          metas.add((channel, Icons.storefront_outlined, null));
        }
    }
    if (summary.deleted > 0) {
      metas.add((
        '${summary.deleted} 个文件已删除',
        Icons.delete_outline,
        scheme.error,
      ));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (summary.hasProgress)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: ClipRRect(
                borderRadius: AppRadius.allSM,
                child: LinearProgressIndicator(
                  value: summary.progress,
                  minHeight: AppSpacing.sm,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: scheme.primary,
                ),
              ),
            ),
          Row(
            children: [
              // 点摘要文字区也能展开（右侧按钮单独响应自己的点击）
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _toggleGroup(groupKey)),
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (var i = 0; i < metas.length; i++) ...[
                        if (i > 0)
                          Text(
                            '·',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.outline),
                          ),
                        _metaChip(
                          context,
                          metas[i].$1,
                          icon: metas[i].$2,
                          color: metas[i].$3,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (action != null) ...[
                const SizedBox(width: AppSpacing.sm),
                action,
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 折叠摘要里的元信息（小号图标 + 次要文字色）
  Widget _metaChip(
    BuildContext context,
    String text, {
    IconData? icon,
    Color? color,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: AppTypography.iconXS, color: tint),
          const SizedBox(width: AppSpacing.xs),
        ],
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tint),
        ),
      ],
    );
  }

  /// 重试组内全部失败任务
  Future<void> _retryFailedInGroup(List<DownloadTask> failed) async {
    for (final item in failed) {
      await notifier.retryDownload(item);
    }
  }

  /// 多文件组的展开/收起
  void _toggleGroup(String groupKey) {
    if (!_expandedKeys.remove(groupKey)) {
      _expandedKeys.add(groupKey);
    }
  }

  /// 卡片首行：应用图标 + 应用名 + 版本 + 状态徽标（多文件组用聚合状态）
  Widget _buildGroupHeader(
    BuildContext context,
    List<DownloadTask> items,
    AppInfo? info, {
    required DownloadGroupSummary summary,
    required bool isExpanded,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final appName = info?.name ?? items[0].appName;
    final isMulti = summary.isMulti;
    final groupKey = '${items[0].appId}_${items[0].version}';

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
                  isMulti
                      ? '${items[0].version} · 共 ${summary.total} 个文件'
                      : items[0].version,
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
          // 多文件组用聚合状态徽标（只看第一条会把组内失败藏起来）
          if (isMulti)
            _buildGroupStatusBadge(context, summary)
          else
            _buildStatusBadge(context, items[0], state.missingFileIds),
          // 多文件组：展开指示（箭头随展开状态旋转过渡）
          if (isMulti) ...[
            const SizedBox(width: AppSpacing.xs),
            AnimatedRotation(
              turns: isExpanded ? 0.5 : 0.0,
              duration: AppAnimation.fast,
              curve: AppAnimation.curve,
              child: Icon(
                Icons.keyboard_arrow_down,
                size: AppTypography.iconMD,
                color: scheme.onSurfaceVariant,
              ),
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
      onTap: () => setState(() => _toggleGroup(groupKey)),
      child: header,
    );
  }

  /// 多文件组的聚合状态徽标：展示整组状态而不是组内第一条
  Widget _buildGroupStatusBadge(
    BuildContext context,
    DownloadGroupSummary summary,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // 整组都已完成但文件全部被删 → 与单条一致的"已删除"警示
    if (summary.allCompleted && summary.deleted == summary.total) {
      return _statusChip(
        context,
        label: '已删除',
        color: scheme.error,
        icon: Icons.delete_outline,
      );
    }
    final (label, color, icon) = switch (summary.kind) {
      DownloadGroupKind.downloading => (
          '下载中',
          scheme.primary,
          Icons.downloading,
        ),
      DownloadGroupKind.completed => (
          '已完成',
          scheme.tertiary,
          Icons.check_circle,
        ),
      DownloadGroupKind.failed => ('失败', scheme.error, Icons.error),
      DownloadGroupKind.queued => (
          '排队中',
          scheme.secondary,
          Icons.queue,
        ),
      DownloadGroupKind.waiting => (
          '等待中',
          scheme.onSurfaceVariant,
          Icons.schedule,
        ),
    };
    return _statusChip(context, label: label, color: color, icon: icon);
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
    DownloadTask downStatus,
  ) {
    return Dismissible(
      key: Key(downStatus.id?.toString() ??
          '${downStatus.appId}-${downStatus.version}-${downStatus.fileName}'),
      direction: DismissDirection.endToStart,
      // 删除前先确认
      confirmDismiss: (_) => _confirmDelete(context, downStatus),
      onDismissed: (_) {
        notifier.deleteDownload(downStatus);
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
      child: Padding(
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
                    downStatus.fileName,
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
            if (downStatus.status == DownloadStatusEnum.downloading ||
                downStatus.status == DownloadStatusEnum.connecting ||
                downStatus.status == DownloadStatusEnum.queued ||
                (downStatus.total > 0 && downStatus.received < downStatus.total))
              _buildProgressBar(context, downStatus)
            else if (downStatus.total > 0)
              Text(
                '文件大小: ${_formatFileSize(downStatus.total)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),

            const SizedBox(height: AppSpacing.sm),

            // 主操作按钮 + 辅助操作
            Row(
              children: [
                _buildPrimaryAction(context, downStatus),
                const Spacer(),
                IconButton(
                  tooltip: '重新下载（清空已下分段，从 0 开始）',
                  icon: const Icon(
                    Icons.refresh,
                    size: AppTypography.iconSM,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => notifier.restartDownload(downStatus),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(
                    Icons.delete_outline,
                    size: AppTypography.iconSM,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    if (await _confirmDelete(context, downStatus)) {
                      notifier.deleteDownload(downStatus);
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
                  onPressed: () => _showDownloadInfo(context, downStatus),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 主操作按钮（由 download_status_utils.dart 的 primaryActionFor 决定）
  /// 已完成但文件已被外部删除时不再提供"安装"，改为红框"已删除"占位。
  Widget _buildPrimaryAction(
    BuildContext context,
    DownloadTask item,
  ) {
    if (isCompletedFileMissing(item, state.missingFileIds)) {
      // 文件已删除：禁用按钮占位（红/黄警示边框），提示用户文件不在了
      return OutlinedButton.icon(
        onPressed: null,
        icon: Icon(
          Icons.delete_outline,
          size: AppTypography.iconSM,
          color: Theme.of(context).colorScheme.error,
        ),
        label: Text(
          '已删除',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          side: BorderSide(color: Theme.of(context).colorScheme.error),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.allSM,
          ),
        ),
      );
    }

    final action = primaryActionFor(item);
    if (action == null) return const SizedBox.shrink();

    final (label, icon) = switch (action) {
      DownloadAction.pause => ('暂停', Icons.pause),
      DownloadAction.resume => ('继续', Icons.play_arrow),
      DownloadAction.retry => ('重试', Icons.refresh),
      DownloadAction.install => ('安装', Icons.install_mobile),
      DownloadAction.cancel => ('取消', Icons.cancel),
    };
    final onPressed = switch (action) {
      DownloadAction.pause => () => notifier.pauseDownload(item),
      DownloadAction.resume => () => notifier.resumeDownload(item),
      DownloadAction.retry => () => notifier.retryDownload(item),
      DownloadAction.install => () => notifier.installApp(item),
      DownloadAction.cancel => () => notifier.cancelDownload(item),
    };

    return _actionButton(
      context,
      label: label,
      icon: icon,
      onPressed: onPressed,
    );
  }

  /// 卡片内统一的紧凑操作按钮（文件行主操作与折叠摘要快捷动作共用同一视觉规格）
  Widget _actionButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
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
  Future<bool> _confirmDelete(BuildContext context, DownloadTask item) async {
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
    DownloadTask initial,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    final channel = inferChannelLabel(initial.url);

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
          child: Consumer(
            builder: (context, ref, _) {
              // 取**实时**任务：页面已订阅 service.watch(id) 并把更新推进 provider，
              // 这里消费它，弹层才会随进度刷新。否则「已下载」/分段色块都只是打开时的
              // 死快照（表现为"已下载是一串不动的字符串"）。
              // 下面整体沿用 `item` 这个名字，内容一行都不用改。
              // latestGroups 是未筛选的原始分组，保证被筛掉的任务也能查到实时值
              final item = ref
                  .watch(downloadManagerProvider)
                  .latestGroups
                  .expand((g) => g)
                  .firstWhere(
                    (t) => t.id == initial.id,
                    orElse: () => initial,
                  );
              return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoSection(context, '基本信息'),
              infoRow('文件名', item.fileName),
              infoRow('应用', '${item.appName}（${item.version}）'),
              infoRow('应用标识', item.appId),
              if (item.total > 0) infoRow('文件大小', _formatFileSize(item.total)),
              infoRow('创建时间', _formatCreateTime(item.createdAt)),
              if (channel != null) infoRow('来源渠道', channel),

              _infoSection(context, '传输详情'),
              if (item.status == DownloadStatusEnum.queued)
                infoRow('状态', '排队中，等待下载槽位'),
              if (item.status == DownloadStatusEnum.downloading &&
                  item.speedBps > 0)
                infoRow('下载速度', formatSpeed(item.speedBps)),
              if (item.status == DownloadStatusEnum.downloading &&
                  (item.etaSec ?? 0) > 0)
                infoRow('剩余时间', formatDuration(item.etaSec!)),
              if (item.total > 0)
                infoRow(
                    '已下载',
                    '${_formatFileSize(item.received)} / ${_formatFileSize(item.total)}'
                        '   ${item.received * 100 ~/ item.total}%'),
              if (item.segments case final segs? when segs.isNotEmpty) ...[
                infoRow('分段', '共 ${segs.length} 段'),
                _segmentBlocks(context, scheme, segs),
              ],

              _infoSection(context, '来源'),
              if (item.headers.isNotEmpty)
                infoRow('请求头',
                    item.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n')),

              _infoSection(context, '存储'),
              infoRow('保存路径', item.filePath),
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
                        item.url,
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
                        await Clipboard.setData(ClipboardData(text: item.url));
                        AppDialogs.showSuccess('已复制下载链接');
                      },
                    ),
                  ],
                ),
              ),
            ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// 信息面板的分组标题（后续新字段直接往对应分组里加即可）
  Widget _infoSection(BuildContext context, String title) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.xs),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  /// 分段进度：**主题色色块**，alpha 越实表示该段下得越多。
  ///
  /// 用色块而不是进度条：段数多时更紧凑、不抢视觉焦点；
  /// 悬浮可看该段的精确数值。
  Widget _segmentBlocks(
    BuildContext context,
    ColorScheme scheme,
    List<SegmentInfo> segs,
  ) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final seg in segs)
          Tooltip(
            // 自绘内容：段号用主题色强调、百分比用正文色、字节数用次要色
            richMessage: TextSpan(
              children: [
                TextSpan(
                  text: '#${seg.index}',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextSpan(
                  text: '  ${(_segPercent(seg) * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextSpan(
                  text: '  ${_formatFileSize(seg.received)}'
                      ' / ${_formatFileSize(seg.endByte - seg.startByte + 1)}',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            textStyle: Theme.of(context).textTheme.bodySmall,
            // 移动端没有 hover：用点击触发气泡（默认是长按）
            triggerMode: TooltipTriggerMode.tap,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: scheme.primary
                    .withValues(alpha: 0.12 + 0.88 * _segPercent(seg)),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
      ],
    );
  }

  /// 单段完成比例
  double _segPercent(SegmentInfo seg) {
    final len = seg.endByte - seg.startByte + 1;
    if (len <= 0) {
      return 0;
    }
    return (seg.received / len).clamp(0.0, 1.0);
  }

  /// 创建时间格式化（DateTime → yyyy-MM-dd HH:mm）
  String _formatCreateTime(DateTime dt) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} '
        '${pad(dt.hour)}:${pad(dt.minute)}';
  }

  /// 构建状态标签（颜色全部取自主题）
  /// [missingFileIds] 已完成但文件已被外部删除的任务 id（命中显示"已删除"）
  Widget _buildStatusBadge(
    BuildContext context,
    DownloadTask item,
    Set<int> missingFileIds,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // 已完成但文件已被删除 → 降级为"已删除"（红色，与失败同级警示）
    if (isCompletedFileMissing(item, missingFileIds)) {
      final (label, color, icon) = (
        '已删除',
        scheme.error,
        Icons.delete_outline,
      );
      return _statusChip(context, label: label, color: color, icon: icon);
    }
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
      DownloadStatusKind.queued => (
          '排队中',
          scheme.secondary,
          Icons.queue,
        ),
      DownloadStatusKind.waiting => (
          '等待中',
          scheme.onSurfaceVariant,
          Icons.schedule,
        ),
    };

    return _statusChip(context, label: label, color: color, icon: icon);
  }

  /// 状态徽标外观（label + 彩色边框/图标 + 文本同色）
  Widget _statusChip(
    BuildContext context, {
    required String label,
    required Color color,
    required IconData icon,
  }) {
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
  Widget _buildProgressBar(BuildContext context, DownloadTask data) {
    final progress = data.total > 0 ? data.received / data.total : 0.0;
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
              '${_formatFileSize(data.received)} / ${_formatFileSize(data.total)}',
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
        // 下载速度与预估剩余时间：两端始终渲染固定行（内容随状态变化），
        // 避免显示/隐藏导致每行高度跳变、页面跳动。
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _statusLineLeft(data),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: data.status == DownloadStatusEnum.downloading
                          ? null
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              Text(
                _statusLineRight(data),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 进度条底部左文案：下载中显示速度，否则显示状态（空串保留行高）。
  String _statusLineLeft(DownloadTask data) {
    if (data.status == DownloadStatusEnum.downloading) {
      return data.speedBps > 0 ? formatSpeed(data.speedBps) : '';
    }
    switch (data.status) {
      case DownloadStatusEnum.paused:
      case DownloadStatusEnum.queued:
      case DownloadStatusEnum.cancelled:
        return '已暂停';
      case DownloadStatusEnum.completed:
        return '已完成';
      case DownloadStatusEnum.failed:
        return '已失败';
      case DownloadStatusEnum.downloading:
      case DownloadStatusEnum.connecting:
        return '';
    }
  }

  /// 进度条底部右文案：下载中显示剩余时间，否则空串（保留行高）。
  String _statusLineRight(DownloadTask data) {
    if (data.status == DownloadStatusEnum.downloading &&
        (data.etaSec ?? 0) > 0) {
      return formatDuration(data.etaSec!);
    }
    return '';
  }

  /// 构建头部"更多操作"菜单项：批量操作（暂停全部/取消排队/重试失败）按存在性
  /// 条件显示，末尾固定清理项。放入 AppBar 后不再有 body 中整行显示/隐藏的布局跳动。
  List<PopupMenuEntry<String>> _buildMoreMenuItems(BuildContext context) {
    final groups = state.groups;
    final hasDownloading = groups.any((g) => g.any(
        (item) =>
            item.status == DownloadStatusEnum.downloading ||
            item.status == DownloadStatusEnum.connecting));
    final hasQueued = groups.any(
        (g) => g.any((item) => item.status == DownloadStatusEnum.queued));
    final hasFailed = groups.any(
        (g) => g.any((item) => item.status == DownloadStatusEnum.failed));
    final scheme = Theme.of(context).colorScheme;

    final items = <PopupMenuEntry<String>>[
      if (hasDownloading)
        PopupMenuItem(
          value: 'pause_all',
          child: Row(
            children: [
              Icon(Icons.pause_circle_outline, size: AppTypography.iconSM),
              const SizedBox(width: AppSpacing.md),
              const Text('暂停全部'),
            ],
          ),
        ),
      if (hasQueued)
        PopupMenuItem(
          value: 'cancel_queued',
          child: Row(
            children: [
              Icon(Icons.cancel_outlined,
                  size: AppTypography.iconSM, color: scheme.error),
              const SizedBox(width: AppSpacing.md),
              const Text('取消排队'),
            ],
          ),
        ),
      if (hasFailed)
        PopupMenuItem(
          value: 'retry_failed',
          child: Row(
            children: [
              Icon(Icons.refresh, size: AppTypography.iconSM),
              const SizedBox(width: AppSpacing.md),
              const Text('重试失败'),
            ],
          ),
        ),
      if (hasDownloading || hasQueued || hasFailed)
        const PopupMenuDivider(),
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
            Icon(Icons.delete_sweep, color: scheme.error),
            const SizedBox(width: AppSpacing.md),
            Text('清空全部', style: TextStyle(color: scheme.error)),
          ],
        ),
      ),
    ];
    return items;
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
