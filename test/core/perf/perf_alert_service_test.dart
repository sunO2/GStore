import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_alert_service.dart';
import 'package:gstore/core/perf/perf_alert_settings.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

/// 构造带指定交付 FPS / jank 帧数的 [FrameStats]（纯 Dart 累加器）。
FrameStats _frameStats({required double fps, int janky = 0, int frames = 6}) {
  final intervalUs = (1000000 / fps).round();
  final acc = FrameStatsAccumulator(window: 120, worstFramesLimit: 0);
  for (var i = 0; i < frames; i++) {
    final isJanky = i < janky;
    acc.addFrame(
      buildUs: isJanky ? 40000 : 8000,
      rasterUs: 4000,
      vsyncUs: 100,
      totalUs: isJanky ? 45000 : 12100,
      vsyncTimestampUs: i * intervalUs,
    );
  }
  return acc.snapshot();
}

/// 记录型出口（spy），可选在横幅上抛错以验证「绝不抛错」。
class _RecordingNotifier implements PerfAlertNotifier {
  final List<PerfAlert> banners = <PerfAlert>[];
  final List<PerfAlert> notifications = <PerfAlert>[];
  bool throwOnBanner = false;

  @override
  Future<void> showBanner(PerfAlert alert) async {
    if (throwOnBanner) throw StateError('banner boom');
    banners.add(alert);
  }

  @override
  Future<void> notify(PerfAlert alert) async => notifications.add(alert);
}

const PerfAlertSettings _on = PerfAlertSettings(enabled: true);

void main() {
  group('evaluate 纯阈值评估', () {
    test('关闭时不产出任何告警', () {
      final alerts = evaluate(
        cpu: const CpuReport(usagePercent: 99),
        thermal: const ThermalReport(zoneCount: 1, maxTempC: 60),
        frames: _frameStats(fps: 10, janky: 5),
        thirdParty: const ThirdPartyAppMetrics(
          jankyPercent: 90,
          fps: 1,
        ),
        settings: PerfAlertSettings.defaults,
      );
      expect(alerts, isEmpty);
    });

    test('全部输入为空 → 空列表（不猜）', () {
      expect(evaluate(settings: _on), isEmpty);
    });

    test('CPU 超过阈值触发；等于阈值为边界不触发', () {
      final over = evaluate(
        cpu: const CpuReport(usagePercent: 91),
        settings: _on,
      );
      expect(over, hasLength(1));
      expect(over.single.kind, PerfAlertKind.cpu);
      expect(over.single.value, 91);
      expect(over.single.threshold, 80);

      final boundary = evaluate(
        cpu: const CpuReport(usagePercent: 80),
        settings: _on,
      );
      expect(boundary, isEmpty);
    });

    test('温度超过阈值触发；等于阈值不触发', () {
      final over = evaluate(
        thermal: const ThermalReport(zoneCount: 1, maxTempC: 46.5),
        settings: _on,
      );
      expect(over.single.kind, PerfAlertKind.temperature);
      expect(over.single.value, 46.5);

      final boundary = evaluate(
        thermal: const ThermalReport(zoneCount: 1, maxTempC: 45),
        settings: _on,
      );
      expect(boundary, isEmpty);
    });

    test('Jank 取第三方占比与窗口比例中的较大者', () {
      // thirdParty 25% vs frames 16.7% → 取 25%。
      final alerts = evaluate(
        thirdParty: const ThirdPartyAppMetrics(jankyPercent: 25),
        frames: _frameStats(fps: 60, janky: 1),
        settings: _on,
      );
      final jank = alerts.singleWhere((a) => a.kind == PerfAlertKind.jank);
      expect(jank.value, 25);
    });

    test('Jank：仅有帧统计时用 windowJankRatio；无 jank 不触发', () {
      final alerts = evaluate(
        frames: _frameStats(fps: 60, janky: 2),
        settings: _on,
      );
      final jank = alerts.singleWhere((a) => a.kind == PerfAlertKind.jank);
      expect(jank.value, closeTo(200 / 6, 0.01));

      final clean = evaluate(
        frames: _frameStats(fps: 60),
        settings: _on,
      );
      expect(clean.where((a) => a.kind == PerfAlertKind.jank), isEmpty);
    });

    test('Jank 等于阈值不触发', () {
      final alerts = evaluate(
        thirdParty: const ThirdPartyAppMetrics(jankyPercent: 5),
        settings: _on,
      );
      expect(alerts, isEmpty);
    });

    test('FPS 低于阈值触发（第三方）；等于阈值不触发', () {
      final low = evaluate(
        thirdParty: const ThirdPartyAppMetrics(fps: 33.5),
        settings: _on,
      );
      expect(low.single.kind, PerfAlertKind.fps);
      expect(low.single.value, 33.5);

      final boundary = evaluate(
        thirdParty: const ThirdPartyAppMetrics(fps: 50),
        settings: _on,
      );
      expect(boundary, isEmpty);
    });

    test('FPS：仅有帧统计（≥2 帧）时参与评估', () {
      final alerts = evaluate(
        frames: _frameStats(fps: 20),
        settings: _on,
      );
      final fps = alerts.singleWhere((a) => a.kind == PerfAlertKind.fps);
      expect(fps.value, closeTo(20, 0.01));

      // 无样本（fps=0）不应被误判为 0fps。
      final empty = evaluate(
        frames: FrameStats.empty(
          windowSize: 120,
          budgetMs: 16.666,
          jankThresholdMs: 33.332,
        ),
        settings: _on,
      );
      expect(empty, isEmpty);
    });

    test('FPS 取第三方与帧统计中的较小者', () {
      final alerts = evaluate(
        thirdParty: const ThirdPartyAppMetrics(fps: 45),
        frames: _frameStats(fps: 30),
        settings: _on,
      );
      final fps = alerts.singleWhere((a) => a.kind == PerfAlertKind.fps);
      expect(fps.value, closeTo(30, 0.01));
    });

    test('多项越界 → 同时产出多条告警', () {
      final alerts = evaluate(
        cpu: const CpuReport(usagePercent: 95),
        thermal: const ThermalReport(zoneCount: 1, maxTempC: 52),
        thirdParty: const ThirdPartyAppMetrics(jankyPercent: 30, fps: 12),
        settings: _on,
      );
      expect(alerts.map((a) => a.kind).toSet(), <PerfAlertKind>{
        PerfAlertKind.cpu,
        PerfAlertKind.temperature,
        PerfAlertKind.jank,
        PerfAlertKind.fps,
      });
    });
  });

  group('PerfAlertDispatcher 节流 / 去重 / 降级', () {
    test('首次派发横幅 + 通知；未过节流窗口不重复；过期后再次派发', () async {
      final notifier = _RecordingNotifier();
      var now = DateTime.fromMillisecondsSinceEpoch(0);
      final dispatcher = PerfAlertDispatcher(
        notifier: notifier,
        clock: () => now,
        bannerThrottle: const Duration(seconds: 60),
        notifyThrottle: const Duration(seconds: 60),
      );
      const alerts = <PerfAlert>[
        PerfAlert(kind: PerfAlertKind.cpu, value: 95, threshold: 80),
      ];

      final first = await dispatcher.dispatch(alerts, settings: _on);
      expect(first.banners, hasLength(1));
      expect(first.notifications, hasLength(1));

      final second = await dispatcher.dispatch(alerts, settings: _on);
      expect(second.isEmpty, isTrue);
      expect(notifier.banners, hasLength(1));
      expect(notifier.notifications, hasLength(1));

      now = now.add(const Duration(seconds: 61));
      final third = await dispatcher.dispatch(alerts, settings: _on);
      expect(third.banners, hasLength(1));
      expect(notifier.banners, hasLength(2));
    });

    test('同一批内同 kind 去重为一次', () async {
      final notifier = _RecordingNotifier();
      final dispatcher = PerfAlertDispatcher(notifier: notifier);
      final result = await dispatcher.dispatch(
        const <PerfAlert>[
          PerfAlert(kind: PerfAlertKind.jank, value: 30, threshold: 5),
          PerfAlert(kind: PerfAlertKind.jank, value: 40, threshold: 5),
        ],
        settings: _on,
      );
      expect(result.banners, hasLength(1));
      expect(notifier.banners.single.value, 30);
    });

    test('通知 / 横幅开关分别生效', () async {
      final notifier = _RecordingNotifier();
      final dispatcher = PerfAlertDispatcher(notifier: notifier);
      const alerts = <PerfAlert>[
        PerfAlert(kind: PerfAlertKind.cpu, value: 95, threshold: 80),
      ];

      final bannersOnly = await dispatcher.dispatch(
        alerts,
        settings: _on.copyWith(notify: false),
      );
      expect(bannersOnly.banners, hasLength(1));
      expect(bannersOnly.notifications, isEmpty);

      final quiet = await PerfAlertDispatcher(notifier: _RecordingNotifier())
          .dispatch(alerts, settings: _on.copyWith(banner: false, notify: false));
      expect(quiet.isEmpty, isTrue);
    });

    test('设置关闭 → 空结果', () async {
      final notifier = _RecordingNotifier();
      final dispatcher = PerfAlertDispatcher(notifier: notifier);
      final result = await dispatcher.dispatch(
        const <PerfAlert>[
          PerfAlert(kind: PerfAlertKind.cpu, value: 95, threshold: 80),
        ],
        settings: PerfAlertSettings.defaults,
      );
      expect(result.isEmpty, isTrue);
      expect(notifier.banners, isEmpty);
    });

    test('出口抛错不向上传播（绝不抛错）', () async {
      final notifier = _RecordingNotifier()..throwOnBanner = true;
      final dispatcher = PerfAlertDispatcher(notifier: notifier);
      final result = await dispatcher.dispatch(
        const <PerfAlert>[
          PerfAlert(kind: PerfAlertKind.cpu, value: 95, threshold: 80),
        ],
        settings: _on,
      );
      // 横幅抛错被吞，通知仍照常发出。
      expect(result.notifications, hasLength(1));
      expect(notifier.notifications, hasLength(1));
      expect(notifier.banners, isEmpty);
    });
  });
}
