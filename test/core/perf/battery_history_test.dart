import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/battery_history.dart';

/// 便捷构造：一条屏幕点亮、放电(status=3)的功耗样本。
BatteryHistoryRecord _rec({
  required int timeMs,
  int session = 1,
  String package = 'com.app',
  String mode = 'balance',
  int current = 100,
  double voltage = 4.0,
  double temperature = 30,
  int status = kBatteryStatusDischarging,
  int screenOn = 1,
}) =>
    BatteryHistoryRecord(
      time: '$timeMs',
      session: session,
      temperature: temperature,
      status: status,
      mode: mode,
      current: current,
      voltage: voltage,
      package: package,
      screenOn: screenOn,
      capacity: 50,
    );

void main() {
  // Android BATTERY_STATUS_*（本文件用字面量，避免与记录器侧同名导出耦合）。
  const int kUnknown = 1;
  const int kCharging = 2;
  const int kNotCharging = 4;
  const int kFull = 5;

  group('isPowerSample（放宽：排除法 status ∉ {2,5}）', () {
    test('亮屏 + Unknown(1) / Discharging(3) / NotCharging(4) → 有效', () {
      for (final status in <int>[kUnknown, kBatteryStatusDischarging,
        kNotCharging]) {
        expect(
          _rec(timeMs: 1, status: status).isPowerSample,
          isTrue,
          reason: 'status=$status 应计入功耗样本',
        );
      }
    });

    test('亮屏 + Charging(2) / Full(5) → 无效（功耗样本排除）', () {
      for (final status in <int>[kCharging, kFull]) {
        expect(
          _rec(timeMs: 1, status: status).isPowerSample,
          isFalse,
          reason: 'status=$status 应被排除',
        );
      }
    });

    test('熄屏（screen_on=0）→ 无效（任何状态）', () {
      for (final status in <int>[kUnknown, kBatteryStatusDischarging,
        kCharging, kNotCharging, kFull]) {
        expect(
          _rec(timeMs: 1, status: status, screenOn: 0).isPowerSample,
          isFalse,
          reason: 'screen_on=0 status=$status 应被排除',
        );
      }
    });

    test('默认 status=-1（无状态）→ 有效（非充电/满电）', () {
      expect(
        const BatteryHistoryRecord(time: '1', session: 1, screenOn: 1)
            .isPowerSample,
        isTrue,
      );
    });
  });

  group('聚合纳入 Unknown 行（修复「记了但看不见」）', () {
    test('aggregateAppPower 同时计入 Unknown(1) 与 Discharging(3)，排除 Charging(2)',
        () {
      final records = <BatteryHistoryRecord>[
        _rec(timeMs: 1, package: 'com.a', current: 100, voltage: 4.0,
            temperature: 20, status: kUnknown),
        _rec(timeMs: 2, package: 'com.a', current: 200, voltage: 5.0,
            temperature: 40, status: kBatteryStatusDischarging),
        // 被排除：充电中（功耗样本外）。
        _rec(timeMs: 3, package: 'com.a', current: 9999, voltage: 4.0,
            status: kCharging),
        // 被排除：熄屏。
        _rec(timeMs: 4, package: 'com.a', current: 8888, voltage: 4.0,
            screenOn: 0, status: kUnknown),
      ];

      final stats = aggregateAppPower(records, session: 1);
      expect(stats.length, 1);
      final a = stats.single;
      expect(a.package, 'com.a');
      expect(a.current, closeTo(150, 1e-9)); // (100 + 200) / 2
      expect(a.power, closeTo(700, 1e-9)); // (100*4 + 200*5) / 2
      expect(a.avgTemperature, closeTo(30, 1e-9)); // (20 + 40) / 2
      expect(a.count, 2);
    });

    test('countSessionSamples / aggregateSessionPower 计入 Unknown(1)', () {
      final records = <BatteryHistoryRecord>[
        _rec(timeMs: 1, current: 100, voltage: 4.0, status: kUnknown),
        _rec(timeMs: 2, current: 200, voltage: 5.0,
            status: kBatteryStatusDischarging),
        _rec(timeMs: 3, current: 9999, voltage: 4.0, status: kCharging),
      ];
      expect(countSessionSamples(records, session: 1), 2);
      // (100*4 + 200*5) / 2 = 700（Charging 行被排除）。
      expect(aggregateSessionPower(records, session: 1), closeTo(700, 1e-9));
    });

    test('NotCharging(4) 仍计入（与 Scene (3,4) 行为一致）', () {
      final records = <BatteryHistoryRecord>[
        _rec(timeMs: 1, current: 50, voltage: 4.0, status: kNotCharging),
      ];
      expect(countSessionSamples(records, session: 1), 1);
      expect(aggregateAppPower(records, session: 1).single.current, 50);
    });
  });
}
