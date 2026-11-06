import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/app_borders.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/compent/pressable_scale.dart';
import 'package:gstore/page/download/download_status_utils.dart';
import 'package:gstore/page/download/download_page_providers.dart';
import 'package:gstore/page/download/download_settings_sheet.dart';
import 'package:gstore/page/download/widgets/download_action_button.dart';
import 'package:gstore/page/download/widgets/download_app_icon.dart';
import 'package:gstore/page/download/widgets/download_detail_sheet.dart';
import 'package:gstore/page/download/widgets/download_hero_card.dart';

class DownloadManager extends ConsumerStatefulWidget {
  const DownloadManager({super.key});

  @override
  ConsumerState<DownloadManager> createState() => _DownloadManagerState();
}

class _DownloadManagerState extends ConsumerState<DownloadManager> {
  /// 多文件组的展开状态（key: appId_version，与分组 key 一致）
  final Set<String> _expandedKeys = {};

  /// 列表滚动控制器（筛选切换时回到顶部，避免停留在旧偏移）。
  final ScrollController _scrollController = ScrollController();

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
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 英雄卡读数取「未筛选」的原始分组：切换筛选不改变总速度/总计数。
    final overview = summarizeOverview(state.latestGroups);

    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
          IconButton(
            key: const Key('download_settings_button'),
            icon: const Icon(TablerIcons.settings),
            tooltip: '下载设置',
            onPressed: () => showDownloadSettingsSheet(context),
          ),
          // 批量操作（暂停全部/取消排队/重试失败）+ 清理：放入导航头部，
          // 避免 body 中条件显示整行导致布局跳动。
          PopupMenuButton<String>(
            icon: const Icon(TablerIcons.dots_vertical),
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
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // 实时吞吐英雄卡：挂在 sliver 头部，高度随滚动连续收起（原生手势）。
          if (overview.hasTasks)
            SliverPersistentHeader(
              pinned: true,
              delegate: _DownloadHeroHeaderDelegate(
                overview: overview,
                onPauseAll: () => notifier.pauseAll(),
                onResumeAll: () => notifier.resumeAll(),
              ),
            ),

          // 筛选标签固定在英雄卡下方（内容滚动时保持可见）。
          SliverPersistentHeader(
            pinned: true,
            delegate: _FixedHeaderDelegate(
              extent: AppSpacing.massive + AppSpacing.md,
              child: Column(
                children: [
                  _buildFilterChips(context),
                  const SizedBox(height: AppSpacing.md),
                ],
              ),
            ),
          ),

          // 下载列表
          if (state.groups.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _buildEmptyState(context),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              sliver: SliverList.builder(
                itemCount: state.groups.length,
                itemBuilder: (context, index) {
                  final items = state.groups[index];
                  final info = state.cachedAppInfo(items[0].appId);
                  return _buildDownloadGroup(context, items, info);
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 构建筛选标签（药丸 chip + 计数徽标）
  Widget _buildFilterChips(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final currentFilter = state.filter;
    final counts = _filterCounts();

    return SizedBox(
      height: AppSpacing.massive,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        children: DownloadFilter.values.map((filter) {
          final isSelected = currentFilter == filter;
          final count = counts[filter] ?? 0;
          return Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: FilterChip(
              showCheckmark: false,
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_getFilterLabel(filter)),
                  const SizedBox(width: AppSpacing.xs),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? scheme.primary.withValues(alpha: 0.16)
                          : scheme.surfaceContainerHighest,
                      borderRadius: AppRadius.allCircle,
                    ),
                    child: Text(
                      '$count',
                      style: text.labelSmall?.copyWith(
                        color: isSelected
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                        fontWeight: AppTypography.weightSemiBold,
                      ),
                    ),
                  ),
                ],
              ),
              selected: isSelected,
              onSelected: (_) {
                notifier.setFilter(filter);
                // 筛选后内容变化，直接回到顶部（英雄卡恢复完整模式）。
                if (_scrollController.hasClients) {
                  _scrollController.jumpTo(0);
                }
              },
              selectedColor: scheme.primaryContainer,
              backgroundColor: scheme.surfaceContainerLow,
              checkmarkColor: scheme.primary,
              shape: const StadiumBorder(),
              side: BorderSide(
                color: isSelected ? scheme.primary : scheme.outlineVariant,
              ),
              labelStyle: text.labelLarge?.copyWith(
                color: isSelected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
                fontWeight: AppTypography.weightMedium,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// 各筛选条件的任务条数（按未筛选的原始分组统计）
  Map<DownloadFilter, int> _filterCounts() {
    var all = 0;
    var downloading = 0;
    var completed = 0;
    var failed = 0;
    for (final group in state.latestGroups) {
      for (final item in group) {
        all++;
        if (matchesFilter(item, DownloadFilter.downloading)) downloading++;
        if (matchesFilter(item, DownloadFilter.completed)) completed++;
        if (matchesFilter(item, DownloadFilter.failed)) failed++;
      }
    }
    return {
      DownloadFilter.all: all,
      DownloadFilter.downloading: downloading,
      DownloadFilter.completed: completed,
      DownloadFilter.failed: failed,
    };
  }

  /// 构建空状态：柔和渐变圆形插画 + 下载图标
  Widget _buildEmptyState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: AppSpacing.huge * 3,
            height: AppSpacing.huge * 3,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary.withValues(alpha: 0.18),
                  scheme.primary.withValues(alpha: 0.04),
                ],
              ),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.12),
              ),
            ),
            child: Center(
              child: Container(
                width: AppSpacing.massive + AppSpacing.xxl,
                height: AppSpacing.massive + AppSpacing.xxl,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.surfaceContainerLow,
                  boxShadow: AppShadows.shadowSM,
                ),
                child: Icon(
                  TablerIcons.download,
                  size: AppTypography.iconXXL,
                  color: scheme.primary.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '暂无下载记录',
            style: text.titleLarge?.copyWith(color: scheme.onSurface),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '下载的应用会显示在这里',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
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
        // 单文件组整卡可点击 → 下载详情；多文件组由头部负责展开/收起。
        onTap: isMulti
            ? null
            : () => showDownloadDetailSheet(context, items.first),
        // 关闭长按/按压水波纹与高亮，避免出现“长按阴影”效果。
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
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
                          _buildDownloadItem(
                            context,
                            items[i],
                            showFileName: isMulti,
                          ),
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
  /// - 全部完成：总大小 + 来源渠道 + 已删除提示（安装统一在详情页操作）
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

    final action = switch (summary.kind) {
      DownloadGroupKind.failed when failedItems.isNotEmpty => _actionButton(
          context,
          label: '重试失败',
          icon: TablerIcons.refresh,
          onPressed: () => _retryFailedInGroup(failedItems),
        ),
      _ => null,
    };

    // (文案, 图标, 颜色覆盖)
    final metas = <(String, IconData?, Color?)>[];
    switch (summary.kind) {
      case DownloadGroupKind.downloading:
        if (summary.speedBps > 0) {
          metas.add(
              ('合计 ${formatSpeed(summary.speedBps)}', TablerIcons.gauge, null));
        }
        metas.add(('${summary.completed}/${summary.total} 已完成', null, null));
        if ((summary.etaSec ?? 0) > 0) {
          metas.add((formatDuration(summary.etaSec!), TablerIcons.clock, null));
        }
      case DownloadGroupKind.queued:
        metas.add(('等待下载槽位', TablerIcons.playlist, null));
        metas.add(('${summary.completed}/${summary.total} 已完成', null, null));
      case DownloadGroupKind.waiting:
        metas.add(('已暂停', TablerIcons.player_pause, null));
        metas.add(('${summary.completed}/${summary.total} 已完成', null, null));
      case DownloadGroupKind.failed:
        if (summary.completed > 0) {
          metas.add((
            '${summary.completed} 个已完成',
            TablerIcons.circle_check,
            null,
          ));
        }
        metas.add((
          '${summary.failed} 个失败',
          TablerIcons.alert_circle_filled,
          scheme.error
        ));
      case DownloadGroupKind.completed:
        if (summary.totalBytes > 0) {
          metas.add((
            _formatFileSize(summary.totalBytes),
            TablerIcons.folder,
            null,
          ));
        }
        final channel = inferChannelLabel(items.first.url);
        if (channel != null) {
          metas.add((channel, TablerIcons.building_store, null));
        }
    }
    if (summary.deleted > 0) {
      metas.add((
        '${summary.deleted} 个文件已删除',
        TablerIcons.trash,
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
                borderRadius: AppRadius.allCircle,
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
        isMulti ? AppSpacing.sm : AppSpacing.xs,
      ),
      child: Row(
        children: [
          _buildAppIcon(
            context,
            info,
            appId: items[0].appId,
            appName: appName,
          ),
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
                        fontWeight: AppTypography.weightSemiBold,
                      ),
                ),
                const SizedBox(height: AppSpacing.xs),
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
                TablerIcons.chevron_down,
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
      return _statusChip(context, label: '已删除', color: scheme.error);
    }
    final (label, color) = switch (summary.kind) {
      DownloadGroupKind.downloading => ('下载中', scheme.primary),
      DownloadGroupKind.completed => ('已完成', scheme.tertiary),
      DownloadGroupKind.failed => ('失败', scheme.error),
      DownloadGroupKind.queued => ('排队中', scheme.secondary),
      DownloadGroupKind.waiting => ('等待中', scheme.onSurfaceVariant),
    };
    return _statusChip(context, label: label, color: color);
  }

  /// 构建应用图标：优先本地/网络图标，缺失时回退已安装应用图标或首字母头像。
  Widget _buildAppIcon(
    BuildContext context,
    AppInfo? info, {
    required String appId,
    required String appName,
  }) {
    return DownloadAppIcon(
      appId: appId,
      appName: appName,
      iconUrl: info?.icon,
      size: AppSpacing.massive,
    );
  }

  /// 构建下载项（文件行）。
  ///
  /// - 单文件组不再重复显示文件名（应用名/版本已在卡片头）；
  /// - 整行点击 → 下载详情 sheet；
  /// - 只保留进行中状态的主操作（暂停/继续/取消/重试），安装按钮已移除。
  Widget _buildDownloadItem(
    BuildContext context,
    DownloadTask downStatus, {
    required bool showFileName,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final action = _buildPrimaryAction(context, downStatus);

    return GestureDetector(
      key: Key(
        'download_item_${downStatus.id ?? downStatus.fileName}',
      ),
      behavior: HitTestBehavior.opaque,
      onTap: () => showDownloadDetailSheet(context, downStatus),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 多文件组才有必要显示文件名（单文件时与应用名重复）
            if (showFileName) ...[
              Text(
                downStatus.fileName,
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: AppTypography.weightMedium,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            // 进度/大小 + 圆形暂停/继续/重试/取消按钮（图标更轻，不再占一整行）
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: _buildTransferMeta(context, downStatus)),
                if (action != null) ...[
                  const SizedBox(width: AppSpacing.md),
                  action,
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 主操作（由 download_status_utils.dart 的 primaryActionFor 决定）。
  ///
  /// 列表项不提供「安装」（已完成项的卡片保持纯展示，点击查看详情）；
  /// 文件已被外部删除时返回 null；其余状态用圆形图标按钮。
  Widget? _buildPrimaryAction(
    BuildContext context,
    DownloadTask item,
  ) {
    if (isCompletedFileMissing(item, state.missingFileIds)) {
      return null;
    }

    final action = primaryActionFor(item);
    if (action == null || action == DownloadAction.install) return null;

    final scheme = Theme.of(context).colorScheme;
    final (label, icon, color) = switch (action) {
      DownloadAction.pause => ('暂停', TablerIcons.player_pause, null),
      DownloadAction.resume => ('继续', TablerIcons.player_play, null),
      DownloadAction.retry => ('重试', TablerIcons.refresh, null),
      DownloadAction.install => ('安装', TablerIcons.device_mobile_down, null),
      DownloadAction.cancel => ('取消', TablerIcons.circle_x, scheme.error),
    };
    final onPressed = switch (action) {
      DownloadAction.pause => () => notifier.pauseDownload(item),
      DownloadAction.resume => () => notifier.resumeDownload(item),
      DownloadAction.retry => () => notifier.retryDownload(item),
      DownloadAction.install => () => notifier.installApp(item),
      DownloadAction.cancel => () => notifier.cancelDownload(item),
    };

    return DownloadRoundActionButton(
      icon: icon,
      tooltip: label,
      onPressed: onPressed,
      color: color,
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
        shape: const StadiumBorder(),
      ),
    );
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
      return _statusChip(context, label: '已删除', color: scheme.error);
    }
    final (label, color) = switch (statusKindOf(item)) {
      DownloadStatusKind.downloading => ('下载中', scheme.primary),
      DownloadStatusKind.completed => ('已完成', scheme.tertiary),
      DownloadStatusKind.failed => ('失败', scheme.error),
      DownloadStatusKind.queued => ('排队中', scheme.secondary),
      DownloadStatusKind.waiting => ('等待中', scheme.onSurfaceVariant),
    };

    return _statusChip(context, label: label, color: color);
  }

  /// 状态徽标外观：圆点 + 文本，浅色底 + 同色描边（非 Material Chip）
  Widget _statusChip(
    BuildContext context, {
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs / 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: AppRadius.allCircle,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: AppSpacing.xs + 2,
            height: AppSpacing.xs + 2,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: AppTypography.weightSemiBold,
                ),
          ),
        ],
      ),
    );
  }

  /// 文件行传输信息：进度条（可下载时）+ 一行「已下载/总量 … 速度/剩余/百分比」。
  ///
  /// 完成后只保留文件总大小，避免 100% 等多余信息。
  Widget _buildTransferMeta(BuildContext context, DownloadTask data) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final isDownloading = data.status == DownloadStatusEnum.downloading;
    final isFailed = data.status == DownloadStatusEnum.failed ||
        isCompletedFileMissing(data, state.missingFileIds);
    final hasTotal = data.total > 0;
    final progress =
        hasTotal ? (data.received / data.total).clamp(0.0, 1.0) : 0.0;
    final isComplete = hasTotal && data.received >= data.total;
    final percent = (progress * 100).toInt();

    final rightParts = <String>[
      if (isDownloading && data.speedBps > 0) formatSpeed(data.speedBps),
      if (isDownloading && (data.etaSec ?? 0) > 0) formatDuration(data.etaSec!),
      if (hasTotal && !isComplete) '$percent%',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasTotal && !isComplete) ...[
          ClipRRect(
            borderRadius: AppRadius.allCircle,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: AppSpacing.xs + 2,
              backgroundColor: scheme.surfaceContainerHighest,
              color: isFailed ? scheme.error : scheme.primary,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
        ],
        Row(
          children: [
            Expanded(
              child: hasTotal
                  ? Text(
                      isComplete
                          ? _formatFileSize(data.total)
                          : '${_formatFileSize(data.received)} / '
                              '${_formatFileSize(data.total)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            if (rightParts.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  rightParts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: text.bodySmall?.copyWith(
                    color: isFailed
                        ? scheme.error
                        : (isDownloading
                            ? scheme.primary
                            : scheme.onSurfaceVariant),
                    fontWeight: AppTypography.weightMedium,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// 构建头部"更多操作"菜单项：批量操作（暂停全部/取消排队/重试失败）按存在性
  /// 条件显示，末尾固定清理项。放入 AppBar 后不再有 body 中整行显示/隐藏的布局跳动。
  List<PopupMenuEntry<String>> _buildMoreMenuItems(BuildContext context) {
    final groups = state.groups;
    final hasDownloading = groups.any((g) => g.any((item) =>
        item.status == DownloadStatusEnum.downloading ||
        item.status == DownloadStatusEnum.connecting));
    final hasQueued = groups
        .any((g) => g.any((item) => item.status == DownloadStatusEnum.queued));
    final hasFailed = groups
        .any((g) => g.any((item) => item.status == DownloadStatusEnum.failed));
    final scheme = Theme.of(context).colorScheme;

    final items = <PopupMenuEntry<String>>[
      if (hasDownloading)
        PopupMenuItem(
          value: 'pause_all',
          child: Row(
            children: [
              Icon(TablerIcons.player_pause, size: AppTypography.iconSM),
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
              Icon(TablerIcons.circle_x,
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
              Icon(TablerIcons.refresh, size: AppTypography.iconSM),
              const SizedBox(width: AppSpacing.md),
              const Text('重试失败'),
            ],
          ),
        ),
      if (hasDownloading || hasQueued || hasFailed) const PopupMenuDivider(),
      const PopupMenuItem(
        value: 'clear_completed',
        child: Row(
          children: [
            Icon(TablerIcons.clear_all),
            SizedBox(width: AppSpacing.md),
            Text('清理已完成'),
          ],
        ),
      ),
      PopupMenuItem(
        value: 'clear_all',
        child: Row(
          children: [
            Icon(TablerIcons.trash_x, color: scheme.error),
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

/// 实时吞吐英雄卡的 pinned sliver 头：高度随滚动偏移连续收缩。
///
/// 折叠进度 t 直接由 [shrinkOffset] 计算（不是阈值切换），卡片内容再按 t
/// 连续压扁/淡出，因此动画完全跟手。
class _DownloadHeroHeaderDelegate extends SliverPersistentHeaderDelegate {
  _DownloadHeroHeaderDelegate({
    required this.overview,
    required this.onPauseAll,
    required this.onResumeAll,
  });

  /// 卡片完整高度（展开态）与简化高度（收起态）。
  static const double _cardMaxExtent = 226;
  static const double _cardMinExtent = 66;
  static const double _outerTop = AppSpacing.sm;
  static const double _outerBottom = AppSpacing.md;

  final DownloadOverview overview;
  final VoidCallback onPauseAll;
  final VoidCallback onResumeAll;

  @override
  double get maxExtent => _outerTop + _cardMaxExtent + _outerBottom;

  @override
  double get minExtent => _outerTop + _cardMinExtent + _outerBottom;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final available =
        (maxExtent - shrinkOffset).clamp(minExtent, maxExtent).toDouble();
    final t = ((maxExtent - available) / (maxExtent - minExtent))
        .clamp(0.0, 1.0)
        .toDouble();

    return SizedBox(
      height: available,
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            _outerTop,
            AppSpacing.lg,
            _outerBottom,
          ),
          child: DownloadHeroCard(
            speedBps: overview.totalSpeedBps,
            active: overview.active,
            queued: overview.queued,
            completed: overview.completed,
            failed: overview.failed,
            waiting: overview.waiting,
            canPause: overview.canPause,
            canResume: overview.canResume,
            onPauseAll: onPauseAll,
            onResumeAll: onResumeAll,
            collapse: t,
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DownloadHeroHeaderDelegate oldDelegate) {
    // 速度/计数实时变化 → 重建头内容（进度刷新本来就会触发）。
    return true;
  }
}

/// 固定高度的 pinned sliver 头（筛选 chips 用）。
class _FixedHeaderDelegate extends SliverPersistentHeaderDelegate {
  _FixedHeaderDelegate({required this.extent, required this.child});

  final double extent;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return SizedBox(
      height: extent,
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: child,
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _FixedHeaderDelegate oldDelegate) => true;
}
