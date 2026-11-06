import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/page/download/download_page_providers.dart';
import 'package:gstore/page/download/download_status_utils.dart';
import 'package:gstore/page/download/widgets/download_action_button.dart';
import 'package:gstore/page/download/widgets/download_app_icon.dart';

/// 打开「下载详情」弹层（FluxDown 风格：进度环 + 统计网格 + 分段条 + 存储信息）。
///
/// 数据全部来自现有 [DownloadTask]，并订阅 [downloadManagerProvider] 实时刷新。
Future<void> showDownloadDetailSheet(
  BuildContext context,
  DownloadTask initial,
) {
  return AppSheet.showCustom<void>(
    context: context,
    builder: (_) => _DownloadDetailSheet(initial: initial),
  );
}

class _DownloadDetailSheet extends ConsumerWidget {
  const _DownloadDetailSheet({required this.initial});

  /// 打开弹层时的任务快照；实时值从 provider 中按 id / fileName 重新取。
  final DownloadTask initial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(downloadManagerProvider);
    final notifier = ref.read(downloadManagerProvider.notifier);
    final task = state.latestGroups
        .expand((group) => group)
        .firstWhere(
          (item) => _sameTask(item, initial),
          orElse: () => initial,
        );
    final missing = isCompletedFileMissing(task, state.missingFileIds);
    final info = state.cachedAppInfo(task.appId);
    final channel = inferChannelLabel(task.url);
    final kind = statusKindOf(task);
    final scheme = Theme.of(context).colorScheme;

    final statusLabel = _statusLabel(task, missing);
    final statusColor = missing ? scheme.error : _statusColor(kind, scheme);

    final stats = <(String, String)>[
      ('文件大小', task.total > 0 ? _formatBytes(task.total) : '未知'),
      ('已下载', _formatBytes(task.received)),
      (
        '下载速度',
        task.speedBps > 0 ? formatSpeed(task.speedBps) : '—',
      ),
      (
        '剩余时间',
        (task.etaSec ?? 0) > 0
            ? formatDuration(task.etaSec!).replaceFirst('剩余 ', '')
            : '—',
      ),
      ('状态', statusLabel),
      if (task.error case final error? when error.isNotEmpty)
        ('错误信息', error),
      ('来源渠道', channel ?? '—'),
      ('创建时间', _formatDateTime(task.createdAt)),
      ('应用标识', task.appId),
    ];

    return AppSheetScaffold(
      title: '下载详情',
      icon: const Icon(TablerIcons.file_download),
      contentPadding: AppSpacing.onlyHorizontalXL,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(
            context,
            task,
            info: info,
            statusLabel: statusLabel,
            statusColor: statusColor,
            missing: missing,
          ),
          const SizedBox(height: AppSpacing.lg),
          _ProgressSection(
            task: task,
            statusLabel: statusLabel,
            color: statusColor,
            missing: missing,
            segments: task.segments ?? const <SegmentInfo>[],
          ),
          const SizedBox(height: AppSpacing.lg),
          _buildActions(context, ref, notifier, task, missing),
          const SizedBox(height: AppSpacing.xl),
          _sectionTitle(context, '基本信息'),
          _StatsGrid(items: stats),
          const SizedBox(height: AppSpacing.xl),
          _sectionTitle(context, '存储'),
          _PathRow(
            label: '保存路径',
            value: task.filePath,
            copyTooltip: '复制保存路径',
          ),
          _PathRow(
            label: '下载链接',
            value: task.url,
            copyTooltip: '复制链接',
          ),
          if (task.headers.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            _sectionTitle(context, '请求头'),
            _RequestHeaders(headers: task.headers),
          ],
        ],
      ),
    );
  }

  /// 任务身份：优先 id；id 缺失时用 appId + version + fileName 兜底。
  static bool _sameTask(DownloadTask a, DownloadTask b) {
    if (a.id != null && b.id != null) return a.id == b.id;
    return a.appId == b.appId &&
        a.version == b.version &&
        a.fileName == b.fileName;
  }

  Widget _buildHeader(
    BuildContext context,
    DownloadTask task, {
    required AppInfo? info,
    required String statusLabel,
    required Color statusColor,
    required bool missing,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DownloadAppIcon(
              appId: task.appId,
              appName: task.appName,
              iconUrl: info?.icon,
              size: AppSpacing.massive + AppSpacing.sm,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.appName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '${task.version} · ${_formatBytes(task.total)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            _StatusPill(label: statusLabel, color: statusColor),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              TablerIcons.file,
              size: AppTypography.iconSM,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                task.fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (missing) ...[
              const SizedBox(width: AppSpacing.sm),
              Icon(
                TablerIcons.alert_triangle,
                size: AppTypography.iconSM,
                color: scheme.error,
              ),
            ],
          ],
        ),
      ],
    );
  }


  Widget _buildActions(
    BuildContext context,
    WidgetRef ref,
    DownloadManagerNotifier notifier,
    DownloadTask task,
    bool missing,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final action = missing ? null : primaryActionFor(task);

    Widget round(
      String label,
      IconData icon,
      VoidCallback onPressed, {
      Color? color,
    }) {
      return DownloadRoundActionButton(
        icon: icon,
        tooltip: label,
        onPressed: onPressed,
        size: 48,
        color: color,
      );
    }

    final Widget? primary = switch (action) {
      null => null,
      DownloadAction.pause => round(
          '暂停',
          TablerIcons.player_pause,
          () => unawaited(notifier.pauseDownload(task)),
        ),
      DownloadAction.resume => round(
          '继续',
          TablerIcons.player_play,
          () => unawaited(notifier.resumeDownload(task)),
        ),
      DownloadAction.retry => round(
          '重试',
          TablerIcons.refresh,
          () => unawaited(notifier.retryDownload(task)),
        ),
      DownloadAction.cancel => round(
          '取消',
          TablerIcons.circle_x,
          () => notifier.cancelDownload(task),
          color: scheme.error,
        ),
      DownloadAction.install => FilledButton.tonalIcon(
          onPressed: () => unawaited(notifier.installApp(task)),
          icon: const Icon(
            TablerIcons.device_mobile_down,
            size: AppTypography.iconSM,
          ),
          label: const Text('安装'),
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            shape: const StadiumBorder(),
          ),
        ),
    };

    return Row(
      children: [
        if (primary != null) primary,
        const Spacer(),
        TextButton.icon(
          onPressed: () => _confirmDelete(context, ref, task),
          icon: Icon(
            TablerIcons.trash,
            size: AppTypography.iconSM,
            color: scheme.error,
          ),
          label: Text(
            '删除记录',
            style: TextStyle(color: scheme.error),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    DownloadTask task,
  ) async {
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '删除下载',
      message: '确定要删除「${task.fileName}」的下载记录吗？此操作不可恢复。',
      confirmText: '删除',
      isDangerous: true,
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(downloadManagerProvider.notifier).deleteDownload(task);
    if (!context.mounted) return;
    Navigator.of(context).pop();
    AppDialogs.showSuccess('已删除下载记录');
  }

  Widget _sectionTitle(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: AppTypography.weightSemiBold,
        ),
      ),
    );
  }

  String _statusLabel(DownloadTask task, bool missing) {
    if (missing) return '已删除';
    return switch (statusKindOf(task)) {
      DownloadStatusKind.downloading => '下载中',
      DownloadStatusKind.completed => '已完成',
      DownloadStatusKind.failed => '失败',
      DownloadStatusKind.queued => '排队中',
      DownloadStatusKind.waiting => '等待中',
    };
  }

  Color _statusColor(DownloadStatusKind kind, ColorScheme scheme) {
    return switch (kind) {
      DownloadStatusKind.downloading => scheme.primary,
      DownloadStatusKind.completed => scheme.tertiary,
      DownloadStatusKind.failed => scheme.error,
      DownloadStatusKind.queued => scheme.secondary,
      DownloadStatusKind.waiting => scheme.onSurfaceVariant,
    };
  }
}

/// 大号进度环（展开动画随进度变化）。
class _ProgressRing extends StatelessWidget {
  const _ProgressRing({
    super.key,
    required this.progress,
    required this.color,
    required this.child,
  });

  final double progress;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppSpacing.massive * 3,
      height: AppSpacing.massive * 3,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: progress),
        duration: AppAnimation.medium,
        curve: AppAnimation.curve,
        builder: (context, value, _) {
          return CustomPaint(
            painter: _RingPainter(progress: value, color: color),
            child: Center(child: child),
          );
        },
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  static const double _outerStroke = 4;
  static const double _innerStroke = 9;
  static const double _ringGap = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = math.min(size.width, size.height) / 2;

    // 第一层：完整圆环（底/轨道层，使用状态色的浅色版本）。
    final outerRadius = maxRadius - _outerStroke / 2;
    canvas.drawCircle(
      center,
      outerRadius,
      Paint()
        ..color = color.withValues(alpha: 0.16)
        ..style = PaintingStyle.stroke
        ..strokeWidth = _outerStroke,
    );

    // 第二层：进度弧（内圈，带圆角端点）。
    if (progress <= 0) return;
    final innerRadius =
        outerRadius - _outerStroke / 2 - _ringGap - _innerStroke / 2;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: innerRadius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _innerStroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

/// 信息小胶囊（速度 / 剩余时间 / 删除警示）。
class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.allCircle,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: AppTypography.iconXS, color: tint),
          const SizedBox(width: AppSpacing.xs),
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: tint),
          ),
        ],
      ),
    );
  }
}

/// 状态徽标（同下载列表风格：圆点 + 文本 + 浅色底）。
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
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
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
}

/// 两列统计网格。
class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.items});

  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < items.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _StatTile(item: items[i])),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: i + 1 < items.length
                        ? _StatTile(item: items[i + 1])
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.item});

  final (String, String) item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.allMD,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.$1,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: AppTypography.heightTight,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            item.$2,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: AppTypography.weightMedium,
              height: AppTypography.heightTight,
            ),
          ),
        ],
      ),
    );
  }
}

/// 分段摘要：共 N 段 · 已完成 X 段。
class _SegmentSummary extends StatelessWidget {
  const _SegmentSummary({required this.segments, required this.tint});

  final List<SegmentInfo> segments;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = segments.where((segment) {
      final length = segment.endByte - segment.startByte + 1;
      return length > 0 && segment.received >= length;
    }).length;
    final totals = _SegmentTotals.of(segments);

    return Row(
      children: [
        Icon(TablerIcons.layout_columns, size: AppTypography.iconSM, color: tint),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            '共 ${segments.length} 段 · 已完成 $done 段',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          '${totals.percent}%',
          style: theme.textTheme.labelMedium?.copyWith(
            color: tint,
            fontWeight: AppTypography.weightSemiBold,
          ),
        ),
      ],
    );
  }
}

/// 分段总量的汇总（按字节区间加权，而不是按段数平均）。
class _SegmentTotals {
  const _SegmentTotals({required this.received, required this.total});

  final int received;
  final int total;

  int get percent =>
      total > 0 ? (received * 100 / total).round().clamp(0, 100) : 0;
  double get progress =>
      total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;

  static _SegmentTotals of(List<SegmentInfo> segments) {
    var received = 0;
    var total = 0;
    for (final segment in segments) {
      final length = segment.endByte - segment.startByte + 1;
      if (length <= 0) continue;
      total += length;
      received += segment.received.clamp(0, length);
    }
    return _SegmentTotals(received: received, total: total);
  }
}

/// 分段进度的渐变展示：整条轨道按加权总进度填充，颜色由浅到深渐变。
///
/// 保留「分段」区块的数量汇总，但不再把轨道切成一段段的小块。
/// 进度区域：Tab 切换「环形进度 / 分段进度」。
///
/// 内容区高度固定，切换 Tab 不会改变 sheet 高度。
class _ProgressSection extends StatefulWidget {
  const _ProgressSection({
    required this.task,
    required this.statusLabel,
    required this.color,
    required this.missing,
    required this.segments,
  });

  final DownloadTask task;
  final String statusLabel;
  final Color color;
  final bool missing;
  final List<SegmentInfo> segments;

  @override
  State<_ProgressSection> createState() => _ProgressSectionState();
}

class _ProgressSectionState extends State<_ProgressSection>
    with SingleTickerProviderStateMixin {
  /// 固定内容高度（环形 tab 的最高内容：环 144 + 字节/速度/提示）。
  static const double _contentHeight = 224;

  late final TabController _tabController =
      TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      children: [
        TabBar(
          controller: _tabController,
          dividerHeight: 0,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: AppRadius.allCircle,
          ),
          labelColor: scheme.onPrimaryContainer,
          unselectedLabelColor: scheme.onSurfaceVariant,
          labelStyle: theme.textTheme.labelMedium?.copyWith(
            fontWeight: AppTypography.weightSemiBold,
          ),
          unselectedLabelStyle: theme.textTheme.labelMedium,
          tabs: const [
            Tab(text: '环形进度', height: 36),
            Tab(text: '分段进度', height: 36),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: _contentHeight,
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildRingTab(context),
              _buildSegmentTab(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRingTab(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final task = widget.task;
    final kind = statusKindOf(task);
    final hasTotal = task.total > 0;
    final progress =
        hasTotal ? (task.received / task.total).clamp(0.0, 1.0) : 0.0;
    final percent = (progress * 100).round();

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ProgressRing(
          key: const Key('download_detail_ring'),
          progress: progress,
          color: widget.color,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                hasTotal ? '$percent%' : widget.statusLabel,
                style: theme.textTheme.displaySmall?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: AppTypography.weightBold,
                  height: AppTypography.heightTight,
                ),
              ),
              if (hasTotal)
                Text(
                  widget.statusLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (hasTotal)
          Text(
            '${_formatBytes(task.received)} / ${_formatBytes(task.total)}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: AppTypography.weightMedium,
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            if (kind == DownloadStatusKind.downloading && task.speedBps > 0)
              _InfoPill(
                icon: TablerIcons.gauge,
                text: formatSpeed(task.speedBps),
                color: scheme.primary,
              ),
            if ((task.etaSec ?? 0) > 0)
              _InfoPill(
                icon: TablerIcons.clock,
                text: formatDuration(task.etaSec!),
              ),
            if (widget.missing)
              _InfoPill(
                icon: TablerIcons.trash,
                text: '文件已被删除',
                color: scheme.error,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildSegmentTab(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final segments = widget.segments;

    if (segments.isEmpty) {
      return Center(
        child: Text(
          '暂无分段信息',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SegmentSummary(segments: segments, tint: widget.color),
        const SizedBox(height: AppSpacing.sm),
        // 4 列宫格：一行 4 段，段数多时内部滚动。
        Expanded(
          child: GridView.builder(
            key: const Key('download_detail_segments'),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: AppSpacing.sm,
              mainAxisSpacing: AppSpacing.xs,
              mainAxisExtent: 46,
            ),
            itemCount: segments.length,
            itemBuilder: (context, index) => _SegmentCell(
              segment: segments[index],
              tint: widget.color,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '颜色越深 = 该段完成度越高',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.outline,
          ),
        ),
      ],
    );
  }
}

/// 单个分段色条：颜色随该段完成度由浅入深。
class _SegmentCell extends StatelessWidget {
  const _SegmentCell({required this.segment, required this.tint});

  final SegmentInfo segment;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final length = segment.endByte - segment.startByte + 1;
    final fill = length > 0 ? (segment.received / length).clamp(0.0, 1.0) : 0.0;
    final percent = (fill * 100).round();
    final light = Color.lerp(scheme.surfaceContainerHighest, tint, 0.18)!;
    final color = Color.lerp(light, tint, fill)!;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '#${segment.index}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Text(
              '$percent%',
              style: theme.textTheme.labelSmall?.copyWith(
                color: tint,
                fontWeight: AppTypography.weightSemiBold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: AppRadius.allCircle,
          ),
        ),
      ],
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({
    required this.label,
    required this.value,
    required this.copyTooltip,
  });

  final String label;
  final String value;
  final String copyTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: AppSpacing.massive + AppSpacing.lg,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
              ),
            ),
          ),
          IconButton(
            tooltip: copyTooltip,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              TablerIcons.copy,
              size: AppTypography.iconSM,
              color: scheme.primary,
            ),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              AppDialogs.showSuccess('已复制$label');
            },
          ),
        ],
      ),
    );
  }
}

class _RequestHeaders extends StatelessWidget {
  const _RequestHeaders({required this.headers});

  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.allMD,
      ),
      child: SelectableText(
        headers.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
          height: AppTypography.heightRelaxed,
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _formatDateTime(DateTime dt) {
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} '
      '${pad(dt.hour)}:${pad(dt.minute)}';
}
