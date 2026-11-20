import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'package:gstore/core/theme/app_theme_config.dart';

/// 主题切换的「圆形揭示」过渡（等价 Android 原生 createCircularReveal）。
///
/// 做法：切换**前**把当前界面截成一张图 → 立即应用新主题（新界面在下面渲染）
/// → 在覆盖层上画旧截图，并用 even-odd 路径挖出一个以点击点为圆心、不断变大
/// 的圆洞，从而露出新主题；边缘叠加多圈错峰淡出的水波光环与一次中心高光。
///
/// 为什么用截图而不是给新界面做裁剪：Flutter 换主题是整棵树重建，旧界面在
/// 状态变更后已经不存在；只有截图能把「旧主题」保留到过渡结束。动画期间只
/// 画一张全屏纹理 + 裁剪路径 + 若干圆环，光栅开销远小于同时渲染两套 UI。
///
/// 使用方式（仅 UI 入口需要）：
/// ```dart
/// await ThemeReveal.instance.run(
///   origin: tapGlobalPosition,
///   apply: () => notifier.setThemeMode(mode),
/// );
/// ```
class ThemeReveal extends ChangeNotifier {
  ThemeReveal._();

  static final ThemeReveal instance = ThemeReveal._();

  /// 由 [ThemeRevealHost] 内的 RepaintBoundary 使用，用于截取切换前画面。
  final GlobalKey captureKey = GlobalKey(debugLabel: 'theme-reveal-capture');

  /// 水波总时长；扩散半径在这段时间内覆盖到最远屏幕角。
  static const Duration duration = Duration(milliseconds: 480);

  AnimationController? _controller;

  ui.Image? _image;
  Offset? _origin;
  bool _busy = false;
  bool _disposed = false;

  /// 供测试注入截图实现（避免依赖真实渲染管线）。
  @visibleForTesting
  Future<ui.Image?> Function(RenderRepaintBoundary boundary)? captureOverride;

  /// 换主题后等待重建稳定的上限；测试可设为 [Duration.zero] 跳过。
  @visibleForTesting
  Duration settleTimeout = const Duration(milliseconds: 320);

  /// 过渡进行中的旧截图；为 null 表示覆盖层应隐藏。
  ui.Image? get image => _image;

  /// 扩散圆心（全局逻辑坐标）。
  Offset get origin => _origin ?? Offset.zero;

  /// 驱动覆盖层重绘的动画（0→1）。
  Animation<double>? get animation => _controller;

  bool get isBusy => _busy;

  /// 由 [ThemeRevealHost] 在 initState 调用。
  void attach(TickerProvider vsync) {
    _controller ??= AnimationController(vsync: vsync, duration: duration);
  }

  /// 由 [ThemeRevealHost] 在 dispose 调用。
  void detach() {
    _controller?.dispose();
    _controller = null;
    _image?.dispose();
    _image = null;
    _origin = null;
  }

  /// 系统「移除动画」开关（无障碍/开发者选项）打开时直接切换。
  bool get _animationsDisabled =>
      WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
          .disableAnimations;

  /// 执行一次揭示动画；[apply] 负责即时应用主题状态。
  ///
  /// [apply] 必须**同步**完成界面状态的翻转（如
  /// `ThemeNotifier.setThemeModeOptimistic`），持久化留在后台；
  /// 否则动画要等配置写入完成才能开始（首次写入可能 ~1s）。
  /// 截图失败、系统关闭动画或已有动画在跑时安全降级为直接切换。
  Future<void> run({
    required Offset origin,
    required VoidCallback apply,
  }) async {
    if (_busy || _disposed) {
      apply();
      return;
    }
    if (_animationsDisabled) {
      apply();
      return;
    }

    _busy = true;
    try {
      final shot = await _capture();
      if (shot == null) {
        apply();
        return;
      }
      _image = shot;
      _origin = origin;
      notifyListeners();

      // 先换主题（覆盖层盖住旧画面，用户看不到中间态）。
      apply();
      if (_controller == null) return;

      // 等新主题的全树重建基本结束再开始扩散：
      // 换主题会让 HomePage/MinePage/NavigationBar 等整树重建，实测连续 7–8 帧
      // 超过 16ms（每帧 17–30ms）。若立即开始动画，扩散前半程会明显卡顿。
      await _waitForThemeRebuildToSettle();
      if (_controller == null) return;

      try {
        await _controller!.forward(from: 0);
      } on TickerCanceled {
        // Host 已销毁：直接结束，finally 会清理。
      }
    } finally {
      _image?.dispose();
      _image = null;
      _origin = null;
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 测试用：清空单例残留状态与注入。
  @visibleForTesting
  void resetForTest() {
    _image?.dispose();
    _image = null;
    _origin = null;
    _busy = false;
    captureOverride = null;
  }

  /// 等待连续两帧 UI 构建耗时回到预算内（或到达 [settleTimeout]）。
  ///
  /// 只影响「动画何时开始」：期间屏幕上一直盖着切换前的截图，用户看到的是
  /// 静止界面，不会露出新主题的半成品。
  Future<void> _waitForThemeRebuildToSettle() async {
    if (settleTimeout == Duration.zero) return;
    final completer = Completer<void>();
    var calmFrames = 0;
    late void Function(List<FrameTiming>) onTimings;
    Timer? timeout;
    Timer? ticker;

    void finish() {
      if (completer.isCompleted) return;
      SchedulerBinding.instance.removeTimingsCallback(onTimings);
      timeout?.cancel();
      ticker?.cancel();
      completer.complete();
    }

    onTimings = (timings) {
      for (final timing in timings) {
        if (timing.buildDuration <= const Duration(milliseconds: 10)) {
          calmFrames++;
        } else {
          calmFrames = 0;
        }
        if (calmFrames >= 2) {
          finish();
          return;
        }
      }
    };
    SchedulerBinding.instance.addTimingsCallback(onTimings);
    // 重建结束后应用会进入空闲（不再产帧），主动排空几帧才能观测到
    // 「连续两帧构建回到预算内」，否则要等满 settleTimeout。
    ticker = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => SchedulerBinding.instance.scheduleFrame(),
    );
    timeout = Timer(settleTimeout, finish);
    await completer.future;
  }

  Future<ui.Image?> _capture() async {
    final render = captureKey.currentContext?.findRenderObject();
    if (render is! RenderRepaintBoundary) return null;
    final injected = captureOverride;
    if (injected != null) return injected(render);
    final dpr = WidgetsBinding.instance.platformDispatcher.views.first
        .devicePixelRatio;
    try {
      // toImageSync：同步返回 GPU 侧图层，不做 CPU 回读。
      // 用 await toImage()（异步回读）在 GPU 降频/空闲时会阻塞 1s+，
      // 表现为点击后界面「冻住」一段时间才开始扩散。
      // 上限 2.0：全量 2.75× 约 10MB；2.0× 约 5MB，肉眼几乎无差。
      return render.toImageSync(pixelRatio: math.min(dpr, 2.0));
    } catch (error) {
      debugPrint('ThemeReveal: 截取切换前画面失败（降级为直接切换） - $error');
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    detach();
    super.dispose();
  }
}

/// 判断切到 [mode] 后解析出的亮度是否真的会变化。
///
/// 不变时（例如「深色 → 跟随系统」而系统本来就是深色）不做揭示动画，
/// 避免闪一下却什么都没变。
bool themeModeChangesBrightness(BuildContext context, AppThemeMode mode) {
  final target = switch (mode) {
    AppThemeMode.light => Brightness.light,
    AppThemeMode.dark => Brightness.dark,
    AppThemeMode.system => MediaQuery.platformBrightnessOf(context),
  };
  return target != Theme.of(context).brightness;
}

/// 挂在 [MaterialApp.builder] 最外层的宿主：提供截屏边界与揭示覆盖层。
class ThemeRevealHost extends StatefulWidget {
  const ThemeRevealHost({super.key, required this.child});

  /// 需要被截取、并在揭示过程中被覆盖的整棵应用界面。
  final Widget child;

  @override
  State<ThemeRevealHost> createState() => _ThemeRevealHostState();
}

class _ThemeRevealHostState extends State<ThemeRevealHost>
    with SingleTickerProviderStateMixin {
  final ThemeReveal _reveal = ThemeReveal.instance;

  @override
  void initState() {
    super.initState();
    _reveal.attach(this);
  }

  @override
  void dispose() {
    _reveal.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _reveal,
      // child 不是 const：它是 MaterialApp 的 Navigator，但只在这里传一次，
      // 动画帧不会重建它（重建只发生在开始/结束两次 notify）。
      child: widget.child,
      builder: (context, child) {
        final image = _reveal.image;
        final animation = _reveal.animation;
        return Stack(
          fit: StackFit.expand,
          children: [
            child!,
            if (image != null && animation != null)
              Positioned.fill(
                child: AbsorbPointer(
                  child: CustomPaint(
                    painter: _ThemeRevealPainter(
                      image: image,
                      origin: _reveal.origin,
                      animation: animation,
                      primary: scheme.primary,
                      surface: scheme.surface,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 旧截图 + 反向圆形裁剪 + 水波涟漪。
class _ThemeRevealPainter extends CustomPainter {
  _ThemeRevealPainter({
    required this.image,
    required this.origin,
    required this.animation,
    required this.primary,
    required this.surface,
  }) : super(repaint: animation);

  final ui.Image image;
  final Offset origin;
  final Animation<double> animation;
  final Color primary;
  final Color surface;

  /// 涟漪圈数（错峰外扩）。
  static const int _rings = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value.clamp(0.0, 1.0);
    final eased = Curves.easeOutCubic.transform(t);
    final maxRadius = _maxRadius(size, origin);
    final radius = maxRadius * eased;

    // 1) 旧画面：整屏绘制，挖掉一个圆心在点击处、半径不断变大的洞。
    final hole = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: origin, radius: radius));
    canvas.save();
    canvas.clipPath(hole);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();

    // 2) 水波：多圈错峰外扩、随扩散淡出。
    for (var i = 0; i < _rings; i++) {
      final ringT = ((t - i * 0.11) / (1 - 0.11 * (_rings - 1))).clamp(0.0, 1.0);
      if (ringT <= 0 || ringT >= 1) continue;
      final ringRadius = maxRadius * Curves.easeOutCubic.transform(ringT);
      final fade = (1 - ringT) * (0.34 - i * 0.08);
      if (fade <= 0) continue;
      canvas.drawCircle(
        origin,
        ringRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0 - i * 0.6
          ..color = primary.withValues(alpha: fade),
      );
    }

    // 3) 扩散前沿：一圈更亮的细环，强化「水波推开」的边缘。
    if (t < 0.94) {
      canvas.drawCircle(
        origin,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = primary.withValues(alpha: 0.55 * (1 - t)),
      );
    }

    // 4) 起点高光：像水滴落点，快速衰减。
    final glow = (1 - t * 3.2).clamp(0.0, 1.0);
    if (glow > 0) {
      final glowRadius = 110.0 * (0.55 + t);
      canvas.drawCircle(
        origin,
        glowRadius,
        Paint()
          ..shader = ui.Gradient.radial(
            origin,
            glowRadius,
            <Color>[
              Color.alphaBlend(
                primary.withValues(alpha: 0.30 * glow),
                surface.withValues(alpha: 0.0),
              ),
              primary.withValues(alpha: 0),
            ],
            <double>[0.0, 1.0],
          ),
      );
      // 落点中心一点点亮，避免大圆显得空。
      canvas.drawCircle(
        origin,
        10 * (0.6 + glow),
        Paint()..color = primary.withValues(alpha: 0.18 * glow),
      );
    }
  }

  static double _maxRadius(Size size, Offset origin) {
    final dx = math.max(origin.dx, size.width - origin.dx);
    final dy = math.max(origin.dy, size.height - origin.dy);
    return math.sqrt(dx * dx + dy * dy);
  }

  @override
  bool shouldRepaint(covariant _ThemeRevealPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.origin != origin ||
      oldDelegate.primary != primary ||
      oldDelegate.surface != surface;
}
