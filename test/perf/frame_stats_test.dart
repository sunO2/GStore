import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/perf/frame_stats.dart';

/// 便捷喂帧：默认 build/raster/vsync 为 0，仅给 total（微秒）。
///
/// [vsyncTimestampUs] 为该帧的 vsync 时间戳（微秒），仅用于交付 FPS；默认 0
/// （多帧同一时间戳 → 跨度 0 → fps 0），因此不关心 FPS 的用例无需显式给出。
void _feed(
  FrameStatsAccumulator acc,
  int totalUs, {
  int buildUs = 0,
  int rasterUs = 0,
  int vsyncUs = 0,
  int vsyncTimestampUs = 0,
}) {
  acc.addFrame(
    buildUs: buildUs,
    rasterUs: rasterUs,
    vsyncUs: vsyncUs,
    totalUs: totalUs,
    vsyncTimestampUs: vsyncTimestampUs,
  );
}

void main() {
  group('FrameStatsAccumulator 空状态', () {
    test('无样本快照全为 0，但保留窗口/预算元信息', () {
      final acc = FrameStatsAccumulator(window: 120);
      final s = acc.snapshot();

      expect(s.totalFrames, 0);
      expect(s.sampledFrames, 0);
      expect(s.fps, 0);
      expect(s.frameIntervalMs, 0);
      expect(s.avgTotalMs, 0);
      expect(s.p50TotalMs, 0);
      expect(s.p90TotalMs, 0);
      expect(s.p99TotalMs, 0);
      expect(s.maxTotalMs, 0);
      expect(s.jankCount, 0);
      expect(s.jankRatio, 0);
      expect(s.windowJankCount, 0);
      expect(s.windowJankRatio, 0);
      expect(s.worstFrames, isEmpty);
      expect(s.windowSize, 120);
      expect(s.budgetMs, 16.666);
      expect(s.jankThresholdMs, closeTo(33.332, 1e-9));
    });
  });

  group('交付 FPS（由 vsync 时间戳换算）', () {
    test('60 帧，时间戳间距 16666µs → fps≈60、帧间隔≈16.666ms', () {
      final acc = FrameStatsAccumulator();
      for (var i = 0; i < 60; i++) {
        _feed(
          acc,
          16666,
          buildUs: 8000,
          rasterUs: 8000,
          vsyncUs: 666,
          vsyncTimestampUs: i * 16666,
        );
      }
      final s = acc.snapshot();

      expect(s.fps, closeTo(60.0, 0.1));
      expect(s.frameIntervalMs, closeTo(16.666, 1e-6));
    });

    test('回归：帧耗时 5ms 但 16666µs 才交付一次 → fps≈60（不是 ~200）', () {
      final acc = FrameStatsAccumulator();
      for (var i = 0; i < 10; i++) {
        // build + raster = 5ms，但每 16.666ms 才交付一帧（60Hz）。
        acc.addFrame(
          buildUs: 2500,
          rasterUs: 2500,
          vsyncUs: 0,
          totalUs: 5000,
          vsyncTimestampUs: i * 16666,
        );
      }
      final s = acc.snapshot();

      expect(s.fps, closeTo(60.0, 0.1));
      // 旧实现 `1e6/均值totalµs` 会把 5ms 帧误报为 200fps —— 必须不是。
      expect(s.fps, isNot(closeTo(200.0, 1.0)));
      // 帧耗时统计仍然如实反映 5ms。
      expect(s.avgTotalMs, closeTo(5.0, 1e-9));
    });

    test('单帧 → fps 0、帧间隔 0', () {
      final acc = FrameStatsAccumulator();
      _feed(acc, 16000, vsyncTimestampUs: 100000);
      final s = acc.snapshot();
      expect(s.fps, 0);
      expect(s.frameIntervalMs, 0);
    });

    test('空 → fps 0、帧间隔 0', () {
      final acc = FrameStatsAccumulator();
      final s = acc.snapshot();
      expect(s.fps, 0);
      expect(s.frameIntervalMs, 0);
    });

    test('时间戳全相同 → 跨度 0 → fps 0、帧间隔 0', () {
      final acc = FrameStatsAccumulator();
      for (var i = 0; i < 5; i++) {
        _feed(acc, 16000, vsyncTimestampUs: 424242);
      }
      final s = acc.snapshot();
      expect(s.fps, 0);
      expect(s.frameIntervalMs, 0);
    });

    test('不规则间隔（16.67ms / 33.3ms 混合）→ fps = (n-1)*1e6/span', () {
      final acc = FrameStatsAccumulator();
      // 相邻间隔：16666, 33332, 16666, 33332 µs。
      const timestamps = <int>[0, 16666, 49998, 66664, 99996];
      for (final ts in timestamps) {
        _feed(acc, 16000, vsyncTimestampUs: ts);
      }
      final s = acc.snapshot();

      final n = timestamps.length;
      final span = timestamps.last - timestamps.first;
      final expected = (n - 1) * 1000000.0 / span;
      expect(s.fps, closeTo(expected, 1e-6));
      expect(
        s.frameIntervalMs,
        closeTo(span / (n - 1) / 1000.0, 1e-9),
      );
    });

    test('reset 清空时间戳 → fps 归 0', () {
      final acc = FrameStatsAccumulator();
      for (var i = 0; i < 60; i++) {
        _feed(acc, 16666, vsyncTimestampUs: i * 16666);
      }
      expect(acc.snapshot().fps, closeTo(60.0, 0.1));

      acc.reset();

      final s = acc.snapshot();
      expect(s.fps, 0);
      expect(s.frameIntervalMs, 0);
      expect(s.sampledFrames, 0);
    });
  });

  group('fps / 均值 / 百分位', () {
    test('恒定 16666µs → 均值/p50/p99 均 16.666ms、无 jank', () {
      final acc = FrameStatsAccumulator();
      for (var i = 0; i < 60; i++) {
        _feed(
          acc,
          16666,
          buildUs: 8000,
          rasterUs: 8000,
          vsyncUs: 666,
          vsyncTimestampUs: i * 16666,
        );
      }
      final s = acc.snapshot();

      expect(s.totalFrames, 60);
      expect(s.sampledFrames, 60);
      expect(s.fps, closeTo(60.0, 0.1));
      expect(s.avgTotalMs, closeTo(16.666, 1e-6));
      expect(s.p50TotalMs, closeTo(16.666, 1e-6));
      expect(s.p99TotalMs, closeTo(16.666, 1e-6));
      expect(s.maxTotalMs, closeTo(16.666, 1e-6));
      expect(s.jankCount, 0);
      expect(s.windowJankCount, 0);
    });

    test('已知序列 1..10ms → 最近秩 p50/p90/p99 分别 5/9/10ms，均值 5.5ms', () {
      final acc = FrameStatsAccumulator(window: 200, budgetMs: 1000);
      for (var i = 1; i <= 10; i++) {
        _feed(
          acc,
          i * 1000,
          buildUs: i * 1000,
          rasterUs: i * 1000,
          vsyncTimestampUs: i * 5500,
        );
      }
      final s = acc.snapshot();

      expect(s.avgTotalMs, closeTo(5.5, 1e-9));
      expect(s.p50TotalMs, 5.0);
      expect(s.p90TotalMs, 9.0);
      expect(s.p99TotalMs, 10.0);
      expect(s.maxTotalMs, 10.0);
      // build / raster 各自独立统计（此处与 total 同序列）。
      expect(s.p50BuildMs, 5.0);
      expect(s.p90BuildMs, 9.0);
      expect(s.p99BuildMs, 10.0);
      expect(s.p50RasterMs, 5.0);
      expect(s.p90RasterMs, 9.0);
      // 时间戳间距 5500µs → 交付 fps = 1e6/5500（与 total 均值无关）。
      expect(s.fps, closeTo(1000000 / 5500, 1e-6));
    });

    test('build/raster/vsync 分别统计（不同量纲不串味）', () {
      final acc = FrameStatsAccumulator(window: 200, budgetMs: 1000);
      for (var i = 1; i <= 10; i++) {
        acc.addFrame(
          buildUs: i * 100,
          rasterUs: i * 1000,
          vsyncUs: 10,
          totalUs: i * 1100,
          vsyncTimestampUs: i * 16666,
        );
      }
      final s = acc.snapshot();

      expect(s.avgBuildMs, closeTo(0.55, 1e-9));
      expect(s.p50BuildMs, closeTo(0.5, 1e-9));
      expect(s.p90BuildMs, closeTo(0.9, 1e-9));
      expect(s.avgRasterMs, closeTo(5.5, 1e-9));
      expect(s.p90RasterMs, closeTo(9.0, 1e-9));
      expect(s.avgVsyncMs, closeTo(0.01, 1e-9));
    });
  });

  group('jank 判定', () {
    test('默认预算 16.666ms：total > 33.332ms 记 jank（严格大于，边界不算）', () {
      final acc = FrameStatsAccumulator();
      expect(acc.jankThresholdMs, closeTo(33.332, 1e-9));

      _feed(acc, 33332); // == 阈值 → 非 jank
      expect(acc.lifetimeJankCount, 0, reason: '等于阈值不算（严格大于）');

      _feed(acc, 33333); // > 阈值 → jank
      expect(acc.lifetimeJankCount, 1);
    });

    test('可配置预算 16ms：阈值 32ms，32000 非 jank / 32001 jank', () {
      final acc = FrameStatsAccumulator(budgetMs: 16.0);
      expect(acc.jankThresholdMs, 32.0);

      _feed(acc, 32000);
      expect(acc.lifetimeJankCount, 0);
      _feed(acc, 32001);
      expect(acc.lifetimeJankCount, 1);
    });

    test('jank_count/jank_ratio 为生命周期，window 变体为窗口内', () {
      final acc = FrameStatsAccumulator(window: 120);
      for (var i = 0; i < 10; i++) {
        _feed(acc, 16000);
      }
      _feed(acc, 40000);
      _feed(acc, 50000);
      final s = acc.snapshot();

      expect(s.totalFrames, 12);
      expect(s.jankCount, 2);
      expect(s.jankRatio, closeTo(2 / 12, 1e-9));
      expect(s.windowJankCount, 2);
      expect(s.windowJankRatio, closeTo(2 / 12, 1e-9));
      expect(s.worstFrames.first.totalUs, 50000);
      expect(s.worstFrames[1].totalUs, 40000);
    });

    test('窗口滚动后旧 jank 移出窗口：生命周期仍记、窗口清零', () {
      final acc = FrameStatsAccumulator(window: 3, budgetMs: 16.0);
      _feed(acc, 40000); // jank，稍后被挤出窗口
      _feed(acc, 10000);
      _feed(acc, 10000);
      _feed(acc, 10000);
      final s = acc.snapshot();

      expect(s.totalFrames, 4);
      expect(s.jankCount, 1);
      expect(s.jankRatio, closeTo(0.25, 1e-9));
      expect(s.windowJankCount, 0);
      expect(s.windowJankRatio, 0);
    });
  });

  group('滚动窗口', () {
    test('window=3：只保留最近 3 帧参与均值/百分位，totalFrames 仍累计', () {
      final acc = FrameStatsAccumulator(window: 3);
      for (final t in [5000, 10000, 15000, 20000, 25000]) {
        _feed(acc, t, buildUs: t);
      }
      final s = acc.snapshot();

      expect(s.totalFrames, 5);
      expect(s.sampledFrames, 3);
      // 最近 3 帧 = 15000/20000/25000 → 均值 20ms
      expect(s.avgTotalMs, closeTo(20.0, 1e-9));
      expect(s.p50TotalMs, 20.0);
      expect(s.p90TotalMs, 25.0);
      expect(s.maxTotalMs, 25.0);
      expect(s.worstFrames, hasLength(3));
      expect(s.worstFrames.first.totalMs, closeTo(25.0, 1e-9));
      expect(s.worstFrames.last.totalMs, closeTo(15.0, 1e-9));
    });

    test('window=3：fps 只用窗口内 3 帧的时间戳跨度', () {
      final acc = FrameStatsAccumulator(window: 3);
      for (var i = 0; i < 5; i++) {
        _feed(acc, 16000, vsyncTimestampUs: i * 16666);
      }
      final s = acc.snapshot();

      // 窗口内时间戳 = [2,3,4]×16666 → span 2×16666、n=3 → fps = 2e6/span。
      expect(s.sampledFrames, 3);
      expect(s.fps, closeTo(60.0, 0.1));
    });
  });

  group('worst frames', () {
    test('默认取 top5，按 total 降序', () {
      final acc = FrameStatsAccumulator(worstFramesLimit: 5, budgetMs: 1000);
      for (final t in [1000, 2000, 3000, 4000, 5000, 6000, 7000]) {
        _feed(acc, t, buildUs: t);
      }
      final s = acc.snapshot();

      expect(s.worstFrames, hasLength(5));
      expect(
        s.worstFrames.map((f) => f.totalMs).toList(),
        [7.0, 6.0, 5.0, 4.0, 3.0],
      );
    });

    test('worstFramesLimit=0 → 不收集', () {
      final acc = FrameStatsAccumulator(worstFramesLimit: 0);
      _feed(acc, 5000);
      expect(acc.snapshot().worstFrames, isEmpty);
    });

    test('worstFrames 为不可变列表', () {
      final acc = FrameStatsAccumulator();
      _feed(acc, 5000);
      final s = acc.snapshot();
      expect(
        () => s.worstFrames.add(s.worstFrames.first),
        throwsUnsupportedError,
      );
    });
  });

  group('健壮性', () {
    test('totalUs <= 0 时回退 build+raster+vsync', () {
      final acc = FrameStatsAccumulator();
      acc.addFrame(
        buildUs: 5000,
        rasterUs: 3000,
        vsyncUs: 1000,
        totalUs: 0,
        vsyncTimestampUs: 16666,
      );
      expect(acc.snapshot().maxTotalMs, closeTo(9.0, 1e-9));
    });

    test('负时长被钳制为 0，不污染统计', () {
      final acc = FrameStatsAccumulator();
      acc.addFrame(
        buildUs: -100,
        rasterUs: -5,
        vsyncUs: -1,
        totalUs: 2000,
        vsyncTimestampUs: 16666,
      );
      final s = acc.snapshot();
      expect(s.avgBuildMs, 0);
      expect(s.avgRasterMs, 0);
      expect(s.avgVsyncMs, 0);
      expect(s.avgTotalMs, closeTo(2.0, 1e-9));
    });
  });

  group('reset', () {
    test('清空样本与生命周期计数，保留窗口/预算配置', () {
      final acc = FrameStatsAccumulator(window: 10, budgetMs: 16.0);
      for (var i = 0; i < 5; i++) {
        _feed(acc, 40000, vsyncTimestampUs: i * 16666);
      }
      expect(acc.snapshot().jankCount, 5);

      acc.reset();

      expect(acc.totalFrames, 0);
      expect(acc.lifetimeJankCount, 0);
      final s = acc.snapshot();
      expect(s.totalFrames, 0);
      expect(s.sampledFrames, 0);
      expect(s.fps, 0);
      expect(s.frameIntervalMs, 0);
      expect(s.jankCount, 0);
      expect(s.jankRatio, 0);
      expect(s.worstFrames, isEmpty);
      expect(s.windowSize, 10);
      expect(s.budgetMs, 16.0);
    });
  });
}
