import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 实时流量卡内的 60 秒双序列吞吐折线图（上行 / 下行）。
///
/// **纯 [CustomPainter] 自绘**：不引入任何图表依赖。设计契约：
///
/// * 两条序列：下载 = `scheme.primary`，上传 = `scheme.tertiary`（沿用旧进度条
///   的配色约定）；线下方低透明度面积填充；
/// * 基线网格线使用 `scheme.surfaceContainerHighest`；
/// * 单调三次插值（Fritsch–Carlson）保证曲线**永不过冲低于基线**；
/// * 上/下行**共享**同一「好看的」纵轴上限（1/2/5×10^n，下限 64 KB/s），
///   绝不把某一方向按另一方向归一化；
/// * 纵轴带**滞回**：立即增长，仅在连续 N 个更低样本后才收缩，避免轴抖动；
/// * `max == 0`（空闲）时渲染平直基线；
/// * 整图包在 `RepaintBoundary` 中，`shouldRepaint` 仅比较版本计数与纵轴上限
///   （及主题色），无变化时返回 `false`。
class ProxyTrafficChart extends StatefulWidget {
  const ProxyTrafficChart({
    super.key,
    required this.buffer,
    this.height = 96,
  });

  /// 页面持有的有界环形缓冲（上/下两路 60 样本）。
  final ProxyTrafficBuffer buffer;

  /// 图表高度。
  final double height;

  @override
  State<ProxyTrafficChart> createState() => _ProxyTrafficChartState();
}

class _ProxyTrafficChartState extends State<ProxyTrafficChart> {
  final TrafficAxisScale _scale = TrafficAxisScale();

  int _seenVersion = -1;
  int _seenReset = -1;
  double _axisMaxBps = TrafficAxisScale.minFloorBps;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant ProxyTrafficChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  /// 仅在缓冲内容/重置计数变化时推进纵轴（build 本身无副作用）。
  void _sync() {
    if (widget.buffer.resetCount != _seenReset) {
      _seenReset = widget.buffer.resetCount;
      _scale.reset();
    }
    if (widget.buffer.version != _seenVersion) {
      _seenVersion = widget.buffer.version;
      _axisMaxBps = _scale.update(widget.buffer.rawMax.toDouble());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      key: const Key('proxy-traffic-chart'),
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: ProxyTrafficChartPainter(
            up: widget.buffer.up,
            down: widget.buffer.down,
            axisMaxBps: _axisMaxBps,
            version: widget.buffer.version,
            downColor: scheme.primary,
            upColor: scheme.tertiary,
            gridColor: scheme.surfaceContainerHighest,
            capacity: widget.buffer.capacity,
          ),
        ),
      ),
    );
  }
}

/// 有界环形缓冲：上行 / 下行两路等长样本，最多 [capacity] 个（默认 60）。
///
/// [version] 每次「追加 / 清空」自增，供 `shouldRepaint` 做 O(1) 变化检测；
/// [resetCount] 仅在 [clear] 时自增，供图表重置纵轴滞回状态。
class ProxyTrafficBuffer {
  ProxyTrafficBuffer({this.capacity = defaultCapacity})
      : assert(capacity > 0, 'capacity must be positive');

  static const int defaultCapacity = 60;

  final int capacity;
  final List<int> _up = <int>[];
  final List<int> _down = <int>[];

  int _version = 0;
  int _resetCount = 0;

  int get version => _version;
  int get resetCount => _resetCount;
  int get length => _up.length;
  bool get isEmpty => _up.isEmpty;
  bool get isNotEmpty => _up.isNotEmpty;

  /// 只读快照（每次返回新列表，避免外部改动内部状态）。
  List<int> get up => List<int>.unmodifiable(_up);
  List<int> get down => List<int>.unmodifiable(_down);

  int get latestUp => _up.isEmpty ? 0 : _up.last;
  int get latestDown => _down.isEmpty ? 0 : _down.last;

  /// 两路合并后的原始最大值（未做「好看」取整 / 下限处理）。
  int get rawMax {
    var max = 0;
    for (final v in _up) {
      if (v > max) max = v;
    }
    for (final v in _down) {
      if (v > max) max = v;
    }
    return max;
  }

  /// 追加一个样本；超出 [capacity] 时丢弃最旧样本（窗口滚动）。
  void add({required int upBps, required int downBps}) {
    _up.add(upBps);
    _down.add(downBps);
    final int excess = _up.length - capacity;
    if (excess > 0) {
      _up.removeRange(0, excess);
      _down.removeRange(0, excess);
    }
    _version++;
  }

  /// 清空全部样本（断连 / 重载快照时调用）。空缓冲不产生新的版本。
  void clear() {
    if (_up.isEmpty && _down.isEmpty) return;
    _up.clear();
    _down.clear();
    _version++;
    _resetCount++;
  }
}

/// 「好看的」纵轴上限：向上取 1 / 2 / 5 × 10^n；非正值返回 0。
double niceCeiling(double value) {
  if (!value.isFinite || value <= 0) return 0;
  final int exponent = (math.log(value) / math.ln10).floor();
  final double power = math.pow(10, exponent).toDouble();
  final double mantissa = value / power;
  final double nice;
  if (mantissa <= 1) {
    nice = 1;
  } else if (mantissa <= 2) {
    nice = 2;
  } else if (mantissa <= 5) {
    nice = 5;
  } else {
    nice = 10;
  }
  return nice * power;
}

/// 带下限与滞回的共享纵轴标尺。
///
/// * [floorBps]：纵轴下限（默认 64 KB/s），小流量不会被放大到满高；
/// * 增长：目标 > 当前时**立即**跟随；
/// * 收缩：目标 < 当前时，仅在连续 [shrinkStableSamples] 个样本后才收缩，
///   避免轴在阈值附近抖动。
class TrafficAxisScale {
  TrafficAxisScale({
    this.floorBps = minFloorBps,
    this.shrinkStableSamples = 8,
  }) : assert(shrinkStableSamples >= 1, 'shrinkStableSamples must be >= 1');

  /// 纵轴下限：64 KB/s。
  static const double minFloorBps = 64 * 1024;

  final double floorBps;
  final int shrinkStableSamples;

  double _current = 0;
  bool _hasValue = false;
  int _stable = 0;

  /// 当前轴上限；尚未喂入任何数据时返回 [floorBps]。
  double get current => _hasValue ? _current : floorBps;

  /// 喂入两路合并后的原始最大值，返回本帧应使用的轴上限。
  double update(double rawMax) {
    var target = niceCeiling(rawMax);
    if (target < floorBps) target = floorBps;
    if (!_hasValue || target > _current) {
      _current = target;
      _hasValue = true;
      _stable = 0;
      return _current;
    }
    if (target < _current) {
      _stable += 1;
      if (_stable >= shrinkStableSamples) {
        _current = target;
        _stable = 0;
      }
    } else {
      _stable = 0;
    }
    return _current;
  }

  /// 重置到「尚未喂入数据」状态（缓冲清空时调用）。
  void reset() {
    _hasValue = false;
    _stable = 0;
  }
}

/// 绘制双序列面积折线图的 [CustomPainter]。
///
/// `Paint` 对象在实例内以 `late final` 字段**只创建一次**；每次 `paint` 仅新建
/// 每条序列的 `Path`（以及面积路径）。样本 ≤ 60，开销可忽略。
class ProxyTrafficChartPainter extends CustomPainter {
  ProxyTrafficChartPainter({
    required this.up,
    required this.down,
    required this.axisMaxBps,
    required this.version,
    required this.downColor,
    required this.upColor,
    required this.gridColor,
    required this.capacity,
  }) : assert(up.length == down.length, 'up/down must share length');

  final List<int> up;
  final List<int> down;
  final double axisMaxBps;
  final int version;
  final Color downColor;
  final Color upColor;
  final Color gridColor;
  final int capacity;

  static const double _lineWidth = 2;
  static const double _fillAlpha = 0.14;

  late final Paint _gridPaint = Paint()
    ..color = gridColor
    ..strokeWidth = 1
    ..style = PaintingStyle.stroke;

  late final Paint _upLinePaint = Paint()
    ..color = upColor
    ..strokeWidth = _lineWidth
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  late final Paint _downLinePaint = Paint()
    ..color = downColor
    ..strokeWidth = _lineWidth
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  late final Paint _upFillPaint = Paint()
    ..color = upColor.withValues(alpha: _fillAlpha)
    ..style = PaintingStyle.fill;

  late final Paint _downFillPaint = Paint()
    ..color = downColor.withValues(alpha: _fillAlpha)
    ..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    if (w <= 0 || h <= 0) return;

    const double pad = _lineWidth / 2;
    final double graphBottom = h - pad;
    const double graphTop = pad;
    final double graphHeight = graphBottom - graphTop;
    final double rightEdge = w - pad;

    // 基线网格。
    canvas.drawLine(
      Offset(0, graphBottom),
      Offset(w, graphBottom),
      _gridPaint,
    );

    final int n = up.length;
    if (n == 0) return;

    // 固定 60 槽位步长，样本少时从右侧生长；满窗后向左滚动。
    final double step =
        capacity <= 1 ? 0 : rightEdge / (capacity - 1);
    double xAt(int i) => rightEdge - (n - 1 - i) * step;
    double yAt(int v) {
      final double t =
          axisMaxBps <= 0 ? 0.0 : (v / axisMaxBps).clamp(0.0, 1.0);
      return graphBottom - t * graphHeight;
    }

    // 单样本：绘制两条平直横线（无过冲、无点）。
    if (n == 1) {
      canvas.drawLine(
        Offset(0, yAt(up[0])),
        Offset(rightEdge, yAt(up[0])),
        _upLinePaint,
      );
      canvas.drawLine(
        Offset(0, yAt(down[0])),
        Offset(rightEdge, yAt(down[0])),
        _downLinePaint,
      );
      return;
    }

    final List<double> xs = List<double>.generate(n, xAt);
    final List<double> ysUp = List<double>.generate(n, (i) => yAt(up[i]));
    final List<double> ysDown = List<double>.generate(n, (i) => yAt(down[i]));

    final Path upLine = _monotonePath(xs, ysUp);
    final Path downLine = _monotonePath(xs, ysDown);

    // 先面积后描线（不画点、无交互、无标题）。
    canvas.drawPath(
      _areaPath(upLine, xs.first, xs.last, graphBottom),
      _upFillPaint,
    );
    canvas.drawPath(
      _areaPath(downLine, xs.first, xs.last, graphBottom),
      _downFillPaint,
    );
    canvas.drawPath(upLine, _upLinePaint);
    canvas.drawPath(downLine, _downLinePaint);
  }

  /// 由折线路径闭合成面积路径（下探到 [bottomY]）。
  Path _areaPath(Path line, double firstX, double lastX, double bottomY) {
    return Path.from(line)
      ..lineTo(lastX, bottomY)
      ..lineTo(firstX, bottomY)
      ..close();
  }

  /// Fritsch–Carlson 单调三次 Hermite 插值；各段严格位于两端点之间（无过冲）。
  Path _monotonePath(List<double> xs, List<double> ys) {
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

    // 端点与内部切线的初始估计。
    final List<double> m = List<double>.filled(n, 0);
    m[0] = slope[0];
    m[n - 1] = slope[n - 2];
    for (var i = 1; i < n - 1; i++) {
      m[i] = (slope[i - 1] + slope[i]) / 2;
    }

    // Fritsch–Carlson 限幅，保证单调（不外推出数据范围）。
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
      final double c1x = xs[i] + h / 3;
      final double c1y = ys[i] + m[i] * h / 3;
      final double c2x = xs[i + 1] - h / 3;
      final double c2y = ys[i + 1] - m[i + 1] * h / 3;
      path.cubicTo(c1x, c1y, c2x, c2y, xs[i + 1], ys[i + 1]);
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant ProxyTrafficChartPainter oldDelegate) {
    return oldDelegate.version != version ||
        oldDelegate.axisMaxBps != axisMaxBps ||
        oldDelegate.capacity != capacity ||
        oldDelegate.upColor != upColor ||
        oldDelegate.downColor != downColor ||
        oldDelegate.gridColor != gridColor;
  }
}
