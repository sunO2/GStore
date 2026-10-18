import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/control_thermal.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

/// 热控节点（由下方 tunables fixture 推导）。
const String _thermalMode = '/sys/class/thermal/thermal_zone0/mode';
const String _thermalMode1 = '/sys/class/thermal/thermal_zone1/mode';

/// 记录命令 + 维护内存节点值的假 runner（**不触碰真实 Shizuku / 真机**）。
///
/// * `cat <path>` → 返回当前值（[values]）+ 成功哨兵；
/// * `printf %s <value> > <path>` → 写成功时更新 [values]；
/// * [deniedReads]/[deniedWrites] → 返回失败哨兵；
/// * [hangReads]/[hangWrites] → 返回**永不完成**的 Future（验证自我限时）；
/// * [ignoreWrites] → 写「成功」但**不**更新 [values]（制造回读不一致）。
class _FakeRunner {
  _FakeRunner({
    Map<String, String>? values,
    this.deniedReads = const <String>{},
    this.deniedWrites = const <String>{},
    this.hangReads = const <String>{},
    this.ignoreWrites = const <String>{},
  }) : values = <String, String>{...?values};

  final Map<String, String> values;
  final Set<String> deniedReads;
  final Set<String> deniedWrites;
  final Set<String> hangReads;
  final Set<String> ignoreWrites;
  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);

    final read = RegExp(r'cat (\S+)').firstMatch(command);
    if (read != null) {
      final path = read.group(1)!;
      if (hangReads.contains(path)) return Completer<String?>().future;
      if (deniedReads.contains(path)) return 'GSTORE_RESULT err=1';
      final value = values[path];
      if (value == null) return 'GSTORE_RESULT err=1';
      return '$value\nGSTORE_RESULT ok=1';
    }

    final write = RegExp(r'printf %s (\S+) > (\S+)').firstMatch(command);
    if (write != null) {
      final value = write.group(1)!;
      final path = write.group(2)!;
      if (deniedWrites.contains(path)) return 'GSTORE_RESULT err=1';
      if (!ignoreWrites.contains(path)) values[path] = value;
      return 'GSTORE_RESULT ok=1';
    }

    return 'GSTORE_RESULT err=1';
  }
}

/// `perf.tunables` fixture：两个热区。
TunablesReport _tunables() => const TunablesReport(
      thermalZones: <PerfThermalTunable>[
        PerfThermalTunable(zone: 'thermal_zone0', type: 'cpu', mode: 'enabled'),
        PerfThermalTunable(zone: 'thermal_zone1', type: 'gpu', mode: 'enabled'),
      ],
    );

/// 能力图 fixture：只有 [writable] 里的节点算可写（fail-closed 语义）。
PerfControlCapabilities _capabilities({required List<String> writable}) =>
    PerfControlCapabilities(
      nodeAvailability: <String, bool>{
        for (final path in writable) path: true,
      },
      binderLevers: const <String, bool>{},
      categoryAvailability: <PerfControlCategory, bool>{
        PerfControlCategory.thermal: writable.isNotEmpty,
      },
      nodeCounts: <PerfControlCategory, int>{
        PerfControlCategory.thermal: writable.length,
      },
      timeoutAvailable: true,
      probedAtMs: 0,
    );

ThermalToggleController _controller(
  _FakeRunner runner, {
  Duration timeout = const Duration(seconds: 6),
}) =>
    ThermalToggleController(
      shell: PrivilegedShell(runner: runner.run, timeout: timeout),
    );

bool _wrote(List<String> commands, String value, String path) =>
    commands.any((c) => c.contains('printf %s $value > $path'));

void main() {
  group('确认门禁（缺失确认 → 零写入）', () {
    test('confirmed=false → confirm_required 且不发出任何命令', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      final result = await _controller(runner).setThermalEnabled(
        false, // 危险方向：关闭热控
        confirmed: false,
        tunables: _tunables(),
        capabilities: _capabilities(writable: <String>[_thermalMode]),
      );

      expect(result.ok, isFalse);
      expect(result.error, ThermalToggleError.confirmRequired);
      // 零命令（既不读也不写）——在任何写之前就拒绝。
      expect(runner.commands, isEmpty);
      expect(result.applied, isEmpty);
    });
  });

  group('确认 + 可写 → 应用并记录原值（供 todo 20 还原）', () {
    test('关闭热控（enabled=false）→ 写 disabled，原值 enabled 被记录', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      final result = await _controller(runner).setThermalEnabled(
        false,
        confirmed: true,
        tunables: _tunables(),
        capabilities: _capabilities(writable: <String>[_thermalMode]),
      );

      expect(result.ok, isTrue);
      expect(result.error, isNull);
      expect(result.applied, hasLength(1));
      expect(result.applied.single.path, _thermalMode);
      expect(result.applied.single.originalValue, 'enabled');
      expect(result.applied.single.appliedValue, 'disabled');
      expect(_wrote(runner.commands, 'disabled', _thermalMode), isTrue);
    });

    test('恢复热控（enabled=true）→ 写 enabled，原值 disabled 被记录', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'disabled'});
      final result = await _controller(runner).setThermalEnabled(
        true,
        confirmed: true,
        tunables: _tunables(),
        capabilities: _capabilities(writable: <String>[_thermalMode]),
      );

      expect(result.ok, isTrue);
      expect(result.applied.single.originalValue, 'disabled');
      expect(result.applied.single.appliedValue, 'enabled');
      expect(_wrote(runner.commands, 'enabled', _thermalMode), isTrue);
    });

    test('多节点全部可写 → 各自记录原值', () async {
      final runner = _FakeRunner(values: <String, String>{
        _thermalMode: 'enabled',
        _thermalMode1: 'disabled',
      });
      final result = await _controller(runner).setThermalEnabled(
        false,
        confirmed: true,
        tunables: _tunables(),
        capabilities:
            _capabilities(writable: <String>[_thermalMode, _thermalMode1]),
      );

      expect(result.ok, isTrue);
      expect(result.applied, hasLength(2));
      expect(
        result.applied.map((r) => r.originalValue).toSet(),
        <String>{'enabled', 'disabled'},
      );
    });
  });

  group('失败路径（写拒 / 回读不一致 → 回滚）', () {
    test('写入被拒 → write_failed 且尝试回滚原值', () async {
      final runner = _FakeRunner(
        values: <String, String>{_thermalMode: 'enabled'},
        deniedWrites: <String>{_thermalMode},
      );
      final result = await _controller(runner).setThermalEnabled(
        false,
        confirmed: true,
        tunables: _tunables(),
        capabilities: _capabilities(writable: <String>[_thermalMode]),
      );

      expect(result.ok, isFalse);
      expect(result.error, ThermalToggleError.writeFailed);
      // 回滚尝试：把原值 enabled 写回该节点。
      expect(result.rolledBack, isNotEmpty);
      expect(_wrote(runner.commands, 'enabled', _thermalMode), isTrue);
    });

    test('回读不一致 → read_back_mismatch 且回滚', () async {
      final runner = _FakeRunner(
        values: <String, String>{_thermalMode: 'enabled'},
        ignoreWrites: <String>{_thermalMode}, // 写"成功"但不生效
      );
      final result = await _controller(runner).setThermalEnabled(
        false,
        confirmed: true,
        tunables: _tunables(),
        capabilities: _capabilities(writable: <String>[_thermalMode]),
      );

      expect(result.ok, isFalse);
      expect(result.error, ThermalToggleError.readBackMismatch);
      expect(result.rolledBack, isNotEmpty);
      expect(_wrote(runner.commands, 'enabled', _thermalMode), isTrue);
    });

    test('第二个节点被拒 → 已应用的第一个节点被回滚', () async {
      final runner = _FakeRunner(
        values: <String, String>{_thermalMode: 'enabled', _thermalMode1: 'enabled'},
        deniedWrites: <String>{_thermalMode1},
      );
      final result = await _controller(runner).setThermalEnabled(
        false,
        confirmed: true,
        tunables: _tunables(),
        capabilities:
            _capabilities(writable: <String>[_thermalMode, _thermalMode1]),
      );

      expect(result.ok, isFalse);
      expect(result.error, ThermalToggleError.writeFailed);
      // 第一个节点已写 disabled，随后被回滚为 enabled。
      expect(_wrote(runner.commands, 'enabled', _thermalMode), isTrue);
      expect(
        result.rolledBack.map((r) => r.path).toSet(),
        <String>{_thermalMode, _thermalMode1},
      );
    });

    test('读原值失败 → read_failed 且零写入（fail-closed）', () async {
      final runner = _FakeRunner(
        values: <String, String>{_thermalMode: 'enabled'},
        deniedReads: <String>{_thermalMode},
      );
      final result = await _controller(runner).setThermalEnabled(
        false,
        confirmed: true,
        tunables: _tunables(),
        capabilities: _capabilities(writable: <String>[_thermalMode]),
      );

      expect(result.ok, isFalse);
      expect(result.error, ThermalToggleError.readFailed);
      expect(runner.commands.any((c) => c.contains('> $_thermalMode')), isFalse);
    });
  });

  group('不可用（零写入）', () {
    test('无可写 thermal 节点 → unavailable 且不发出任何命令', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      final result = await _controller(runner).setThermalEnabled(
        false,
        confirmed: true,
        tunables: _tunables(),
        capabilities: _capabilities(writable: const <String>[]),
      );

      expect(result.ok, isFalse);
      expect(result.error, ThermalToggleError.unavailable);
      expect(runner.commands, isEmpty);
      expect(result.applied, isEmpty);
    });

    test('tunables 未枚举到 thermal 节点 → unavailable', () async {
      final runner = _FakeRunner();
      final result = await _controller(runner).setThermalEnabled(
        false,
        confirmed: true,
        tunables: const TunablesReport(),
        capabilities: _capabilities(writable: <String>[_thermalMode]),
      );

      expect(result.ok, isFalse);
      expect(result.error, ThermalToggleError.unavailable);
      expect(runner.commands, isEmpty);
    });
  });

  group('对抗类载荷 / 超时', () {
    test('malformed bool → invalid_arg 且零写入', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      final caps = _capabilities(writable: <String>[_thermalMode]);

      for (final bad in <Object?>['yes', 'true', 1, null]) {
        final result = await _controller(runner).setThermalEnabledLoose(
          bad,
          confirmed: true,
          tunables: _tunables(),
          capabilities: caps,
        );
        expect(result.ok, isFalse);
        expect(result.error, PrivilegedError.invalidArg);
      }
      expect(runner.commands, isEmpty);
    });

    test('宽松入口接受真正的 bool → 正常应用', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      final result = await _controller(runner).setThermalEnabledLoose(
        false,
        confirmed: true,
        tunables: _tunables(),
        capabilities: _capabilities(writable: <String>[_thermalMode]),
      );
      expect(result.ok, isTrue);
      expect(result.applied.single.appliedValue, 'disabled');
    });

    test('读取挂起 → 自我限时（ok:false），且每条命令都自带 timeout 前缀', () async {
      final runner = _FakeRunner(
        values: <String, String>{_thermalMode: 'enabled'},
        hangReads: <String>{_thermalMode},
      );
      final result = await _controller(
        runner,
        timeout: const Duration(milliseconds: 40),
      ).setThermalEnabled(
        false,
        confirmed: true,
        tunables: _tunables(),
        capabilities: _capabilities(writable: <String>[_thermalMode]),
      );

      expect(result.ok, isFalse);
      expect(result.error, ThermalToggleError.readFailed);
      // 每条特权命令都必须自我限时（继承 todo 10 约束）。
      expect(runner.commands, isNotEmpty);
      for (final command in runner.commands) {
        expect(command.startsWith('timeout '), isTrue,
            reason: '每条特权命令都必须自我限时: $command');
      }
    });

    test('所有成功/失败路径的命令均自限时且无未加引号的危险注入', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      await _controller(runner).setThermalEnabled(
        false,
        confirmed: true,
        tunables: _tunables(),
        capabilities: _capabilities(writable: <String>[_thermalMode]),
      );

      for (final command in runner.commands) {
        expect(command.startsWith('timeout '), isTrue);
        expect(command.contains('; echo'), isFalse,
            reason: '哨兵必须以 &&/|| 链，绝不用 ; echo');
      }
    });
  });
}
