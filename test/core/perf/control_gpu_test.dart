import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

/// 带状态的可编程假 runner（**不触碰真实 Shizuku / 节点**）。
///
/// * `test -w`：命中 [writable] → `ok=1`，否则 `err=1`；
/// * 写入：更新 [nodeValues]（除 [stubborn] 外）；[denyWrites] → `err=1`，
///   [stubborn] → 假成功 `ok=1` 但**不更新**节点（模拟「哨兵假成功 / 只读 FS」）；
/// * 读取：返回 [nodeValues] 当前值；无值 → `err=1`。
class _FakeGpuRunner {
  _FakeGpuRunner({
    this.writable = const <String>{},
    Map<String, String>? values,
    this.denyWrites = const <String>{},
    this.stubborn = const <String>{},
    this.throwing = false,
  }) : nodeValues = <String, String>{...?values};

  final Set<String> writable;
  final Map<String, String> nodeValues;
  final Set<String> denyWrites;
  final Set<String> stubborn;
  final bool throwing;
  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);
    if (throwing) throw StateError('runner boom');

    final probe = RegExp(r'test -w (\S+)').firstMatch(command);
    if (probe != null) {
      return writable.contains(probe.group(1))
          ? 'GSTORE_RESULT ok=1'
          : 'GSTORE_RESULT err=1';
    }

    final write = RegExp(r'printf %s (\S+) > (\S+)').firstMatch(command);
    if (write != null) {
      final value = write.group(1)!;
      final path = write.group(2)!;
      if (denyWrites.contains(path)) return 'GSTORE_RESULT err=1';
      if (stubborn.contains(path)) return 'GSTORE_RESULT ok=1';
      nodeValues[path] = value;
      return 'GSTORE_RESULT ok=1';
    }

    final read = RegExp(r'cat (\S+)').firstMatch(command);
    if (read != null) {
      final value = nodeValues[read.group(1)];
      return value == null ? 'GSTORE_RESULT err=1' : '$value\nGSTORE_RESULT ok=1';
    }
    return 'GSTORE_RESULT err=1';
  }

  /// 实际写命令（`printf … > …`）；「零写入」断言用。
  List<String> get writeCommands =>
      commands.where((c) => c.contains('printf %s')).toList();
}

// ---- 混合 fixture 推导出的 GPU 控制节点 ----
const String _gpuDevfreqGovernor = '/sys/class/kgsl/kgsl-3d0/devfreq/governor';
const String _gpuDevfreqMin = '/sys/class/kgsl/kgsl-3d0/devfreq/min_freq';
const String _gpuMinPwrlevel = '/sys/class/kgsl/kgsl-3d0/min_pwrlevel';
const String _gpuMaxPwrlevel = '/sys/class/kgsl/kgsl-3d0/max_pwrlevel';

/// 有 kgsl GPU 可控面的 tunables（available=[500,800]，power_levels=14）。
TunablesReport _gpuTunables() => const TunablesReport(
      gpu: PerfGpuTunables(
        availableFrequenciesMhz: <double>[500, 800],
        freqSource: '/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies',
        governor: 'msm-adreno-tz',
        governorSource: _gpuDevfreqGovernor,
        powerLevels: 14,
        powerSource: '/sys/class/kgsl/kgsl-3d0/num_pwrlevels',
      ),
    );

/// 无任何 GPU 可控面（桌面 / CI 主机常见）。
const TunablesReport _emptyTunables = TunablesReport();

GpuControlAction _actionWith(_FakeGpuRunner runner) =>
    GpuControlAction(shell: PrivilegedShell(runner: runner.run));

void main() {
  group('入参校验（非法 → rejected，零命令）', () {
    test('空策略 → rejected，零命令', () async {
      final runner = _FakeGpuRunner();
      final result =
          await _actionWith(runner).applyGpuPolicy(const GpuPolicy());
      expect(result.isRejected, isTrue);
      expect(result.error, 'empty_policy');
      expect(runner.commands, isEmpty);
    });

    test('危险 token governor（`; rm`）→ rejected，零命令', () async {
      final runner = _FakeGpuRunner();
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(governor: 'perf; rm -rf /'),
        tunables: _gpuTunables(),
      );
      expect(result.isRejected, isTrue);
      expect(result.error, PrivilegedError.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('频率不在 available → rejected，零命令', () async {
      final runner = _FakeGpuRunner();
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(minFreqMhz: 123),
        tunables: _gpuTunables(),
      );
      expect(result.isRejected, isTrue);
      expect(runner.commands, isEmpty);
    });

    test('功耗档位越界 → rejected，零命令', () async {
      final runner = _FakeGpuRunner();
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(maxPwrlevel: 99),
        tunables: _gpuTunables(),
      );
      expect(result.isRejected, isTrue);
      expect(runner.commands, isEmpty);
    });

    test('min > max（频率）→ rejected，零命令', () async {
      final runner = _FakeGpuRunner();
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(minFreqMhz: 800, maxFreqMhz: 500),
        tunables: _gpuTunables(),
      );
      expect(result.isRejected, isTrue);
      expect(runner.commands, isEmpty);
    });
  });

  group('happy：可写节点 → 施加 + 回读通过', () {
    test('min_pwrlevel + min_freq 写入并回读一致 → applied（2 写）', () async {
      final runner = _FakeGpuRunner(
        writable: <String>{_gpuMinPwrlevel, _gpuDevfreqMin},
        values: <String, String>{
          _gpuMinPwrlevel: '0',
          _gpuDevfreqMin: '300000000',
        },
      );
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(minPwrlevel: 4, minFreqMhz: 500),
        tunables: _gpuTunables(),
      );

      expect(result.applied, isTrue);
      expect(result.writeCount, 2);
      expect(result.rollbackCount, 0);
      expect(runner.nodeValues[_gpuMinPwrlevel], '4');
      expect(runner.nodeValues[_gpuDevfreqMin], '500000000');
    });

    test('governor 写入并回读一致 → applied', () async {
      final runner = _FakeGpuRunner(
        writable: <String>{_gpuDevfreqGovernor},
        values: <String, String>{_gpuDevfreqGovernor: 'msm-adreno-tz'},
      );
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(governor: 'performance'),
        tunables: _gpuTunables(),
      );

      expect(result.applied, isTrue);
      expect(runner.nodeValues[_gpuDevfreqGovernor], 'performance');
    });
  });

  group('unavailable：无可写节点 → 零写入', () {
    test('空 tunables（无 GPU 节点）→ unavailable，零写入', () async {
      final runner = _FakeGpuRunner();
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(minPwrlevel: 0),
        tunables: _emptyTunables,
      );

      expect(result.isUnavailable, isTrue);
      expect(result.error, GpuControlError.unavailable);
      expect(result.writeCount, 0);
      expect(runner.writeCommands, isEmpty);
      expect(runner.commands, isEmpty);
    });

    test('有候选节点但全不可写 → unavailable，零写入', () async {
      final runner = _FakeGpuRunner(); // writable 为空 → 全部 err=1
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(minPwrlevel: 0, maxPwrlevel: 1),
        tunables: _gpuTunables(),
      );

      expect(result.isUnavailable, isTrue);
      expect(result.writeCount, 0);
      expect(runner.writeCommands, isEmpty);
      // 只发了只读探测命令。
      expect(runner.commands, isNotEmpty);
    });

    test('governor 无候选（tunables 无 GPU 来源）→ unavailable', () async {
      final runner = _FakeGpuRunner();
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(governor: 'performance'),
        tunables: _emptyTunables,
      );
      expect(result.isUnavailable, isTrue);
      expect(runner.commands, isEmpty);
      expect(runner.writeCommands, isEmpty);
    });
  });

  group('对抗：假成功 / 回读不符 → failed + 回滚', () {
    test('哨兵假成功（写返回 ok=1 但节点未变）→ failed，不判成功', () async {
      final runner = _FakeGpuRunner(
        writable: <String>{_gpuMinPwrlevel},
        values: <String, String>{_gpuMinPwrlevel: '0'},
        stubborn: <String>{_gpuMinPwrlevel},
      );
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(minPwrlevel: 4),
        tunables: _gpuTunables(),
      );

      expect(result.applied, isFalse);
      expect(result.status, GpuPolicyStatus.failed);
      expect(result.error, GpuControlError.readbackMismatch);
      expect(result.writeCount, 1);
      expect(runner.nodeValues[_gpuMinPwrlevel], '0');
    });

    test('写入被拒 → failed(write_failed)', () async {
      final runner = _FakeGpuRunner(
        writable: <String>{_gpuMinPwrlevel},
        values: <String, String>{_gpuMinPwrlevel: '0'},
        denyWrites: <String>{_gpuMinPwrlevel},
      );
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(minPwrlevel: 4),
        tunables: _gpuTunables(),
      );

      expect(result.status, GpuPolicyStatus.failed);
      expect(result.error, GpuControlError.writeFailed);
    });

    test('runner 抛异常 → fail-closed unavailable，绝不抛出', () async {
      final runner = _FakeGpuRunner(throwing: true);
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(minPwrlevel: 4),
        tunables: _gpuTunables(),
      );

      expect(result.isUnavailable, isTrue);
      expect(result.applied, isFalse);
      expect(runner.writeCommands, isEmpty);
    });

    test('第二个旋钮回读失败 → 两个写都回滚', () async {
      final runner = _FakeGpuRunner(
        writable: <String>{_gpuMinPwrlevel, _gpuMaxPwrlevel},
        values: <String, String>{
          _gpuMinPwrlevel: '0',
          _gpuMaxPwrlevel: '13',
        },
        stubborn: <String>{_gpuMaxPwrlevel},
      );
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(minPwrlevel: 2, maxPwrlevel: 10),
        tunables: _gpuTunables(),
      );

      expect(result.status, GpuPolicyStatus.failed);
      expect(result.writeCount, 2);
      // min_pwrlevel 写成功后被回滚；max 为 stubborn，回滚「成功」但不改值。
      expect(runner.nodeValues[_gpuMinPwrlevel], '0');
      expect(result.rollbackCount, greaterThanOrEqualTo(1));
    });
  });

  group('自限时（hung 防护）', () {
    test('每条命令都以 `timeout <n> sh -c` 自我限时', () async {
      final runner = _FakeGpuRunner(
        writable: <String>{_gpuMinPwrlevel},
        values: <String, String>{_gpuMinPwrlevel: '0'},
      );
      final result = await _actionWith(runner).applyGpuPolicy(
        const GpuPolicy(minPwrlevel: 4),
        tunables: _gpuTunables(),
      );

      expect(result.applied, isTrue);
      expect(runner.commands, isNotEmpty);
      for (final command in runner.commands) {
        expect(command, startsWith('timeout '));
        expect(command, contains('sh -c'));
      }
    });
  });
}
