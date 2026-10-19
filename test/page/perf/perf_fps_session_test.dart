import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/perf/fps_session.dart';
import 'package:gstore/core/perf/fps_session_recorder.dart';
import 'package:gstore/core/perf/fps_session_store.dart';
import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_auto_export_settings.dart';
import 'package:gstore/core/perf/perf_history_store.dart';
import 'package:gstore/core/perf/perf_report_store.dart';
import 'package:gstore/core/perf/perf_target_store.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';
import 'package:gstore/page/perf/reports_page.dart';

/// 假网关：始终抛「模块不可用」，缩短页面为降级展示。
class _UnavailableGateway implements PerfModuleGateway {
  final StreamController<PerfRawEvent> _events =
      StreamController<PerfRawEvent>.broadcast();

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async =>
      throw PerfModuleUnavailableException();

  @override
  Stream<PerfRawEvent> get events => _events.stream;
}

/// 内存报告存储：绕过真实文件 I/O。
class _MemoryReportStore extends PerfReportStore {
  _MemoryReportStore() : super(baselineStore: InMemoryBaselineStore());

  @override
  Future<List<SavedPerfReport>> listReports() async =>
      const <SavedPerfReport>[];

  @override
  Future<String?> readReport(String path) async => null;
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
  required FpsSessionStore store,
  required FpsSessionRecorder recorder,
}) {
  return ProviderScope(
    overrides: [
      perfModuleProvider
          .overrideWithValue(PerfModule(gateway: _UnavailableGateway())),
      perfFrameMonitorProvider.overrideWithValue(_publishedMonitor()),
      perfAvailabilityStreamProvider
          .overrideWithValue(const Stream<PerfAvailability>.empty()),
      perfReportStoreProvider.overrideWithValue(_MemoryReportStore()),
      perfHistoryStoreProvider.overrideWithValue(_FakeHistoryStore()),
      perfTargetStoreProvider.overrideWithValue(InMemoryPerfTargetStore()),
      perfAutoExportSettingsStoreProvider
          .overrideWithValue(InMemoryPerfAutoExportSettingsStore()),
      fpsSessionStoreProvider.overrideWithValue(store),
      fpsSessionRecorderProvider.overrideWithValue(recorder),
    ],
    // 挂 navigatorKey（AppDialogs 确认弹层走全局 key）；不挂 scaffoldMessengerKey。
    child: MaterialApp(
      navigatorKey: appNavigatorKey,
      home: const PerfReportsPage(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('FPS 会话卡：开始/停止录制，实时状态与列表', (tester) async {
    _useTallViewport(tester);
    final store = InMemoryFpsSessionStore();
    final sequence = <double>[60, 60, 30];
    var index = 0;
    final recorder = FpsSessionRecorder(
      store: store,
      sampler: () async => index < sequence.length ? sequence[index++] : null,
      maxDuration: null,
    );
    addTearDown(recorder.dispose);

    await tester.pumpWidget(_harness(store: store, recorder: recorder));
    await _settleAsync(tester);

    expect(find.text('FPS 会话录制'), findsOneWidget);
    expect(find.byKey(const Key('perf_fps_record_live')), findsOneWidget);
    expect(find.byKey(const Key('perf_fps_record_toggle')), findsOneWidget);
    expect(find.byKey(const Key('perf_fps_sessions')), findsOneWidget);
    expect(find.text('开始录制'), findsOneWidget);

    // 开始录制。
    await tester.tap(find.byKey(const Key('perf_fps_record_toggle')));
    await tester.pump();
    expect(find.text('停止录制'), findsOneWidget);

    // 三拍采样：60 / 60 / 30。
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    }

    final live = find.byKey(const Key('perf_fps_record_live'));
    expect(
      find.descendant(of: live, matching: find.text('30.0')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: live, matching: find.text('3')),
      findsOneWidget,
    );

    // 停止 → 落盘并刷新列表。
    await tester.tap(find.byKey(const Key('perf_fps_record_toggle')));
    await _settleAsync(tester);

    expect(find.text('开始录制'), findsOneWidget);
    expect(find.textContaining('avg 50.0'), findsOneWidget);
    expect(find.textContaining('min 30.0'), findsOneWidget);
    expect(find.textContaining('max 60.0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FPS 会话卡：列出会话 + 导出 + 删除', (tester) async {
    _useTallViewport(tester);
    final store = InMemoryFpsSessionStore(
      seed: <FpsSession>[
        FpsSession.fromRecording(
          id: 's1',
          label: '测试会话',
          startMs: 1000,
          endMs: 61000,
          samples: const <double>[60, 60, 30],
        ),
      ],
    );
    final recorder = FpsSessionRecorder(
      store: store,
      sampler: () async => null,
      maxDuration: null,
    );
    addTearDown(recorder.dispose);

    await tester.pumpWidget(_harness(store: store, recorder: recorder));
    await _settleAsync(tester);

    expect(find.byKey(const Key('perf_fps_session_s1')), findsOneWidget);
    expect(
      find.byKey(const Key('perf_fps_session_delete_s1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('perf_fps_session_export_s1')),
      findsOneWidget,
    );
    expect(find.text('测试会话'), findsOneWidget);
    expect(find.textContaining('1分0秒'), findsOneWidget);
    expect(find.textContaining('avg 50.0'), findsOneWidget);
    expect(find.textContaining('min 30.0'), findsOneWidget);
    expect(find.textContaining('max 60.0'), findsOneWidget);

    // 导出（无宿主 method channel → 退化为复制，无异常）。
    await tester.tap(find.byKey(const Key('perf_fps_session_export_s1')));
    await _settleAsync(tester);
    expect(tester.takeException(), isNull);

    // 删除 → 确认弹层 → 列表移除。
    await tester.tap(find.byKey(const Key('perf_fps_session_delete_s1')));
    await _settleAsync(tester);
    expect(find.text('删除会话？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await _settleAsync(tester);

    expect(find.byKey(const Key('perf_fps_session_s1')), findsNothing);
    expect(find.textContaining('暂无会话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FPS 会话卡：列表与详情显示 Scene-parity 指标', (tester) async {
    _useTallViewport(tester);
    final store = InMemoryFpsSessionStore(
      seed: <FpsSession>[
        FpsSession.fromRecording(
          id: 'sp1',
          label: '场景会话',
          startMs: 1000,
          endMs: 3000,
          samples: const <double>[60, 60, 30],
          avgPower: 1.25,
          viewSize: '1080.0x2340.0',
          mode: '均衡',
          temperatures: const <double>[46, 41.5],
        ),
      ],
    );
    final recorder = FpsSessionRecorder(
      store: store,
      sampler: () async => null,
      maxDuration: null,
    );
    addTearDown(recorder.dispose);

    await tester.pumpWidget(_harness(store: store, recorder: recorder));
    await _settleAsync(tester);

    // 列表：流畅度 2/3→67%、高温 1/2→50%、功耗 / 模式 / 视图。
    expect(find.textContaining('流畅度 67%'), findsOneWidget);
    expect(find.textContaining('高温占比 50%'), findsOneWidget);
    expect(find.textContaining('功耗 1.25 W'), findsOneWidget);
    expect(find.textContaining('模式 均衡'), findsOneWidget);
    expect(find.textContaining('视图 1080.0x2340.0'), findsOneWidget);

    // 点开详情：全部 Scene-parity 指标逐项展示。
    await tester.tap(find.byKey(const Key('perf_fps_session_sp1')));
    await _settleAsync(tester);
    expect(find.text('平均功耗'), findsOneWidget);
    expect(find.text('1.25 W'), findsOneWidget);
    expect(find.text('流畅度'), findsOneWidget);
    expect(find.text('67%'), findsOneWidget);
    expect(find.text('高温占比'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('均衡'), findsOneWidget);
    expect(find.text('1080.0x2340.0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FPS 会话卡：无数据会话指标降级为 —', (tester) async {
    _useTallViewport(tester);
    final store = InMemoryFpsSessionStore(
      seed: <FpsSession>[
        FpsSession.fromRecording(
          id: 'empty1',
          label: '空数据',
          startMs: 0,
          endMs: 0,
          samples: const <double>[],
        ),
      ],
    );
    final recorder = FpsSessionRecorder(
      store: store,
      sampler: () async => null,
      maxDuration: null,
    );
    addTearDown(recorder.dispose);

    await tester.pumpWidget(_harness(store: store, recorder: recorder));
    await _settleAsync(tester);

    // 无样本 → 列表比率与模式/视图均为降级展示，不抛异常。
    expect(find.textContaining('流畅度 —'), findsOneWidget);
    expect(find.textContaining('高温占比 —'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
