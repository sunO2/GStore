import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';
import 'package:gstore/page/perf/scene_dashboard_hero.dart';
import 'package:gstore/page/perf/scene_ring_gauge.dart';
import 'package:gstore/page/perf/state.dart';
import 'package:gstore/page/perf/view.dart';

/// 空网关（本测试不触发真实刷新 / 采集；仅用于覆盖 provider）。
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

/// 概览状态：全量设备报告 + FPS 滚动历史 `[60,30,50]` + 温度历史 `[47,40]`。
///
/// * MAX/MIN/AVG = 60.0 / 30.0 / 46.7（`140/3`）；
/// * ≥45fps 占比 = `2/3` = 66.7%；
/// * ≥46℃ 占比 = `1/2` = 50.0%。
PerfPageState _overviewState() => PerfPageState(
      loading: false,
      availability: PerfAvailability.ready,
      frameMonitorRunning: true,
      frameStats: _sixtyFpsStats(),
      fpsHistory: const <double>[60, 30, 50],
      thermalMaxHistory: const <double>[47, 40],
      cpu: const CpuReport(
        usagePercent: 37.5,
        perCoreUsage: <double>[10.0, 95.0, 50.0],
        coreCount: 3,
        governor: 'schedutil',
        cores: <PerfCpuCore>[
          PerfCpuCore(id: 0, freqMhz: 1800),
          PerfCpuCore(id: 1, freqMhz: 2200),
          PerfCpuCore(id: 2, freqMhz: 2400),
        ],
      ),
      memory: const MemoryReport(
        usedPercent: 50,
        swapPercent: 25,
        usedKb: 8192000,
        usedHuman: '8 GB',
        swapUsedKb: 1024000,
        swapUsedHuman: '1 GB',
      ),
      gpu: const GpuReport(busyPercent: 12, freqMhz: 587, name: 'Adreno 650'),
      battery: const BatteryReport(
        present: true,
        capacityPercent: 80,
        status: 'Charging',
        currentMa: 500,
        voltageV: 4.2,
        temperatureC: 42,
      ),
      thermal: const ThermalReport(
        maxTempC: 42,
        zones: <ThermalZone>[
          ThermalZone(zone: 'thermal_zone0', kind: 'cpu', tempC: 42),
        ],
      ),
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 6000);
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

/// 推进若干帧让异步 provider（设备信息 / 能力）收敛，不触发无限加载动画。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Finder _inKey(String key, String text) => find.descendant(
      of: find.byKey(Key(key)),
      matching: find.text(text),
    );

void main() {
  testWidgets('概览 Scene 化：hero 置顶（ring gauges）、设备头、FPS 统计、tab 完整',
      (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_harness(_overviewState()));
    await _settle(tester);

    // ---------- SceneDashboardHero 作为第一个概览项 ----------
    expect(find.byType(SceneDashboardHero), findsOneWidget);
    expect(find.byKey(const Key('scene_hero_rings')), findsOneWidget);
    // 招牌圆环（RAM / SWAP / GPU / CPU）由 hero 渲染。
    expect(find.byType(SceneRingGauge), findsNWidgets(4));

    // ---------- 设备信息头（机型 / 平台 / 系统；noop 网关 → 占位「—」）----------
    expect(find.byKey(const Key('perf_device_header')), findsOneWidget);
    expect(find.byKey(const Key('perf_device_model')), findsOneWidget);
    expect(find.byKey(const Key('perf_device_platform')), findsOneWidget);
    expect(find.byKey(const Key('perf_device_os')), findsOneWidget);
    // 无数据降级：三个设备格均显「—」。
    expect(_inKey('perf_device_model', '—'), findsOneWidget);
    expect(_inKey('perf_device_platform', '—'), findsOneWidget);
    expect(_inKey('perf_device_os', '—'), findsOneWidget);

    // ---------- FPS 统计（MAX / MIN / AVG + ≥45fps / ≥46℃）----------
    expect(find.byKey(const Key('perf_fps_max')), findsOneWidget);
    expect(find.byKey(const Key('perf_fps_min')), findsOneWidget);
    expect(find.byKey(const Key('perf_fps_avg')), findsOneWidget);
    expect(find.byKey(const Key('perf_fps_fluency')), findsOneWidget);
    expect(find.byKey(const Key('perf_fps_hightemp')), findsOneWidget);

    expect(_inKey('perf_fps_max', '60.0'), findsOneWidget);
    expect(_inKey('perf_fps_min', '30.0'), findsOneWidget);
    expect(_inKey('perf_fps_avg', '46.7'), findsOneWidget);
    expect(_inKey('perf_fps_fluency', '66.7%'), findsOneWidget);
    expect(_inKey('perf_fps_hightemp', '50.0%'), findsOneWidget);

    // ---------- 五段 tab 原样保留 ----------
    expect(find.byKey(const Key('perf-tab-switch')), findsOneWidget);
    for (final key in const <String>[
      'perf_tab_overview',
      'perf_tab_hardware',
      'perf_tab_control',
      'perf_tab_reports',
      'perf_tab_third_party',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: '$key 应存在');
    }

    // ---------- 既有功能保留 ----------
    expect(find.byKey(const Key('perf_frame_toggle')), findsOneWidget);
    expect(find.byKey(const Key('perf_sampling_switch')), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('概览 Scene 化：无 FPS / 温度样本时统计降级为「—」', (tester) async {
    _useTallViewport(tester);
    // 空历史（frameStats 有 60fps 但滚动历史为空）→ 统计全「—」。
    await tester.pumpWidget(_harness(PerfPageState(
      loading: false,
      availability: PerfAvailability.ready,
      frameStats: _sixtyFpsStats(),
    )));
    await _settle(tester);

    for (final key in const <String>[
      'perf_fps_max',
      'perf_fps_min',
      'perf_fps_avg',
      'perf_fps_fluency',
      'perf_fps_hightemp',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: '$key 应存在');
      expect(_inKey(key, '—'), findsOneWidget, reason: '$key 应降级为「—」');
    }

    // hero 恒渲染（空态：无逐核 / 无热区）。
    expect(find.byKey(const Key('scene_hero_rings')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
