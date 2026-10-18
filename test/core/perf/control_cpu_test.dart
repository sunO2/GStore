import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/control_cpu.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

// ---- 节点路径（与 fixture 的 policy0 一致） ----

const String _gov =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor';
const String _min =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq';
const String _max =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq';

/// 记录命令并模拟**节点状态机**的假 runner（**不触碰真实 Shizuku**）。
///
/// * 写命令 `printf %s <v> > <path>`：默认把 [current] 更新为 `<v>` 并返回
///   `GSTORE_RESULT ok=1`；[denyWrite] → `err=1`；[misleading] → 无哨兵的
///   `; ok=1` 假成功串；[hang] → `null`（no_output）；[lieWrite] → 报成功但
///   **不更新** [current]（模拟「写成功但值未生效」）。
/// * 读命令 `cat <path>`：返回 [current] 值 + 哨兵。
class _FakeCpuRunner {
  _FakeCpuRunner({
    Map<String, String>? current,
    this.denyWrite = const <String>{},
    this.misleading = const <String>{},
    this.hang = const <String>{},
    this.lieWrite = const <String>{},
  }) : current = <String, String>{...?current};

  final Map<String, String> current;
  final Set<String> denyWrite;
  final Set<String> misleading;
  final Set<String> hang;
  final Set<String> lieWrite;
  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);

    final write = RegExp(r'printf %s (\S+) > (\S+)').firstMatch(command);
    if (write != null) {
      final value = write.group(1)!;
      final path = write.group(2)!;
      if (hang.contains(path)) return null;
      if (misleading.contains(path)) {
        // 「假成功」：只有 `; ok=1`，没有哨兵行 → 绝不能被当作成功。
        return '$path: write failed; ok=1\n';
      }
      if (denyWrite.contains(path)) {
        return '$path: Permission denied\nGSTORE_RESULT err=1';
      }
      if (!lieWrite.contains(path)) current[path] = value;
      return 'GSTORE_RESULT ok=1';
    }

    final read = RegExp(r'\bcat (\S+)').firstMatch(command);
    if (read != null) {
      final path = read.group(1)!;
      final value = current[path];
      if (value == null) return '$path: No such file\nGSTORE_RESULT err=1';
      return '$value\nGSTORE_RESULT ok=1';
    }

    return 'GSTORE_RESULT err=1';
  }

  Iterable<String> get writeCommands =>
      commands.where((c) => c.contains('printf %s'));

  bool get hasAnyWrite => writeCommands.isNotEmpty;
}

/// 默认 world-readable 的 sysfs reader（从 runner 的 [current] 读取）；
/// [notWorldReadable] 中的节点模拟 App uid 读不到 → 强制特权 shell 回落。
PerfSysfsReader _reader(
  _FakeCpuRunner runner, {
  Set<String> notWorldReadable = const <String>{},
}) =>
    (String path) async {
      if (notWorldReadable.contains(path)) {
        return SysfsReadResult(path: path, exists: false);
      }
      final value = runner.current[path];
      return SysfsReadResult(
        path: path,
        value: value,
        exists: value != null,
      );
    };

/// policy0 fixture：governor `schedutil`，可用频率 300/1800/2400 MHz。
const TunablesReport _tunables = TunablesReport(
  cpuClusters: <PerfCpuCluster>[
    PerfCpuCluster(
      policy: 'policy0',
      relatedCpus: <int>[0, 1, 2, 3],
      availableGovernors: <String>['schedutil', 'performance', 'powersave'],
      governor: 'schedutil',
      availableFrequenciesMhz: <double>[300, 1800, 2400],
      minFreqMhz: 300,
      maxFreqMhz: 2400,
    ),
  ],
);

/// 初始节点值（kHz / governor 串）。
Map<String, String> _initialNodes() => <String, String>{
      _gov: 'schedutil',
      _min: '300000',
      _max: '2400000',
    };

/// 构建能力快照：默认 CPU 类别可用且三个节点可写。
PerfControlCapabilities _caps({
  bool cpuAvailable = true,
  Map<String, bool>? nodes,
}) {
  final nodeMap = nodes ??
      <String, bool>{_gov: true, _min: true, _max: true};
  final counts = <PerfControlCategory, int>{
    for (final category in PerfControlCategory.values) category: 0,
  };
  counts[PerfControlCategory.cpu] = nodeMap.values.where((v) => v).length;
  return PerfControlCapabilities(
    nodeAvailability: nodeMap,
    binderLevers: const <String, bool>{},
    categoryAvailability: <PerfControlCategory, bool>{
      for (final category in PerfControlCategory.values)
        category: category == PerfControlCategory.cpu ? cpuAvailable : false,
    },
    nodeCounts: counts,
    timeoutAvailable: true,
    probedAtMs: 0,
  );
}

CpuControl _control(
  _FakeCpuRunner runner, {
  PerfControlCapabilities? capabilities,
  PerfSysfsReader? reader,
  Set<String> notWorldReadable = const <String>{},
  TunablesReport tunables = _tunables,
}) =>
    CpuControl(
      shell: PrivilegedShell(runner: runner.run),
      tunables: tunables,
      capabilities: capabilities ?? _caps(),
      sysfsReader: reader ?? _reader(runner, notWorldReadable: notWorldReadable),
    );

void main() {
  group('写前校验（必须在任何命令之前，零写入）', () {
    test('非法 governor → invalid_arg 且零写入', () async {
      final runner = _FakeCpuRunner(current: _initialNodes());
      final result =
          await _control(runner).applyCpuPolicy(cluster: 'policy0', governor: 'bogus');

      expect(result.ok, isFalse);
      expect(result.status, CpuPolicyStatus.invalidArg);
      expect(runner.commands, isEmpty, reason: '校验失败不得发任何命令');
      expect(runner.hasAnyWrite, isFalse);
    });

    test('频率不在 available 列表 → invalid_arg 且零写入', () async {
      final runner = _FakeCpuRunner(current: _initialNodes());
      final result = await _control(runner)
          .applyCpuPolicy(cluster: 'policy0', minFreqMhz: 1234);

      expect(result.status, CpuPolicyStatus.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('min > max → invalid_arg 且零写入', () async {
      final runner = _FakeCpuRunner(current: _initialNodes());
      final result = await _control(runner).applyCpuPolicy(
        cluster: 'policy0',
        minFreqMhz: 2400,
        maxFreqMhz: 300,
      );

      expect(result.status, CpuPolicyStatus.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('无任何变更 → invalid_arg 且零写入', () async {
      final runner = _FakeCpuRunner(current: _initialNodes());
      final result = await _control(runner).applyCpuPolicy(cluster: 'policy0');

      expect(result.status, CpuPolicyStatus.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('未知簇 → not_found 且零写入', () async {
      final runner = _FakeCpuRunner(current: _initialNodes());
      final result =
          await _control(runner).applyCpuPolicy(cluster: 'policy9', governor: 'performance');

      expect(result.status, CpuPolicyStatus.notFound);
      expect(runner.commands, isEmpty);
    });
  });

  group('能力门禁（fail-closed，零写入）', () {
    test('未探测（capabilities=null）→ unavailable 且零写入', () async {
      final runner = _FakeCpuRunner(current: _initialNodes());
      final result = await CpuControl(
        shell: PrivilegedShell(runner: runner.run),
        tunables: _tunables,
        sysfsReader: _reader(runner),
      ).applyCpuPolicy(cluster: 'policy0', governor: 'performance');

      expect(result.status, CpuPolicyStatus.unavailable);
      expect(runner.commands, isEmpty);
    });

    test('CPU 类别不可用 → unavailable 且零写入', () async {
      final runner = _FakeCpuRunner(current: _initialNodes());
      final result = await _control(
        runner,
        capabilities: _caps(cpuAvailable: false),
      ).applyCpuPolicy(cluster: 'policy0', governor: 'performance');

      expect(result.status, CpuPolicyStatus.unavailable);
      expect(runner.commands, isEmpty);
    });

    test('目标节点探测为不可写 → unavailable 且零写入', () async {
      final runner = _FakeCpuRunner(current: _initialNodes());
      final result = await _control(
        runner,
        capabilities: _caps(nodes: <String, bool>{
          _gov: true,
          _min: false,
          _max: true,
        }),
      ).applyCpuPolicy(cluster: 'policy0', governor: 'performance', minFreqMhz: 1800);

      expect(result.status, CpuPolicyStatus.unavailable);
      expect(runner.commands, isEmpty);
    });
  });

  group('happy path：回读确认才成功', () {
    test('合法 governor + min + max 应用且回读匹配 → ok', () async {
      final runner = _FakeCpuRunner(current: _initialNodes());
      final result = await _control(runner).applyCpuPolicy(
        cluster: 'policy0',
        governor: 'performance',
        minFreqMhz: 1800,
        maxFreqMhz: 2400,
      );

      expect(result.ok, isTrue);
      expect(result.status, CpuPolicyStatus.ok);
      expect(result.cluster, 'policy0');
      expect(result.applied, hasLength(3));
      // 节点状态已生效。
      expect(runner.current[_gov], 'performance');
      expect(runner.current[_min], '1800000');
      expect(runner.current[_max], '2400000');
      // 覆盖项记录写前值（todo 20 revert 输入）。
      expect(result.applied.firstWhere((c) => c.path == _gov).before, 'schedutil');
      expect(result.applied.firstWhere((c) => c.path == _min).before, '300000');

      // 每条特权命令都自我限时（hung command 由 timeout 兜底）。
      for (final command in runner.commands) {
        expect(command.startsWith('timeout '), isTrue,
            reason: '每条特权命令都必须自我限时：$command');
      }
      // 只写 cpufreq 白名单节点。
      for (final command in runner.writeCommands) {
        expect(
          RegExp(r'>\s*/sys/devices/system/cpu/cpufreq/policy0/scaling_')
              .hasMatch(command),
          isTrue,
          reason: '写入必须命中白名单节点：$command',
        );
      }
    });

    test('非 world-readable 节点 → 回读经特权 shell 回落并匹配', () async {
      final runner = _FakeCpuRunner(current: _initialNodes());
      final result = await _control(
        runner,
        notWorldReadable: <String>{_gov},
      ).applyCpuPolicy(cluster: 'policy0', governor: 'performance');

      expect(result.ok, isTrue);
      expect(runner.current[_gov], 'performance');
      // 回读必须走 shell（cat），因为 App uid 读不到该节点。
      expect(runner.commands.any((c) => c.contains('cat $_gov')), isTrue);
    });
  });

  group('失败路径：结构化失败 + 回滚（不留部分状态）', () {
    test('第二个写入被拒 → ok:false + 回滚已生效的 governor', () async {
      final runner = _FakeCpuRunner(
        current: _initialNodes(),
        denyWrite: <String>{_min},
      );
      final result = await _control(runner).applyCpuPolicy(
        cluster: 'policy0',
        governor: 'performance',
        minFreqMhz: 1800,
      );

      expect(result.ok, isFalse);
      expect(result.status, CpuPolicyStatus.writeDenied);
      // governor 先写成功，min 被拒 → 回滚 governor。
      expect(result.rollback, hasLength(1));
      expect(result.rollback.single.path, _gov);
      expect(result.rollback.single.after, 'schedutil');
      expect(result.rolledBack, isTrue);
      // 节点状态已复原（无部分状态）。
      expect(runner.current[_gov], 'schedutil');
      expect(runner.current[_min], '300000');
    });

    test('回读不匹配（写成功但未生效）→ ok:false + 回滚', () async {
      final runner = _FakeCpuRunner(
        current: _initialNodes(),
        lieWrite: <String>{_min},
      );
      final result = await _control(runner).applyCpuPolicy(
        cluster: 'policy0',
        governor: 'performance',
        minFreqMhz: 1800,
      );

      expect(result.ok, isFalse);
      expect(result.status, CpuPolicyStatus.readbackMismatch);
      expect(result.message, contains('read-back mismatch'));
      // governor + min 都被回滚（min 写入虽「成功」但值未生效）。
      expect(result.rollback, hasLength(2));
      expect(result.rolledBack, isTrue);
      expect(runner.current[_gov], 'schedutil');
      expect(runner.current[_min], '300000');
    });

    test('假成功输出（无哨兵的 `; ok=1`）绝不算成功 → 回滚', () async {
      final runner = _FakeCpuRunner(
        current: _initialNodes(),
        misleading: <String>{_min},
      );
      final result = await _control(runner).applyCpuPolicy(
        cluster: 'policy0',
        governor: 'performance',
        minFreqMhz: 1800,
      );

      expect(result.ok, isFalse);
      expect(result.status, CpuPolicyStatus.writeDenied);
      expect(result.applied, isEmpty);
      expect(result.rolledBack, isTrue);
      expect(runner.current[_gov], 'schedutil');
    });

    test('挂起命令（runner 返回 null → no_output）→ 结构化失败 + 回滚', () async {
      final runner = _FakeCpuRunner(
        current: _initialNodes(),
        hang: <String>{_min},
      );
      final result = await _control(runner).applyCpuPolicy(
        cluster: 'policy0',
        governor: 'performance',
        minFreqMhz: 1800,
      );

      expect(result.ok, isFalse);
      expect(result.status, CpuPolicyStatus.writeDenied);
      expect(result.rolledBack, isTrue);
      expect(runner.current[_gov], 'schedutil');
    });
  });

  group('结果可序列化（证据 / 报告 / todo 20）', () {
    test('成功结果 describe()/toJson() 含覆盖项', () async {
      final runner = _FakeCpuRunner(current: _initialNodes());
      final result = await _control(runner)
          .applyCpuPolicy(cluster: 'policy0', governor: 'performance');

      final json = result.toJson();
      expect(json['ok'], isTrue);
      expect(json['status'], CpuPolicyStatus.ok);
      expect(json['applied'], hasLength(1));
      expect(result.describe(), contains('status=ok'));
    });
  });
}
