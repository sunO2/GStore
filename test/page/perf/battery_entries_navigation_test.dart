import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/hardware_page.dart';
import 'package:gstore/page/perf/logic.dart';

/// scene-to-gstore-parity Task 3：电池卡「耗电统计 / 充电曲线」入口导航测试。
///
/// 用 [GoRouter]（`MaterialApp.router`）承载 [PerfHardwarePage]，模块以假网关
/// 就绪（不触碰 FFI），点击入口后断言推入对应 [AppRoute] 的目标页。
class _FakeGateway implements PerfModuleGateway {
  final StreamController<PerfRawEvent> _events =
      StreamController<PerfRawEvent>.broadcast();

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    final body = _data()[method];
    if (body == null) throw StateError('no stub for $method');
    return Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': body})),
    );
  }

  @override
  Stream<PerfRawEvent> get events => _events.stream;

  static Map<String, Map<String, dynamic>> _data() => {
        'perf.cpu': {'usage_percent': 12.0, 'core_count': 4},
        'perf.memory': {'total_kb': 100, 'used_kb': 50, 'used_percent': 50.0},
        'perf.battery': {
          'present': true,
          'capacity_percent': 80.0,
          'voltage_v': 4.2,
          'current_ma': 500.0,
          'temperature_c': 30.5,
          'status': 'Charging',
          'health': 'Good',
        },
        'perf.thermal': {'zone_count': 0, 'zones': <dynamic>[]},
        'perf.gpu': <String, dynamic>{},
        'perf.network': {
          'rx_bytes_per_sec': 10.0,
          'tx_bytes_per_sec': 20.0,
        },
        'perf.processes': {'total': 0, 'processes': <dynamic>[]},
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('点击 耗电统计 / 充电曲线 → 推入对应 AppRoute', (tester) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: PerfHardwarePage()),
        ),
        GoRoute(
          path: AppRoute.batteryStats,
          builder: (context, state) =>
              const Scaffold(body: Text('BATTERY_STATS_DEST')),
        ),
        GoRoute(
          path: AppRoute.chargeCurve,
          builder: (context, state) =>
              const Scaffold(body: Text('CHARGE_CURVE_DEST')),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          perfModuleProvider
              .overrideWithValue(PerfModule(gateway: _FakeGateway())),
          perfFrameMonitorProvider.overrideWithValue(FrameMonitor()),
          perfAvailabilityStreamProvider.overrideWithValue(
            Stream<PerfAvailability>.value(PerfAvailability.ready),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    Finder listScrollable() => find
        .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
        .first;

    // 电池卡入口：耗电统计。
    await tester.scrollUntilVisible(
      find.byKey(const Key('battery_stats_entry')),
      300,
      scrollable: listScrollable(),
    );
    await tester.tap(find.byKey(const Key('battery_stats_entry')));
    await tester.pumpAndSettle();
    expect(find.text('BATTERY_STATS_DEST'), findsOneWidget);

    // 返回硬件页：充电曲线。
    router.pop();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('battery_curve_entry')),
      300,
      scrollable: listScrollable(),
    );
    await tester.tap(find.byKey(const Key('battery_curve_entry')));
    await tester.pumpAndSettle();
    expect(find.text('CHARGE_CURVE_DEST'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
