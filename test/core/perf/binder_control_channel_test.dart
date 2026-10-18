import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/binder_control_channel.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';

/// 记录命令并返回罐头输出的假 runner（**不触碰真实 Shizuku**）。
class _FakeRunner {
  _FakeRunner({this.responder, this.hang = false});

  /// 按完整命令返回原始合并输出；`null` 时返回成功哨兵。
  final String? Function(String command)? responder;

  /// 为真时永不完成（模拟原生侧卡死；由 [PrivilegedShell] 的 Dart 侧超时兜底）。
  final bool hang;

  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);
    if (hang) return Completer<String>().future;
    if (responder != null) return responder!(command);
    return 'GSTORE_RESULT ok=1';
  }
}

/// 手搓能力图：只把 [availableLevers] 里的杠杆标记为可用。
PerfControlCapabilities _caps(Set<String> availableLevers) =>
    PerfControlCapabilities(
      nodeAvailability: const <String, bool>{},
      binderLevers: <String, bool>{
        for (final lever in PerfControlLevers.all)
          lever: availableLevers.contains(lever),
      },
      categoryAvailability: const <PerfControlCategory, bool>{},
      nodeCounts: const <PerfControlCategory, int>{},
      timeoutAvailable: true,
      probedAtMs: 0,
    );

BinderControlChannel _channel(
  _FakeRunner runner, {
  Set<String> availableLevers = const <String>{},
  PerfControlCapabilities? capabilities,
}) {
  final shell = PrivilegedShell(
    runner: runner.run,
    timeout: const Duration(milliseconds: 150),
    inShellTimeoutSeconds: 5,
  );
  return BinderControlChannel(
    shell: shell,
    capabilities: capabilities ?? _caps(availableLevers),
  );
}

void main() {
  group('探测门禁：不可用杠杆零调用', () {
    test('五个杠杆在全部不可用时都返回 unavailable 且不下发命令', () async {
      const levers = <String>[
        PerfControlLevers.powerFixedPerf,
        PerfControlLevers.thermal,
        PerfControlLevers.settings,
        PerfControlLevers.deviceConfig,
        PerfControlLevers.amStandbyBucket,
      ];

      for (final lever in levers) {
        final runner = _FakeRunner();
        final channel = _channel(runner); // 无任何可用杠杆

        final results = <BinderControlResult>[
          await channel.setFixedPerformanceMode(enabled: true),
          await channel.thermalStatus(),
          await channel.thermalReset(),
          await channel.thermalOverrideZoneStatus(
            zone: 'thermal_zone0',
            status: 'severe',
          ),
          await channel.putGlobalSetting(key: 'k', value: 'v'),
          await channel.putDeviceConfig(
            namespace: 'activity_manager',
            key: 'k',
            value: 'v',
          ),
          await channel.setStandbyBucket(package: 'com.example.app', bucket: 10),
        ];

        for (final result in results) {
          expect(result.ok, isFalse, reason: lever);
          expect(result.error, BinderControlError.unavailable, reason: lever);
          expect(result.command, isNull, reason: lever);
          expect(result.raw, isNull, reason: lever);
        }
        expect(runner.commands, isEmpty,
            reason: '不可用杠杆绝不下发任何命令（$lever）');
      }
    });

    test('门禁先于校验：不可用杠杆即使入参非法也返回 unavailable', () async {
      final runner = _FakeRunner();
      final channel = _channel(runner); // am 不可用

      final result = await channel.setStandbyBucket(
        package: 'bad;rm -rf /', // 非法包名
        bucket: 10,
      );

      expect(result.error, BinderControlError.unavailable);
      expect(runner.commands, isEmpty);
    });

    test('仅可用杠杆被放行：一个可用、其余不可用', () async {
      final runner = _FakeRunner();
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.settings},
      );

      final allowed = await channel.putGlobalSetting(key: 'k', value: 'v');
      final blocked = await channel.setFixedPerformanceMode(enabled: true);

      expect(allowed.ok, isTrue);
      expect(blocked.error, BinderControlError.unavailable);
      // 只有 settings 的 read+write 两条命令。
      expect(runner.commands.length, 2);
      expect(
        runner.commands.every((c) => c.contains('settings')),
        isTrue,
      );
    });
  });

  group('cmd power', () {
    test('可用时下发 set-fixed-performance-mode-enabled true 且哨兵成功', () async {
      final runner = _FakeRunner();
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.powerFixedPerf},
      );

      final result = await channel.setFixedPerformanceMode(enabled: true);

      expect(result.ok, isTrue);
      expect(result.error, isNull);
      expect(result.command, contains('cmd power set-fixed-performance-mode-enabled true'));
      expect(result.command, startsWith('timeout 5 sh -c'));
      expect(runner.commands, hasLength(1));
    });

    test('false 分支同样下发', () async {
      final runner = _FakeRunner();
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.powerFixedPerf},
      );

      final result = await channel.setFixedPerformanceMode(enabled: false);

      expect(result.command, contains('set-fixed-performance-mode-enabled false'));
      expect(result.ok, isTrue);
    });
  });

  group('cmd thermal', () {
    Set<String> thermalOn() => const <String>{PerfControlLevers.thermal};

    test('状态读取下发裸 cmd thermal', () async {
      final runner = _FakeRunner();
      final result = await _channel(runner, availableLevers: thermalOn())
          .thermalStatus();

      expect(result.ok, isTrue);
      expect(result.command, contains('cmd thermal'));
    });

    test('reset 下发 cmd thermal reset', () async {
      final runner = _FakeRunner();
      final result = await _channel(runner, availableLevers: thermalOn())
          .thermalReset();

      expect(result.ok, isTrue);
      expect(result.command, contains('cmd thermal reset'));
    });

    test('override-status 规范化状态为小写', () async {
      final runner = _FakeRunner();
      final result = await _channel(runner, availableLevers: thermalOn())
          .thermalOverrideZoneStatus(zone: 'thermal_zone0', status: 'SEVERE');

      expect(result.ok, isTrue);
      expect(
        result.command,
        contains('cmd thermal override-status thermal_zone0 severe'),
      );
    });

    test('非法状态被拒绝且零调用', () async {
      final runner = _FakeRunner();
      final result = await _channel(runner, availableLevers: thermalOn())
          .thermalOverrideZoneStatus(zone: 'thermal_zone0', status: 'bogus');

      expect(result.error, PrivilegedError.invalidArg);
      expect(result.detail, 'status_not_allowed');
      expect(result.command, isNull);
      expect(runner.commands, isEmpty);
    });

    test('非法热区 token 被拒绝且零调用', () async {
      final runner = _FakeRunner();
      final result = await _channel(runner, availableLevers: thermalOn())
          .thermalOverrideZoneStatus(zone: 'zone;rm', status: 'severe');

      expect(result.error, PrivilegedError.invalidArg);
      expect(runner.commands, isEmpty);
    });
  });

  group('settings（有状态，记录原值）', () {
    test('写入前读取原值并随结果返回', () async {
      final runner = _FakeRunner(
        responder: (command) => command.contains('settings get global bluetooth_on')
            ? '0\nGSTORE_RESULT ok=1'
            : 'GSTORE_RESULT ok=1',
      );
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.settings},
      );

      final result = await channel.putGlobalSetting(
        key: 'bluetooth_on',
        value: '1',
      );

      expect(result.ok, isTrue);
      expect(result.original, '0');
      expect(result.command, contains('settings put global bluetooth_on 1'));
      // 第一条是 get，第二条是 put。
      expect(runner.commands, hasLength(2));
      expect(runner.commands.first, contains('settings get global bluetooth_on'));
    });

    test('原值读取失败（无哨兵）不影响写入成功，original 为 null', () async {
      final runner = _FakeRunner(
        responder: (command) => command.contains('settings get global')
            ? 'garbage'
            : 'GSTORE_RESULT ok=1',
      );
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.settings},
      );

      final result = await channel.putGlobalSetting(key: 'k', value: 'v');

      expect(result.ok, isTrue);
      expect(result.original, isNull);
    });

    test('危险字符 key 被拒绝且零调用', () async {
      final runner = _FakeRunner();
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.settings},
      );

      final result = await channel.putGlobalSetting(key: 'a;b', value: 'v');

      expect(result.error, PrivilegedError.invalidArg);
      expect(result.command, isNull);
      expect(runner.commands, isEmpty);
    });
  });

  group('device_config（有状态，记录原值）', () {
    test('读取原值并写入', () async {
      final runner = _FakeRunner(
        responder: (command) => command.contains('device_config get')
            ? '500\nGSTORE_RESULT ok=1'
            : 'GSTORE_RESULT ok=1',
      );
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.deviceConfig},
      );

      final result = await channel.putDeviceConfig(
        namespace: 'activity_manager',
        key: 'max_cached_processes',
        value: '1000',
      );

      expect(result.ok, isTrue);
      expect(result.original, '500');
      expect(
        result.command,
        contains('device_config put activity_manager max_cached_processes 1000'),
      );
    });

    test('非法 namespace 被拒绝且零调用', () async {
      final runner = _FakeRunner();
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.deviceConfig},
      );

      final result = await channel.putDeviceConfig(
        namespace: r'ns$(id)',
        key: 'k',
        value: 'v',
      );

      expect(result.error, PrivilegedError.invalidArg);
      expect(runner.commands, isEmpty);
    });
  });

  group('am set-standby-bucket（有状态，记录原值）', () {
    test('读取原 bucket 并写入', () async {
      final runner = _FakeRunner(
        responder: (command) => command.contains('am get-standby-bucket')
            ? '10\nGSTORE_RESULT ok=1'
            : 'GSTORE_RESULT ok=1',
      );
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.amStandbyBucket},
      );

      final result = await channel.setStandbyBucket(
        package: 'com.example.app',
        bucket: 30,
      );

      expect(result.ok, isTrue);
      expect(result.original, '10');
      expect(
        result.command,
        contains('am set-standby-bucket com.example.app 30'),
      );
    });

    test('非法包名被拒绝且零调用', () async {
      final runner = _FakeRunner();
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.amStandbyBucket},
      );

      final result = await channel.setStandbyBucket(
        package: '1badname',
        bucket: 10,
      );

      expect(result.error, PrivilegedError.invalidArg);
      expect(runner.commands, isEmpty);
    });
  });

  group('哨兵成功强制', () {
    test('无哨兵输出绝不判成功', () async {
      final runner = _FakeRunner(responder: (_) => 'Success');
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.powerFixedPerf},
      );

      final result = await channel.setFixedPerformanceMode(enabled: true);

      expect(result.ok, isFalse);
      expect(result.error, PrivilegedError.sentinelMissing);
    });

    test('误导性 Success + err 哨兵 → command_failed', () async {
      final runner = _FakeRunner(
        responder: (_) => 'Success\nGSTORE_RESULT err=1',
      );
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.powerFixedPerf},
      );

      final result = await channel.setFixedPerformanceMode(enabled: true);

      expect(result.ok, isFalse);
      expect(result.error, PrivilegedError.commandFailed);
    });

    test('卡死命令由自我限时兜底（timeout）', () async {
      final runner = _FakeRunner(hang: true);
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.powerFixedPerf},
      );

      final result = await channel.setFixedPerformanceMode(enabled: true);

      expect(result.ok, isFalse);
      expect(result.error, PrivilegedError.timeout);
      // 命令自身以 toybox timeout 前缀自我限时。
      expect(result.command, startsWith('timeout 5 sh -c'));
    });

    test('runner 返回 null → no_output', () async {
      final runner = _FakeRunner(responder: (_) => null);
      final channel = _channel(
        runner,
        availableLevers: const <String>{PerfControlLevers.powerFixedPerf},
      );

      final result = await channel.setFixedPerformanceMode(enabled: true);

      expect(result.ok, isFalse);
      expect(result.error, PrivilegedError.noOutput);
    });
  });
}
