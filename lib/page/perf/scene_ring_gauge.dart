/// Scene 风格**环形仪表**（性能监控页本地组件）。
///
/// 复刻 Scene `CpuChartView` / `RamChartView` 的招牌圆环：从顶部（-90°）起、
/// 顺时针扫过 `value/max` 比例的一整圈（[SceneRingPainter]），环内叠加
/// 数值 / 标签 / 副标签文字。
///
/// ## 契约
/// * **颜色**：环色由调用方经 [tierColor] 传入（性能页用
///   [ScenePerfStyle.cpuColor] / [ramColor] / [temperatureColor] 从集中阈值
///   `lib/core/perf/scene_thresholds.dart` 映射主题角色 + Scene 强调色）；
///   轨道色取 `scheme.surfaceContainerHighest`；文字取 `textTheme` /
///   `onSurfaceVariant`。**本文件无硬编码颜色**（AGENTS.md）。
/// * **降级**：`value` 为 `null` 由调用方传 `0`；`NaN` / `±Infinity` / 越界
///   一律钳制，**绝不抛异常**（无原生模块 / 无数据时照常渲染空环）。
/// * **量纲**：[value] 与 [max] 成对使用——百分比用 `max: 100`（默认），
///   0..1 比率用 `max: 1`。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:gstore/core/design/design_tokens.dart';

import 'scene_perf_style.dart';

/// Scene 风格环形仪表。
class SceneRingGauge extends StatelessWidget {
  const SceneRingGauge({
    super.key,
    required this.value,
    required this.tierColor,
    this.max = 100,
    this.label,
    this.sublabel,
    this.valueText,
    this.size = ScenePerfStyle.ringSize,
    this.strokeWidth = ScenePerfStyle.ringStrokeWidth,
  });

  /// 当前值（与 [max] 成对：百分比用 `max: 100`，0..1 比率用 `max: 1`）。
  final double value;

  /// 满环对应值（必须 `> 0`；`<= 0` / 非有限时按空环处理）。
  final double max;

  /// 进度弧颜色（阈值档位色；由调用方提供）。
  final Color tierColor;

  /// 环内主标签（如「内存」）。
  final String? label;

  /// 环内副标签（如「3.1 / 8.0 GB」）。
  final String? sublabel;

  /// 环内数值文字（如 `42%`）；`null` 时不显示。
  final String? valueText;

  /// 组件边长（正方形）。
  final double size;

  /// 弧线粗细。
  final double strokeWidth;

  /// 归一化进度（`0..1`；非法 / 未满 [max] 情况一律安全钳制）。
  double get fraction {
    if (!value.isFinite || !max.isFinite || max <= 0) return 0;
    return (value / max).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Positioned.fill(
              child: CustomPaint(
                painter: SceneRingPainter(
                  fraction: fraction,
                  color: tierColor,
                  trackColor: scheme.surfaceContainerHighest,
                  strokeWidth: strokeWidth,
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (valueText != null)
                  Text(
                    valueText!,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: tierColor,
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                if (label != null)
                  Text(
                    label!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (sublabel != null)
                  Text(
                    sublabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// [SceneRingGauge] 的绘制器：Scene 招牌整圆环（顶部起、顺时针扫过 [fraction]）。
class SceneRingPainter extends CustomPainter {
  SceneRingPainter({
    required this.fraction,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  /// 归一化进度（`0..1`）。
  final double fraction;

  /// 进度弧颜色。
  final Color color;

  /// 轨道颜色。
  final Color trackColor;

  /// 弧线粗细。
  final double strokeWidth;

  /// 起始角：正上方（-90°）。
  static const double _startAngle = -math.pi / 2;

  /// 整圈弧度。
  static const double _fullSweep = 2 * math.pi;

  @override
  void paint(Canvas canvas, Size size) {
    final double side = math.min(size.width, size.height);
    if (side <= 0 || strokeWidth <= 0) return;

    final double radius = (side - strokeWidth) / 2;
    if (radius <= 0) return;

    final Offset center = size.center(Offset.zero);
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    final Paint track = Paint()
      ..color = trackColor
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawArc(rect, _startAngle, _fullSweep, false, track);

    final double clamped = fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0;
    if (clamped <= 0) return;

    final Paint progress = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawArc(rect, _startAngle, _fullSweep * clamped, false, progress);
  }

  @override
  bool shouldRepaint(covariant SceneRingPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
