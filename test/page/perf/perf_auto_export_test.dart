import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_auto_export_settings.dart';
import 'package:gstore/core/perf/perf_history_store.dart';
import 'package:gstore/core/perf/perf_report_store.dart';
import 'package:gstore/core/perf/perf_target_store.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';
import 'package:gstore/page/perf/reports_page.dart';
import 'package:gstore/page/perf/view.dart';

/// 假网关：始终抛「模块不可用」，页面降级为单张提示卡（缩短页面）。
class _UnavailableGateway implements PerfModuleGateway {
  final StreamController<PerfRawEvent> _events =
      StreamController<PerfRawEvent>.broadcast();

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async =>
      throw PerfModuleUnavailableException();

  @override
  Stream<PerfRawEvent> get events => _events.stream;
}

/// 就绪网关：`perf.start` 返回 `running=true`；其余方法返回空 `data` 信封。
class _ReadyGateway implements PerfModuleGateway {
  final StreamController<PerfRawEvent> _events =
      StreamController<PerfRawEvent>.broadcast();

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    final Map<String, dynamic> data = switch (method) {
      'perf.start' => <String, dynamic>{'running': true, 'interval_ms': 2000},
      'perf.stop' => <String, dynamic>{'running': false, 'was_running': true},
      _ => <String, dynamic>{},
    };
    return Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );
  }

  @override
  Stream<PerfRawEvent> get events => _events.stream;
}

/// 内存报告存储：绕过真实文件 I/O；可预置报告。
class _MemoryReportStore extends PerfReportStore {
  _MemoryReportStore([List<SavedPerfReport> seed = const <SavedPerfReport>[]])
      : super(baselineStore: InMemoryBaselineStore()) {
    reports.addAll(seed);
  }

  final List<SavedPerfReport> reports = <SavedPerfReport>[];

  @override
  Future<SavedPerfReport> saveReport({
    required PerfReportFormat format,
    required String content,
    required DateTime timestamp,
  }) async {
    final saved = SavedPerfReport(
      path:
          '/mem/perf_${timestamp.millisecondsSinceEpoch}.${format.extension}',
      format: format,
      timestamp: timestamp,
    );
    reports.add(saved);
    return saved;
  }

  @override
  Future<List<SavedPerfReport>> listReports() async =>
      List<SavedPerfReport>.of(reports)
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

  @override
  Future<String?> readReport(String path) async => 'sample-report-content';

  @override
  Future<bool> deleteReport(String path) async {
    reports.removeWhere((report) => report.path == path);
    return true;
  }
}

/// 内存历史存储：绕过真实文件 I/O。
class _FakeHistoryStore extends PerfHistoryStore {
  @override
  Future<PerfHistorySnapshot> load() async => const PerfHistorySnapshot();

  @override
  Future<void> save(PerfHistorySnapshot snapshot) async {}
}

/// 已发布 60fps 快照的帧监控。
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
  tester.view.physicalSize = const Size(1080, 9000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 推进若干帧完成异步加载与弹层动画（不用 pumpAndSettle：AppLoading 无限动画）。
Future<void> _settleAsync(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _harness({
  required PerfReportStore reportStore,
  required PerfAutoExportSettingsStore settingsStore,
}) {
  return ProviderScope(
    overrides: [
      perfModuleProvider
          .overrideWithValue(PerfModule(gateway: _UnavailableGateway())),
      perfFrameMonitorProvider.overrideWithValue(_publishedMonitor()),
      perfAvailabilityStreamProvider
          .overrideWithValue(const Stream<PerfAvailability>.empty()),
      perfReportStoreProvider.overrideWithValue(reportStore),
      perfHistoryStoreProvider.overrideWithValue(_FakeHistoryStore()),
      perfTargetStoreProvider.overrideWithValue(InMemoryPerfTargetStore()),
      perfAutoExportSettingsStoreProvider.overrideWithValue(settingsStore),
    ],
    // 仅挂 navigatorKey（AppDialogs 确认弹层走全局 key）；不挂
    // scaffoldMessengerKey，避免 Snackbar 计时器在测试结尾残留。
    child: MaterialApp(
      navigatorKey: appNavigatorKey,
      home: const PerfReportsPage(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('自动导出配置卡：开关持久化 + 格式选择弹层', (tester) async {
    _useTallViewport(tester);
    final reportStore = _MemoryReportStore();
    final settingsStore = InMemoryPerfAutoExportSettingsStore();

    await tester.pumpWidget(_harness(
      reportStore: reportStore,
      settingsStore: settingsStore,
    ));
    await _settleAsync(tester);

    expect(find.text('自动导出'), findsOneWidget);
    expect(find.byKey(const Key('perf_auto_export_switch')), findsOneWidget);
    var sw = tester.widget<SwitchListTile>(
      find.byKey(const Key('perf_auto_export_switch')),
    );
    expect(sw.value, isFalse);

    await tester.tap(find.byKey(const Key('perf_auto_export_switch')));
    await _settleAsync(tester);
    expect((await settingsStore.load())!.enabled, isTrue);

    await tester.tap(find.byKey(const Key('perf_auto_export_format')));
    await _settleAsync(tester);
    expect(
      find.byKey(const Key('perf_auto_export_format_csv')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('perf_auto_export_format_csv')));
    await _settleAsync(tester);
    expect(
      (await settingsStore.load())!.format,
      PerfAutoExportFormat.csv,
    );
    expect(find.text('CSV 扁平'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动导出间隔：底部弹层编辑保存生效', (tester) async {
    _useTallViewport(tester);
    final settingsStore = InMemoryPerfAutoExportSettingsStore(
      const PerfAutoExportSettings(enabled: true, intervalMinutes: 5),
    );

    await tester.pumpWidget(_harness(
      reportStore: _MemoryReportStore(),
      settingsStore: settingsStore,
    ));
    await _settleAsync(tester);

    expect(find.text('每 5 分钟'), findsOneWidget);

    await tester.tap(find.byKey(const Key('perf_auto_export_interval')));
    await _settleAsync(tester);
    expect(
      find.byKey(const Key('perf_auto_export_interval_input')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('perf_auto_export_interval_input')),
      '15',
    );
    await tester.tap(find.byKey(const Key('perf_auto_export_interval_save')));
    await _settleAsync(tester);

    expect((await settingsStore.load())!.intervalMinutes, 15);
    expect(find.text('每 15 分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('最近报告：列出报告 + 操作弹层 + 菜单删除', (tester) async {
    _useTallViewport(tester);
    final reportStore = _MemoryReportStore(<SavedPerfReport>[
      SavedPerfReport(
        path: '/mem/perf_1000.json',
        format: PerfReportFormat.json,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
      ),
      SavedPerfReport(
        path: '/mem/perf_2000.csv',
        format: PerfReportFormat.csv,
        timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
      ),
    ]);

    await tester.pumpWidget(_harness(
      reportStore: reportStore,
      settingsStore: InMemoryPerfAutoExportSettingsStore(),
    ));
    await _settleAsync(tester);

    expect(find.text('最近报告'), findsOneWidget);
    expect(find.textContaining('perf_2000.csv'), findsOneWidget);
    expect(find.textContaining('perf_1000.json'), findsOneWidget);
    expect(find.byKey(const Key('perf_reports_clear_all')), findsOneWidget);

    // 点击条目 → 操作弹层（查看 / 分享 / 复制）。
    await tester.tap(find.byKey(const Key('perf_report_2000')));
    await _settleAsync(tester);
    expect(find.byKey(const Key('perf_report_view')), findsOneWidget);
    expect(find.byKey(const Key('perf_report_share')), findsOneWidget);
    expect(find.byKey(const Key('perf_report_copy')), findsOneWidget);

    await tester.tap(find.byKey(const Key('perf_report_copy')));
    await _settleAsync(tester);
    expect(tester.takeException(), isNull);

    // 菜单删除 → 确认弹层 → 删除成功。
    await tester.tap(find.byKey(const Key('perf_report_menu_2000')));
    await _settleAsync(tester);
    await tester.tap(find.text('删除').last);
    await _settleAsync(tester);
    expect(find.text('删除报告？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await _settleAsync(tester);

    expect(find.textContaining('perf_2000.csv'), findsNothing);
    expect(find.textContaining('perf_1000.json'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('回归：概览开启采样即驱动自动导出服务（无需报告页挂载）',
      (tester) async {
    _useTallViewport(tester);
    final container = ProviderContainer(
      overrides: [
        perfModuleProvider
            .overrideWithValue(PerfModule(gateway: _ReadyGateway())),
        perfFrameMonitorProvider.overrideWithValue(_publishedMonitor()),
        perfAvailabilityStreamProvider
            .overrideWithValue(Stream<PerfAvailability>.value(
          PerfAvailability.ready,
        )),
        perfReportStoreProvider.overrideWithValue(_MemoryReportStore()),
        perfHistoryStoreProvider.overrideWithValue(_FakeHistoryStore()),
        perfTargetStoreProvider.overrideWithValue(InMemoryPerfTargetStore()),
        perfAutoExportSettingsStoreProvider.overrideWithValue(
          InMemoryPerfAutoExportSettingsStore(
            const PerfAutoExportSettings(enabled: true),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    // 只挂概览页：报告页（_AutoExportCard）不参与，服务必须仍由 provider 驱动。
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PerfMonitorPage()),
      ),
    );
    await _settleAsync(tester);

    // 前置：模块就绪（采样开关可交互），自动导出服务尚未运行。
    final samplingSwitch = tester.widget<SwitchListTile>(
      find.byKey(const Key('perf_sampling_switch')),
    );
    expect(samplingSwitch.onChanged, isNotNull);
    expect(container.read(perfAutoExportServiceProvider).isRunning, isFalse);

    // 开启后台采样 → provider 的 `ref.listen` 驱动服务启动。
    await tester.tap(find.byKey(const Key('perf_sampling_switch')));
    await _settleAsync(tester);
    expect(container.read(perfMonitorProvider).sampling, isTrue);
    expect(container.read(perfAutoExportServiceProvider).isRunning, isTrue);

    // 关闭采样 → 服务停止。（采样关闭路径会 `await _sampleSub.cancel()`，在
    // fake-async 下该 future 需真实事件循环才完成，故经 runAsync 驱动真实开关回调。）
    await tester.runAsync(() async {
      final tile = tester.widget<SwitchListTile>(
        find.byKey(const Key('perf_sampling_switch')),
      );
      tile.onChanged!(!tile.value);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await _settleAsync(tester);
    expect(container.read(perfMonitorProvider).sampling, isFalse);
    expect(container.read(perfAutoExportServiceProvider).isRunning, isFalse);

    expect(tester.takeException(), isNull);
  });
}
