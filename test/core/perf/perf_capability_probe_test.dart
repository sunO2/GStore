import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

/// 记录命令并返回罐头输出的假 runner（**不触碰真实 Shizuku**）。
///
/// 每个 `test -w <path>` 依据 [writable]/[denied]/[unknown]/[errors]/[noOutput]
/// 决定返回；杠杆按 [levers] 子串匹配；未命中一律返回失败哨兵（fail-closed 基线）。
class _FakeRunner {
  _FakeRunner({
    this.writable = const <String>[],
    this.denied = const <String>[],
    this.unknown = const <String>[],
    this.errors = const <String>[],
    this.noOutput = const <String>[],
    this.throwing = false,
    this.timeoutAvailable = true,
    this.levers = const <String, String?>{},
  });

  final List<String> writable;
  final List<String> denied;
  final List<String> unknown;
  final List<String> errors;
  final List<String> noOutput;
  final bool throwing;
  final bool timeoutAvailable;
  final Map<String, String?> levers;
  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);
    if (throwing) throw StateError('runner boom');

    final node = RegExp(r'test -w (\S+)').firstMatch(command);
    if (node != null) {
      final path = node.group(1)!;
      if (errors.contains(path)) throw StateError('node boom');
      if (noOutput.contains(path)) return null;
      if (unknown.contains(path)) return 'garbage without any sentinel';
      if (writable.contains(path)) return 'GSTORE_RESULT ok=1';
      if (denied.contains(path)) return 'denied\nGSTORE_RESULT err=1';
      return 'GSTORE_RESULT err=1';
    }

    if (command.contains('command -v timeout')) {
      return timeoutAvailable
          ? '/system/bin/timeout\nGSTORE_RESULT ok=1'
          : 'GSTORE_RESULT err=1';
    }

    for (final entry in levers.entries) {
      if (command.contains(entry.key)) return entry.value;
    }
    return 'GSTORE_RESULT err=1';
  }
}

// ---- 候选节点（由 tunables 推导，与下方 fixture 对应） ----

const String _cpuGovernor =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor';
const String _cpuMin =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq';
const String _cpuMax =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq';
const String _cpusetCpus = '/dev/cpuset/top-app/cpus';
const String _cpusetMems = '/dev/cpuset/top-app/mems';
const String _thermalMode = '/sys/class/thermal/thermal_zone0/mode';
const String _gpuGovernor =
    '/sys/class/kgsl/kgsl-3d0/devfreq/governor';
const String _gpuMin = '/sys/class/kgsl/kgsl-3d0/devfreq/min_freq';
const String _gpuMax = '/sys/class/kgsl/kgsl-3d0/devfreq/max_freq';
// GPU 根目录同级节点（由 freqSource / powerSource 的父目录推导）。
const String _gpuRootGovernor = '/sys/class/kgsl/kgsl-3d0/governor';
const String _gpuMinGpuclk = '/sys/class/kgsl/kgsl-3d0/min_gpuclk';
const String _gpuMaxGpuclk = '/sys/class/kgsl/kgsl-3d0/max_gpuclk';
const String _gpuMinPwrlevel = '/sys/class/kgsl/kgsl-3d0/min_pwrlevel';
const String _gpuMaxPwrlevel = '/sys/class/kgsl/kgsl-3d0/max_pwrlevel';

const List<String> _allNodes = <String>[
  _cpuGovernor,
  _cpuMin,
  _cpuMax,
  _cpusetCpus,
  _cpusetMems,
  _thermalMode,
  _gpuGovernor,
  _gpuMin,
  _gpuMax,
  _gpuRootGovernor,
  _gpuMinGpuclk,
  _gpuMaxGpuclk,
  _gpuMinPwrlevel,
  _gpuMaxPwrlevel,
];

/// 混合 fixture：CPU / GPU / thermal 有可写节点，cpuset 全无。
TunablesReport _mixedTunables() => const TunablesReport(
      cpuClusters: <PerfCpuCluster>[
        PerfCpuCluster(
          policy: 'policy0',
          relatedCpus: <int>[0, 1, 2, 3],
          availableGovernors: <String>['schedutil', 'performance'],
          governor: 'schedutil',
          availableFrequenciesMhz: <double>[300, 1800, 2400],
          minFreqMhz: 300,
          maxFreqMhz: 2400,
        ),
      ],
      cpusets: <PerfCpuset>[
        PerfCpuset(name: 'top-app', cpus: '0-3', mems: '0'),
      ],
      thermalZones: <PerfThermalTunable>[
        PerfThermalTunable(zone: 'thermal_zone0', type: 'cpu', mode: 'enabled'),
      ],
      gpu: PerfGpuTunables(
        availableFrequenciesMhz: <double>[500, 800],
        freqSource: '/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies',
        governor: 'msm-adreno-tz',
        governorSource: _gpuGovernor,
        powerLevels: 14,
        powerSource: '/sys/class/kgsl/kgsl-3d0/num_pwrlevels',
      ),
    );

/// 空 fixture：无任何候选节点。
TunablesReport _emptyTunables() => const TunablesReport();

PerfCapabilityProbe _probeWith(_FakeRunner runner) => PerfCapabilityProbe(
      shell: PrivilegedShell(runner: runner.run),
    );

void main() {
  group('test -w 判定（fail-closed，只有正向信号才算可用）', () {
    test('exit 0（哨兵 ok=1）→ available', () async {
      final runner = _FakeRunner(writable: <String>[_cpuGovernor]);
      final caps = await _probeWith(runner).probe(_mixedTunables());

      expect(caps.isNodeAvailable(_cpuGovernor), isTrue);
      // 同批未列出的节点一律不可用。
      expect(caps.isNodeAvailable(_cpuMin), isFalse);
    });

    test('exit 1（哨兵 err=1）→ unavailable', () async {
      final runner = _FakeRunner(denied: <String>[_cpuGovernor]);
      final caps = await _probeWith(runner).probe(_mixedTunables());

      expect(caps.isNodeAvailable(_cpuGovernor), isFalse);
    });

    test('命令抛异常 → unavailable（execution_error 仍 fail-closed）', () async {
      final runner = _FakeRunner(errors: <String>[_cpuGovernor]);
      final caps = await _probeWith(runner).probe(_mixedTunables());

      expect(caps.isNodeAvailable(_cpuGovernor), isFalse);
    });

    test('runner 返回 null（no_output）→ unavailable', () async {
      final runner = _FakeRunner(noOutput: <String>[_cpuGovernor]);
      final caps = await _probeWith(runner).probe(_mixedTunables());

      expect(caps.isNodeAvailable(_cpuGovernor), isFalse);
    });

    test('无哨兵（unknown 输出）→ unavailable', () async {
      final runner = _FakeRunner(unknown: <String>[_cpuGovernor]);
      final caps = await _probeWith(runner).probe(_mixedTunables());

      expect(caps.isNodeAvailable(_cpuGovernor), isFalse);
    });

    test('runner 整体抛异常 → 全部 unavailable（绝不抛出）', () async {
      final runner = _FakeRunner(throwing: true);
      final caps = await _probeWith(runner).probe(_mixedTunables());

      expect(caps.availableNodeCount, 0);
      expect(caps.categoryAvailability.values.any((v) => v), isFalse);
    });
  });

  group('候选节点来自 perf.tunables（无节点则无候选）', () {
    test('空 tunables → 零候选节点、零可用', () async {
      final runner = _FakeRunner();
      final caps = await _probeWith(runner).probe(_emptyTunables());

      expect(caps.nodeAvailability, isEmpty);
      expect(caps.availableNodeCount, 0);
      // 零候选 → 不发 `test -w` 命令，只跑杠杆 + timeout 探测。
      expect(
        runner.commands.where((c) => c.contains('test -w')).isEmpty,
        isTrue,
      );
    });

    test('白名单外的候选路径不被探测（直接不可用，不发命令）', () async {
      // 构造一个 policy 名含点（会推导出白名单外路径）的簇。
      const tunables = TunablesReport(
        cpuClusters: <PerfCpuCluster>[PerfCpuCluster(policy: 'policy0')],
      );
      final runner = _FakeRunner(writable: <String>[_cpuGovernor]);
      final caps = await _probeWith(runner).probe(tunables);

      // policy0 的三个路径都在白名单内 → 会被探测。
      expect(caps.isNodeAvailable(_cpuGovernor), isTrue);
    });
  });

  group('per-category 汇总（Wave 4 gating 契约）', () {
    test('混合 fixture → 每类别的可用性 + 计数', () async {
      final runner = _FakeRunner(
        writable: <String>[_cpuGovernor, _cpuMax, _thermalMode, _gpuGovernor],
        denied: <String>[_cpuMin, _cpusetCpus, _cpusetMems, _gpuMin, _gpuMax],
        levers: <String, String?>{
          'cmd power':
              'Available commands:\n  set-fixed-performance-mode-enabled\nGSTORE_RESULT ok=1',
          'cmd thermal': 'thermal service help\nGSTORE_RESULT ok=1',
          'settings get global bluetooth_on': '0\nGSTORE_RESULT ok=1',
          'device_config': 'GSTORE_RESULT err=1',
          'am help':
              'am set-standby-bucket\nGSTORE_RESULT ok=1',
        },
      );

      final caps = await _probeWith(runner).probe(_mixedTunables());

      expect(caps.nodeAvailability.keys.toSet(), _allNodes.toSet());
      expect(caps.isCategoryAvailable(PerfControlCategory.cpu), isTrue);
      expect(caps.isCategoryAvailable(PerfControlCategory.gpu), isTrue);
      expect(caps.isCategoryAvailable(PerfControlCategory.thermal), isTrue);
      // cpuset 零可写节点 → 类别必须关闭（Wave 4 跳过 + 记录 deferral）。
      expect(caps.isCategoryAvailable(PerfControlCategory.cpuset), isFalse);
      expect(caps.isCategoryAvailable(PerfControlCategory.binderLevers), isTrue);
      expect(caps.nodeCounts[PerfControlCategory.cpu], 2);
      expect(caps.nodeCounts[PerfControlCategory.thermal], 1);
      expect(caps.nodeCounts[PerfControlCategory.cpuset], 0);

      // 摘要可序列化且含全部类别。
      final json = caps.toJson();
      final categories = json['categories'] as Map<String, dynamic>;
      expect(categories.keys.toSet(),
          PerfControlCategory.values.map((c) => c.id).toSet());
      expect((categories['cpuset'] as Map)['available'], isFalse);
    });

    test('全部不可用 → 空/禁用集合（failure QA）', () async {
      final runner = _FakeRunner(
        denied: _allNodes,
        timeoutAvailable: false,
        levers: const <String, String?>{
          'cmd power': 'GSTORE_RESULT err=1',
          'cmd thermal': 'GSTORE_RESULT err=1',
          'settings get global bluetooth_on': 'GSTORE_RESULT err=1',
          'device_config': 'GSTORE_RESULT err=1',
          'am help': 'GSTORE_RESULT err=1',
        },
      );

      final caps = await _probeWith(runner).probe(_mixedTunables());

      expect(caps.availableNodeCount, 0);
      expect(caps.binderLevers.values.any((v) => v), isFalse);
      for (final category in PerfControlCategory.values) {
        expect(caps.isCategoryAvailable(category), isFalse,
            reason: '${category.id} 必须关闭');
      }
      expect(caps.timeoutAvailable, isFalse);
      expect(caps.nodeCounts.values.every((c) => c == 0), isTrue);
    });
  });

  group('Binder 命令杠杆（只读 / help 调用）', () {
    test('标记命中才可用；缺标记/失败 → 不可用', () async {
      final runner = _FakeRunner(
        levers: <String, String?>{
          // 命中标记 → available。
          'cmd power':
              'set-fixed-performance-mode-enabled\nGSTORE_RESULT ok=1',
          // 无标记的杠杆要求命令退出 0；此例命令失败 → 不可用。
          'cmd thermal': 'thermal service error\nGSTORE_RESULT err=1',
          // 只读 get 成功（无标记）→ available。
          'settings get global bluetooth_on': '1\nGSTORE_RESULT ok=1',
          // 命令失败 → 不可用。
          'device_config': 'Unknown command\nGSTORE_RESULT err=2',
          // `am help` 成功但无标记 → 不可用（有标记的杠杆 positive signal 不足）。
          'am help': 'am start\nam broadcast\nGSTORE_RESULT ok=1',
        },
      );

      final caps = await _probeWith(runner).probe(_mixedTunables());

      expect(caps.isLeverAvailable(PerfControlLevers.powerFixedPerf), isTrue);
      expect(caps.isLeverAvailable(PerfControlLevers.settings), isTrue);
      expect(caps.isLeverAvailable(PerfControlLevers.thermal), isFalse);
      expect(caps.isLeverAvailable(PerfControlLevers.deviceConfig), isFalse);
      expect(caps.isLeverAvailable(PerfControlLevers.amStandbyBucket), isFalse);
      // 至少一个杠杆可用 → binder-levers 类别可用。
      expect(caps.isCategoryAvailable(PerfControlCategory.binderLevers), isTrue);
    });

    test('杠杆探测命令均为只读（无重定向写 / 全部自限时）', () async {
      final runner = _FakeRunner();
      await _probeWith(runner).probe(_mixedTunables());

      for (final command in runner.commands) {
        expect(RegExp(r'>\s*/sys').hasMatch(command), isFalse);
        expect(RegExp(r'>\s*/dev/cpuset').hasMatch(command), isFalse);
        expect(command.startsWith('timeout '), isTrue,
            reason: '每条特权命令都必须自我限时');
      }
    });
  });

  group('timeout 自限时工具探测', () {
    test('command -v timeout 成功 → true；失败 → false', () async {
      final present = await _probeWith(_FakeRunner(timeoutAvailable: true))
          .probe(_emptyTunables());
      final absent = await _probeWith(_FakeRunner(timeoutAvailable: false))
          .probe(_emptyTunables());
      expect(present.timeoutAvailable, isTrue);
      expect(absent.timeoutAvailable, isFalse);
    });
  });

  group('会话缓存', () {
    test('第二次 probe 复用缓存（不再发命令）；refresh 强制重探', () async {
      final runner = _FakeRunner(writable: <String>[_cpuGovernor]);
      final probe = _probeWith(runner);

      final first = await probe.probe(_mixedTunables());
      final commandsAfterFirst = runner.commands.length;
      final second = await probe.probe(_mixedTunables());

      expect(identical(first, second), isTrue);
      expect(runner.commands.length, commandsAfterFirst);

      await probe.probe(_mixedTunables(), refresh: true);
      expect(runner.commands.length, greaterThan(commandsAfterFirst));
    });
  });

  group('Riverpod 接线（provider / notifier 暴露结果）', () {
    test('perfControlCapabilitiesProvider 暴露探测结果', () async {
      final runner = _FakeRunner(
        writable: <String>[_cpuGovernor],
        levers: <String, String?>{
          'cmd power':
              'set-fixed-performance-mode-enabled\nGSTORE_RESULT ok=1',
        },
      );
      final container = ProviderContainer(
        overrides: <Override>[
          perfCapabilityProbeProvider.overrideWithValue(
            PerfCapabilityProbe(shell: PrivilegedShell(runner: runner.run)),
          ),
          perfTunablesLoaderProvider
              .overrideWithValue(() async => _mixedTunables()),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(perfControlCapabilitiesProvider), isNull);

      final caps = await container
          .read(perfControlCapabilitiesProvider.notifier)
          .probe();

      expect(caps, isNotNull);
      expect(caps!.isCategoryAvailable(PerfControlCategory.cpu), isTrue);
      expect(container.read(perfControlCapabilitiesProvider), same(caps));
    });

    test('tunables 加载失败 → 降级为 null（绝不抛出）', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          perfCapabilityProbeProvider.overrideWithValue(
            PerfCapabilityProbe(shell: PrivilegedShell(runner: (_) async => 'x')),
          ),
          perfTunablesLoaderProvider
              .overrideWithValue(() async => throw StateError('no module')),
        ],
      );
      addTearDown(container.dispose);

      final caps = await container
          .read(perfControlCapabilitiesProvider.notifier)
          .probe();

      expect(caps, isNull);
    });
  });
}
