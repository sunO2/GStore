import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/battery_source.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';

/// 固定返回一份 `perf.battery` 报告；**不触碰 FFI**。
class _BatteryGateway implements PerfModuleGateway {
  _BatteryGateway(this.battery);

  final Map<String, dynamic> battery;

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    if (method != PerfMethods.battery) {
      throw StateError('unexpected method: $method');
    }
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{'ok': true, 'data': battery}),
      ),
    );
  }

  @override
  Stream<PerfRawEvent> get events => const Stream<PerfRawEvent>.empty();
}

class _StubChannel extends BatteryManagerChannel {
  _StubChannel(this._reading);

  final BatteryReading? _reading;

  @override
  Future<BatteryReading?> read() async => _reading;
}

/// Task 5 关键回归：Rust sysfs 报 `present=false` 时**仍要**用 BatteryManager
/// 合并，不能短路丢弃电池数据。
void main() {
  setUp(resetBatteryReadingCache);

  test('sysfs present=false 时仍合并 BatteryManager（关键回归）', () async {
    final module = PerfModule(
      gateway: _BatteryGateway(<String, dynamic>{
        'present': false,
        'charge_full_uah': 4000000,
        'cycle_count': 321,
      }),
    );

    final report = await readMergedBatteryForTest(
      module,
      channel: _StubChannel(
        const BatteryReading(
          present: true,
          capacityPercent: 55,
          currentMa: -420,
          voltageV: 4.05,
          temperatureC: 31.5,
          statusCode: 3,
          statusLabel: 'Discharging',
          interactive: true,
          sources: {'battery_manager'},
        ),
      ),
    );

    expect(report.present, isTrue);
    expect(report.capacityPercent, 55.0);
    expect(report.currentMa, -420.0);
    expect(report.voltageV, 4.05);
    expect(report.temperatureC, 31.5);
    expect(report.status, 'Discharging');
    // sysfs-only 字段沿用原始报告。
    expect(report.chargeFullUah, 4000000);
    expect(report.cycleCount, 321);
  });

  test('sysfs 完整时仍走合并，字段优先级 sysfs > battery_manager', () async {
    final module = PerfModule(
      gateway: _BatteryGateway(<String, dynamic>{
        'present': true,
        'capacity_percent': 80.0,
        'current_ma': -600.0,
        'voltage_v': 4.2,
        'temperature_c': 30.0,
        'status': 'Discharging',
        'base_path': '/sys/class/power_supply/battery',
      }),
    );

    final report = await readMergedBatteryForTest(
      module,
      channel: _StubChannel(
        const BatteryReading(
          present: true,
          capacityPercent: 55,
          currentMa: -420,
          voltageV: 4.05,
          sources: {'battery_manager'},
        ),
      ),
    );

    expect(report.present, isTrue);
    expect(report.capacityPercent, 80.0);
    expect(report.currentMa, -600.0);
    expect(report.voltageV, 4.2);
    expect(report.basePath, '/sys/class/power_supply/battery');
  });

  test('BatteryManager 不可用（null）→ 回退原始 sysfs 报告', () async {
    final module = PerfModule(
      gateway: _BatteryGateway(<String, dynamic>{
        'present': true,
        'capacity_percent': 61.0,
        'base_path': '/sys/class/power_supply/battery',
      }),
    );

    final report = await readMergedBatteryForTest(
      module,
      channel: _StubChannel(null),
    );

    expect(report.present, isTrue);
    expect(report.capacityPercent, 61.0);
    expect(report.basePath, '/sys/class/power_supply/battery');
  });

  test('全源均无电池 → 回退原始报告（不丢 charge-full / cycle）', () async {
    final module = PerfModule(
      gateway: _BatteryGateway(<String, dynamic>{
        'present': false,
        'charge_full_uah': 3900000,
        'cycle_count': 12,
      }),
    );

    final report = await readMergedBatteryForTest(
      module,
      channel: _StubChannel(null),
    );

    expect(report.present, isFalse);
    expect(report.chargeFullUah, 3900000);
    expect(report.cycleCount, 12);
  });
}
