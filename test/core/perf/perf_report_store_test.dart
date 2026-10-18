import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_report_store.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PerfReportStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('perf_report_store_test');
    store = PerfReportStore(
      directoryProvider: () async => tempDir,
      baselineStore: InMemoryBaselineStore(),
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('saveReport 落盘到 perf_reports/perf_<ts>.json 并可读回', () async {
    final ts = DateTime.fromMillisecondsSinceEpoch(1700000000123);
    final saved = await store.saveReport(
      format: PerfReportFormat.json,
      content: '{"a":1}',
      timestamp: ts,
    );
    expect(saved.fileName, 'perf_1700000000123.json');
    expect(saved.path, contains('perf_reports'));
    expect(File(saved.path).existsSync(), isTrue);
    expect(await store.readReport(saved.path), '{"a":1}');
  });

  test('listReports 按时间戳降序返回 json/csv', () async {
    await store.saveReport(
      format: PerfReportFormat.json,
      content: 'a',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    await store.saveReport(
      format: PerfReportFormat.csv,
      content: 'b',
      timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
    );
    final list = await store.listReports();
    expect(list.length, 2);
    expect(list.first.timestamp.millisecondsSinceEpoch, 2000);
    expect(list.first.format, PerfReportFormat.csv);
    expect(list.last.format, PerfReportFormat.json);
  });

  test('deleteReport 删除文件；readReport 缺失返回 null', () async {
    final saved = await store.saveReport(
      format: PerfReportFormat.json,
      content: 'x',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1),
    );
    expect(await store.deleteReport(saved.path), isTrue);
    expect(File(saved.path).existsSync(), isFalse);
    expect(await store.readReport(saved.path), isNull);
    expect(await store.deleteReport(saved.path), isTrue);
  });

  test('基线 save/load/clear 往返', () async {
    expect(await store.loadBaseline(), isNull);
    await store.saveBaseline(<String, dynamic>{
      'cpu_percent': 12.5,
      'fps': 60.0,
      kPerfBaselineTsKey: 1700000000000,
    });
    final loaded = await store.loadBaseline();
    expect(loaded, isNotNull);
    expect(loaded!['cpu_percent'], 12.5);
    expect(loaded['fps'], 60.0);
    await store.clearBaseline();
    expect(await store.loadBaseline(), isNull);
  });

  test('buildBaselineMetrics：抽取五指标 + 时间戳，缺失项不写入', () {
    final acc = FrameStatsAccumulator();
    for (var i = 0; i < 4; i++) {
      acc.addFrame(
        buildUs: 8000,
        rasterUs: 8000,
        vsyncUs: 666,
        totalUs: 16666,
        vsyncTimestampUs: i * 16666,
      );
    }
    final metrics = buildBaselineMetrics(
      cpu: const CpuReport(usagePercent: 20),
      memory: const MemoryReport(usedPercent: 40),
      thermal: const ThermalReport(maxTempC: 45),
      frameStats: acc.snapshot(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(999),
    );
    expect(metrics['cpu_percent'], 20.0);
    expect(metrics['memory_percent'], 40.0);
    expect(metrics['thermal_max_c'], 45.0);
    expect(metrics['fps'], isA<double>());
    expect(metrics['jank_percent'], isA<double>());
    expect(metrics[kPerfBaselineTsKey], 999);

    final partial = buildBaselineMetrics(cpu: const CpuReport(usagePercent: 1));
    expect(partial.containsKey('fps'), isFalse);
    expect(partial.containsKey('thermal_max_c'), isFalse);
  });

  test('compareToBaseline：delta / deltaPercent / 缺失数学', () {
    final deltas = compareToBaseline(
      <String, dynamic>{
        'cpu_percent': 30.0,
        'memory_percent': 40.0,
        'fps': 50.0,
      },
      <String, dynamic>{
        'cpu_percent': 20.0,
        'memory_percent': 50.0,
        'fps': 60.0,
      },
    );
    expect(deltas.length, kPerfBaselineMetrics.length);
    final cpu = deltas.firstWhere((d) => d.key == 'cpu_percent');
    expect(cpu.delta, 10.0);
    expect(cpu.deltaPercent, 50.0);
    final mem = deltas.firstWhere((d) => d.key == 'memory_percent');
    expect(mem.delta, -10.0);
    expect(mem.deltaPercent, -20.0);
    // 温度缺失 → 不可比。
    final thermal = deltas.firstWhere((d) => d.key == 'thermal_max_c');
    expect(thermal.comparable, isFalse);
    expect(thermal.delta, isNull);
    expect(thermal.deltaPercent, isNull);
  });

  test('compareToBaseline：基线为 0 时 deltaPercent 为 null', () {
    final deltas = compareToBaseline(
      <String, dynamic>{'fps': 10.0},
      <String, dynamic>{'fps': 0.0},
    );
    final fps = deltas.firstWhere((d) => d.key == 'fps');
    expect(fps.delta, 10.0);
    expect(fps.deltaPercent, isNull);
  });

  test('SharedPrefsBaselineStore：跨实例持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final storeA = PerfReportStore(baselineStore: const SharedPrefsBaselineStore());
    await storeA.saveBaseline(<String, dynamic>{'cpu_percent': 7.0});
    final storeB = PerfReportStore(baselineStore: const SharedPrefsBaselineStore());
    final loaded = await storeB.loadBaseline();
    expect(loaded!['cpu_percent'], 7.0);
    await storeB.clearBaseline();
    expect(await storeA.loadBaseline(), isNull);
  });
}
