import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/tools/perf_control_tools.dart';
import 'package:gstore/core/perf/control_cpu.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

// ==================== 节点常量 ====================

const String _cpuGov = '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor';
const String _gpuGov = '/sys/class/kgsl/kgsl-3d0/devfreq/governor';
const String _thermalMode = '/sys/class/thermal/thermal_zone0/mode';
const String _cpusetTasks = '/dev/cpuset/top-app/tasks';
const String _cpusetCpus = '/dev/cpuset/top-app/cpus';

// ==================== 假 runner（内存节点，无 Shizuku / 真机） ====================

/// 记录命令 + 维护内存节点值的假 [CommandRunner]。
///
/// * `test -w <path>` → 成功哨兵（除非在 [nonWritable]）；
/// * `cat <path>` → 当前值 + 成功哨兵（未知 / 拒绝 → `err=`）；
/// * `printf %s <value> > <path>` → 写成功时更新 [values]；
/// * [throwAll] / [delayAll] → 模拟执行异常 / 挂起（验证有界超时）。
class _FakeRunner {
  _FakeRunner({
    Map<String, String>? values,
    this.deniedReads = const <String>{},
    this.deniedWrites = const <String>{},
    this.nonWritable = const <String>{},
    this.throwAll = false,
    this.delayAll,
  }) : values = <String, String>{...?values};

  final Map<String, String> values;
  final Set<String> deniedReads;
  final Set<String> deniedWrites;
  final Set<String> nonWritable;
  final bool throwAll;
  final Duration? delayAll;
  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);
    if (throwAll) throw StateError('boom');
    if (delayAll != null) await Future<void>.delayed(delayAll!);

    final testW = RegExp(r'test -w (\S+)').firstMatch(command);
    if (testW != null) {
      return nonWritable.contains(testW.group(1))
          ? 'GSTORE_RESULT err=1'
          : 'GSTORE_RESULT ok=1';
    }

    final read = RegExp(r'cat (\S+)').firstMatch(command);
    if (read != null) {
      final path = read.group(1)!;
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
      values[path] = value;
      return 'GSTORE_RESULT ok=1';
    }

    return 'GSTORE_RESULT err=1';
  }
}

// ==================== fixtures ====================

TunablesReport _cpuTunables() => const TunablesReport(
      cpuClusters: <PerfCpuCluster>[
        PerfCpuCluster(
          policy: 'policy0',
          relatedCpus: <int>[0, 1, 2, 3],
          availableGovernors: <String>['schedutil', 'performance'],
          governor: 'schedutil',
          availableFrequenciesMhz: <double>[300, 1800],
          minFreqMhz: 300,
          maxFreqMhz: 1800,
        ),
      ],
    );

TunablesReport _gpuTunables() => const TunablesReport(
      gpu: PerfGpuTunables(
        governorSource: _gpuGov,
        availableFrequenciesMhz: <double>[200, 600],
        powerLevels: 8,
      ),
    );

TunablesReport _thermalTunables() => const TunablesReport(
      thermalZones: <PerfThermalTunable>[
        PerfThermalTunable(zone: 'thermal_zone0', type: 'cpu', mode: 'enabled'),
      ],
    );

TunablesReport _cpusetTunables() => const TunablesReport(
      cpusets: <PerfCpuset>[PerfCpuset(name: 'top-app', cpus: '0-7', mems: '0')],
    );

/// 能力图 fixture：[category] 显式可用，[nodes] 显式可写（fail-closed）。
PerfControlCapabilities _caps({
  Map<String, bool> nodes = const <String, bool>{},
  bool cpu = false,
  bool gpu = false,
  bool cpuset = false,
  bool thermal = false,
}) =>
    PerfControlCapabilities(
      nodeAvailability: nodes,
      binderLevers: const <String, bool>{},
      categoryAvailability: <PerfControlCategory, bool>{
        PerfControlCategory.cpu: cpu,
        PerfControlCategory.gpu: gpu,
        PerfControlCategory.cpuset: cpuset,
        PerfControlCategory.thermal: thermal,
        PerfControlCategory.binderLevers: false,
      },
      nodeCounts: const <PerfControlCategory, int>{},
      timeoutAvailable: true,
      probedAtMs: 0,
    );

/// 构造被测工具模块（依赖全部注入；不触碰 Shizuku / 原生模块）。
AgentToolModule _tool(
  _FakeRunner runner, {
  TunablesReport? tunables,
  PerfControlCapabilities? caps,
  PidResolver? pidResolver,
  PerfSysfsReader? sysfsReader,
  Duration timeout = kPerfControlToolTimeout,
  Duration shellTimeout = const Duration(seconds: 6),
}) =>
    PerfControlTools(
      shell: PrivilegedShell(runner: runner.run, timeout: shellTimeout),
      tunablesLoader: () async => tunables ?? const TunablesReport(),
      capabilitiesLoader: (t) async => caps,
      pidResolver: pidResolver,
      cpuSysfsReader: sysfsReader,
      timeout: timeout,
    ).tools.single;

Map<String, dynamic> _decode(String text) =>
    jsonDecode(text) as Map<String, dynamic>;

Future<Map<String, dynamic>> _call(
  AgentToolModule tool,
  Map<String, dynamic> params,
) async =>
    _decode(await tool.execute(const AgentToolContext(), params));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('元数据（工具模块协议）', () {
    test('toolName=perfControl、moduleName、enabled、描述完整', () {
      final tool = _tool(_FakeRunner());
      expect(tool.toolName, 'perfControl');
      expect(tool.moduleName, 'agent_tool_perfControl');
      expect(tool.enabled, isTrue);
      expect(tool.toolDescription.trim(), isNotEmpty);
    });

    test('action 与 confirm 均为必填参数', () {
      final tool = _tool(_FakeRunner());
      final action = tool.toolParams.firstWhere((p) => p.name == 'action');
      expect(action.required, isTrue);
      final confirm = tool.toolParams.firstWhere((p) => p.name == 'confirm');
      expect(confirm.required, isTrue);
      expect(confirm.type, 'bool');
    });

    test('spec 标记为整体敏感（alwaysSensitive）', () {
      expect(kPerfControlSpec.alwaysSensitive, isTrue);
    });
  });

  group('确认门禁（无 confirm → 拒绝且零写入）', () {
    test('thermal 缺 confirm → confirm_required 且零命令', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      final json = await _call(_tool(runner,
          tunables: _thermalTunables(),
          caps: _caps(thermal: true, nodes: <String, bool>{_thermalMode: true})), <String, dynamic>{
        'action': 'thermal',
        'enabled': false,
      });
      expect(json['ok'], isFalse);
      expect(json['error'], PerfControlError.confirmRequired);
      expect(runner.commands, isEmpty);
    });

    test('confirm="true" 字符串 / 1 / null → 均拒绝且零命令', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      final tool = _tool(runner,
          tunables: _thermalTunables(),
          caps: _caps(thermal: true, nodes: <String, bool>{_thermalMode: true}));
      for (final bad in <Object?>['true', 1, null, false]) {
        final json = await _call(tool, <String, dynamic>{
          'action': 'thermal',
          'enabled': false,
          'confirm': bad,
        });
        expect(json['error'], PerfControlError.confirmRequired);
      }
      expect(runner.commands, isEmpty);
    });

    test('cpu 携带合法载荷但缺 confirm → 门禁先于动作，零命令', () async {
      final runner = _FakeRunner(values: <String, String>{_cpuGov: 'schedutil'});
      final json = await _call(_tool(runner,
          tunables: _cpuTunables(),
          caps: _caps(cpu: true, nodes: <String, bool>{_cpuGov: true})), <String, dynamic>{
        'action': 'cpu',
        'cluster': 'policy0',
        'governor': 'performance',
      });
      expect(json['error'], PerfControlError.confirmRequired);
      expect(runner.commands, isEmpty);
    });
  });

  group('confirm + 能力可用 → 应用（经 todos 16-19）', () {
    test('thermal enabled=false → 写 disabled 并报告 applied', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      final json = await _call(_tool(runner,
          tunables: _thermalTunables(),
          caps: _caps(thermal: true, nodes: <String, bool>{_thermalMode: true})), <String, dynamic>{
        'action': 'thermal',
        'enabled': false,
        'confirm': true,
      });
      expect(json['ok'], isTrue);
      expect(json['available'], isTrue);
      expect((json['applied'] as List).contains(_thermalMode), isTrue);
      expect(
        runner.commands.any((c) => c.contains('printf %s disabled > $_thermalMode')),
        isTrue,
      );
    });

    test('cpu governor 变更 → 写 scaling_governor 并回读确认', () async {
      final runner = _FakeRunner(values: <String, String>{_cpuGov: 'schedutil'});
      final json = await _call(
        _tool(
          runner,
          tunables: _cpuTunables(),
          caps: _caps(cpu: true, nodes: <String, bool>{_cpuGov: true}),
          sysfsReader: (path) async => SysfsReadResult(
            path: path,
            value: runner.values[path],
            exists: runner.values.containsKey(path),
          ),
        ),
        <String, dynamic>{
          'action': 'cpu',
          'cluster': 'policy0',
          'governor': 'performance',
          'confirm': true,
        },
      );
      expect(json['ok'], isTrue);
      expect(
        runner.commands.any((c) => c.contains('printf %s performance > $_cpuGov')),
        isTrue,
      );
    });

    test('gpu governor 变更 → applied 且写入受 kGpuControlAllowlist 约束', () async {
      final runner = _FakeRunner(values: <String, String>{_gpuGov: 'msm-adreno-tz'});
      final json = await _call(
        _tool(runner,
            tunables: _gpuTunables(), caps: _caps(gpu: true)),
        <String, dynamic>{
          'action': 'gpu',
          'governor': 'performance',
          'confirm': true,
        },
      );
      expect(json['ok'], isTrue);
      expect(json['status'], 'applied');
      expect(
        runner.commands.any((c) => c.contains('printf %s performance > $_gpuGov')),
        isTrue,
      );
    });

    test('cpuset 归属 → applied_pids 含解析到的 pid', () async {
      final runner = _FakeRunner(values: <String, String>{
        _cpusetTasks: '',
        _cpusetCpus: '',
      });
      final json = await _call(
        _tool(
          runner,
          tunables: _cpusetTunables(),
          caps: _caps(cpuset: true),
          pidResolver: (pkg) async => <int>[1234],
        ),
        <String, dynamic>{
          'action': 'cpuset',
          'package': 'com.demo.app',
          'cpuset': 'top-app',
          'confirm': true,
        },
      );
      expect(json['ok'], isTrue);
      expect(json['applied_pids'], <dynamic>[1234]);
      expect(
        runner.commands.any((c) => c.contains('printf %s 1234 > $_cpusetTasks')),
        isTrue,
      );
    });
  });

  group('能力门禁（fail-closed，零写入）', () {
    test('类别不可用 → unavailable 且零命令', () async {
      final runner = _FakeRunner(values: <String, String>{_cpuGov: 'schedutil'});
      final json = await _call(_tool(runner,
          tunables: _cpuTunables(), caps: _caps(cpu: false)), <String, dynamic>{
        'action': 'cpu',
        'cluster': 'policy0',
        'governor': 'performance',
        'confirm': true,
      });
      expect(json['ok'], isFalse);
      expect(json['error'], PerfControlError.unavailable);
      expect(json['available'], isFalse);
      expect(runner.commands, isEmpty);
    });

    test('能力探测返回 null（未探测）→ unavailable 且零命令', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      final json = await _call(
        _tool(runner, tunables: _thermalTunables(), caps: null),
        <String, dynamic>{
          'action': 'thermal',
          'enabled': false,
          'confirm': true,
        },
      );
      expect(json['error'], PerfControlError.unavailable);
      expect(runner.commands, isEmpty);
    });
  });

  group('对抗类载荷（结构化错误 + 零命令）', () {
    test('未知 action → invalid_action 且零命令', () async {
      final runner = _FakeRunner();
      final json = await _call(_tool(runner), <String, dynamic>{
        'action': 'reboot',
        'confirm': true,
      });
      expect(json['error'], PerfControlError.invalidAction);
      expect(runner.commands, isEmpty);
    });

    test('cpu 缺 cluster → invalid_arg 且零命令', () async {
      final runner = _FakeRunner();
      final json = await _call(
        _tool(runner, tunables: _cpuTunables(), caps: _caps(cpu: true)),
        <String, dynamic>{
          'action': 'cpu',
          'governor': 'performance',
          'confirm': true,
        },
      );
      expect(json['error'], PerfControlError.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('cpu governor 不在可用集合 → invalid_arg 且零命令', () async {
      final runner = _FakeRunner(values: <String, String>{_cpuGov: 'schedutil'});
      final json = await _call(
        _tool(
          runner,
          tunables: _cpuTunables(),
          caps: _caps(cpu: true, nodes: <String, bool>{_cpuGov: true}),
          sysfsReader: (path) async => SysfsReadResult(
            path: path,
            value: runner.values[path],
            exists: runner.values.containsKey(path),
          ),
        ),
        <String, dynamic>{
          'action': 'cpu',
          'cluster': 'policy0',
          'governor': 'ondemand',
          'confirm': true,
        },
      );
      expect(json['error'], PerfControlError.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('prompt-injection：governor 携带命令注入 → invalid_arg 且命令体不含载荷', () async {
      final runner = _FakeRunner(values: <String, String>{_cpuGov: 'schedutil'});
      final json = await _call(
        _tool(
          runner,
          tunables: _cpuTunables(),
          caps: _caps(cpu: true, nodes: <String, bool>{_cpuGov: true}),
          sysfsReader: (path) async => SysfsReadResult(
            path: path,
            value: runner.values[path],
            exists: runner.values.containsKey(path),
          ),
        ),
        <String, dynamic>{
          'action': 'cpu',
          'cluster': 'policy0',
          'governor': 'performance; rm -rf /',
          'confirm': true,
        },
      );
      expect(json['error'], PerfControlError.invalidArg);
      expect(runner.commands, isEmpty);
      expect(runner.commands.any((c) => c.contains('rm -rf')), isFalse);
    });

    test('prompt-injection：cpuset 名携带注入 → invalid_arg 且零命令', () async {
      final runner = _FakeRunner();
      final json = await _call(
        _tool(runner, tunables: _cpusetTunables(), caps: _caps(cpuset: true),
            pidResolver: (pkg) async => <int>[1234]),
        <String, dynamic>{
          'action': 'cpuset',
          'package': 'com.demo.app',
          'cpuset': 'top-app; echo pwned',
          'confirm': true,
        },
      );
      expect(json['error'], PerfControlError.invalidArg);
      expect(runner.commands, isEmpty);
      expect(runner.commands.any((c) => c.contains('pwned')), isFalse);
    });

    test('thermal malformed bool（字符串）→ invalid_arg 且零命令', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      final json = await _call(
        _tool(runner,
            tunables: _thermalTunables(),
            caps: _caps(
                thermal: true, nodes: <String, bool>{_thermalMode: true})),
        <String, dynamic>{
          'action': 'thermal',
          'enabled': 'yes',
          'confirm': true,
        },
      );
      expect(json['error'], PerfControlError.invalidArg);
      expect(runner.commands.any((c) => c.contains('> $_thermalMode')), isFalse);
    });
  });

  group('读 / 写失败路径（结构化失败，不留部分状态）', () {
    test('thermal 写被拒 → write_failed 且回滚原值', () async {
      final runner = _FakeRunner(
        values: <String, String>{_thermalMode: 'enabled'},
        deniedWrites: <String>{_thermalMode},
      );
      final json = await _call(
        _tool(runner,
            tunables: _thermalTunables(),
            caps: _caps(
                thermal: true, nodes: <String, bool>{_thermalMode: true})),
        <String, dynamic>{
          'action': 'thermal',
          'enabled': false,
          'confirm': true,
        },
      );
      expect(json['ok'], isFalse);
      expect(json['error'], 'write_failed');
      // 回滚尝试：把原值 enabled 写回该节点。
      expect(
        runner.commands.any((c) => c.contains('printf %s enabled > $_thermalMode')),
        isTrue,
      );
    });

    test('thermal 读原值失败 → read_failed 且零写入', () async {
      final runner = _FakeRunner(
        values: <String, String>{_thermalMode: 'enabled'},
        deniedReads: <String>{_thermalMode},
      );
      final json = await _call(
        _tool(runner,
            tunables: _thermalTunables(),
            caps: _caps(
                thermal: true, nodes: <String, bool>{_thermalMode: true})),
        <String, dynamic>{
          'action': 'thermal',
          'enabled': false,
          'confirm': true,
        },
      );
      expect(json['ok'], isFalse);
      expect(json['error'], 'read_failed');
      expect(runner.commands.any((c) => c.contains('> $_thermalMode')), isFalse);
    });

    test('gpu 控制节点不可写 → unavailable 且零写入', () async {
      final runner = _FakeRunner(
        values: <String, String>{_gpuGov: 'msm-adreno-tz'},
        nonWritable: <String>{_gpuGov},
      );
      final json = await _call(
        _tool(runner, tunables: _gpuTunables(), caps: _caps(gpu: true)),
        <String, dynamic>{
          'action': 'gpu',
          'governor': 'performance',
          'confirm': true,
        },
      );
      expect(json['ok'], isFalse);
      expect(json['error'], PerfControlError.unavailable);
      expect(runner.commands.any((c) => c.contains('> $_gpuGov')), isFalse);
    });
  });

  group('绝不抛出（超时 / 异常降级为结构化 JSON）', () {
    test('runner 抛异常 → ok:false 结构化结果（不抛出）', () async {
      final runner = _FakeRunner(throwAll: true);
      final json = await _call(
        _tool(runner,
            tunables: _thermalTunables(),
            caps: _caps(
                thermal: true, nodes: <String, bool>{_thermalMode: true})),
        <String, dynamic>{
          'action': 'thermal',
          'enabled': false,
          'confirm': true,
        },
      );
      expect(json['ok'], isFalse);
      expect(json['error'], isNotNull);
    });

    test('tunables 加载抛异常 → unavailable（不抛出）', () async {
      final runner = _FakeRunner();
      final tool = PerfControlTools(
        shell: PrivilegedShell(runner: runner.run),
        tunablesLoader: () async => throw StateError('no module'),
        capabilitiesLoader: (t) async => _caps(cpu: true),
      ).tools.single;
      final json = await _call(tool, <String, dynamic>{
        'action': 'cpu',
        'cluster': 'policy0',
        'governor': 'performance',
        'confirm': true,
      });
      expect(json['error'], PerfControlError.unavailable);
      expect(runner.commands, isEmpty);
    });

    test('读取挂起 → 超时有界（error=timeout）', () async {
      final runner = _FakeRunner(
        values: <String, String>{_thermalMode: 'enabled'},
        delayAll: const Duration(milliseconds: 300),
      );
      final json = await _call(
        _tool(
          runner,
          tunables: _thermalTunables(),
          caps: _caps(
              thermal: true, nodes: <String, bool>{_thermalMode: true}),
          timeout: const Duration(milliseconds: 30),
        ),
        <String, dynamic>{
          'action': 'thermal',
          'enabled': false,
          'confirm': true,
        },
      );
      expect(json['ok'], isFalse);
      expect(json['error'], PerfControlError.timeout);
    });

    test('所有已发出的特权命令均自限时（timeout 前缀）', () async {
      final runner = _FakeRunner(values: <String, String>{_thermalMode: 'enabled'});
      await _call(
        _tool(runner,
            tunables: _thermalTunables(),
            caps: _caps(thermal: true, nodes: <String, bool>{_thermalMode: true})),
        <String, dynamic>{
          'action': 'thermal',
          'enabled': false,
          'confirm': true,
        },
      );
      expect(runner.commands, isNotEmpty);
      for (final command in runner.commands) {
        expect(command.startsWith('timeout '), isTrue,
            reason: '每条特权命令都必须自我限时: $command');
        expect(command.contains('; echo'), isFalse,
            reason: '哨兵必须以 &&/|| 链，绝不用 ; echo');
      }
    });
  });

  group('context.cancelled → 直接返回「已取消」', () {
    test('stopRequested 为真时不执行任何动作', () async {
      final runner = _FakeRunner();
      final tool = _tool(runner);
      final result = await tool.execute(
        AgentToolContext(stopRequested: () => true),
        <String, dynamic>{'action': 'cpu', 'confirm': true},
      );
      expect(result, '已取消');
      expect(runner.commands, isEmpty);
    });
  });
}
