import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/frame_stats.dart';

/// 便捷喂帧：默认 build/raster/vsync 为 0，仅给 total（微秒）与 vsync 时间戳。
void _feed(
  FrameStatsAccumulator acc,
  int totalUs, {
  int vsyncTimestampUs = 0,
}) {
  acc.addFrame(
    buildUs: 0,
    rasterUs: 0,
    vsyncUs: 0,
    totalUs: totalUs,
    vsyncTimestampUs: vsyncTimestampUs,
  );
}

/// 时间窗口径的交付 FPS 测试（默认 2s）。
///
/// 与 `test/perf/frame_stats_test.dart`（整窗 / 百分位 / jank 全量回归）互补，
/// 本文件聚焦「`fps` / `frameIntervalMs` 只由末样本往前 [fpsWindow] 内的近期样本
/// 换算」这一新口径。
void main() {
  group('FrameStatsAccumulator 时间窗 FPS', () {
    test('默认窗口为 2s', () {
      final acc = FrameStatsAccumulator();
      expect(acc.fpsWindow, const Duration(seconds: 2));
    });

    test('末 2s 内 6 帧 @60Hz + 2s 前老样本 → fps≈60（老样本不拉低）', () {
      final acc = FrameStatsAccumulator();
      // 10s 前的老样本：整窗口径会被它拉低到 ~0.6fps。
      _feed(acc, 16000, vsyncTimestampUs: 0);
      // 末 2s 内 6 帧，间隔 16666µs（60Hz）。
      for (var i = 0; i < 6; i++) {
        _feed(acc, 16000, vsyncTimestampUs: 10000000 + i * 16666);
      }
      final s = acc.snapshot();

      // 近期 6 帧跨度 = 5×16666 → fps = 5e6/83330 ≈ 60。
      expect(s.fps, closeTo(60.0, 0.1));
      expect(s.frameIntervalMs, closeTo(16.666, 1e-2));
      // 整窗仍保留全部 7 帧（百分位/jank 用全窗）。
      expect(s.sampledFrames, 7);
    });

    test('仅 1 个近期样本（其余超窗）→ fps 0', () {
      final acc = FrameStatsAccumulator();
      for (var i = 0; i < 5; i++) {
        _feed(acc, 16000, vsyncTimestampUs: i * 16666); // 0..66664（老）
      }
      _feed(acc, 16000, vsyncTimestampUs: 5000000); // 唯一的近期样本
      final s = acc.snapshot();

      expect(s.fps, 0);
      expect(s.frameIntervalMs, 0);
      expect(s.sampledFrames, 6);
    });

    test('fpsWindow: null → 退回整窗（120 帧）口径', () {
      final acc = FrameStatsAccumulator(fpsWindow: null);
      // 老样本 + 末 2s 内 6 帧 @60Hz。
      _feed(acc, 16000, vsyncTimestampUs: 0);
      for (var i = 0; i < 6; i++) {
        _feed(acc, 16000, vsyncTimestampUs: 10000000 + i * 16666);
      }
      final s = acc.snapshot();

      // 整窗 7 帧：span = 10083330 - 0 → fps = 6e6/span（远小于 60）。
      const span = 10000000 + 5 * 16666;
      expect(s.fps, closeTo(6 * 1000000.0 / span, 1e-6));
      expect(s.fps, lessThan(1.0));
    });

    test('百分位 / jank / maxTotal 仍用完整窗口（超窗老 jank 帧仍计）', () {
      final acc = FrameStatsAccumulator();
      // 10s 前的老 jank 帧（total 50ms > 阈值 33.332ms）。
      _feed(acc, 50000, vsyncTimestampUs: 0);
      // 末 2s 内 6 帧 total 16ms。
      for (var i = 0; i < 6; i++) {
        _feed(acc, 16000, vsyncTimestampUs: 10000000 + i * 16666);
      }
      final s = acc.snapshot();

      expect(s.windowJankCount, 1); // 完整窗口仍含老 jank 帧
      expect(s.jankCount, 1); // 生命周期
      expect(s.maxTotalMs, closeTo(50.0, 1e-9));
      expect(s.p99TotalMs, closeTo(50.0, 1e-9));
      // 但 fps 只看近期 6 帧。
      expect(s.fps, closeTo(60.0, 0.1));
    });

    test('自定义 fpsWindow=500ms：仅取末 500ms 内样本', () {
      final acc = FrameStatsAccumulator(
        fpsWindow: const Duration(milliseconds: 500),
      );
      // 早先 3 帧（间隔 10ms）——距末样本 > 500ms，应被排除。
      for (var i = 0; i < 3; i++) {
        _feed(acc, 16000, vsyncTimestampUs: i * 10000); // 0/10000/20000
      }
      // 末 3 帧（间隔 10ms），时间轴在 1s 处。
      for (var i = 0; i < 3; i++) {
        _feed(acc, 16000, vsyncTimestampUs: 1000000 + i * 10000);
      }
      final s = acc.snapshot();

      // 近期 3 帧，span = 20000µs → fps = 2e6/20000 = 100。
      expect(s.fps, closeTo(100.0, 1e-6));
      expect(s.frameIntervalMs, closeTo(10.0, 1e-9));
    });

    test('时间戳全相同 → 近期跨度 0 → fps 0', () {
      final acc = FrameStatsAccumulator();
      for (var i = 0; i < 5; i++) {
        _feed(acc, 16000, vsyncTimestampUs: 424242);
      }
      final s = acc.snapshot();
      expect(s.fps, 0);
      expect(s.frameIntervalMs, 0);
    });
  });
}
