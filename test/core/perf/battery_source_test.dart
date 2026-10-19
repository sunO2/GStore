import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/battery_source.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart' show BatteryReport;

/// 返回固定读数的假通道（跳过平台通道调用）。
class _StubChannel extends BatteryManagerChannel {
  _StubChannel(this._reading);

  final BatteryReading? _reading;

  @override
  Future<BatteryReading?> read() async => _reading;
}

/// 统计调用次数的假通道。
class _CountingChannel extends BatteryManagerChannel {
  _CountingChannel(this._reading);

  final BatteryReading? _reading;
  int calls = 0;

  @override
  Future<BatteryReading?> read() async {
    calls++;
    return _reading;
  }
}

/// 读取即抛异常的假通道（诊断错误路径）。
class _ThrowingChannel extends BatteryManagerChannel {
  @override
  Future<BatteryReading?> read() async => throw StateError('channel boom');
}

const String _fullDumpsys = '''
Current Battery Service state:
  AC powered: false
  USB powered: true
  Wireless powered: false
  status: 2
  health: 2
  present: true
  level: 76
  scale: 100
  voltage: 4123
  temperature: 329
  technology: Li-ion
  current now: -550000
  charge counter: 3000000
''';

void main() {
  setUp(resetBatteryReadingCache);

  group('parseDumpsysBattery', () {
    test('完整样本：字段/单位全部归一', () {
      final r = parseDumpsysBattery(_fullDumpsys);
      expect(r.present, isTrue);
      expect(r.capacityPercent, 76.0);
      expect(r.voltageV, 4.123);
      expect(r.currentMa, -550.0);
      expect(r.temperatureC, 32.9);
      expect(r.statusCode, 2);
      expect(r.statusLabel, 'Charging');
      expect(r.health, 'Good');
      expect(r.technology, 'Li-ion');
      expect(r.sources, contains('dumpsys'));
    });

    test('缺 current now → currentMa 为 null（其余仍解析）', () {
      const text = 'level: 50\nscale: 100\nvoltage: 3800\ntemperature: 300';
      final r = parseDumpsysBattery(text);
      expect(r.currentMa, isNull);
      expect(r.capacityPercent, 50.0);
      expect(r.voltageV, 3.8);
      expect(r.temperatureC, 30.0);
    });

    test('无 level/scale → capacityPercent 为 null，但电压已解析 → present', () {
      final r = parseDumpsysBattery('voltage: 4000');
      expect(r.capacityPercent, isNull);
      expect(r.voltageV, 4.0);
      expect(r.present, isTrue);
    });

    test('垃圾 / 哨兵行 / 空串宽容，不抛', () {
      const text = 'garbage line without colon\n'
          '  : leading colon ignored\n'
          'GSTORE_RESULT ok=1\n'
          'level: not-a-number\n'
          'status: 3';
      final r = parseDumpsysBattery(text);
      expect(r.present, isFalse);
      expect(r.capacityPercent, isNull);
      expect(r.statusCode, 3);
      expect(r.statusLabel, 'Discharging');
      expect(parseDumpsysBattery('').present, isFalse);
    });

    test('present: false 显式覆盖', () {
      final r = parseDumpsysBattery('present: false\nlevel: 90\nscale: 100');
      expect(r.present, isFalse);
      expect(r.capacityPercent, 90.0);
    });
  });

  group('mergeBatteryReadings', () {
    test('sysfs 提供全部字段 → 全部采用 sysfs', () {
      const sysfs = BatteryReading(
        present: true,
        capacityPercent: 61.0,
        voltageV: 4.2,
        currentMa: -850.0,
        temperatureC: 33.5,
        statusCode: 3,
        statusLabel: 'Discharging',
        health: 'Good',
        technology: 'Li-ion',
        basePath: '/sys/class/power_supply/battery',
        sources: {'sysfs'},
      );
      final merged = mergeBatteryReadings(sysfs: sysfs);
      expect(merged.present, isTrue);
      expect(merged.capacityPercent, 61.0);
      expect(merged.voltageV, 4.2);
      expect(merged.currentMa, -850.0);
      expect(merged.basePath, '/sys/class/power_supply/battery');
      expect(merged.sources, {'sysfs'});
    });

    test('sysfs 缺电流/电压 → batteryManager 补齐', () {
      const sysfs = BatteryReading(
        present: true,
        capacityPercent: 61.0,
        temperatureC: 33.5,
        sources: {'sysfs'},
      );
      const bm = BatteryReading(
        present: true,
        voltageV: 4.05,
        currentMa: -420.0,
        statusCode: 3,
        sources: {'battery_manager'},
      );
      final merged = mergeBatteryReadings(sysfs: sysfs, batteryManager: bm);
      expect(merged.currentMa, -420.0);
      expect(merged.voltageV, 4.05);
      expect(merged.capacityPercent, 61.0);
      expect(merged.temperatureC, 33.5);
      expect(merged.sources, {'sysfs', 'battery_manager'});
    });

    test('sysfs + bm 都缺 → dumpsys 补齐', () {
      const sysfs = BatteryReading(present: true, sources: {'sysfs'});
      final dumpsys = parseDumpsysBattery(_fullDumpsys);
      final merged = mergeBatteryReadings(sysfs: sysfs, dumpsys: dumpsys);
      expect(merged.currentMa, -550.0);
      expect(merged.voltageV, 4.123);
      expect(merged.sources, {'sysfs', 'dumpsys'});
    });

    test('present 取并集（任一 present 即为 true）', () {
      final merged = mergeBatteryReadings(
        sysfs: const BatteryReading(present: false),
        batteryManager: const BatteryReading(present: true),
      );
      expect(merged.present, isTrue);
    });

    test('sources 取并集', () {
      final merged = mergeBatteryReadings(
        sysfs: const BatteryReading(present: true, sources: {'sysfs'}),
        batteryManager:
            const BatteryReading(present: true, sources: {'battery_manager'}),
        dumpsys: const BatteryReading(present: true, sources: {'dumpsys'}),
      );
      expect(merged.sources, {'sysfs', 'battery_manager', 'dumpsys'});
    });

    test('全 null → present=false 且字段为空', () {
      final merged = mergeBatteryReadings();
      expect(merged.present, isFalse);
      expect(merged.voltageV, isNull);
      expect(merged.currentMa, isNull);
      expect(merged.sources, isEmpty);
    });

    test('status 优先采用有整型码的值（label-only 让位于 int）', () {
      const sysfs = BatteryReading(
        present: true,
        statusLabel: 'Full',
        sources: {'sysfs'},
      );
      const dumpsys = BatteryReading(
        present: true,
        statusCode: 4,
        sources: {'dumpsys'},
      );
      final merged = mergeBatteryReadings(sysfs: sysfs, dumpsys: dumpsys);
      expect(merged.statusCode, 4);
      expect(merged.statusLabel, 'Not charging');
    });

    test('interactive 取第一个非 null（sysfs > bm > dumpsys）', () {
      final merged = mergeBatteryReadings(
        sysfs: const BatteryReading(present: true, sources: {'sysfs'}),
        batteryManager: const BatteryReading(
          present: true,
          interactive: false,
          sources: {'battery_manager'},
        ),
        dumpsys: const BatteryReading(
          present: true,
          interactive: true,
          sources: {'dumpsys'},
        ),
      );
      expect(merged.interactive, isFalse);
    });
  });

  group('BatteryManagerChannel 转换', () {
    test('纯转换 helper：mV→V、µA→mA、十分之一℃→℃、int 码→标签', () {
      final r = batteryReadingFromBatteryManagerMap(<String, Object?>{
        'present': true,
        'level': 80,
        'scale': 100,
        'voltageMv': 4123,
        'temperatureTenthsC': 329,
        'status': 3,
        'health': 2,
        'technology': 'Li-ion',
        'currentUa': -550000,
        'capacityPercent': 80,
        'interactive': true,
      });
      expect(r.present, isTrue);
      expect(r.voltageV, 4.123);
      expect(r.currentMa, -550.0);
      expect(r.temperatureC, 32.9);
      expect(r.statusCode, 3);
      expect(r.statusLabel, 'Discharging');
      expect(r.health, 'Good');
      expect(r.technology, 'Li-ion');
      expect(r.capacityPercent, 80.0);
      expect(r.interactive, isTrue);
      expect(r.sources, {'battery_manager'});
    });

    test('纯转换 helper：null 字段保持 null，unknown 码 → Unknown', () {
      final r = batteryReadingFromBatteryManagerMap(<String, Object?>{
        'present': false,
        'voltageMv': null,
        'currentUa': null,
        'status': 99,
      });
      expect(r.present, isFalse);
      expect(r.voltageV, isNull);
      expect(r.currentMa, isNull);
      expect(r.statusCode, 99);
      expect(r.statusLabel, 'Unknown');
      expect(r.interactive, isNull);
    });

    test('interactive 解析：bool / 数字 / 字符串；缺失 → null', () {
      expect(
        batteryReadingFromBatteryManagerMap(
          <String, Object?>{'interactive': true},
        ).interactive,
        isTrue,
      );
      expect(
        batteryReadingFromBatteryManagerMap(
          <String, Object?>{'interactive': 0},
        ).interactive,
        isFalse,
      );
      expect(
        batteryReadingFromBatteryManagerMap(
          <String, Object?>{'interactive': 'true'},
        ).interactive,
        isTrue,
      );
      expect(
        batteryReadingFromBatteryManagerMap(
          <String, Object?>{'interactive': 'garbage'},
        ).interactive,
        isNull,
      );
    });

    test('mock MethodChannel handler 驱动 read()', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('gstore/battery');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'read') return null;
        return <String, Object?>{
          'present': true,
          'level': 76,
          'scale': 100,
          'voltageMv': 4000,
          'temperatureTenthsC': 300,
          'status': 2,
          'health': 2,
          'technology': 'Li-ion',
          'currentUa': -500000,
          'capacityPercent': 76,
        };
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final reading = await BatteryManagerChannel(channel: channel).read();
      expect(reading, isNotNull);
      expect(reading!.voltageV, 4.0);
      expect(reading.currentMa, -500.0);
      expect(reading.temperatureC, 30.0);
      expect(reading.statusLabel, 'Charging');
    });

    test('无 handler → MissingPluginException → null（绝不抛出）', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('gstore/battery_missing_plugin_test');
      final reading = await BatteryManagerChannel(channel: channel).read();
      expect(reading, isNull);
    });
  });

  group('readBatteryReading 合并编排', () {
    test('全源缺失 → null', () async {
      final r = await readBatteryReading(
        includeDumpsys: false,
        sysfsReader: () async => null,
        channel: _StubChannel(null),
      );
      expect(r, isNull);
    });

    test('sysfs 缺电流/电压 → 用 bm，且不执行 dumpsys', () async {
      var shellCalls = 0;
      final r = await readBatteryReading(
        sysfsReader: () async =>
            const BatteryReading(present: true, capacityPercent: 61.0),
        channel: _StubChannel(
          const BatteryReading(
            present: true,
            voltageV: 4.05,
            currentMa: -420.0,
          ),
        ),
        shellRunner: (command) async {
          shellCalls++;
          return _fullDumpsys;
        },
      );
      expect(r, isNotNull);
      expect(r!.currentMa, -420.0);
      expect(r.voltageV, 4.05);
      expect(shellCalls, 0);
    });

    test('sysfs + bm 都缺电流/电压 → 执行 dumpsys 合并', () async {
      String? shellCommand;
      final r = await readBatteryReading(
        includeDumpsys: true,
        sysfsReader: () async => const BatteryReading(
          present: true,
          capacityPercent: 61.0,
          sources: {'sysfs'},
        ),
        channel: _StubChannel(const BatteryReading(present: true)),
        shellRunner: (command) async {
          shellCommand = command;
          return _fullDumpsys;
        },
      );
      expect(shellCommand, kBatteryDumpsysCommand);
      expect(r, isNotNull);
      expect(r!.currentMa, -550.0);
      expect(r.voltageV, 4.123);
      expect(r.capacityPercent, 61.0);
      expect(r.sources, {'sysfs', 'dumpsys'});
    });

    test('sysfsReader 抛异常 → 静默降级为 null 源', () async {
      final r = await readBatteryReading(
        includeDumpsys: false,
        sysfsReader: () async => throw StateError('boom'),
        channel: _StubChannel(
          const BatteryReading(present: true, voltageV: 3.9),
        ),
      );
      expect(r, isNotNull);
      expect(r!.voltageV, 3.9);
    });
  });

  group('readBatteryReading TTL 缓存', () {
    test('同键第二次命中缓存（不再读源）', () async {
      var sysfsCalls = 0;
      final channel =
          _CountingChannel(const BatteryReading(present: true, interactive: true));

      Future<BatteryReading?> read() => readBatteryReading(
            sysfsReader: () async {
              sysfsCalls++;
              return const BatteryReading(present: true, capacityPercent: 50);
            },
            channel: channel,
          );

      final first = await read();
      final second = await read();
      expect(identical(first, second), isTrue);
      expect(sysfsCalls, 1);
      expect(channel.calls, 1);
    });

    test('forceRefresh 绕过缓存', () async {
      var sysfsCalls = 0;
      final channel = _CountingChannel(const BatteryReading(present: true));
      Future<BatteryReading?> read({bool force = false}) => readBatteryReading(
            forceRefresh: force,
            sysfsReader: () async {
              sysfsCalls++;
              return const BatteryReading(present: true);
            },
            channel: channel,
          );

      await read();
      await read();
      expect(sysfsCalls, 1);
      await read(force: true);
      expect(sysfsCalls, 2);
      expect(channel.calls, 2);
    });

    test('cacheTtl: Duration.zero → 每次都视为过期', () async {
      var sysfsCalls = 0;
      Future<BatteryReading?> read() => readBatteryReading(
            cacheTtl: Duration.zero,
            sysfsReader: () async {
              sysfsCalls++;
              return const BatteryReading(present: true);
            },
            channel: _StubChannel(null),
          );

      await read();
      await read();
      expect(sysfsCalls, 2);
    });

    test('includeDumpsys 分键缓存（完整结果不污染廉价结果）', () async {
      var shellCalls = 0;
      final channel = _CountingChannel(
        const BatteryReading(present: true, capacityPercent: 42),
      );

      // 廉价：不跑 shell。
      final cheap = await readBatteryReading(
        sysfsReader: () async => null,
        channel: channel,
      );
      expect(cheap!.capacityPercent, 42.0);
      expect(shellCalls, 0);

      // 完整：缺电流/电压 → 跑一次 shell。
      final full = await readBatteryReading(
        includeDumpsys: true,
        sysfsReader: () async => null,
        channel: channel,
        shellRunner: (_) async {
          shellCalls++;
          return _fullDumpsys;
        },
      );
      expect(full!.currentMa, -550.0);
      expect(shellCalls, 1);

      // 再取廉价 → 命中廉价缓存，不跑 shell。
      final cheapAgain = await readBatteryReading(
        sysfsReader: () async => null,
        channel: channel,
      );
      expect(cheapAgain!.currentMa, isNull);
      expect(shellCalls, 1);
    });
  });

  group('readBatteryReading 默认不跑 dumpsys', () {
    test('includeDumpsys 默认 false → shell 一次都不执行', () async {
      var shellCalls = 0;
      final r = await readBatteryReading(
        sysfsReader: () async => const BatteryReading(
          present: true,
          capacityPercent: 42,
        ),
        channel: _StubChannel(null),
        shellRunner: (_) async {
          shellCalls++;
          return _fullDumpsys;
        },
      );
      expect(r, isNotNull);
      expect(r!.capacityPercent, 42.0);
      expect(r.currentMa, isNull); // 廉价路径不补电流
      expect(shellCalls, 0);
    });
  });

  group('readBatterySourceDiagnostics', () {
    test('逐源返回 sysfs / battery_manager / dumpsys（含 raw 原文）', () async {
      final list = await readBatterySourceDiagnostics(
        sysfsReader: () async => const BatteryReading(
          present: true,
          capacityPercent: 70,
          sources: {'sysfs'},
        ),
        channel: _StubChannel(
          const BatteryReading(
            present: true,
            currentMa: -400,
            sources: {'battery_manager'},
          ),
        ),
        shellRunner: (_) async => _fullDumpsys,
      );

      expect(list.map((d) => d.source).toList(),
          <String>['sysfs', 'battery_manager', 'dumpsys']);
      expect(list[0].reading!.capacityPercent, 70.0);
      expect(list[1].reading!.currentMa, -400.0);
      expect(list[2].reading!.currentMa, -550.0);
      expect(list[2].raw, _fullDumpsys);
      expect(list.every((d) => d.error == null), isTrue);
    });

    test('单源抛异常 → 捕获到 error，绝不抛出；dumpsys raw 回退 error', () async {
      final list = await readBatterySourceDiagnostics(
        sysfsReader: () async => throw StateError('sysfs boom'),
        channel: _ThrowingChannel(),
        shellRunner: (_) async => throw StateError('shell boom'),
      );

      expect(list, hasLength(3));
      expect(list[0].error, contains('sysfs boom'));
      expect(list[1].error, contains('channel boom'));
      expect(list[2].reading, isNull);
      expect(list[2].raw, contains('shell boom'));
    });
  });

  group('sysfs BatteryReport → BatteryReading', () {
    test('status 字符串转 int 码（确保 status 为 int-backed）', () {
      const report = BatteryReport(
        present: true,
        voltageV: 3.8,
        currentMa: -550.0,
        temperatureC: 32.9,
        status: 'Discharging',
        basePath: '/sys/class/power_supply/battery',
      );
      final r = batteryReadingFromSysfs(report);
      expect(r.present, isTrue);
      expect(r.statusCode, 3);
      expect(r.statusLabel, 'Discharging');
      expect(r.basePath, '/sys/class/power_supply/battery');
      expect(r.sources, {'sysfs'});
    });

    test('status 为 null → statusCode 为 null', () {
      final r = batteryReadingFromSysfs(const BatteryReport(present: false));
      expect(r.statusCode, isNull);
      expect(r.statusLabel, isNull);
    });
  });
}
