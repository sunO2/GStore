/// 与数据无关的折线 / 仪表盘自绘组件（**零第三方图表依赖**）。
///
/// 设计契约（AGENTS.md / theme-usage-guide.md）：
/// * 所有颜色来自 [ColorScheme]（调用方传入，缺省取 `scheme.primary`）；
/// * 仅使用设计令牌控制高度 / 半径 / 内边距，无硬编码颜色 / 字号；
/// * 全部为 [CustomPainter] 自绘，`shouldRepaint` 按数据内容与样式比较，
///   数据不变时返回 `false`，避免无谓重绘。
///
/// 主要导出：
/// * [LineChart]：折线 sparkline，支持面积渐变、网格线、当前值标点；
/// * [GaugeChart]：百分比弧形仪表盘（nice-to-have）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_spacing.dart';

/// 自绘折线图（sparkline）。
///
/// 特性：
/// * [values] 为按时间升序的样本序列；空序列绘制底部基线；
/// * `NaN` / `±Infinity` 样本会被**跳过**（遇无效值断开线段）；
/// * 单点绘制一条贯穿的平直横线；全部等值绘制居中平线；
/// * 单调三次（Fritsch–Carlson）平滑，曲线永不过冲出数据范围；
/// * 抗锯齿、圆角端点；可选线下方渐变填充、水平网格线、末端标点。
class LineChart extends StatelessWidget {
  const LineChart({
    super.key,
    required this.values,
    this.minY,
    this.maxY,
    this.color,
    this.fill = true,
    this.strokeWidth = 2,
    this.gridLines = 0,
    this.showMarker = true,
    this.height = AppSpacing.massive,
  });

  /// 按时间升序的样本序列。
  final List<double> values;

  /// 纵轴下限；为 `null` 时由数据自动推导。
  final double? minY;

  /// 纵轴上限；为 `null` 时由数据自动推导。
  final double? maxY;

  /// 线条 / 填充 / 标点颜色；为 `null` 时取 `scheme.primary`。
  final Color? color;

  /// 是否绘制线下方渐变填充。
  final bool fill;

  /// 线宽。
  final double strokeWidth;

  /// 水平网格线条数（`0` 为不绘制）。
  final int gridLines;

  /// 是否在末端样本处绘制标点。
  final bool showMarker;

  /// 图表高度。
  final double height;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: LineChartPainter(
            values: values,
            minY: minY,
            maxY: maxY,
            color: color ?? scheme.primary,
            gridColor: scheme.surfaceContainerHighest,
            fill: fill,
            strokeWidth: strokeWidth,
            gridLines: gridLines,
            showMarker: showMarker,
          ),
        ),
      ),
    );
  }
}

/// [LineChart] 的绘制器。
class LineChartPainter extends CustomPainter {
  LineChartPainter({
    required this.values,
    required this.minY,
    required this.maxY,
    required this.color,
    required this.gridColor,
    required this.fill,
    required this.strokeWidth,
    required this.gridLines,
    required this.showMarker,
  });

  final List<double> values;
  final double? minY;
  final double? maxY;
  final Color color;
  final Color gridColor;
  final bool fill;
  final double strokeWidth;
  final int gridLines;
  final bool showMarker;

  static const double _markerRadius = 2.5;
  static const double _markerHaloScale = 2.2;
  static const double _fillTopAlpha = 0.28;

  late final Paint _linePaint = Paint()
    ..color = color
    ..strokeWidth = strokeWidth
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  late final Paint _gridPaint = Paint()
    ..color = gridColor
    ..strokeWidth = 1
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true;

  late final Paint _markerPaint = Paint()
    ..color = color
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;

  late final Paint _markerHaloPaint = Paint()
    ..color = color.withValues(alpha: 0.22)
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    if (w <= 0 || h <= 0) return;

    final double pad = math.max(strokeWidth / 2, _markerRadius);
    final Rect area = Rect.fromLTRB(pad, pad, w - pad, h - pad);
    if (area.width <= 0 || area.height <= 0) return;

    _paintGrid(canvas, area);

    final int n = values.length;
    if (n == 0) {
      _paintBaseline(canvas, area);
      return;
    }

    // 有限样本边界（NaN / Infinity 视为无效，跳过）。
    double dataMin = double.infinity;
    double dataMax = double.negativeInfinity;
    var finiteCount = 0;
    for (final double v in values) {
      if (!v.isFinite) continue;
      finiteCount++;
      if (v < dataMin) dataMin = v;
      if (v > dataMax) dataMax = v;
    }
    if (finiteCount == 0) {
      _paintBaseline(canvas, area);
      return;
    }

    final double lo = minY ?? dataMin;
    final double hi = maxY ?? dataMax;
    final bool flat = !(hi > lo);
    final double span = flat ? 0 : (hi - lo);

    double yAt(double v) {
      if (flat) return area.center.dy;
      final double t = ((v - lo) / span).clamp(0.0, 1.0);
      return area.bottom - t * area.height;
    }

    double xAt(int i) =>
        n <= 1 ? area.center.dx : area.left + i / (n - 1) * area.width;

    // 单点：贯穿整宽的平直横线（避免只剩一个不可见的小点）。
    if (n == 1) {
      final double y = yAt(values[0]);
      canvas.drawLine(Offset(area.left, y), Offset(area.right, y), _linePaint);
      _paintMarker(canvas, Offset(area.right, y));
      return;
    }

    // 将连续有效样本切成线段（无效值断开）。
    final List<List<int>> segments = <List<int>>[];
    List<int>? current;
    for (var i = 0; i < n; i++) {
      if (values[i].isFinite) {
        current ??= <int>[];
        current.add(i);
      } else if (current != null) {
        segments.add(current);
        current = null;
      }
    }
    if (current != null) segments.add(current);

    Offset? lastFinite;
    for (final List<int> seg in segments) {
      final List<double> xs = <double>[for (final int i in seg) xAt(i)];
      final List<double> ys = <double>[for (final int i in seg) yAt(values[i])];

      if (seg.length == 1) {
        lastFinite = Offset(xs[0], ys[0]);
        _paintMarker(canvas, lastFinite);
        continue;
      }

      final Path line = _smoothPath(xs, ys);
      if (fill) {
        final Path filled = Path.from(line)
          ..lineTo(xs.last, area.bottom)
          ..lineTo(xs.first, area.bottom)
          ..close();
        canvas.drawPath(filled, _fillPaint(area));
      }
      canvas.drawPath(line, _linePaint);
      lastFinite = Offset(xs.last, ys.last);
    }

    if (showMarker && lastFinite != null) {
      _paintMarker(canvas, lastFinite);
    }
  }

  void _paintGrid(Canvas canvas, Rect area) {
    if (gridLines <= 0) return;
    for (var i = 0; i < gridLines; i++) {
      final double t = gridLines == 1 ? 0.0 : i / (gridLines - 1);
      final double y = area.bottom - t * area.height;
      canvas.drawLine(Offset(area.left, y), Offset(area.right, y), _gridPaint);
    }
  }

  void _paintBaseline(Canvas canvas, Rect area) {
    canvas.drawLine(
      Offset(area.left, area.bottom),
      Offset(area.right, area.bottom),
      _gridPaint,
    );
  }

  void _paintMarker(Canvas canvas, Offset point) {
    if (!showMarker) return;
    canvas.drawCircle(
      point,
      _markerRadius * _markerHaloScale,
      _markerHaloPaint,
    );
    canvas.drawCircle(point, _markerRadius, _markerPaint);
  }

  Paint _fillPaint(Rect area) {
    return Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          color.withValues(alpha: _fillTopAlpha),
          color.withValues(alpha: 0),
        ],
      ).createShader(area)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
  }

  /// Fritsch–Carlson 单调三次 Hermite 插值；各段严格位于两端点之间（无过冲）。
  Path _smoothPath(List<double> xs, List<double> ys) {
    final int n = xs.length;
    final Path path = Path();
    if (n == 0) return path;
    if (n == 1) {
      path.moveTo(xs[0], ys[0]);
      return path;
    }

    final List<double> dx = List<double>.filled(n - 1, 0);
    final List<double> slope = List<double>.filled(n - 1, 0);
    for (var i = 0; i < n - 1; i++) {
      dx[i] = xs[i + 1] - xs[i];
      slope[i] = dx[i] == 0 ? 0 : (ys[i + 1] - ys[i]) / dx[i];
    }

    final List<double> m = List<double>.filled(n, 0);
    m[0] = slope[0];
    m[n - 1] = slope[n - 2];
    for (var i = 1; i < n - 1; i++) {
      m[i] = (slope[i - 1] + slope[i]) / 2;
    }

    for (var i = 0; i < n - 1; i++) {
      if (slope[i] == 0) {
        m[i] = 0;
        m[i + 1] = 0;
        continue;
      }
      final double a = m[i] / slope[i];
      final double b = m[i + 1] / slope[i];
      final double s = a * a + b * b;
      if (s > 9) {
        final double tau = 3 / math.sqrt(s);
        m[i] = tau * a * slope[i];
        m[i + 1] = tau * b * slope[i];
      }
    }

    path.moveTo(xs[0], ys[0]);
    for (var i = 0; i < n - 1; i++) {
      final double h = dx[i];
      path.cubicTo(
        xs[i] + h / 3,
        ys[i] + m[i] * h / 3,
        xs[i + 1] - h / 3,
        ys[i + 1] - m[i + 1] * h / 3,
        xs[i + 1],
        ys[i + 1],
      );
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant LineChartPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.minY != minY ||
        oldDelegate.maxY != maxY ||
        oldDelegate.fill != fill ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.gridLines != gridLines ||
        oldDelegate.showMarker != showMarker ||
        _listChanged(oldDelegate.values, values);
  }

  static bool _listChanged(List<double> a, List<double> b) {
    if (identical(a, b)) return false;
    if (a.length != b.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return true;
    }
    return false;
  }
}

/// 自绘弧形仪表盘（百分比指标）。
///
/// [value] 取 `0..100`（越界钳制）。轨道色来自 `scheme.surfaceContainerHighest`，
/// 进度色由 [color] 指定（缺省 `scheme.primary`）。指示弧从 210° 起、扫过 240°。
class GaugeChart extends StatelessWidget {
  const GaugeChart({
    super.key,
    required this.value,
    this.color,
    this.size = 72,
    this.strokeWidth = 8,
  });

  /// 百分比数值（`0..100`）。
  final double value;

  /// 进度弧颜色；为 `null` 时取 `scheme.primary`。
  final Color? color;

  /// 组件边长（正方形）。
  final double size;

  /// 弧线粗细。
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: GaugeChartPainter(
            value: value,
            color: color ?? scheme.primary,
            trackColor: scheme.surfaceContainerHighest,
            strokeWidth: strokeWidth,
          ),
        ),
      ),
    );
  }
}

/// [GaugeChart] 的绘制器。
class GaugeChartPainter extends CustomPainter {
  GaugeChartPainter({
    required this.value,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double value;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  /// 起始角（弧度，从正右方顺时针）：210°。
  static const double _startAngle = 210 * math.pi / 180;

  /// 扫过角（弧度）：240°。
  static const double _sweepAngle = 240 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final double side = math.min(size.width, size.height);
    if (side <= 0) return;

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

    final Paint progress = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    canvas.drawArc(rect, _startAngle, _sweepAngle, false, track);

    final double clamped = value.isFinite ? value.clamp(0.0, 100.0) : 0.0;
    if (clamped > 0) {
      canvas.drawArc(
        rect,
        _startAngle,
        _sweepAngle * (clamped / 100.0),
        false,
        progress,
      );
    }
  }

  @override
  bool shouldRepaint(covariant GaugeChartPainter oldDelegate) {
    return oldDelegate.value != value ||
        oldDelegate.color != color ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
