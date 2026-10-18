import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/compent/line_chart.dart';
import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';
import 'package:gstore/page/perf/view.dart';

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
///
/// FPS 现由窗口内 vsync **时间戳**跨度换算（interval-based）：每帧间隔 16666µs，
/// 于是 60 帧的交付 FPS ≈ 60.0。
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

/// 铺满大视口（ListView 懒构建，避免 offscreen 卡片找不到）。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _harness({
  required PerfModule module,
  required FrameMonitor monitor,
  required Stream<PerfAvailability> availability,
}) {
  return ProviderScope(
    overrides: [
      perfModuleProvider.overrideWithValue(module),
      perfFrameMonitorProvider.overrideWithValue(monitor),
      perfAvailabilityStreamProvider.overrideWithValue(availability),
    ],
    child: const MaterialApp(home: PerfMonitorPage()),
  );
}

/// 推进若干帧让 availability 流与异步 refresh 完成（不使用 pumpAndSettle：
/// 加载态含 [AppLoading] 无限动画会使其超时）。
Future<void> _settleAsync(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('模块不可用：FPS 区仍渲染 + 友好「安装 / 重试」卡片（不崩溃）',
      (tester) async {
    _useTallViewport(tester);
    final gateway = _FakeGateway(data: const {}, unavailable: true);
    final monitor = _publishedMonitor();

    await tester.pumpWidget(_harness(
      module: PerfModule(gateway: gateway),
      monitor: monitor,
      availability: Stream<PerfAvailability>.value(PerfAvailability.failed),
    ));
    await _settleAsync(tester);

    // 页面骨架恒存在。
    expect(find.text('性能监控'), findsOneWidget);
    expect(find.text('渲染 / FPS'), findsOneWidget);
    // FPS 纯 Dart，模块不可用也应展示数值。
    expect(find.text('60.0'), findsOneWidget);

    // 图表区（趋势卡）恒渲染：FPS sparkline 不受模块可用性影响。
    expect(find.text('指标趋势'), findsOneWidget);
    expect(find.byType(LineChart), findsWidgets);

    // 友好降级卡片 + 显式安装入口。
    expect(find.text('原生性能模块未就绪'), findsOneWidget);
    expect(find.text('安装 / 重试'), findsOneWidget);
    expect(find.byKey(const Key('perf_retry')), findsOneWidget);

    // 采样开关在模块未就绪时禁用。
    final sw = tester.widget<SwitchListTile>(
      find.byKey(const Key('perf_sampling_switch')),
    );
    expect(sw.onChanged, isNull);

    // 无裸异常泄漏。
    expect(tester.takeException(), isNull);
  });

  testWidgets('重试在模块仍不可用时：不崩溃且保持降级卡片', (tester) async {
    _useTallViewport(tester);
    final gateway = _FakeGateway(data: const {}, unavailable: true);
    final monitor = _publishedMonitor();

    await tester.pumpWidget(_harness(
      module: PerfModule(gateway: gateway),
      monitor: monitor,
      availability: Stream<PerfAvailability>.value(PerfAvailability.failed),
    ));
    await _settleAsync(tester);

    await tester.tap(find.byKey(const Key('perf_retry')));
    await _settleAsync(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('原生性能模块未就绪'), findsOneWidget);
  });

  testWidgets('模块就绪：渲染 CPU / 内存 / 电池 / 温度 / GPU / 网络 / 进程 数值',
      (tester) async {
    _useTallViewport(tester);
    final gateway = _FakeGateway(data: {
      'perf.cpu': {
        'usage_percent': 37.5,
        'per_core_usage': <dynamic>[10.0, 20.5, 30.0],
        'core_count': 8,
        'frequencies_mhz': <dynamic>[1800.0, null, 2400.0],
        'governor': 'schedutil',
        'min_freq_mhz': 300.0,
        'max_freq_mhz': 2400.0,
        'loadavg': {
          'load1': 0.15,
          'load5': 0.1,
          'load15': 0.05,
        },
      },
      'perf.memory': {
        'total_kb': 16384000,
        'used_kb': 8192000,
        'available_kb': 8192000,
        'used_percent': 50.0,
        'swap_total_kb': 4096000,
        'swap_used_kb': 1024000,
        'swap_percent': 25.0,
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
        'health': 'Good',
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
      'perf.network': {
        'rx_bytes': 1204224,
        'tx_bytes': 2048000,
        'rx_bytes_per_sec': 1024.0,
        'tx_bytes_per_sec': 2048.0,
        'interfaces': <dynamic>[
          {
            'name': 'wlan0',
            'rx_bytes': 1204224,
            'tx_bytes': 2048000,
            'rx_bytes_per_sec': 1024.0,
            'tx_bytes_per_sec': 2048.0,
          },
        ],
      },
      'perf.processes': {
        'total': 200,
        'sort': 'cpu',
        'processes': <dynamic>[
          {
            'pid': 1234,
            'name': 'com.example.app',
            'state': 'S',
            'cpu_percent': 12.5,
            'rss_kb': 102400,
          },
        ],
      },
    });
    final monitor = _publishedMonitor();

    await tester.pumpWidget(_harness(
      module: PerfModule(gateway: gateway),
      monitor: monitor,
      availability: Stream<PerfAvailability>.value(PerfAvailability.ready),
    ));
    await _settleAsync(tester);

    // 降级卡片不再出现，模块区域正常渲染。
    expect(find.text('原生性能模块未就绪'), findsNothing);
    expect(tester.takeException(), isNull);

    // 趋势图表区 + 每个指标的 sparkline 卡片。
    expect(find.text('指标趋势'), findsOneWidget);
    expect(find.byType(LineChart), findsWidgets);
    expect(find.text('等待数据'), findsNothing);

    // FPS。
    expect(find.text('60.0'), findsOneWidget);

    // CPU：聚合占用 + 调速器。
    expect(find.text('37.5%'), findsOneWidget);
    expect(find.textContaining('schedutil'), findsOneWidget);

    // 内存：使用 / 总量。
    expect(find.textContaining('8 GB / 16 GB'), findsOneWidget);

    // 电池：容量。
    expect(find.text('80%'), findsOneWidget);

    // 温度：最高温度高亮。
    expect(find.textContaining('最高 42.0'), findsOneWidget);

    // GPU 型号。
    expect(find.text('Adreno 650'), findsOneWidget);

    // 网络接口。
    expect(find.textContaining('wlan0'), findsOneWidget);

    // 进程 Top-N。
    expect(find.textContaining('com.example.app'), findsOneWidget);

    // 采样开关就绪后可交互（默认仍为关）。
    final sw = tester.widget<SwitchListTile>(
      find.byKey(const Key('perf_sampling_switch')),
    );
    expect(sw.onChanged, isNotNull);
    expect(sw.value, false);
  });

  testWidgets('实时刷新开关：开启触发 1s 轮询，卸载后取消定时器（无 pending timer）',
      (tester) async {
    _useTallViewport(tester);
    final gateway = _FakeGateway(data: {
      'perf.cpu': {'usage_percent': 12.0, 'core_count': 4},
      'perf.memory': {'total_kb': 100, 'used_kb': 50, 'used_percent': 50.0},
      'perf.battery': {'present': false},
      'perf.thermal': {'zone_count': 0, 'zones': <dynamic>[]},
      'perf.gpu': <String, dynamic>{},
      'perf.network': {
        'rx_bytes_per_sec': 10.0,
        'tx_bytes_per_sec': 20.0,
      },
      'perf.processes': {'total': 0, 'processes': <dynamic>[]},
    });
    final monitor = _publishedMonitor();

    await tester.pumpWidget(_harness(
      module: PerfModule(gateway: gateway),
      monitor: monitor,
      availability: Stream<PerfAvailability>.value(PerfAvailability.ready),
    ));
    await _settleAsync(tester);

    // 默认关闭实时刷新。
    var sw = tester.widget<SwitchListTile>(
      find.byKey(const Key('perf_live_switch')),
    );
    expect(sw.value, false);

    await tester.tap(find.byKey(const Key('perf_live_switch')));
    await tester.pump();
    sw = tester.widget<SwitchListTile>(
      find.byKey(const Key('perf_live_switch')),
    );
    expect(sw.value, true);

    // 推进 1s 触发一次静默轮询（不应抛异常 / 不闪烁 loading）。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    // 卸载 -> ProviderScope 释放 -> onDispose 取消定时器。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
