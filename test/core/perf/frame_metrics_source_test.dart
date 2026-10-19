import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/frame_metrics_source.dart';

void main() {
  group('frameMetricsFromJson', () {
    test('解析完整摘要', () {
      final reading = frameMetricsFromJson(
        '{"count":120,"avgMs":12.5,"p90Ms":18.0,"p99Ms":24.0,'
        '"jankPercent":8.3,"lastMs":11.0,"refreshRate":120.0,'
        '"windowSize":300}',
      );

      expect(reading, isNotNull);
      expect(reading!.count, 120);
      expect(reading.avgMs, 12.5);
      expect(reading.p90Ms, 18.0);
      expect(reading.p99Ms, 24.0);
      expect(reading.jankPercent, closeTo(8.3, 1e-9));
      expect(reading.lastMs, 11.0);
      expect(reading.refreshRate, 120.0);
      expect(reading.windowSize, 300);
      expect(reading.hasSamples, isTrue);
    });

    test('非法 / 非对象 / 无样本 → null', () {
      expect(frameMetricsFromJson('not-json'), isNull);
      expect(frameMetricsFromJson('[]'), isNull);
      expect(frameMetricsFromJson('{}'), isNull);
      expect(frameMetricsFromJson('{"count":0}'), isNull);
    });

    test('缺失数值字段降级为 0，jankPercent 钳制到 [0,100]', () {
      final reading = frameMetricsFromJson('{"count":5,"jankPercent":150}');

      expect(reading, isNotNull);
      expect(reading!.avgMs, 0);
      expect(reading.p90Ms, 0);
      expect(reading.jankPercent, 100);
      expect(reading.refreshRate, isNull);
    });
  });

  group('frameMetricsFromDurations（jank 口径）', () {
    test('60Hz 罐头帧：25ms 阈值，4 帧中 1 帧 jank = 25%', () {
      final reading = frameMetricsFromDurations(
        const <double>[16, 16, 16, 40],
        refreshRate: 60,
      );

      expect(reading.count, 4);
      expect(reading.avgMs, 22.0);
      expect(reading.p90Ms, 40.0);
      expect(reading.p99Ms, 40.0);
      expect(reading.jankPercent, 25.0);
      expect(reading.lastMs, 40.0);
    });

    test('120Hz：阈值 12.5ms，30ms 帧计入 jank', () {
      final reading = frameMetricsFromDurations(
        const <double>[8, 8, 30],
        refreshRate: 120,
      );

      expect(reading.count, 3);
      expect(reading.jankPercent, closeTo(100 / 3, 1e-9));
      expect(reading.p90Ms, 30.0);
    });

    test('空列表 → 零摘要', () {
      final reading = frameMetricsFromDurations(const <double>[]);
      expect(reading.count, 0);
      expect(reading.hasSamples, isFalse);
      expect(reading.jankPercent, 0);
    });

    test('过滤 NaN / Infinity / 负数', () {
      final reading = frameMetricsFromDurations(
        const <double>[double.nan, double.infinity, -1, 10],
      );
      expect(reading.count, 1);
      expect(reading.avgMs, 10);
    });
  });

  group('RustJniFrameMetricsBridge', () {
    test('注入读取器：正常 JSON → 模型', () async {
      final bridge = RustJniFrameMetricsBridge(
        readJson: () async => '{"count":2,"avgMs":9,"p90Ms":10,'
            '"p99Ms":10,"jankPercent":0,"lastMs":10}',
      );
      final reading = await bridge.read();
      expect(reading?.count, 2);
    });

    test('注入读取器：null / 抛异常 / 空串 → null', () async {
      expect(
        await RustJniFrameMetricsBridge(readJson: () async => null).read(),
        isNull,
      );
      expect(
        await RustJniFrameMetricsBridge(readJson: () async => '').read(),
        isNull,
      );
      expect(
        await RustJniFrameMetricsBridge(
          readJson: () async => throw StateError('ffi'),
        ).read(),
        isNull,
      );
    });
  });
}
