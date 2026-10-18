import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_history_store.dart';
import 'package:gstore/core/perf/perf_report_store.dart';
import 'package:gstore/core/perf/perf_target_store.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';
import 'package:gstore/page/perf/reports_page.dart';
import 'package:gstore/page/perf/view.dart';

/// 假网关：全部方法返回空数据（不触碰 FFI）。
class _FakeGateway implements PerfModuleGateway {
  final StreamController<PerfRawEvent> _events =
      StreamController<PerfRawEvent>.broadcast();

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async =>
      Uint8List.fromList(utf8.encode('{"ok":true,"data":{}}'));

  @override
  Stream<PerfRawEvent> get events => _events.stream;
}

/// 内存报告存储：绕过真实文件 I/O（widget test 的 fake-async 下真实 I/O 不推进）。
class _FakeReportStore extends PerfReportStore {
  _FakeReportStore() : super(baselineStore: InMemoryBaselineStore());

  final List<SavedPerfReport> _reports = <SavedPerfReport>[];

  @override
  Future<SavedPerfReport> saveReport({
    required PerfReportFormat format,
    required String content,
    required DateTime timestamp,
  }) async {
    final saved = SavedPerfReport(
      path: '/fake/perf_${timestamp.millisecondsSinceEpoch}.${format.extension}',
      format: format,
      timestamp: timestamp,
    );
    _reports.add(saved);
    return saved;
  }

  @override
  Future<List<SavedPerfReport>> listReports() async =>
      List<SavedPerfReport>.of(_reports);
}

/// 内存历史存储：绕过真实文件 I/O。
class _FakeHistoryStore extends PerfHistoryStore {
  @override
  Future<PerfHistorySnapshot> load() async => const PerfHistorySnapshot();

  @override
  Future<void> save(PerfHistorySnapshot snapshot) async {}
}

/// 构造一个**已发布 60fps 快照**的帧监控。
FrameMonitor _publishedMonitor() {
  final accumulator = FrameStatsAccumulator();
  final monitor = FrameMonitor(accumulator: accumulator);
  monitor.start();
  for (var i = 0; i < 60; i++) {
    accumulator.addFrame(
      buildUs: 8000,
      rasterUs: 8000,
      vsyncUs: 666,
      totalUs: 16666,
      vsyncTimestampUs: i * 16666,
    );
  }
  monitor.stop();
  return monitor;
}

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settleAsync(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Widget _harness({
  required Widget home,
  required PerfReportStore reportStore,
  required PerfHistoryStore historyStore,
  required PerfTargetStore targetStore,
}) {
  return ProviderScope(
    overrides: [
      perfModuleProvider.overrideWithValue(PerfModule(gateway: _FakeGateway())),
      perfFrameMonitorProvider.overrideWithValue(_publishedMonitor()),
      perfAvailabilityStreamProvider
          .overrideWithValue(const Stream<PerfAvailability>.empty()),
      perfReportStoreProvider.overrideWithValue(reportStore),
      perfHistoryStoreProvider.overrideWithValue(historyStore),
      perfTargetStoreProvider.overrideWithValue(targetStore),
    ],
    child: MaterialApp(home: home),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('基线卡：设为基线 → 对比显示逐指标 delta 行', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_harness(
      home: const PerfMonitorPage(),
      reportStore: _FakeReportStore(),
      historyStore: _FakeHistoryStore(),
      targetStore: InMemoryPerfTargetStore(),
    ));
    await _settleAsync(tester);

    expect(find.text('基线对比'), findsOneWidget);
    expect(find.textContaining('未设置基线'), findsOneWidget);

    await tester.tap(find.byKey(const Key('perf_baseline_set')));
    await _settleAsync(tester);
    expect(find.textContaining('已设置基线'), findsOneWidget);

    await tester.tap(find.byKey(const Key('perf_baseline_compare')));
    await _settleAsync(tester);
    // FPS / jank 可比 → 展示「基线 … → 当前 …」；CPU/内存/温度 数据不足。
    expect(find.textContaining('→ 当前'), findsWidgets);
    expect(find.text('数据不足'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出：选择 JSON → 落盘 → 提供分享 / 复制', (tester) async {
    _useTallViewport(tester);
    final reportStore = _FakeReportStore();
    await tester.pumpWidget(_harness(
      home: const PerfReportsPage(),
      reportStore: reportStore,
      historyStore: _FakeHistoryStore(),
      targetStore: InMemoryPerfTargetStore(
        const PerfPinnedTarget(package: 'com.example.app', label: '示例应用'),
      ),
    ));
    await _settleAsync(tester);

    await tester.tap(find.byKey(const Key('perf_export')));
    await _settleAsync(tester);
    expect(find.text('导出报告'), findsOneWidget);
    expect(find.text('JSON'), findsOneWidget);
    expect(find.text('CSV'), findsOneWidget);

    await tester.tap(find.byKey(const Key('perf_export_json')));
    await _settleAsync(tester);
    expect(find.text('报告已保存'), findsOneWidget);
    expect(find.byKey(const Key('perf_export_share')), findsOneWidget);
    expect(find.byKey(const Key('perf_export_copy')), findsOneWidget);

    expect((await reportStore.listReports()).first.format,
        PerfReportFormat.json);

    await tester.tap(find.byKey(const Key('perf_export_copy')));
    await _settleAsync(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出：选择 CSV 格式落盘', (tester) async {
    _useTallViewport(tester);
    final reportStore = _FakeReportStore();
    await tester.pumpWidget(_harness(
      home: const PerfReportsPage(),
      reportStore: reportStore,
      historyStore: _FakeHistoryStore(),
      targetStore: InMemoryPerfTargetStore(),
    ));
    await _settleAsync(tester);

    await tester.tap(find.byKey(const Key('perf_export')));
    await _settleAsync(tester);
    await tester.tap(find.byKey(const Key('perf_export_csv')));
    await _settleAsync(tester);

    final reports = await reportStore.listReports();
    expect(reports, isNotEmpty);
    expect(reports.first.format, PerfReportFormat.csv);
    expect(tester.takeException(), isNull);
  });
}

