import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/device_state.dart';

void main() {
  group('deviceStateFromRustJniJson · 完整 JSON', () {
    test('解析电池 / 显示模式 / 内存 / 流量 / 热状态', () {
      final reading = deviceStateFromRustJniJson('''
        {
          "battery": {
            "present": true, "level": 80, "scale": 100,
            "voltageMv": 4300, "temperatureTenthsC": 312,
            "status": 3, "health": 2, "technology": "Li-ion",
            "currentUa": -450000, "chargeCounterUah": 3200000,
            "energyCounterNwh": 12000000, "chargeTimeRemainingMs": 1800000,
            "powerSave": false, "deviceIdle": true, "interactive": true
          },
          "display": {
            "refreshRate": 120.00001,
            "supportedModes": [
              {"mode": 1, "width": 1080, "height": 2400, "refreshRate": 60.0},
              {"mode": 2, "width": 1080, "height": 2400, "refreshRate": 90.0},
              {"mode": 3, "width": 1080, "height": 2400, "refreshRate": 120.00001}
            ]
          },
          "memory": {"totalMem": 8000000000, "availMem": 3000000000,
                     "threshold": 500000000, "lowMemory": false},
          "traffic": {"totalRx": 100, "totalTx": 200, "mobileRx": 10,
                      "mobileTx": 20, "uidRx": 1, "uidTx": 2},
          "thermal": {"status": 2, "headroom": 0.42}
        }
      ''');

      expect(reading, isNotNull);
      final state = reading!;
      expect(state.fromRustJni, isTrue);
      expect(state.sources, contains('rust_jni'));

      final battery = state.battery!;
      expect(battery.present, isTrue);
      expect(battery.level, 80);
      expect(battery.scale, 100);
      expect(battery.voltageV, 4.3);
      expect(battery.temperatureC, 31.2);
      expect(battery.currentMa, -450.0);
      expect(battery.chargeCounterUah, 3200000);
      expect(battery.energyCounterNwh, 12000000);
      expect(battery.chargeTimeRemainingMs, 1800000);
      expect(battery.powerSave, isFalse);
      expect(battery.deviceIdle, isTrue);
      expect(battery.interactive, isTrue);

      expect(state.displayRefreshRate, 120.00001);
      expect(state.supportedDisplayModes, hasLength(3));
      expect(state.supportedDisplayModes[1].mode, 2);
      expect(state.supportedDisplayModes[1].width, 1080);
      expect(state.supportedDisplayModes[1].refreshRate, 90.0);

      expect(state.memory!.totalMem, 8000000000);
      expect(state.memory!.availMem, 3000000000);
      expect(state.memory!.threshold, 500000000);
      expect(state.memory!.lowMemory, isFalse);

      expect(state.traffic!.totalRx, 100);
      expect(state.traffic!.totalTx, 200);
      expect(state.traffic!.mobileRx, 10);
      expect(state.traffic!.mobileTx, 20);
      expect(state.traffic!.uidRx, 1);
      expect(state.traffic!.uidTx, 2);

      expect(state.thermalStatus, 2);
      expect(state.thermalHeadroom, 0.42);
    });

    test('supportedModes → 四舍五入 / 去重 / 升序档位', () {
      final reading = deviceStateFromRustJniJson('''
        {"display": {"supportedModes": [
          {"refreshRate": 120.00001},
          {"refreshRate": 59.94},
          {"refreshRate": 120.0},
          {"refreshRate": 90.2}
        ]}}
      ''');
      expect(reading!.refreshLevels, equals(<int>[60, 90, 120]));
    });
  });

  group('deviceStateFromRustJniJson · 部分 / 非法输入', () {
    test('仅 battery：其余字段为 null / 空', () {
      final reading = deviceStateFromRustJniJson(
        '{"battery": {"present": true, "level": 55}}',
      );
      expect(reading, isNotNull);
      expect(reading!.battery!.level, 55);
      expect(reading.displayRefreshRate, isNull);
      expect(reading.supportedDisplayModes, isEmpty);
      expect(reading.memory, isNull);
      expect(reading.traffic, isNull);
      expect(reading.thermalStatus, isNull);
      expect(reading.thermalHeadroom, isNull);
    });

    test('字段类型不符时跳过而非抛出', () {
      final reading = deviceStateFromRustJniJson('''
        {"battery": "oops",
         "display": {"refreshRate": "not-a-number",
                     "supportedModes": [1, {"refreshRate": "x"}, {"refreshRate": 90}]},
         "memory": {"totalMem": "123", "lowMemory": "true"},
         "thermal": {"status": "2", "headroom": "nan"}}
      ''');
      expect(reading, isNotNull);
      expect(reading!.battery, isNull);
      expect(reading.displayRefreshRate, isNull);
      expect(reading.supportedDisplayModes, hasLength(1));
      expect(reading.supportedDisplayModes.single.refreshRate, 90);
      expect(reading.memory!.totalMem, 123);
      expect(reading.memory!.lowMemory, isTrue);
      expect(reading.thermalStatus, 2);
      expect(reading.thermalHeadroom, isNull);
    });

    test('空对象 → 全空快照（非 null）', () {
      final reading = deviceStateFromRustJniJson('{}');
      expect(reading, isNotNull);
      expect(reading!.battery, isNull);
      expect(reading.supportedDisplayModes, isEmpty);
    });

    test('垃圾字符串 / 非对象 JSON → null', () {
      expect(deviceStateFromRustJniJson('not json'), isNull);
      expect(deviceStateFromRustJniJson(''), isNull);
      expect(deviceStateFromRustJniJson('[1,2,3]'), isNull);
      expect(deviceStateFromRustJniJson('"text"'), isNull);
      expect(deviceStateFromRustJniJson('null'), isNull);
    });
  });

  group('RustJniDeviceStateBridge', () {
    test('注入读取成功 → 解析快照', () async {
      final bridge = RustJniDeviceStateBridge(
        readJson: () async =>
            '{"display": {"refreshRate": 90, "supportedModes": [{"refreshRate": 90}]}}',
      );
      final reading = await bridge.read();
      expect(reading, isNotNull);
      expect(reading!.displayRefreshRate, 90);
      expect(reading.refreshLevels, equals(<int>[90]));
    });

    test('null / 空串 / 抛异常 → null（绝不抛出）', () async {
      expect(
        await RustJniDeviceStateBridge(readJson: () async => null).read(),
        isNull,
      );
      expect(
        await RustJniDeviceStateBridge(readJson: () async => '').read(),
        isNull,
      );
      expect(
        await RustJniDeviceStateBridge(
          readJson: () async => throw StateError('ffi down'),
        ).read(),
        isNull,
      );
    });
  });
}
