import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/design/app_borders.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_shadows.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/page/download/download_status_utils.dart';

/// FluxDown 风格的「实时吞吐」英雄卡。
///
/// 纯展示组件：所有读数由外部（未筛选的整页任务）计算后以标量传入，
/// 自身只负责排版、约 30 秒速度波形与暂停/恢复全部按钮。
///
/// - 卡面**不是** [AppCard]，以免破坏下载页「每组恰好一个 AppCard」的约定；
/// - 不包含任何 [LinearProgressIndicator]（波形由 CustomPainter 绘制）；
/// - 文案只用 `实时吞吐` / `活跃` / `排队` / `完成` / `失败`，不引入 `下载中`。
class DownloadHeroCard extends StatefulWidget {
  const DownloadHeroCard({
    super.key,
    required this.speedBps,
    required this.active,
    required this.queued,
    required this.completed,
    required this.failed,
    required this.waiting,
    required this.canPause,
    required this.canResume,
    required this.onPauseAll,
    required this.onResumeAll,
    this.collapse = 0,
    this.sampleInterval = const Duration(seconds: 1),
    this.window = 30,
  }) : assert(window > 0, 'window 必须大于 0'),
       assert(collapse >= 0 && collapse <= 1, 'collapse 必须在 0..1 之间');

  /// 下载中任务合计速度（bytes/s）；0 显示 `0 B/s`。
  final int speedBps;

  /// 下载中/连接中数量
  final int active;

  /// 排队中数量
  final int queued;

  /// 已完成数量
  final int completed;

  /// 失败数量
  final int failed;

  /// 等待中数量（paused / cancelled，可继续）
  final int waiting;

  /// 是否展示「暂停全部」（有下载中任务）
  final bool canPause;

  /// 是否展示「恢复全部」（有可继续任务）
  final bool canResume;

  /// 暂停全部回调
  final VoidCallback onPauseAll;

  /// 恢复全部回调
  final VoidCallback onResumeAll;

  /// 收起进度：0 = 完整模式，1 = 单行简化模式。
  ///
  /// 由外层 SliverPersistentHeader 根据滚动偏移连续传入，卡片内容与高度
  /// 跟随手势实时收缩（不是阈值切换）。
  final double collapse;

  /// 波形采样间隔（默认 1s × 30 点；父级刷新也会补点，约等于最近一段时间的速度）
  final Duration sampleInterval;

  /// 波形保留的采样点数量
  final int window;

  @override
  State<DownloadHeroCard> createState() => _DownloadHeroCardState();
}

class _DownloadHeroCardState extends State<DownloadHeroCard> {
  late List<double> _samples;
  Timer? _sampleTimer;
  bool _disableAnimations = false;
  bool _motionInitialized = false;

  bool get _live => widget.active > 0 && widget.speedBps > 0;

  @override
  void initState() {
    super.initState();
    _samples = List<double>.filled(widget.window, 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.disableAnimationsOf(context);
    if (!_motionInitialized || disabled != _disableAnimations) {
      _motionInitialized = true;
      _disableAnimations = disabled;
      _syncMotion();
    }
  }

  @override
  void didUpdateWidget(covariant DownloadHeroCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.window != widget.window) {
      _samples = [
        ..._samples.skip(math.max(0, _samples.length - widget.window)),
        ...List<double>.filled(
          math.max(0, widget.window - _samples.length),
          0,
        ),
      ];
    }
    final bool wasLive = oldWidget.active > 0 && oldWidget.speedBps > 0;
    if (oldWidget.speedBps != widget.speedBps ||
        oldWidget.active != widget.active) {
      // 立即把最新读数推入波形（父级刷新即触发重绘）。
      _pushSample(widget.speedBps.toDouble());
      // 只在「空闲 ↔ 传输中」切换时启停采样，避免每次进度刷新都重置 1s 定时器。
      if (wasLive != _live) _syncMotion();
    }
  }

  @override
  void dispose() {
    _sampleTimer?.cancel();
    super.dispose();
  }

  /// 仅在「传输中且未禁用动画」时采样；空闲时停表，避免常驻 1Hz 重建。
  ///
  /// 呼吸点由 [_LiveDot] 自己的 controller 负责，这里不重复动画。
  void _syncMotion() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    if (_disableAnimations || !_live) return;
    _sampleTimer = Timer.periodic(widget.sampleInterval, (_) {
      if (!mounted) return;
      setState(() => _pushSample(widget.speedBps.toDouble()));
    });
  }

  void _pushSample(double value) {
    final next = List<double>.of(_samples);
    if (next.isEmpty) return;
    next.removeAt(0);
    next.add(value.isFinite && value > 0 ? value : 0);
    _samples = next;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final reading = speedReadingOf(widget.speedBps);
    final t = widget.collapse.clamp(0.0, 1.0);
    // 收起后段才渐显同排速度，避免与大号速度数字长时间重叠。
    final compactOpacity = ((t - 0.35) / 0.65).clamp(0.0, 1.0);
    final padding = EdgeInsets.lerp(
      const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      t,
    )!;

    return Container(
      key: const Key('download_hero'),
      clipBehavior: Clip.antiAlias,
      decoration: _decoration(context, scheme),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: AppSpacing.massive,
              child: Row(
                children: [
                  _LiveDot(
                    live: _live,
                    animationsEnabled: !_disableAnimations,
                    color: _live ? scheme.primary : scheme.outline,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    '实时吞吐',
                    style: text.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: AppTypography.weightMedium,
                      letterSpacing: AppTypography.spacingWider,
                    ),
                  ),
                  const Spacer(),
                  // 收起态速度（展开态由下方大号数字承担，避免重复）。
                  if (compactOpacity > 0)
                    Opacity(
                      opacity: compactOpacity,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            reading.value,
                            maxLines: 1,
                            style: text.titleLarge?.copyWith(
                              height: AppTypography.heightTight,
                              color: scheme.onSurface,
                              fontWeight: AppTypography.weightBold,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Text(
                            reading.unit,
                            maxLines: 1,
                            style: text.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: AppTypography.weightMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(width: AppSpacing.sm),
                  _buildToggleButton(scheme),
                ],
              ),
            ),
            // 展开态内容：高度随收起进度实时压扁，同时淡出。
            if (t < 1)
              ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: (1 - t).clamp(0.0, 1.0),
                  child: Opacity(
                    opacity: (1 - t).clamp(0.0, 1.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: AppSpacing.sm),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Flexible(
                              child: Text(
                                reading.value,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.displayLarge?.copyWith(
                                  fontSize: AppTypography.sizeHuge,
                                  height: AppTypography.heightTight,
                                  color: scheme.onSurface,
                                  fontWeight: AppTypography.weightBold,
                                ),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              reading.unit,
                              maxLines: 1,
                              style: text.titleMedium?.copyWith(
                                fontSize: AppTypography.sizeXL,
                                color: scheme.onSurfaceVariant,
                                fontWeight: AppTypography.weightMedium,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        SizedBox(
                          height: AppSpacing.huge + AppSpacing.md,
                          child: CustomPaint(
                            painter: _SparklinePainter(
                              samples: _samples,
                              lineColor: scheme.primary,
                              fillColor: scheme.primary.withValues(alpha: 0.16),
                              baselineColor:
                                  scheme.outlineVariant.withValues(alpha: 0.5),
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        _buildStats(text, scheme),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 卡面装饰（展开/简化共用）。
  BoxDecoration _decoration(BuildContext context, ColorScheme scheme) {
    return BoxDecoration(
      borderRadius: AppRadius.allXL,
      border: AppBorders.all(context, color: scheme.outlineVariant),
      boxShadow: AppShadows.shadowSM,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          scheme.primary.withValues(alpha: 0.07),
          scheme.surfaceContainerLow,
          scheme.surfaceContainer,
        ],
        stops: const [0.0, 0.45, 1.0],
      ),
    );
  }


  Widget _buildToggleButton(ColorScheme scheme) {
    final enabled = widget.canPause || widget.canResume;
    final label = widget.canPause ? '暂停全部' : '恢复全部';
    final icon =
        widget.canPause ? TablerIcons.player_pause : TablerIcons.player_play;

    return Tooltip(
      message: label,
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.85),
        shape: const CircleBorder(),
        child: InkWell(
          key: const Key('download_hero_toggle'),
          customBorder: const CircleBorder(),
          onTap: !enabled
              ? null
              : (widget.canPause ? widget.onPauseAll : widget.onResumeAll),
          child: SizedBox(
            width: AppSpacing.massive,
            height: AppSpacing.massive,
            child: Icon(
              icon,
              size: AppTypography.iconLG,
              color: enabled
                  ? scheme.onSurface
                  : scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }

  /// 统计行：`活跃 n · 排队 n · 完成 n · 失败 n`（数字加重，分隔点用 outline）。
  Widget _buildStats(TextTheme text, ColorScheme scheme) {
    TextStyle? numberStyle() => text.bodySmall?.copyWith(
          color: scheme.onSurface,
          fontWeight: AppTypography.weightSemiBold,
          letterSpacing: AppTypography.spacingNormal,
        );
    final base = text.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      letterSpacing: AppTypography.spacingNormal,
    );
    const separator = ' · ';

    return Text.rich(
      TextSpan(
        style: base,
        children: [
          const TextSpan(text: '活跃 '),
          TextSpan(text: '${widget.active}', style: numberStyle()),
          const TextSpan(text: '$separator排队 '),
          TextSpan(text: '${widget.queued}', style: numberStyle()),
          const TextSpan(text: '$separator完成 '),
          TextSpan(text: '${widget.completed}', style: numberStyle()),
          const TextSpan(text: '$separator失败 '),
          TextSpan(text: '${widget.failed}', style: numberStyle()),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 6dp 状态点：live 时呼吸；静止时弱化。
class _LiveDot extends StatefulWidget {
  const _LiveDot({
    required this.live,
    required this.animationsEnabled,
    required this.color,
  });

  final bool live;
  final bool animationsEnabled;
  final Color color;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _sync();
  }

  @override
  void didUpdateWidget(covariant _LiveDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.live != widget.live ||
        oldWidget.animationsEnabled != widget.animationsEnabled) {
      _sync();
    }
  }

  void _sync() {
    if (widget.live && widget.animationsEnabled) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final pulse =
            widget.live && widget.animationsEnabled ? _controller.value : 1.0;
        final alpha = widget.live ? 0.55 + 0.45 * pulse : 1.0;
        return Container(
          width: AppSpacing.sm,
          height: AppSpacing.sm,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: alpha),
            shape: BoxShape.circle,
            boxShadow: widget.live
                ? [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.35 * pulse),
                      blurRadius: AppSpacing.sm,
                    ),
                  ]
                : null,
          ),
        );
      },
    );
  }
}

/// 平滑速度波形（Catmull-Rom → 三次贝塞尔），面积淡填充 + 发丝基线。
class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.samples,
    required this.lineColor,
    required this.fillColor,
    required this.baselineColor,
  });

  final List<double> samples;
  final Color lineColor;
  final Color fillColor;
  final Color baselineColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final baselineY = size.height - 1;
    canvas.drawLine(
      Offset(0, baselineY),
      Offset(size.width, baselineY),
      Paint()
        ..color = baselineColor
        ..strokeWidth = 1,
    );
    if (samples.isEmpty) return;

    var maxSample = 1.0;
    for (final value in samples) {
      if (value > maxSample) maxSample = value;
    }

    const padding = 4.0;
    final usableHeight = math.max(1.0, size.height - padding * 2);
    double xAt(int i) =>
        samples.length <= 1 ? 0 : i * size.width / (samples.length - 1);
    double yAt(double value) =>
        size.height -
        padding -
        (value / maxSample).clamp(0.0, 1.0) * usableHeight;

    final points = [
      for (var i = 0; i < samples.length; i++) Offset(xAt(i), yAt(samples[i])),
    ];

    final line = Path()..moveTo(points.first.dx, points.first.dy);
    const tension = 0.18;
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = i > 0 ? points[i - 1] : points[i];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = i + 2 < points.length ? points[i + 2] : points[i + 1];
      final c1 = Offset(
        p1.dx + (p2.dx - p0.dx) * tension,
        p1.dy + (p2.dy - p0.dy) * tension,
      );
      final c2 = Offset(
        p2.dx - (p3.dx - p1.dx) * tension,
        p2.dy - (p3.dy - p1.dy) * tension,
      );
      line.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }

    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.lineColor != lineColor ||
        oldDelegate.fillColor != fillColor ||
        oldDelegate.baselineColor != baselineColor ||
        !_sameSamples(oldDelegate.samples, samples);
  }

  static bool _sameSamples(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
