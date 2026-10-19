import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/home/tab/dashboard/view.dart';
import 'package:gstore/page/perf/logic.dart';

/// 假网关：受控返回信封响应；可切换为「模块不可用」；**不触碰 FFI**。
class _FakeGateway implements PerfModuleGateway {
  _FakeGateway({required this.data, this.unavailable = false});

  final Map<String, Map<String, dynamic>> data;
  final bool unavailable;
  final StreamController<PerfRawEvent> _events =
      StreamController<PerfRawEvent>.broadcast();

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    if (unavailable) {
      throw PerfModuleUnavailableException();
    }
    final body = data[method];
    if (body == null) {
      throw StateError('no stub for $method');
    }
    return _okEnvelope(body);
  }

  @override
  Stream<PerfRawEvent> get events => _events.stream;

  static Uint8List _okEnvelope(Map<String, dynamic> body) => Uint8List.fromList(
        utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': body})),
      );
}

/// 构造一个**已发布 60fps 快照**的帧监控（start → 喂帧 → stop 强制发布）。
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

/// 模块就绪时的完整基线数据（CPU / 内存 / 电池 / 温度 / GPU），供仪表盘卡片渲染。
Map<String, Map<String, dynamic>> _moduleReadyData() => {
      'perf.cpu': {
        'usage_percent': 37.5,
        'per_core_usage': <dynamic>[10.0, 20.5, 30.0],
        'core_count': 8,
        'frequencies_mhz': <dynamic>[1800.0, null, 2400.0],
        'governor': 'schedutil',
      },
      'perf.memory': {
        'total_kb': 16384000,
        'used_kb': 8192000,
        'available_kb': 8192000,
        'used_percent': 50.0,
        'swap_total_kb': 4096000,
        'swap_used_kb': 1024000,
        'swap_percent': 25.0,
        'swap_cached_kb': 20480,
        'buffers_kb': 10240,
        'dirty_kb': 512,
        'total_human': '16 GB',
        'used_human': '8 GB',
        'available_human': '8 GB',
        'swap_total_human': '4 GB',
        'swap_used_human': '1 GB',
      },
      'perf.battery': {
        'present': true,
        'capacity_percent': 80.0,
        'voltage_v': 4.2,
        'current_ma': 500.0,
        'temperature_c': 30.5,
        'status': 'Charging',
      },
      'perf.thermal': {
        'zone_count': 2,
        'max_temp_c': 42.0,
        'zones': <dynamic>[
          {
            'source': 'thermal_zone',
            'zone': 'thermal_zone0',
            'kind': 'cpu',
            'temp_c': 42.0,
          },
          {
            'source': 'thermal_zone',
            'zone': 'thermal_zone1',
            'kind': 'gpu',
            'temp_c': 38.0,
          },
        ],
      },
      'perf.gpu': {
        'name': 'Adreno 650',
        'freq_mhz': 587.0,
        'busy_percent': 12.0,
      },
      'perf.network': {'rx_bytes_per_sec': 0.0, 'tx_bytes_per_sec': 0.0},
      'perf.processes': {'total': 0, 'processes': <dynamic>[]},
    };

/// 铺满大视口（ListView 懒构建，避免 offscreen 卡片找不到）。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

TunablesReport _tunables() => const TunablesReport(
      cpuClusters: <PerfCpuCluster>[
        PerfCpuCluster(policy: 'policy0', relatedCpus: <int>[0, 1, 2, 3]),
      ],
      cpusets: <PerfCpuset>[PerfCpuset(name: 'top-app', cpus: '0-3')],
      thermalZones: <PerfThermalTunable>[
        PerfThermalTunable(zone: 'thermal_zone0', mode: 'enabled'),
      ],
    );

PerfControlCapabilities _caps({required bool available}) =>
    PerfControlCapabilities(
      nodeAvailability: const <String, bool>{},
      binderLevers: const <String, bool>{},
      categoryAvailability: <PerfControlCategory, bool>{
        PerfControlCategory.cpu: available,
        PerfControlCategory.gpu: available,
        PerfControlCategory.cpuset: available,
        PerfControlCategory.thermal: available,
        PerfControlCategory.binderLevers: false,
      },
      nodeCounts: const <PerfControlCategory, int>{},
      timeoutAvailable: true,
      probedAtMs: 0,
    );

/// 单 harness：仪表盘页 + 受控 perf 模块 / 帧监控 / 能力加载器。
Widget _harness({
  required PerfModule module,
  required FrameMonitor monitor,
  required Stream<PerfAvailability> availability,
  DashboardTunablesLoader? tunablesLoader,
  DashboardCapabilitiesLoader? capabilitiesLoader,
}) {
  return ProviderScope(
    overrides: <Override>[
      perfModuleProvider.overrideWithValue(module),
      perfFrameMonitorProvider.overrideWithValue(monitor),
      perfAvailabilityStreamProvider.overrideWithValue(availability),
    ],
    child: MaterialApp(
      home: DashboardPage(
        tunablesLoader: tunablesLoader ?? () async => _tunables(),
        capabilitiesLoader: capabilitiesLoader,
      ),
    ),
  );
}

/// 推进若干帧让异步 refresh / 能力探测完成（不使用 pumpAndSettle：
/// [AppLoading] 无限动画会使其超时）。
Future<void> _settleAsync(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 断言四档模式按钮全部为禁用占位。
void _expectModeButtonsDisabled(WidgetTester tester) {
  for (final id in const <String>[
    'powersave',
    'balance',
    'performance',
    'fast',
  ]) {
    final button = tester.widget<OutlinedButton>(
      find.byKey(Key('dashboard_mode_$id')),
    );
    expect(button.onPressed, isNull, reason: '$id 应为禁用占位');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('模块就绪：渲染 RAM/SWAP/CPU/GPU/逐核/电池/温度 卡片（无 Shizuku）',
      (tester) async {
    _useTallViewport(tester);
    final gateway = _FakeGateway(data: _moduleReadyData());

    await tester.pumpWidget(_harness(
      module: PerfModule(gateway: gateway),
      monitor: _publishedMonitor(),
      availability: Stream<PerfAvailability>.value(PerfAvailability.ready),
      capabilitiesLoader: (_) async => _caps(available: true),
    ));
    await _settleAsync(tester);

    for (final key in const <String>[
      'dashboard_card_ram',
      'dashboard_card_swap',
      'dashboard_card_cpu',
      'dashboard_card_gpu',
      'dashboard_card_per_core',
      'dashboard_card_battery',
      'dashboard_card_temperature',
      'dashboard_card_mode',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: '$key 应存在');
    }

    // 数值渲染。
    expect(find.textContaining('8 GB'), findsWidgets);
    expect(find.textContaining('schedutil'), findsOneWidget);
    expect(find.text('Adreno 650'), findsOneWidget);
    expect(find.textContaining('核0'), findsOneWidget);
    expect(find.text('80%'), findsWidgets);
    expect(find.textContaining('最高 42.0'), findsOneWidget);

    // 即便能力可写，四档按钮仍为**禁用占位**（接线在 todo 29）。
    _expectModeButtonsDisabled(tester);
    expect(
      find.byKey(const Key('dashboard_mode_reason')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('能力探测为空（无 writable 类别）：四按钮禁用 + 可见原因，不崩溃',
      (tester) async {
    _useTallViewport(tester);
    final gateway = _FakeGateway(data: _moduleReadyData());

    await tester.pumpWidget(_harness(
      module: PerfModule(gateway: gateway),
      monitor: _publishedMonitor(),
      availability: Stream<PerfAvailability>.value(PerfAvailability.ready),
      capabilitiesLoader: (_) async => _caps(available: false),
    ));
    await _settleAsync(tester);

    _expectModeButtonsDisabled(tester);
    expect(
      find.textContaining('无可写控制类别'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('能力探测失败（null）：四按钮禁用 + 原因，不崩溃', (tester) async {
    _useTallViewport(tester);
    final gateway = _FakeGateway(data: _moduleReadyData());

    await tester.pumpWidget(_harness(
      module: PerfModule(gateway: gateway),
      monitor: _publishedMonitor(),
      availability: Stream<PerfAvailability>.value(PerfAvailability.ready),
      capabilitiesLoader: (_) async => null,
    ));
    await _settleAsync(tester);

    _expectModeButtonsDisabled(tester);
    expect(find.textContaining('未探测'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('能力加载器抛异常：降级为 null（禁用 + 原因），不崩溃', (tester) async {
    _useTallViewport(tester);
    final gateway = _FakeGateway(data: _moduleReadyData());

    await tester.pumpWidget(_harness(
      module: PerfModule(gateway: gateway),
      monitor: _publishedMonitor(),
      availability: Stream<PerfAvailability>.value(PerfAvailability.ready),
      capabilitiesLoader: (_) async => throw StateError('probe failed'),
    ));
    await _settleAsync(tester);

    _expectModeButtonsDisabled(tester);
    expect(find.textContaining('未探测'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('模块不可用：占位卡片渲染、按钮禁用、不崩溃', (tester) async {
    _useTallViewport(tester);
    final gateway = _FakeGateway(data: const {}, unavailable: true);

    await tester.pumpWidget(_harness(
      module: PerfModule(gateway: gateway),
      monitor: _publishedMonitor(),
      availability: Stream<PerfAvailability>.value(PerfAvailability.failed),
      capabilitiesLoader: (_) async => null,
    ));
    await _settleAsync(tester);

    // 卡片仍渲染（降级占位）。
    expect(find.byKey(const Key('dashboard_card_ram')), findsOneWidget);
    expect(find.byKey(const Key('dashboard_card_cpu')), findsOneWidget);
    expect(find.byKey(const Key('dashboard_card_mode')), findsOneWidget);
    // 逐核 / 热区为空占位。
    expect(find.byKey(const Key('dashboard_per_core_empty')), findsOneWidget);
    expect(find.byKey(const Key('dashboard_thermal_empty')), findsOneWidget);
    // 降级提示可见。
    expect(find.byKey(const Key('dashboard_module_hint')), findsOneWidget);

    _expectModeButtonsDisabled(tester);
    expect(tester.takeException(), isNull);
  });
}
