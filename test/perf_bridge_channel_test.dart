import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/battery_source.dart';
import 'package:gstore/core/perf/device_state.dart';
import 'package:gstore/core/perf/foreground_source.dart';
import 'package:gstore/core/perf/frame_metrics_source.dart';
import 'package:gstore/core/platform/platform_channel.dart';
import 'package:gstore/core/shell/rust_shizuku_runner.dart';

/// Default readers of the five bridge classes must reach `gstore/platform`
/// (Todo 4) instead of the deleted FRB functions, while the injected seams and
/// the battery merge order stay untouched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const platformChannel = MethodChannel(PlatformChannelClient.channelName);
  late List<MethodCall> calls;

  void installHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformChannel, handler);
  }

  Future<Object?> okHandler(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'readBattery':
        return jsonEncode(<String, Object?>{
          'present': true,
          'voltageMv': 4123,
          'currentUa': -550000,
          'temperatureTenthsC': 329,
          'status': 3,
          'health': 2,
          'technology': 'Li-ion',
          'capacityPercent': 80,
          'interactive': true,
        });
      case 'readDeviceState':
        return jsonEncode(<String, Object?>{
          'battery': <String, Object?>{'present': true, 'level': 70},
          'display': <String, Object?>{
            'refreshRate': 120.0,
            'supportedModes': <Object?>[],
          },
        });
      case 'readForeground':
        return jsonEncode(<String, Object?>{
          'enabled': true,
          'package': 'com.example.app',
          'activity': 'com.example.app.Main',
          'updatedAtMs': 1700000000000,
        });
      case 'readFrameMetrics':
        return jsonEncode(<String, Object?>{
          'count': 3,
          'avgMs': 8.5,
          'p90Ms': 10.0,
          'p99Ms': 11.0,
          'jankPercent': 0.0,
          'lastMs': 9.0,
          'refreshRate': 60.0,
          'windowSize': 120,
        });
      case 'exec':
        return call.arguments == 'pm list packages'
            ? 'package:com.example.app'
            : null;
      case 'available':
        return true;
      default:
        throw MissingPluginException('unexpected method ${call.method}');
    }
  }

  setUp(() {
    calls = <MethodCall>[];
    resetBatteryReadingCache();
  });

  tearDown(() {
    installHandler((call) async => null);
  });

  group('gstore/platform default readers', () {
    test('RustJniBatteryBridge reads battery + interactive from the channel',
        () async {
      installHandler(okHandler);

      final bridge = RustJniBatteryBridge();
      final reading = await bridge.read();
      final interactive = await bridge.readInteractive();

      expect(reading, isNotNull);
      expect(reading!.present, isTrue);
      expect(reading.voltageV, 4.123);
      expect(reading.currentMa, -550.0);
      expect(reading.temperatureC, 32.9);
      expect(reading.statusLabel, 'Discharging');
      expect(reading.health, 'Good');
      expect(reading.capacityPercent, 80.0);
      expect(reading.sources, <String>{'rust_jni'});
      expect(interactive, isTrue);
      expect(
        calls.where((call) => call.method == 'readBattery'),
        hasLength(2),
        reason: 'both readers use the same channel payload',
      );
    });

    test('RustJniDeviceStateBridge reads the device state payload', () async {
      installHandler(okHandler);

      final reading = await RustJniDeviceStateBridge().read();

      expect(reading, isNotNull);
      expect(reading!.battery?.level, 70);
      expect(reading.displayRefreshRate, 120.0);
      expect(reading.sources, contains('rust_jni'));
      expect(calls.single.method, 'readDeviceState');
    });

    test('RustJniForegroundBridge reads the accessibility payload', () async {
      installHandler(okHandler);

      final reading = await RustJniForegroundBridge().read();

      expect(reading, isNotNull);
      expect(reading!.enabled, isTrue);
      expect(reading.package, 'com.example.app');
      expect(reading.activity, 'com.example.app.Main');
      expect(reading.updatedAtMs, 1700000000000);
      expect(calls.single.method, 'readForeground');
    });

    test('RustJniFrameMetricsBridge reads the frame metrics payload', () async {
      installHandler(okHandler);

      final reading = await RustJniFrameMetricsBridge().read();

      expect(reading, isNotNull);
      expect(reading!.count, 3);
      expect(reading.avgMs, 8.5);
      expect(reading.p90Ms, 10.0);
      expect(reading.refreshRate, 60.0);
      expect(calls.single.method, 'readFrameMetrics');
    });

    test('rustShizukuRunner/rustShizukuAvailable use exec/available', () async {
      installHandler(okHandler);

      final output = await rustShizukuRunner('pm list packages');
      final available = await rustShizukuAvailable();

      expect(output, 'package:com.example.app');
      expect(available, isTrue);
      expect(
        calls.map((call) => call.method),
        <String>['exec', 'available'],
        reason: 'exactly one privileged-shell path remains',
      );
      expect(calls.first.arguments, 'pm list packages');
    });

    test('a typed error envelope degrades to null / false (never throws)',
        () async {
      installHandler((call) async {
        switch (call.method) {
          case 'exec':
            return null;
          case 'available':
            return false;
          default:
            return jsonEncode(<String, Object?>{
              'ok': false,
              'code': 'CORE_E_PLATFORM_DENIED',
              'message': 'shizuku not granted',
            });
        }
      });

      expect(await RustJniBatteryBridge().read(), isNull);
      expect(await RustJniDeviceStateBridge().read(), isNull);
      expect(await RustJniForegroundBridge().read(), isNull);
      expect(await RustJniFrameMetricsBridge().read(), isNull);
      expect(await rustShizukuRunner('pm list packages'), isNull);
      expect(await rustShizukuAvailable(), isFalse);
    });

    test('injected reader seams still win over the channel', () async {
      installHandler(okHandler);

      final bridge = RustJniBatteryBridge(
        readJson: () async => '{"present":true,"capacityPercent":22}',
        readInteractive: () async => false,
      );

      final reading = await bridge.read();
      final interactive = await bridge.readInteractive();

      expect(reading!.capacityPercent, 22.0);
      expect(interactive, isFalse);
      expect(calls, isEmpty, reason: 'the injected seam must not hit the channel');
    });
  });

  group('battery merge order is unchanged', () {
    test('sysfs > platform > battery_manager > dumpsys', () async {
      installHandler(okHandler);
      var dumpsysCalls = 0;

      final merged = await readBatteryReading(
        includeDumpsys: true,
        cacheTtl: Duration.zero,
        sysfsReader: () async => const BatteryReading(
          present: true,
          capacityPercent: 55.0,
          sources: <String>{'sysfs'},
        ),
        rustBridge: RustJniBatteryBridge(
          // no voltage here, so dumpsys is the only source that can fill it
          readJson: () async =>
              '{"present":true,"currentUa":-100000,"status":3}',
        ),
        channel: BatteryManagerChannel(
          channel: const MethodChannel('gstore/battery'),
          rustBridge: RustJniBatteryBridge(
            readJson: () async => '{"present":true}',
          ),
        ),
        shellRunner: (command) async {
          dumpsysCalls++;
          expect(command, kBatteryDumpsysCommand);
          return 'level: 42\nscale: 100\nvoltage: 3900\n'
              'current now: -300000\ntechnology: Li-ion';
        },
      );

      expect(merged, isNotNull);
      expect(merged!.capacityPercent, 55.0, reason: 'sysfs wins capacity');
      expect(merged.currentMa, -100.0, reason: 'platform beats dumpsys');
      expect(merged.voltageV, 3.9, reason: 'dumpsys is the last resort');
      expect(merged.statusLabel, 'Discharging');
      expect(merged.sources, <String>{
        'sysfs',
        'rust_jni',
        'dumpsys',
      });
      expect(dumpsysCalls, 1);
    });
  });
}
