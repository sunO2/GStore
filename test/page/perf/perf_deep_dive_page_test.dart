import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';
import 'package:gstore/page/perf/view.dart';

/// 假网关：受控返回信封响应；未提供 stub 的方法抛 [StateError]（由页面
/// [_softFetch] 捕获 → 该卡片降级，不影响其它卡片）；**不触碰 FFI**。
class _FakeGateway implements PerfModuleGateway {
  _FakeGateway(this.data);

  final Map<String, Map<String, dynamic>> data;
  final StreamController<PerfRawEvent> _events =
      StreamController<PerfRawEvent>.broadcast();

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
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

/// 铺满大视口（ListView 懒构建，避免 offscreen 卡片找不到）。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 8000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _harness({
  required PerfModule module,
  required FrameMonitor monitor,
}) {
  return ProviderScope(
    overrides: [
      perfModuleProvider.overrideWithValue(module),
      perfFrameMonitorProvider.overrideWithValue(monitor),
      perfAvailabilityStreamProvider.overrideWithValue(
        Stream<PerfAvailability>.value(PerfAvailability.ready),
      ),
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

/// 各模块基线（不含深度报告），供「不可用」测试复用。
Map<String, Map<String, dynamic>> _baseData() => {
      'perf.cpu': {'usage_percent': 10.0, 'core_count': 4},
      'perf.memory': {'total_kb': 1000, 'used_kb': 500, 'used_percent': 50.0},
      'perf.battery': {'present': false},
      'perf.thermal': {'zone_count': 0, 'zones': <dynamic>[]},
      'perf.gpu': <String, dynamic>{},
      'perf.network': <String, dynamic>{
        'rx_bytes_per_sec': 10.0,
        'tx_bytes_per_sec': 20.0,
        'interfaces': <dynamic>[],
      },
      'perf.processes': {'total': 0, 'processes': <dynamic>[]},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('模块就绪：深度卡片渲染注入数据', (tester) async {
    _useTallViewport(tester);
    final gateway = _FakeGateway({
      ..._baseData(),
      'perf.cpu': {
        'usage_percent': 12.5,
        'core_count': 4,
        'governor': 'schedutil',
        'freq_residency': <dynamic>[
          <String, dynamic>{'freq_mhz': 300, 'ticks': 100},
          <String, dynamic>{'freq_mhz': 1800, 'ticks': 900},
        ],
      },
      'perf.pressure': {
        'cpu': {
          'some': {'avg10': 1.5, 'avg60': 2.0},
          'full': {'avg10': 0.5},
        },
        'memory': {
          'some': {'avg10': 4.0},
        },
        'io': {
          'some': {'avg10': 9.9},
        },
      },
      'perf.cooling': {
        'count': 1,
        'devices': <dynamic>[
          {
            'device': 'cooling_device0',
            'type': 'cpu',
            'cur_state': 3,
            'max_state': 10,
          },
        ],
      },
      'perf.battery_health': {
        'present': true,
        'charge_full_uah': 4400000,
        'charge_full_design_uah': 4000000,
        'cycle_count': 321,
        'health': 'Good',
        'status': 'Discharging',
        'technology': 'Li-ion',
        'temperature_c': 31.5,
      },
      'perf.storage': {
        'volumes': <dynamic>[
          {
            'mount': '/data',
            'fs': 'f2fs',
            'total_kb': 102400000,
            'free_kb': 40960000,
            'used_kb': 61440000,
            'used_percent': 60.0,
          },
        ],
      },
      'perf.network': {
        'rx_bytes_per_sec': 10.0,
        'tx_bytes_per_sec': 20.0,
        'interfaces': <dynamic>[
          {'name': 'wlan0', 'rx_bytes_per_sec': 10.0, 'tx_bytes_per_sec': 20.0},
          {
            'name': 'rmnet0',
            'rx_errors': 2,
            'tx_errors': 1,
            'rx_dropped': 3,
            'tx_dropped': 4,
          },
        ],
      },
    });

    await tester.pumpWidget(_harness(
      module: PerfModule(gateway: gateway),
      monitor: _publishedMonitor(),
    ));
    await _settleAsync(tester);

    expect(tester.takeException(), isNull);

    // 卡片标题全部渲染。
    expect(find.text('PSI 压力'), findsOneWidget);
    expect(find.text('散热设备'), findsOneWidget);
    expect(find.text('电池健康'), findsOneWidget);
    expect(find.text('存储'), findsOneWidget);
    expect(find.text('CPU 频率驻留'), findsOneWidget);
    expect(find.text('网卡错误'), findsOneWidget);

    // PSI：CPU some avg10 + full。
    expect(find.textContaining('some 1.50%'), findsOneWidget);

    // 散热：type • cur/max。
    expect(find.textContaining('cpu • 3/10'), findsOneWidget);

    // 电池健康：满电 / 设计容量（mAh）+ 健康度 + 循环次数。
    expect(find.text('4400 mAh'), findsOneWidget);
    expect(find.text('4000 mAh'), findsOneWidget);
    expect(find.text('110%'), findsOneWidget);
    expect(find.text('321'), findsOneWidget);

    // 存储：挂载点 + 用量。
    expect(find.textContaining('/data'), findsOneWidget);

    // CPU 频率驻留：归一化占比。
    expect(find.text('300 MHz'), findsOneWidget);
    expect(find.text('1800 MHz'), findsOneWidget);
    expect(find.text('10.0%'), findsOneWidget);
    expect(find.text('90.0%'), findsOneWidget);

    // 网卡错误：仅展示有非零计数的接口。
    expect(find.textContaining('错误 2/1'), findsOneWidget);
    expect(find.textContaining('丢包 3/4'), findsOneWidget);
  });

  testWidgets('深度报告缺失：卡片降级为「不可用」（不崩溃）', (tester) async {
    _useTallViewport(tester);
    // 仅提供既有方法 stub；深度方法触发 StateError → 页面软降级。
    final gateway = _FakeGateway(_baseData());

    await tester.pumpWidget(_harness(
      module: PerfModule(gateway: gateway),
      monitor: _publishedMonitor(),
    ));
    await _settleAsync(tester);

    expect(tester.takeException(), isNull);

    // 标题仍在（卡片恒渲染），内容降级。
    expect(find.text('PSI 压力'), findsOneWidget);
    expect(find.text('散热设备'), findsOneWidget);
    expect(find.text('电池健康'), findsOneWidget);
    expect(find.text('存储'), findsOneWidget);
    expect(find.text('CPU 频率驻留'), findsOneWidget);
    expect(find.text('网卡错误'), findsOneWidget);

    // 多处「不可用」降级文案。
    expect(find.text('不可用'), findsWidgets);
    expect(find.text('不可用（内核未开启 PSI）'), findsOneWidget);
    expect(find.text('无错误计数'), findsOneWidget);
  });
}
