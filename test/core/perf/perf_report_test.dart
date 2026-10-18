import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_report.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

/// 构造一个交付 FPS ≈ 60、含 1 帧 jank 的帧统计。
FrameStats _frameStats() {
  final acc = FrameStatsAccumulator();
  for (var i = 0; i < 60; i++) {
    acc.addFrame(
      buildUs: 8000,
      rasterUs: 8000,
      vsyncUs: 666,
      totalUs: i == 10 ? 40000 : 16666,
      vsyncTimestampUs: i * 16666,
    );
  }
  return acc.snapshot();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final timestamp = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  test('buildPerfReportJson：完整分节键与值', () {
    final json = buildPerfReportJson(
      timestamp: timestamp,
      cpu: const CpuReport(usagePercent: 37.5, coreCount: 8, governor: 'schedutil'),
      memory: const MemoryReport(totalKb: 1000, usedKb: 500, usedPercent: 50),
      battery: const BatteryReport(present: true, capacityPercent: 80),
      thermal: const ThermalReport(zoneCount: 2, maxTempC: 42),
      gpu: const GpuReport(name: 'Adreno', freqMhz: 587, busyPercent: 12),
      network: const NetworkReport(rxBytes: 100, txBytes: 200),
      frameStats: _frameStats(),
      targetLabel: '微信',
    );

    expect(json['schema'], kPerfReportSchema);
    expect(json['generated_at_ms'], 1700000000000);
    expect(json['target_label'], '微信');
    final cpu = json['cpu']! as Map<String, dynamic>;
    expect(cpu['usage_percent'], 37.5);
    expect(cpu['core_count'], 8);
    expect(cpu['governor'], 'schedutil');
    final memory = json['memory']! as Map<String, dynamic>;
    expect(memory['used_percent'], 50.0);
    final frame = json['frame']! as Map<String, dynamic>;
    expect((frame['fps']! as num).toDouble(), closeTo(60.0, 0.01));
    expect(frame['jank_count'], 1);
    final network = json['network']! as Map<String, dynamic>;
    expect(network['interface_count'], 0);
    expect(json['third_party'], isNull);
  });

  test('buildPerfReportJson：缺失分节为 null（仅 FPS 也能导出）', () {
    final json = buildPerfReportJson(
      timestamp: timestamp,
      frameStats: _frameStats(),
    );
    expect(json['cpu'], isNull);
    expect(json['memory'], isNull);
    expect(json['battery'], isNull);
    expect(json['thermal'], isNull);
    expect(json['gpu'], isNull);
    expect(json['network'], isNull);
    expect(json['third_party'], isNull);
    expect(json['frame'], isNotNull);
  });

  test('buildPerfReportJson：确定性（同一输入恒定输出）', () {
    Map<String, dynamic> build() => buildPerfReportJson(
          timestamp: timestamp,
          cpu: const CpuReport(usagePercent: 10),
          frameStats: _frameStats(),
        );
    expect(jsonEncode(build()), jsonEncode(build()));
  });

  test('buildPerfReportJson：第三方 Sample 优先于 metrics 并带 ts', () {
    const metrics = ThirdPartyAppMetrics(
      package: 'com.example',
      cpuPercent: 12.5,
      memPssKb: 204800,
      fps: 58.5,
    );
    final json = buildPerfReportJson(
      timestamp: timestamp,
      thirdParty: const ThirdPartyAppMetrics(package: 'ignored'),
      thirdPartySample: const ThirdPartySample(tsMs: 2000, metrics: metrics),
    );
    final tp = json['third_party']! as Map<String, dynamic>;
    expect(tp['package'], 'com.example');
    expect(tp['cpu_percent'], 12.5);
    expect(tp['fps'], 58.5);
    expect(tp['ts_ms'], 2000);
  });

  test('buildPerfReportCsv：表头 + 扁平行 + null 空值', () {
    final csv = buildPerfReportCsv(
      timestamp: timestamp,
      cpu: const CpuReport(usagePercent: 37.5, coreCount: 8),
      thermal: const ThermalReport(zoneCount: 2, maxTempC: 42),
    );
    final lines = csv.split('\n');
    expect(lines.first, 'section,metric,value');
    expect(lines, contains('cpu,usage_percent,37.5'));
    expect(lines, contains('cpu,core_count,8'));
    expect(lines, contains('thermal,max_temp_c,42.0'));
    // 缺失分节不产出任何行。
    expect(lines.any((l) => l.startsWith('memory,')), isFalse);
    expect(lines.any((l) => l.startsWith('gpu,')), isFalse);
  });

  test('buildPerfReportCsv：仅 FPS 时仍含 frame 行', () {
    final csv = buildPerfReportCsv(timestamp: timestamp, frameStats: _frameStats());
    expect(csv.split('\n').first, 'section,metric,value');
    expect(csv, contains('frame,fps,'));
    expect(csv, contains('frame,jank_count,1'));
  });

  test('buildPerfReportCsv：字段含逗号时被引号转义', () {
    final csv = buildPerfReportCsv(
      timestamp: timestamp,
      cpu: const CpuReport(governor: 'a,b'),
    );
    expect(csv, contains('"a,b"'));
  });
}
