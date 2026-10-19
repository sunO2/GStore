import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';
import 'package:gstore/page/perf/state.dart';
import 'package:gstore/page/perf/view.dart';

/// 只会抛「模块不可用」的空网关（本测试不触碰性能模块）。
class _NoopGateway implements PerfModuleGateway {
  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    throw PerfModuleUnavailableException();
  }

  @override
  Stream<PerfRawEvent> get events => const Stream<PerfRawEvent>.empty();
}

/// 直接产出固定 [PerfPageState] 的假 Notifier（避免真实采集 / 定时器）。
class _FakePerfMonitorNotifier extends PerfMonitorNotifier {
  _FakePerfMonitorNotifier(this._initial);

  final PerfPageState _initial;

  @override
  PerfPageState build() => _initial;
}

/// 60fps 快照（时间戳间隔 16666µs）。
FrameStats _sixtyFpsStats() {
  final acc = FrameStatsAccumulator();
  for (var i = 0; i < 60; i++) {
    acc.addFrame(
      buildUs: 8000,
      rasterUs: 8000,
      vsyncUs: 666,
      totalUs: 16666,
      vsyncTimestampUs: i * 16666,
    );
  }
  return acc.snapshot();
}

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _harness(PerfPageState state) {
  return ProviderScope(
    overrides: [
      perfMonitorProvider.overrideWith(() => _FakePerfMonitorNotifier(state)),
      perfModuleProvider.overrideWithValue(PerfModule(gateway: _NoopGateway())),
      perfFrameMonitorProvider.overrideWithValue(FrameMonitor()),
      perfAvailabilityStreamProvider.overrideWithValue(
        Stream<PerfAvailability>.value(PerfAvailability.failed),
      ),
    ],
    child: const MaterialApp(home: PerfMonitorPage()),
  );
}

void main() {
  testWidgets('FPS 卡：三口径并列标注渲染（本应用 / 屏幕 / 第三方）',
      (tester) async {
    _useTallViewport(tester);
    final state = PerfPageState(
      loading: false,
      frameStats: _sixtyFpsStats(),
      frameMonitorRunning: true,
      screenFps: 118.5,
      screenFpsLayer: 'SurfaceView[com.x/com.x.Main]#0(BLAST)',
      screenFpsHistory: const <double>[118.5],
      thirdPartyFps: 55.0,
      thirdPartyFpsLabel: '微信',
    );

    await tester.pumpWidget(_harness(state));
    await tester.pump();

    // 三个口径 Key 均在。
    expect(find.byKey(const Key('perf_fps_app')), findsOneWidget);
    expect(find.byKey(const Key('perf_fps_screen')), findsOneWidget);
    expect(find.byKey(const Key('perf_fps_third_party')), findsOneWidget);

    // 标签（「第三方」同时是顶部 tab 标签，限定到 FPS 列避免歧义）。
    expect(find.text('本应用'), findsOneWidget);
    expect(find.text('屏幕'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('perf_fps_third_party')),
        matching: find.text('第三方'),
      ),
      findsOneWidget,
    );

    // 数值：本应用 60.0 / 屏幕 118.5 / 第三方 55.0。
    expect(find.text('60.0'), findsOneWidget);
    expect(find.text('118.5'), findsOneWidget);
    expect(find.text('55.0'), findsOneWidget);

    // 副标：屏幕层短名 + 第三方目标展示名。
    expect(find.text('com.x.Main](BLAST)'), findsOneWidget);
    expect(find.text('微信'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('FPS 卡：屏幕 / 第三方缺失时降级文案', (tester) async {
    _useTallViewport(tester);
    final state = PerfPageState(
      loading: false,
      frameStats: _sixtyFpsStats(),
      frameMonitorRunning: false,
    );

    await tester.pumpWidget(_harness(state));
    await tester.pump();

    expect(find.byKey(const Key('perf_fps_screen')), findsOneWidget);
    expect(find.byKey(const Key('perf_fps_third_party')), findsOneWidget);

    // 屏幕缺失 → 需 Shizuku / 无数据；第三方缺失 → 未选择目标。
    expect(find.text('需 Shizuku / 无数据'), findsOneWidget);
    expect(find.text('未选择目标'), findsOneWidget);
    // 两个缺失值均以「—」占位（限定到各自列，避免与 hero / 设备头 / FPS 统计
    // 的「—」占位混淆）。
    expect(
      find.descendant(
        of: find.byKey(const Key('perf_fps_screen')),
        matching: find.text('—'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('perf_fps_third_party')),
        matching: find.text('—'),
      ),
      findsOneWidget,
    );
    // 本应用仍有数值。
    expect(find.text('60.0'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
