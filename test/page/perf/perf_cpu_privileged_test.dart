// 逐核占用兜底：Rust `per_core_usage` 为空（Android 8+ /proc/stat 受限）时，
// 经特权 shell 读取 `/proc/stat` 并回填到 perfMonitorProvider。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/cpu_stat_source.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';

/// CPU 网关：`perf.cpu` 返回 [cpuData]，其它方法返回空报告（让整页 refresh 成功）。
class _CpuGateway implements PerfModuleGateway {
  _CpuGateway(this.cpuData);

  final Map<String, dynamic> cpuData;

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    final data = method == PerfMethods.cpu ? cpuData : <String, dynamic>{};
    return Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );
  }

  @override
  Stream<PerfRawEvent> get events => const Stream<PerfRawEvent>.empty();
}

Map<String, dynamic> _cpuData({
  required List<double> perCore,
  double usage = 0,
}) =>
    <String, dynamic>{
      'usage_percent': usage,
      'per_core_usage': perCore,
      'core_count': 2,
      'cores': <dynamic>[
        <String, dynamic>{'id': 0, 'freq_mhz': 1800.0},
        <String, dynamic>{'id': 1, 'freq_mhz': 2400.0},
      ],
    };

/// 每次调用递增的 `/proc/stat`：任意相邻两拍 → 聚合 / 逐核均为 20%。
String _statFor(int n) => 'cpu  ${50 * n} 0 ${50 * n} ${400 * n} 0 0 0\n'
    'cpu0 ${25 * n} 0 ${25 * n} ${200 * n} 0 0 0\n'
    'cpu1 ${25 * n} 0 ${25 * n} ${200 * n} 0 0 0\n';

ProviderContainer _container(_CpuGateway gateway, CpuStatReader reader) =>
    ProviderContainer(
      overrides: <Override>[
        perfModuleProvider.overrideWithValue(PerfModule(gateway: gateway)),
        perfCpuStatReaderProvider.overrideWithValue(reader),
        perfAvailabilityStreamProvider.overrideWithValue(
          Stream<PerfAvailability>.value(PerfAvailability.ready),
        ),
      ],
    );

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('Rust 逐核为空时经特权 /proc/stat 回填（频率保持模块值）', () async {
    var calls = 0;
    final reader = CpuStatReader(runner: (_) async {
      calls++;
      return '${_statFor(calls)}\nGSTORE_RESULT ok=1\n';
    });
    final container = _container(
      _CpuGateway(_cpuData(perCore: const <double>[])),
      reader,
    );
    addTearDown(container.dispose);

    expect(
      identical(container.read(perfCpuStatReaderProvider), reader),
      isTrue,
      reason: 'override 应生效',
    );
    final notifier = container.read(perfMonitorProvider.notifier);
    await _settle();
    expect(container.read(perfMonitorProvider).moduleReady, isTrue);

    await notifier.refreshCpu(); // 第一拍：建立特权基线
    await notifier.refreshCpu(); // 第二拍：计算并回填

    final CpuReport? cpu = container.read(perfMonitorProvider).cpu;
    expect(cpu, isNotNull);
    expect(cpu!.usagePercent, 20.0);
    expect(cpu.perCoreUsage, <double>[20.0, 20.0]);
    // 频率仍来自模块报告，未被兜底覆盖。
    expect(cpu.cores.map((c) => c.freqMhz), <double?>[1800.0, 2400.0]);
    expect(calls, greaterThanOrEqualTo(2));
  });

  test('模块逐核可用时不触发特权读取（不覆盖真实数据）', () async {
    var calls = 0;
    final reader = CpuStatReader(runner: (_) async {
      calls++;
      return '${_statFor(calls)}\nGSTORE_RESULT ok=1\n';
    });
    final container = _container(
      _CpuGateway(
        _cpuData(perCore: const <double>[11.0, 22.0], usage: 33),
      ),
      reader,
    );
    addTearDown(container.dispose);

    final notifier = container.read(perfMonitorProvider.notifier);
    await _settle();
    await notifier.refreshCpu();
    await notifier.refreshCpu();

    final CpuReport? cpu = container.read(perfMonitorProvider).cpu;
    expect(cpu, isNotNull);
    expect(cpu!.perCoreUsage, <double>[11.0, 22.0]);
    expect(cpu.usagePercent, 33.0);
    expect(calls, 0, reason: '模块已提供逐核数据时不应执行特权 shell');
  });
}
