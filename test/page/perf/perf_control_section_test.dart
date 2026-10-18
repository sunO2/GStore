import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/perf/control_cpu.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/control_thermal.dart';
import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/control_page.dart';
import 'package:gstore/page/perf/logic.dart';
import 'package:gstore/page/perf/perf_control_actions.dart';

/// 假网关：受控返回信封响应；**不触碰 FFI**。
class _FakeGateway implements PerfModuleGateway {
  _FakeGateway(this.data);

  final Map<String, Map<String, dynamic>> data;
  final StreamController<PerfRawEvent> _events =
      StreamController<PerfRawEvent>.broadcast();

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    final body = data[method];
    if (body == null) throw StateError('no stub for $method');
    return Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': body})),
    );
  }

  @override
  Stream<PerfRawEvent> get events => _events.stream;
}

/// 假控制动作：记录调用次数与最近一次 governor；**不触碰 Shizuku / 真机**。
class _FakeActions implements PerfControlActions {
  int cpuCalls = 0;
  int gpuCalls = 0;
  int cpusetCalls = 0;
  int thermalCalls = 0;
  String? lastGovernor;

  @override
  Future<CpuPolicyResult> applyCpu({
    required String cluster,
    String? governor,
    double? minFreqMhz,
    double? maxFreqMhz,
  }) async {
    cpuCalls++;
    lastGovernor = governor;
    return CpuPolicyResult(
      ok: true,
      status: CpuPolicyStatus.ok,
      cluster: cluster,
      applied: <CpuPolicyChange>[
        if (governor != null)
          CpuPolicyChange(
            path: '/sys/devices/system/cpu/cpufreq/$cluster/scaling_governor',
            before: 'schedutil',
            after: governor,
          ),
      ],
    );
  }

  @override
  Future<GpuPolicyResult> applyGpu(GpuPolicy policy) async {
    gpuCalls++;
    return GpuPolicyResult.applied(<GpuPolicyWrite>[]);
  }

  @override
  Future<CpusetResult> applyCpuset({
    required String pkgOrPid,
    required String cpuset,
  }) async {
    cpusetCalls++;
    return const CpusetResult(
      ok: true,
      status: kCpusetStatusApplied,
      message: 'ok',
    );
  }

  @override
  Future<ThermalToggleResult> setThermal(
    bool enabled, {
    required bool confirmed,
  }) async {
    thermalCalls++;
    return ThermalToggleResult(ok: true, requestedEnabled: enabled);
  }
}

const String _govNode =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor';
const String _minNode =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq';
const String _maxNode =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq';

TunablesReport _tunables() => const TunablesReport(
      cpuClusters: <PerfCpuCluster>[
        PerfCpuCluster(
          policy: 'policy0',
          relatedCpus: <int>[0, 1, 2, 3],
          availableGovernors: <String>['schedutil', 'performance'],
          governor: 'schedutil',
          availableFrequenciesMhz: <double>[300, 1800, 2400],
          minFreqMhz: 300,
          maxFreqMhz: 2400,
        ),
      ],
      cpusets: <PerfCpuset>[
        PerfCpuset(name: 'top-app', cpus: '0-3', mems: '0'),
      ],
      thermalZones: <PerfThermalTunable>[
        PerfThermalTunable(zone: 'thermal_zone0', mode: 'enabled'),
      ],
      gpu: PerfGpuTunables(
        availableFrequenciesMhz: <double>[100, 200],
        powerLevels: 4,
      ),
    );

PerfControlCapabilities _caps({required bool available}) =>
    PerfControlCapabilities(
      nodeAvailability: <String, bool>{
        _govNode: available,
        _minNode: available,
        _maxNode: available,
      },
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

Map<String, Map<String, dynamic>> _readyData() => <String, Map<String, dynamic>>{
      'perf.cpu': <String, dynamic>{'usage_percent': 10.0, 'core_count': 4},
      'perf.memory': <String, dynamic>{
        'total_kb': 100,
        'used_kb': 50,
        'used_percent': 50.0,
      },
      'perf.battery': <String, dynamic>{'present': false},
      'perf.thermal': <String, dynamic>{'zone_count': 0, 'zones': <dynamic>[]},
      'perf.gpu': <String, dynamic>{},
      'perf.network': <String, dynamic>{
        'rx_bytes_per_sec': 10.0,
        'tx_bytes_per_sec': 20.0,
      },
      'perf.processes': <String, dynamic>{'total': 0, 'processes': <dynamic>[]},
    };

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

/// 铺满超大视口（ListView 懒构建，控制区在页面底部）。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 20000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _harness({
  required TunablesReport tunables,
  required PerfControlCapabilities? caps,
  required PerfControlActions actions,
}) {
  return ProviderScope(
    overrides: [
      perfModuleProvider
          .overrideWithValue(PerfModule(gateway: _FakeGateway(_readyData()))),
      perfFrameMonitorProvider.overrideWithValue(_publishedMonitor()),
      perfAvailabilityStreamProvider.overrideWithValue(
        Stream<PerfAvailability>.value(PerfAvailability.ready),
      ),
      perfControlTunablesLoaderProvider.overrideWithValue(() async => tunables),
      perfControlCapabilitiesLoaderProvider
          .overrideWithValue(({bool refresh = false}) async => caps),
      perfControlActionsFactoryProvider.overrideWithValue((t, c) => actions),
    ],
    child: MaterialApp(
      // 挂载全局弹层 / Snackbar 通道（[AppDialogs] 统一走全局 key）。
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const PerfControlPage(),
    ),
  );
}

/// 推进若干帧（不用 pumpAndSettle：[AppLoading] 无限动画会超时）。
Future<void> _settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

String _currentText(WidgetTester tester, String policy) =>
    tester
        .widget<Text>(find.byKey(Key('perf_control_cpu_current_$policy')))
        .data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('应用 governor：危险确认后写入并更新展示值', (tester) async {
    _useTallViewport(tester);
    final actions = _FakeActions();
    await tester.pumpWidget(_harness(
      tunables: _tunables(),
      caps: _caps(available: true),
      actions: actions,
    ));
    await _settle(tester);

    // 控制区渲染，初始展示 schedutil。
    expect(find.byKey(const Key('perf_control_section')), findsOneWidget);
    expect(_currentText(tester, 'policy0'), contains('schedutil'));
    expect(actions.cpuCalls, 0);

    // 选择 performance。
    await tester.tap(find.byKey(const Key('perf_control_cpu_governor_policy0')));
    await _settle(tester);
    await tester.tap(find.text('performance').last);
    await _settle(tester);

    // 点击应用 → 出现危险确认弹层；未确认前绝不写入。
    await tester.tap(find.byKey(const Key('perf_control_cpu_apply_policy0')));
    await _settle(tester);
    expect(find.text('应用 CPU 策略？'), findsOneWidget);
    expect(actions.cpuCalls, 0);

    await tester.tap(find.text('确认应用'));
    await _settle(tester);

    expect(actions.cpuCalls, 1);
    expect(actions.lastGovernor, 'performance');
    expect(_currentText(tester, 'policy0'), contains('performance'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消危险确认：不写入且展示值不变', (tester) async {
    _useTallViewport(tester);
    final actions = _FakeActions();
    await tester.pumpWidget(_harness(
      tunables: _tunables(),
      caps: _caps(available: true),
      actions: actions,
    ));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('perf_control_cpu_apply_policy0')));
    await _settle(tester);
    expect(find.text('应用 CPU 策略？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await _settle(tester);

    expect(actions.cpuCalls, 0);
    expect(_currentText(tester, 'policy0'), contains('schedutil'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('无可用能力：所有控件 fail-closed 禁用且给出可见原因', (tester) async {
    _useTallViewport(tester);
    final actions = _FakeActions();
    await tester.pumpWidget(_harness(
      tunables: _tunables(),
      caps: _caps(available: false),
      actions: actions,
    ));
    await _settle(tester);

    expect(find.byKey(const Key('perf_control_section')), findsOneWidget);
    expect(find.textContaining('不可用'), findsWidgets);

    for (final key in const <String>[
      'perf_control_cpu_apply_policy0',
      'perf_control_gpu_apply',
      'perf_control_cpuset_apply',
    ]) {
      final button = tester.widget<FilledButton>(find.byKey(Key(key)));
      expect(button.onPressed, isNull, reason: '$key 应禁用');
    }
    final thermal = tester.widget<SwitchListTile>(
      find.byKey(const Key('perf_control_thermal_switch')),
    );
    expect(thermal.onChanged, isNull);

    // 任意控件均无法写入。
    expect(actions.cpuCalls, 0);
    expect(actions.gpuCalls, 0);
    expect(actions.cpusetCalls, 0);
    expect(actions.thermalCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('能力未探测（null）：控件同样禁用并显示「未探测」', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_harness(
      tunables: _tunables(),
      caps: null,
      actions: _FakeActions(),
    ));
    await _settle(tester);

    expect(find.textContaining('未探测'), findsWidgets);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('perf_control_cpu_apply_policy0')),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
