import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// 点阵 logo 的单个点亮度。`#` 亮、`o` 强调、`+` 半亮、`.` 灭。
enum _DotKind { off, on, mid, hi }

_DotKind _kindOf(String ch) => switch (ch) {
      '#' => _DotKind.on,
      'o' => _DotKind.hi,
      '+' => _DotKind.mid,
      _ => _DotKind.off,
    };

double _litOf(_DotKind kind) => switch (kind) {
      _DotKind.on || _DotKind.hi => 1,
      _DotKind.mid => 0.45,
      _DotKind.off => 0,
    };

double _baseAlpha(_DotKind kind, double vignette) => switch (kind) {
      _DotKind.on => 0.92,
      _DotKind.hi => 1,
      _DotKind.mid => 0.40,
      _DotKind.off => 0.09 * vignette,
    };

double _easeOutCubic(double x) {
  final double y = 1 - x;
  return 1 - y * y * y;
}

double _easeInOutCubic(double x) {
  if (x < 0.5) return 4 * x * x * x;
  final double y = -2 * x + 2;
  return 1 - (y * y * y) / 2;
}

/// 回弹缓出：0 → ≈1.1 → 1。
double _backOut(double x) {
  const double c1 = 1.70158;
  const double c3 = c1 + 1;
  final double y = x - 1;
  return 1 + c3 * y * y * y + c1 * y * y;
}

double _smoothStep(double x) => x * x * (3 - 2 * x);

// ── 时间轴（毫秒）。与 FluxDown 的 DotMatrixMotion 保持一致 ──
const double _introSpreadMs = 380;
const double _introLitDelayMs = 180;
const double _introDotMs = 440;
const int _introEndMs = 1000;

const int _sweepFirstRestMs = 900;
const int _sweepMs = 1800;
const int _cycleMs = 6400;
const double _sweepHalfWidth = 0.24;

const double _pressInMs = 140;
const double _pressOutMs = 360;
const int _rippleMs = 760;
const int _maxRipples = 3;
const double _lensSteps = 3.2;

double _sweepProgress(int sinceIntro) {
  final int t = sinceIntro - _introEndMs - _sweepFirstRestMs;
  if (t < 0) return double.nan;
  final int phase = t % _cycleMs;
  if (phase >= _sweepMs) return double.nan;
  return phase / _sweepMs;
}

/// 对角坐标 [u] ∈ [0,1] 处的扫光强度：紧支撑 smoothstep 光带。
double _sweepBand(double u, double progress) {
  if (progress.isNaN) return 0;
  final double center =
      -_sweepHalfWidth + (1 + 2 * _sweepHalfWidth) * _easeInOutCubic(progress);
  final double x = 1 - (u - center).abs() / _sweepHalfWidth;
  if (x <= 0) return 0;
  return _smoothStep(x);
}

/// 一个点的静态几何与入场参数（构建时算一次，绘制时只读）。
class _DotCell {
  const _DotCell({
    required this.kind,
    required this.x,
    required this.y,
    required this.vignette,
    required this.diag,
    required this.introDelay,
  });

  final _DotKind kind;
  final double x;
  final double y;
  final double vignette;
  final double diag;
  final double introDelay;

  double get lit => _litOf(kind);
}

class _Ripple {
  const _Ripple(this.at, this.start);

  final Offset at;
  final int start;
}

/// 只用于触发重绘的 ChangeNotifier（不参与 Widget 重组）。
class _RepaintNotifier extends ChangeNotifier {
  void bump() => notifyListeners();
}

/// 点阵图形：单 Canvas 逐点绘制，入场回弹 / 待机斜扫 / 按住透镜 / 轻点涟漪。
///
/// 与 FluxDown 的 `DotMatrix` 同款动效，但颜色全部取自 GStore 主题：
/// 灭点 `onSurface` α 0.09（向四角渐隐）、亮点 `onSurface`、强调点 `primary`。
/// 所有动画阶段静止时 Ticker 会休眠到下一次扫光，避免常驻 60fps。
class DotMatrix extends StatefulWidget {
  const DotMatrix({
    super.key,
    required this.rows,
    this.dot = 6,
    this.gap = 3,
    this.animate = true,
    this.semanticLabel,
  });

  /// 点阵文本行：`#` 亮、`o` 强调、`+` 半亮、`.` 灭。
  final List<String> rows;
  final double dot;
  final double gap;
  final bool animate;

  /// 非空时作为图片语义；为空时视为装饰并清除语义。
  final String? semanticLabel;

  @override
  State<DotMatrix> createState() => _DotMatrixState();
}

class _DotMatrixState extends State<DotMatrix>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _RepaintNotifier _repaint = _RepaintNotifier();
  final List<_Ripple> _ripples = <_Ripple>[];

  Timer? _wakeTimer;
  int _now = 0;
  int _timeBaseMs = 0;
  final int _introStart = 0;
  bool _live = true;
  bool _reduceMotion = false;

  bool _pressed = false;
  bool _tap = true;
  Offset _touch = Offset.zero;
  Offset _downAt = Offset.zero;
  int _pressAt = -1;
  int _releaseAt = -1;
  double _releaseLevel = 0;
  int? _hoverCell;

  List<_DotCell> _cells = const <_DotCell>[];
  int _cols = 0;
  int _rowCount = 0;
  double _width = 0;
  double _height = 0;
  double _step = 0;
  double _radius = 0;
  double _maxDist = 1;

  Color _ink = const Color(0xFF000000);
  Color _hi = const Color(0xFF000000);
  Color _glow = const Color(0x00000000);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _rebuildGeometry();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ColorScheme scheme = Theme.of(context).colorScheme;
    _ink = scheme.onSurface;
    _hi = scheme.primary;
    _glow = scheme.primary.withValues(alpha: 0.38);

    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _live = widget.animate && !_reduceMotion;
    if (_live) {
      _ensureTicker();
    } else {
      _sleepForever();
    }
  }

  @override
  void didUpdateWidget(covariant DotMatrix oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rows != widget.rows ||
        oldWidget.dot != widget.dot ||
        oldWidget.gap != widget.gap) {
      _rebuildGeometry();
      _bump();
    }
    if (oldWidget.animate != widget.animate) {
      _live = widget.animate && !_reduceMotion;
      if (_live) {
        _ensureTicker();
      } else {
        _sleepForever();
      }
    }
  }

  @override
  void dispose() {
    _wakeTimer?.cancel();
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _rebuildGeometry() {
    final List<String> rows = widget.rows;
    if (rows.isEmpty) {
      _cells = const <_DotCell>[];
      _cols = 0;
      _rowCount = 0;
      _width = 0;
      _height = 0;
      return;
    }
    final int cols = rows.fold<int>(
      0,
      (int m, String row) => math.max(m, row.length),
    );
    final int nRows = rows.length;
    final double step = widget.dot + widget.gap;
    final double radius = widget.dot / 2;
    final double midX = (cols - 1) * step / 2 + radius;
    final double midY = (nRows - 1) * step / 2 + radius;
    final double maxDist = math.max(math.sqrt(midX * midX + midY * midY), 1);
    final double spanX = math.max(cols - 1, 1).toDouble();
    final double spanY = math.max(nRows - 1, 1).toDouble();

    final List<_DotCell> cells = <_DotCell>[];
    for (int r = 0; r < nRows; r++) {
      final String line = rows[r];
      for (int c = 0; c < cols; c++) {
        final String ch = c < line.length ? line[c] : '.';
        final _DotKind kind = _kindOf(ch);
        final double x = c * step + radius;
        final double y = r * step + radius;
        final double dx = x - midX;
        final double dy = y - midY;
        final double distNorm =
            math.min(math.sqrt(dx * dx + dy * dy) / maxDist, 1.0);
        cells.add(_DotCell(
          kind: kind,
          x: x,
          y: y,
          vignette: 1 - 0.55 * distNorm * distNorm,
          diag: 0.62 * (c / spanX) + 0.38 * (r / spanY),
          introDelay: (_litOf(kind) > 0 ? _introLitDelayMs : 0) +
              distNorm * _introSpreadMs,
        ));
      }
    }

    _cells = cells;
    _cols = cols;
    _rowCount = nRows;
    _step = step;
    _radius = radius;
    _maxDist = maxDist;
    _width = widget.dot * cols + widget.gap * (cols - 1);
    _height = widget.dot * nRows + widget.gap * (nRows - 1);
  }

  void _bump() {
    if (!_live) _now = _introEndMs + 1;
    _repaint.bump();
  }

  void _ensureTicker() {
    if (!_live || !mounted) return;
    _wakeTimer?.cancel();
    _wakeTimer = null;
    if (!_ticker.isActive) {
      _timeBaseMs = _now;
      _ticker.start();
    }
  }

  void _sleepForever() {
    _wakeTimer?.cancel();
    _wakeTimer = null;
    if (_ticker.isActive) _ticker.stop();
    _now = _introEndMs + 1;
    _repaint.bump();
  }

  void _sleepUntil(int ms) {
    if (_ticker.isActive) {
      _ticker.stop();
      _timeBaseMs = _now;
    }
    _wakeTimer?.cancel();
    if (ms <= 0) {
      _ensureTicker();
      return;
    }
    _wakeTimer = Timer(Duration(milliseconds: ms), _ensureTicker);
  }

  void _onTick(Duration elapsed) {
    _now = _timeBaseMs + elapsed.inMilliseconds;
    _repaint.bump();
    final int next = _nextChangeAt(_now);
    if (next > _now) {
      _sleepUntil(next - _now);
    }
  }

  int _nextChangeAt(int now) {
    if (!_live) return now;
    if (now - _introStart < _introEndMs) return now;
    if (_pressed || _lens(now) > 0) return now;
    for (final _Ripple ripple in _ripples) {
      if (_rippleProgress(ripple, now) >= 0) return now;
    }
    final int firstSweep = _introStart + _introEndMs + _sweepFirstRestMs;
    if (now < firstSweep) return firstSweep;
    final int phase = (now - firstSweep) % _cycleMs;
    return phase < _sweepMs ? now : now + (_cycleMs - phase);
  }

  double _lens(int now) {
    if (_pressed) {
      if (_pressAt < 0) return 0;
      final double p = ((now - _pressAt) / _pressInMs).clamp(0.0, 1.0);
      return _easeOutCubic(p);
    }
    if (_releaseAt < 0) return 0;
    final double p = ((now - _releaseAt) / _pressOutMs).clamp(0.0, 1.0);
    return _releaseLevel * (1 - _easeOutCubic(p));
  }

  double _rippleProgress(_Ripple ripple, int now) {
    final double p = (now - ripple.start) / _rippleMs;
    return (p < 0 || p >= 1) ? -1 : p;
  }

  int? _cellAt(Offset local) {
    if (_step <= 0 || _cols == 0 || _rowCount == 0) return null;
    final int col = (local.dx / _step).floor();
    final int row = (local.dy / _step).floor();
    if (col < 0 || col >= _cols || row < 0 || row >= _rowCount) return null;
    return row * _cols + col;
  }

  bool _isLit(int? cell) {
    if (cell == null || cell < 0 || cell >= _cells.length) return false;
    return _cells[cell].lit > 0;
  }

  Offset _localOf(Offset global) {
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      return renderObject.globalToLocal(global);
    }
    return global;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!_live) return;
    final Offset local = _localOf(event.position);
    _pressed = true;
    _tap = true;
    _touch = local;
    _downAt = local;
    _pressAt = _now;
    _releaseAt = -1;
    _hoverCell = _cellAt(local);
    _ensureTicker();
    _bump();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_live || !_pressed) return;
    final Offset local = _localOf(event.position);
    _touch = local;
    if ((local - _downAt).distance > kTouchSlop) _tap = false;
    final int? cell = _cellAt(local);
    if (cell != _hoverCell) {
      _hoverCell = cell;
      if (_isLit(cell)) unawaited(HapticFeedback.selectionClick());
    }
    _bump();
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_live || !_pressed) return;
    _touch = _localOf(event.position);
    if (_tap) {
      _ripples.add(_Ripple(_touch, _now));
      if (_ripples.length > _maxRipples) _ripples.removeAt(0);
      unawaited(HapticFeedback.lightImpact());
    }
    _pressed = false;
    _releaseLevel = 0;
    _releaseAt = _now;
    _hoverCell = null;
    _ensureTicker();
    _bump();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (!_pressed) return;
    _pressed = false;
    _releaseLevel = 0;
    _releaseAt = _now;
    _hoverCell = null;
    _tap = false;
    _bump();
  }

  @override
  Widget build(BuildContext context) {
    if (_cells.isEmpty) return const SizedBox.shrink();

    Widget content = RepaintBoundary(
      child: CustomPaint(
        size: Size(_width, _height),
        painter: _DotMatrixPainter(
          state: this,
          repaint: _repaint,
          ink: _ink,
          hi: _hi,
          glow: _glow,
        ),
      ),
    );

    content = Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: content,
    );

    final String? label = widget.semanticLabel;
    if (label != null && label.isNotEmpty) {
      return Semantics(label: label, image: true, child: content);
    }
    return ExcludeSemantics(child: content);
  }
}

class _DotMatrixPainter extends CustomPainter {
  _DotMatrixPainter({
    required this.state,
    required Listenable repaint,
    required this.ink,
    required this.hi,
    required this.glow,
  }) : super(repaint: repaint);

  final _DotMatrixState state;
  final Color ink;
  final Color hi;
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final int now = state._live ? state._now : _introEndMs + 1;
    final double introElapsed = (now - state._introStart).toDouble();
    final double sweep =
        state._live ? _sweepProgress(now - state._introStart) : double.nan;
    final double lens = state._live ? state._lens(now) : 0;
    final Offset touch = state._touch;
    final double lensRadius = _lensSteps * state._step;
    final double lensR2 = lensRadius * lensRadius;
    final double rippleReach = state._maxDist * 2.1;
    final double ringWidth = state._step * 1.3;
    final double radius = state._radius;

    final Paint fill = Paint()..isAntiAlias = true;
    final Paint glowPaint = Paint()
      ..isAntiAlias = true
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    for (final _DotCell cell in state._cells) {
      final _DotKind kind = cell.kind;
      final double lit = cell.lit;
      double alpha = _baseAlpha(kind, cell.vignette);
      double tint = kind == _DotKind.hi ? 1 : 0;
      double scale = 1;

      // 入场：灭点自中心向外回弹铺开，亮点晚一拍“落笔”。
      final double introProgress =
          ((introElapsed - cell.introDelay) / _introDotMs).clamp(0.0, 1.0);
      if (introProgress < 1) {
        scale *= _backOut(introProgress);
        alpha *= _easeOutCubic(introProgress);
      }

      // 待机斜扫：经过的亮点放大、染强调色，灭点泛起淡淡一线。
      final double band = _sweepBand(cell.diag, sweep);
      if (band > 0) {
        alpha += band * (0.10 * (1 - lit) + (1 - alpha) * lit);
        tint += band * (0.35 + 0.5 * lit);
        scale *= 1 + 0.16 * band * lit;
      }

      // 按住透镜：附近点放大、外推、染强调色。
      double offsetX = 0;
      double offsetY = 0;
      if (lens > 0) {
        final double dx = cell.x - touch.dx;
        final double dy = cell.y - touch.dy;
        final double d2 = (dx * dx + dy * dy) / lensR2;
        if (d2 < 1) {
          final double f0 = 1 - d2;
          final double f = f0 * f0 * lens;
          scale *= 1 + 0.5 * f;
          alpha += f * (0.28 * (1 - lit) + (1 - alpha) * lit);
          tint += 0.55 * f;
          final double dist = math.sqrt(dx * dx + dy * dy);
          if (dist > 0.5) {
            final double push = 0.32 * state._step * f * math.sqrt(d2) / dist;
            offsetX = dx * push;
            offsetY = dy * push;
          }
        }
      }

      // 轻点涟漪：最多 3 圈，760ms 扩散。
      for (final _Ripple ripple in state._ripples) {
        final double p = state._rippleProgress(ripple, now);
        if (p < 0) continue;
        final double dx = cell.x - ripple.at.dx;
        final double dy = cell.y - ripple.at.dy;
        final double x = 1 -
            (math.sqrt(dx * dx + dy * dy) - p * rippleReach).abs() / ringWidth;
        if (x <= 0) continue;
        final double g = _smoothStep(x) * (1 - p);
        scale *= 1 + 0.45 * g;
        alpha += g * (0.35 * (1 - lit) + (1 - alpha) * lit);
        tint += 0.8 * g;
      }

      final double px = cell.x + offsetX;
      final double py = cell.y + offsetY;
      final double tintClamped = tint.clamp(0.0, 1.0);
      final double alphaClamped = alpha.clamp(0.0, 1.0);

      if (tintClamped > 0.01) {
        final double glowAlpha =
            (tintClamped * (0.7 + 0.3 * band) * introProgress.clamp(0.0, 1.0))
                .clamp(0.0, 1.0);
        if (glowAlpha > 0.01) {
          glowPaint.color = glow.withValues(alpha: glow.a * glowAlpha);
          canvas.drawCircle(Offset(px, py), radius + 8, glowPaint);
        }
      }

      final Color color =
          Color.lerp(ink, hi, tintClamped)!.withValues(alpha: alphaClamped);
      fill.color = color;
      canvas.drawCircle(Offset(px, py), radius * scale, fill);
    }
  }

  @override
  bool shouldRepaint(covariant _DotMatrixPainter oldDelegate) =>
      oldDelegate.ink != ink ||
      oldDelegate.hi != hi ||
      oldDelegate.glow != glow ||
      oldDelegate.state != state;
}
