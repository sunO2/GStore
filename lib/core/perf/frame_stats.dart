/// GStore 帧时序（FPS / jank）滚动统计 —— **纯 Dart，无 Flutter 依赖**。
///
/// 本文件只使用 `dart:` 基础库与纯 Dart 代码，**不 import 任何 Flutter 框架库**，
/// 因此可以在没有运行 Flutter 引擎的普通单元测试（`package:test` /
/// `flutter_test`）中直接实例化与断言。Flutter 的 `FrameTiming` 没有公开构造
/// 函数，无法在测试里构造，这正是把「测量」与「统计」分层的原因：
/// 上层 [FrameMonitor]（见 `frame_monitor.dart`）负责把 `FrameTiming` 转换为纯
/// 时长数字，喂给本文件的 [FrameStatsAccumulator]。
///
/// ## 单位约定（务必注意）
/// * **输入**：所有 `*Us` 字段/参数的单位为**微秒（µs）**，与 Flutter
///   `FrameTiming` 的 `Duration.inMicroseconds` 对齐。
/// * **输出**：所有 `*Ms` 后缀的统计量单位为**毫秒（ms）**。
///
/// ## 统计口径
/// * 滚动窗口：默认保留最近 [FrameStatsAccumulator.window] 帧（默认 120），
///   `avg` / `p50` / `p90` / `p99` / `fps` / 窗口 jank 均只由窗口内帧计算。
/// * 百分位采用**最近秩（nearest-rank）**法：升序排序后
///   `index = ceil(p/100 * N) - 1`（越界钳制到 `[0, N-1]`），结果确定、可复现。
/// * **交付 FPS（delivered FPS）**：由窗口内各帧的 **vsync 时间戳**
///   （[FrameSample.vsyncTimestampUs]，即 Flutter `FrameTiming.timestampInMicroseconds`）
///   换算：`fps = (n - 1) × 1e6 / (lastTimestampUs - firstTimestampUs)`（n = 窗口帧数）。
///   这是「实际交付的帧率」，与每帧耗时无关——一帧即便只花 8ms，只要每 16.67ms 才
///   交付一次，就应记为 ≈60fps，而不是 `1e6/8000` ≈125fps。窗口内帧数 < 2 或时间跨度
///   ≤ 0（例如时间戳全相同）时 `fps = 0`。`frameIntervalMs` 为窗口内**平均帧间隔**
///   = `(lastTimestampUs - firstTimestampUs) / (n - 1) / 1000`（同条件下为 0）。
///   **注意**：`total` 帧耗时只用于均值/百分位/jank，**绝不**用来换算 FPS。
/// * jank 定义：`total 帧时间 > jankThresholdFactor × budget`，默认系数 2、
///   周期 `budgetMs = 16.666`（≈60Hz），故默认阈值为 33.332ms。判定用**严格大于**。
library;

/// 单帧时序样本（输入单位：微秒）。
///
/// [totalUs] 为该帧总跨度（Flutter 的 `FrameTiming.totalSpan`）；若上游未提供
/// 有效的 total，[FrameStatsAccumulator.addFrame] 会回退为
/// `build + raster + vsync`。
class FrameSample {
  const FrameSample({
    required this.buildUs,
    required this.rasterUs,
    required this.vsyncUs,
    required this.totalUs,
    required this.vsyncTimestampUs,
  });

  /// UI（build）阶段耗时，微秒。
  final int buildUs;

  /// GPU（raster）阶段耗时，微秒。
  final int rasterUs;

  /// vsync 开销，微秒。
  final int vsyncUs;

  /// 该帧总耗时，微秒。
  final int totalUs;

  /// 该帧的 **vsync 时间戳**（微秒），对应 Flutter
  /// `FrameTiming.timestampInMicroseconds`。
  ///
  /// 仅用于计算**交付 FPS**与**平均帧间隔**；与 [vsyncUs]（vsync 开销）无关。
  final int vsyncTimestampUs;

  /// UI 阶段耗时（毫秒）。
  double get buildMs => buildUs / Duration.microsecondsPerMillisecond;

  /// GPU 阶段耗时（毫秒）。
  double get rasterMs => rasterUs / Duration.microsecondsPerMillisecond;

  /// vsync 开销（毫秒）。
  double get vsyncMs => vsyncUs / Duration.microsecondsPerMillisecond;

  /// 总耗时（毫秒）。
  double get totalMs => totalUs / Duration.microsecondsPerMillisecond;

  @override
  String toString() => 'FrameSample(total=${totalMs.toStringAsFixed(2)}ms, '
      'build=${buildMs.toStringAsFixed(2)}ms, '
      'raster=${rasterMs.toStringAsFixed(2)}ms)';
}

/// 一次 [FrameStatsAccumulator.snapshot] 的不可变统计结果。
///
/// 所有 `*Ms` 字段单位为**毫秒**；比率字段为 `[0, 1]` 的小数。
class FrameStats {
  const FrameStats({
    required this.totalFrames,
    required this.windowSize,
    required this.sampledFrames,
    required this.budgetMs,
    required this.jankThresholdMs,
    required this.fps,
    required this.frameIntervalMs,
    required this.avgBuildMs,
    required this.avgRasterMs,
    required this.avgVsyncMs,
    required this.avgTotalMs,
    required this.p50BuildMs,
    required this.p90BuildMs,
    required this.p99BuildMs,
    required this.p50RasterMs,
    required this.p90RasterMs,
    required this.p99RasterMs,
    required this.p50TotalMs,
    required this.p90TotalMs,
    required this.p99TotalMs,
    required this.maxTotalMs,
    required this.jankCount,
    required this.jankRatio,
    required this.windowJankCount,
    required this.windowJankRatio,
    required this.worstFrames,
  });

  /// 无帧样本时的空统计（除窗口/预算元信息外全为 0）。
  factory FrameStats.empty({
    required int windowSize,
    required double budgetMs,
    required double jankThresholdMs,
    int totalFrames = 0,
    int jankCount = 0,
  }) =>
      FrameStats(
        totalFrames: totalFrames,
        windowSize: windowSize,
        sampledFrames: 0,
        budgetMs: budgetMs,
        jankThresholdMs: jankThresholdMs,
        fps: 0,
        frameIntervalMs: 0,
        avgBuildMs: 0,
        avgRasterMs: 0,
        avgVsyncMs: 0,
        avgTotalMs: 0,
        p50BuildMs: 0,
        p90BuildMs: 0,
        p99BuildMs: 0,
        p50RasterMs: 0,
        p90RasterMs: 0,
        p99RasterMs: 0,
        p50TotalMs: 0,
        p90TotalMs: 0,
        p99TotalMs: 0,
        maxTotalMs: 0,
        jankCount: jankCount,
        jankRatio: totalFrames == 0 ? 0 : jankCount / totalFrames,
        windowJankCount: 0,
        windowJankRatio: 0,
        worstFrames: const <FrameSample>[],
      );

  /// 自上次 [FrameStatsAccumulator.reset] 起累计喂入的帧数（生命周期计数）。
  final int totalFrames;

  /// 配置的滚动窗口大小 N。
  final int windowSize;

  /// 当前窗口内实际保留的帧数（`min(totalFrames, windowSize)`）。
  final int sampledFrames;

  /// 单帧预算（显示周期），毫秒。默认 16.666。
  final double budgetMs;

  /// jank 判定阈值（毫秒）= `jankThresholdFactor × budgetMs`。默认 33.332。
  final double jankThresholdMs;

  /// **交付** FPS（delivered FPS），由窗口内各帧的 vsync **时间戳**换算：
  /// `(n - 1) × 1e6 / (lastTimestampUs - firstTimestampUs)`。
  ///
  /// 反映「实际交付的帧率」，**不是**由帧耗时换算的理论吞吐。窗口内帧数 < 2 或
  /// 时间跨度 ≤ 0 时为 0。注意 `total` 帧耗时只用于均值/百分位/jank。
  final double fps;

  /// 窗口内**平均帧间隔**（毫秒）= `(lastTimestampUs - firstTimestampUs) / (n-1) / 1000`。
  ///
  /// 与 `1000 / fps` 互为倒数；窗口内帧数 < 2 或跨度 ≤ 0 时为 0。
  final double frameIntervalMs;

  final double avgBuildMs;
  final double avgRasterMs;
  final double avgVsyncMs;
  final double avgTotalMs;

  final double p50BuildMs;
  final double p90BuildMs;
  final double p99BuildMs;

  final double p50RasterMs;
  final double p90RasterMs;
  final double p99RasterMs;

  final double p50TotalMs;
  final double p90TotalMs;
  final double p99TotalMs;

  /// 窗口内单帧 total 最大值（毫秒）。
  final double maxTotalMs;

  /// **生命周期** jank 帧累计数（自 reset 起）。
  final int jankCount;

  /// **生命周期** jank 比率 = `jankCount / totalFrames`。
  final double jankRatio;

  /// 当前**窗口**内 jank 帧数。
  final int windowJankCount;

  /// 当前**窗口**内 jank 比率 = `windowJankCount / sampledFrames`。
  final double windowJankRatio;

  /// 窗口内 total 耗时最长的前 N 帧（默认 5，按 total 降序，不可变）。
  final List<FrameSample> worstFrames;

  @override
  String toString() => 'FrameStats(frames=$totalFrames, window=$sampledFrames/'
      '$windowSize, fps=${fps.toStringAsFixed(1)}, '
      'avgTotal=${avgTotalMs.toStringAsFixed(2)}ms, '
      'p90Total=${p90TotalMs.toStringAsFixed(2)}ms, '
      'p99Total=${p99TotalMs.toStringAsFixed(2)}ms, '
      'jank=$jankCount(${(jankRatio * 100).toStringAsFixed(1)}%))';
}

/// 帧时序滚动累加器（纯 Dart，可在无 Flutter 引擎的测试中直接使用）。
///
/// 使用方式：
/// ```dart
/// final acc = FrameStatsAccumulator(window: 120);
/// acc.addFrame(
///   buildUs: 8000,
///   rasterUs: 4000,
///   vsyncUs: 100,
///   totalUs: 12100,
///   vsyncTimestampUs: 16666, // FrameTiming.timestampInMicroseconds
/// );
/// final stats = acc.snapshot();
/// ```
class FrameStatsAccumulator {
  FrameStatsAccumulator({
    int window = 120,
    double budgetMs = 16.666,
    double jankThresholdFactor = 2.0,
    int worstFramesLimit = 5,
  })  : assert(window > 0, 'window 必须 > 0'),
        assert(budgetMs > 0, 'budgetMs 必须 > 0'),
        assert(jankThresholdFactor > 0, 'jankThresholdFactor 必须 > 0'),
        assert(worstFramesLimit >= 0, 'worstFramesLimit 必须 >= 0'),
        _window = window,
        _budgetMs = budgetMs,
        _jankThresholdFactor = jankThresholdFactor,
        _worstFramesLimit = worstFramesLimit;

  final int _window;
  final double _budgetMs;
  final double _jankThresholdFactor;
  final int _worstFramesLimit;

  /// 滚动窗口（最近 [_window] 帧）。
  final List<FrameSample> _samples = <FrameSample>[];

  int _totalFrames = 0;
  int _lifetimeJank = 0;

  /// 滚动窗口大小 N。
  int get window => _window;

  /// 单帧预算（显示周期），毫秒。
  double get budgetMs => _budgetMs;

  /// jank 判定阈值（毫秒）。
  double get jankThresholdMs => _budgetMs * _jankThresholdFactor;

  /// 自 [reset] 起累计帧数。
  int get totalFrames => _totalFrames;

  /// 自 [reset] 起累计 jank 帧数。
  int get lifetimeJankCount => _lifetimeJank;

  double get _jankThresholdUs => jankThresholdMs * 1000.0;

  /// 喂入一帧。参数单位均为**微秒**。
  ///
  /// [vsyncTimestampUs] 为该帧的 vsync 时间戳（Flutter
  /// `FrameTiming.timestampInMicroseconds`），**用于换算交付 FPS 与平均帧间隔**；
  /// 它是时间轴上的绝对时刻，不像其余参数那样代表耗时，因此**不做** `max(0, ·)`
  /// 钳制（时间戳可以为 0）。若上游确实没有时间戳，可传 0，此时窗口跨度可能失效，
  /// FPS 退化为 0。
  ///
  /// [totalUs] <= 0 时回退为 `buildUs + rasterUs + vsyncUs`。其余时长输入按
  /// `max(0, ·)` 钳制，避免上游出现负时长污染统计。
  void addFrame({
    required int buildUs,
    required int rasterUs,
    required int vsyncUs,
    required int totalUs,
    required int vsyncTimestampUs,
  }) {
    final b = buildUs < 0 ? 0 : buildUs;
    final r = rasterUs < 0 ? 0 : rasterUs;
    final v = vsyncUs < 0 ? 0 : vsyncUs;
    final t = totalUs > 0 ? totalUs : (b + r + v);

    _samples.add(
      FrameSample(
        buildUs: b,
        rasterUs: r,
        vsyncUs: v,
        totalUs: t,
        vsyncTimestampUs: vsyncTimestampUs,
      ),
    );
    if (_samples.length > _window) {
      _samples.removeAt(0);
    }
    _totalFrames++;
    if (t > _jankThresholdUs) {
      _lifetimeJank++;
    }
  }

  /// 计算当前统计快照（不修改内部状态）。
  FrameStats snapshot() {
    final n = _samples.length;
    if (n == 0) {
      return FrameStats.empty(
        windowSize: _window,
        budgetMs: _budgetMs,
        jankThresholdMs: jankThresholdMs,
        totalFrames: _totalFrames,
        jankCount: _lifetimeJank,
      );
    }

    final builds = List<int>.generate(n, (i) => _samples[i].buildUs)..sort();
    final rasters = List<int>.generate(n, (i) => _samples[i].rasterUs)..sort();
    final vsyncs = List<int>.generate(n, (i) => _samples[i].vsyncUs)..sort();
    final totals = List<int>.generate(n, (i) => _samples[i].totalUs)..sort();

    final avgTotalUs = _sum(totals) / n;

    // 交付 FPS：来自窗口内 vsync 时间戳的跨度，与帧耗时无关。
    final firstTs = _samples.first.vsyncTimestampUs;
    final lastTs = _samples.last.vsyncTimestampUs;
    final spanUs = lastTs - firstTs;
    final hasSpan = n >= 2 && spanUs > 0;
    final fps = hasSpan ? (n - 1) * 1000000.0 / spanUs : 0.0;
    final frameIntervalMs = hasSpan ? spanUs / (n - 1) / 1000.0 : 0.0;

    final thresholdUs = _jankThresholdUs;
    var windowJank = 0;
    for (final s in _samples) {
      if (s.totalUs > thresholdUs) windowJank++;
    }

    return FrameStats(
      totalFrames: _totalFrames,
      windowSize: _window,
      sampledFrames: n,
      budgetMs: _budgetMs,
      jankThresholdMs: jankThresholdMs,
      fps: fps,
      frameIntervalMs: frameIntervalMs,
      avgBuildMs: _sum(builds) / n / 1000.0,
      avgRasterMs: _sum(rasters) / n / 1000.0,
      avgVsyncMs: _sum(vsyncs) / n / 1000.0,
      avgTotalMs: avgTotalUs / 1000.0,
      p50BuildMs: _percentileMs(builds, 50),
      p90BuildMs: _percentileMs(builds, 90),
      p99BuildMs: _percentileMs(builds, 99),
      p50RasterMs: _percentileMs(rasters, 50),
      p90RasterMs: _percentileMs(rasters, 90),
      p99RasterMs: _percentileMs(rasters, 99),
      p50TotalMs: _percentileMs(totals, 50),
      p90TotalMs: _percentileMs(totals, 90),
      p99TotalMs: _percentileMs(totals, 99),
      maxTotalMs: totals.last / 1000.0,
      jankCount: _lifetimeJank,
      jankRatio: _totalFrames == 0 ? 0 : _lifetimeJank / _totalFrames,
      windowJankCount: windowJank,
      windowJankRatio: n == 0 ? 0 : windowJank / n,
      worstFrames: _worstFrames(),
    );
  }

  /// 清空全部滚动样本与计数器（窗口/预算配置保留）。
  void reset() {
    _samples.clear();
    _totalFrames = 0;
    _lifetimeJank = 0;
  }

  /// 窗口内 total 最长前 [_worstFramesLimit] 帧（降序、不可变）。
  List<FrameSample> _worstFrames() {
    if (_worstFramesLimit == 0 || _samples.isEmpty) {
      return const <FrameSample>[];
    }
    final copy = List<FrameSample>.of(_samples)
      ..sort((a, b) => b.totalUs.compareTo(a.totalUs));
    final take = copy.length < _worstFramesLimit
        ? copy.length
        : _worstFramesLimit;
    return List<FrameSample>.unmodifiable(copy.sublist(0, take));
  }

  static int _sum(List<int> values) {
    var total = 0;
    for (final v in values) {
      total += v;
    }
    return total;
  }

  /// 最近秩百分位（输入已升序）。返回毫秒。
  static double _percentileMs(List<int> sortedUs, double p) {
    final n = sortedUs.length;
    if (n == 0) return 0;
    final rank = (p / 100.0 * n).ceil();
    var index = rank - 1;
    if (index < 0) index = 0;
    if (index > n - 1) index = n - 1;
    return sortedUs[index] / 1000.0;
  }
}
