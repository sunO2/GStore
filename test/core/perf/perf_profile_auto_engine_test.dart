// fake_async 是 flutter_test 的传递依赖（未直接列入 pubspec，故忽略该 lint）。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/control_cpu.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/control_thermal.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/perf_control_session.dart';
import 'package:gstore/core/perf/perf_profile.dart';
import 'package:gstore/core/perf/perf_profile_auto_engine.dart';
import 'package:gstore/core/perf/perf_profile_store.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

// ---- 节点路径 ----
const String _gov0 =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor';
const String _min0 =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq';
const String _max0 =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq';
const String _gov4 =
    '/sys/devices/system/cpu/cpufreq/policy4/scaling_governor';
const String _min4 =
    '/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq';
const String _max4 =
    '/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq';
const String _gpuPwr = '/sys/class/kgsl/kgsl-3d0/max_pwrlevel';
const String _thermal = '/sys/class/thermal/thermal_zone0/mode';
const String _cpusetBgTasks = '/dev/cpuset/background/tasks';
const String _cpusetBgCpus = '/dev/cpuset/background/cpus';
const String _cpusetTopTasks = '/dev/cpuset/top-app/tasks';

/// 记录命令并模拟**节点状态机**的假 runner（不触碰 Shizuku / 真机）。
class _FakeRunner {
  _FakeRunner({
    Map<String, String>? current,
    this.denyWrite = const <String>{},
    this.lieWrite = const <String>{},
  }) : current = <String, String>{...?current};

  final Map<String, String> current;
  final Set<String> denyWrite;
  final Set<String> lieWrite;
  final List<String> commands = <String>[];

  /// 下一次写命令前先等待该 gate（模拟「写入挂起 / 切换发生在写入途中」）。
  Completer<void>? _writeGate;

  void gateNextWrite(Completer<void> gate) => _writeGate = gate;

  Iterable<String> get writeCommands =>
      commands.where((c) => c.contains('printf %s'));

  Future<String?> run(String command) async {
    commands.add(command);

    // test -w
    final test = RegExp(r'test -w (\S+)').firstMatch(command);
    if (test != null) {
      final path = test.group(1)!;
      if (!current.containsKey(path)) return 'GSTORE_RESULT err=1';
      return 'GSTORE_RESULT ok=1';
    }

    // pidof
    final pidof = RegExp(r'pidof (\S+)').firstMatch(command);
    if (pidof != null) {
      return 'GSTORE_RESULT err=1';
    }

    // write
    final write = RegExp(r'printf %s (\S+) > (\S+)').firstMatch(command);
    if (write != null) {
      final gate = _writeGate;
      if (gate != null) {
        _writeGate = null;
        await gate.future;
      }
      final value = write.group(1)!;
      final path = write.group(2)!;
      if (denyWrite.contains(path)) {
        return '$path: Permission denied\nGSTORE_RESULT err=1';
      }
      if (!lieWrite.contains(path)) {
        if (path.endsWith('/tasks')) {
          final existing = (current[path] ?? '')
              .split(RegExp(r'\s+'))
              .where((t) => t.isNotEmpty && t != value)
              .toList();
          existing.add(value);
          current[path] = existing.join('\n');
        } else {
          current[path] = value;
        }
      }
      return 'GSTORE_RESULT ok=1';
    }

    // read
    final read = RegExp(r'cat (\S+)').firstMatch(command);
    if (read != null) {
      final path = read.group(1)!;
      final value = current[path];
      if (value == null) return '$path: No such file\nGSTORE_RESULT err=1';
      return '$value\nGSTORE_RESULT ok=1';
    }

    return 'GSTORE_RESULT ok=1';
  }
}

/// policy0（300/1800/2400 MHz）+ policy4（300/1800 MHz）+ GPU/cpuset/thermal。
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
    PerfCpuCluster(
      policy: 'policy4',
      relatedCpus: <int>[4, 5, 6, 7],
      availableGovernors: <String>['schedutil', 'performance'],
      governor: 'schedutil',
      availableFrequenciesMhz: <double>[300, 1800],
      minFreqMhz: 300,
      maxFreqMhz: 1800,
    ),
  ],
  cpusets: <PerfCpuset>[
    PerfCpuset(name: 'background', cpus: '0-7', mems: '0'),
  ],
  thermalZones: <PerfThermalTunable>[
    PerfThermalTunable(zone: 'thermal_zone0', type: 'cpu', mode: 'disabled'),
  ],
  gpu: PerfGpuTunables(
    availableFrequenciesMhz: <double>[],
    freqSource: '/sys/class/kgsl/kgsl-3d0/gpuclk',
    powerLevels: 6,
  ),
);

/// 初始节点值（写前状态）。
Map<String, String> _initialNodes() => <String, String>{
      _gov0: 'schedutil',
      _min0: '300000',
      _max0: '2400000',
      _gov4: 'schedutil',
      _min4: '300000',
      _max4: '1800000',
      _gpuPwr: '4',
      _thermal: 'disabled',
      _cpusetBgTasks: '',
      _cpusetBgCpus: '0-7',
      _cpusetTopTasks: '1234',
    };

/// 能力快照：默认四类皆可用、所有目标节点可写。
PerfControlCapabilities _caps({
  bool cpu = true,
  bool thermal = true,
  Map<String, bool>? nodes,
}) {
  final nodeMap = nodes ??
      <String, bool>{
        _gov0: true,
        _min0: true,
        _max0: true,
        _gov4: true,
        _min4: true,
        _max4: true,
        _gpuPwr: true,
        _thermal: true,
      };
  final counts = <PerfControlCategory, int>{
    for (final category in PerfControlCategory.values) category: 0,
  };
  counts[PerfControlCategory.cpu] =
      nodeMap.entries.where((e) => e.value && e.key.contains('/cpu/')).length;
  return PerfControlCapabilities(
    nodeAvailability: nodeMap,
    binderLevers: const <String, bool>{},
    categoryAvailability: <PerfControlCategory, bool>{
      PerfControlCategory.cpu: cpu,
      PerfControlCategory.gpu: true,
      PerfControlCategory.cpuset: true,
      PerfControlCategory.thermal: thermal,
      PerfControlCategory.binderLevers: false,
    },
    nodeCounts: counts,
    timeoutAvailable: true,
    probedAtMs: 0,
  );
}

// ---- 档案 fixture ----

PerfProfile _profileA({bool enabled = true}) => PerfProfile(
      package: 'com.a',
      enabled: enabled,
      cpuClusters: <String, PerfCpuClusterProfile>{
        'policy0': const PerfCpuClusterProfile(
          governor: 'performance',
          minFreqMhz: 1800,
          maxFreqMhz: 2400,
        ),
      },
    );

PerfProfile _profileB() => const PerfProfile(
      package: 'com.b',
      enabled: true,
      cpuClusters: <String, PerfCpuClusterProfile>{
        'policy0': PerfCpuClusterProfile(
          governor: 'powersave',
          minFreqMhz: 300,
          maxFreqMhz: 1800,
        ),
      },
    );

/// 覆盖四类动作的档案（CPU + GPU + cpuset + thermal）。
PerfProfile _profileAll() => const PerfProfile(
      package: 'com.all',
      enabled: true,
      cpuClusters: <String, PerfCpuClusterProfile>{
        'policy0': PerfCpuClusterProfile(
          governor: 'performance',
          minFreqMhz: 1800,
          maxFreqMhz: 2400,
        ),
      },
      gpuLevel: 2,
      cpuset: 'background',
      thermalEnabled: true,
    );

/// 两个簇的档案：policy0 成功、policy4 中途失败 → 引擎需回滚 policy0。
PerfProfile _profileTwoClusters() => const PerfProfile(
      package: 'com.two',
      enabled: true,
      cpuClusters: <String, PerfCpuClusterProfile>{
        'policy0': PerfCpuClusterProfile(governor: 'performance'),
        'policy4': PerfCpuClusterProfile(governor: 'performance'),
      },
    );

/// 测试装配：全部依赖注入，零 Shizuku / 真机 / 平台通道。
class _Harness {
  _Harness({
    Map<String, String>? nodes,
    Map<String, PerfProfile>? profiles,
    this.capabilities,
    this.globalEnabled = true,
    Duration debounce = Duration.zero,
    List<int>? cpusetPids,
    Set<String> denyWrite = const <String>{},
    Set<String> lieWrite = const <String>{},
  })  : runner = _FakeRunner(
          current: nodes ?? _initialNodes(),
          denyWrite: denyWrite,
          lieWrite: lieWrite,
        ),
        store = InMemoryPerfProfileStore(profiles) {
    final shell = PrivilegedShell(
      runner: runner.run,
      timeout: const Duration(seconds: 30),
    );
    sessionStore = InMemoryPerfControlSessionStore();
    session = PerfControlSession(shell: shell, store: sessionStore);
    engine = PerfProfileAutoEngine(
      store: store,
      session: session,
      cpuControl: CpuControl(
        shell: shell,
        tunables: _tunables,
        capabilities: capabilities,
        sysfsReader: (path) async {
          final value = runner.current[path];
          return SysfsReadResult(
            path: path,
            value: value,
            exists: value != null,
          );
        },
      ),
      gpuControl: GpuControlAction(
        shell: shell,
        tunablesLoader: () async => _tunables,
        reader: (path) async => runner.current[path],
      ),
      cpusetControl: CpusetController(
        shell: shell,
        pidResolver: (pkg) async => cpusetPids ?? const <int>[],
        cpusetNames: const <String>['top-app', 'background'],
      ),
      thermalControl: ThermalToggleController(shell: shell),
      tunables: _tunables,
      capabilities: () => capabilities,
      isGloballyEnabled: () => globalEnabled,
      debounce: debounce,
    );
  }

  final _FakeRunner runner;
  final InMemoryPerfProfileStore store;
  PerfControlCapabilities? capabilities;
  bool globalEnabled;

  late final InMemoryPerfControlSessionStore sessionStore;
  late final PerfControlSession session;
  late final PerfProfileAutoEngine engine;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('进入前台 → 应用档案', () {
    test('enabled 档案 → 所有覆盖项经会话登记', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: _caps(),
      );

      final report = await h.engine.onForegroundPackage('com.a');

      expect(report.outcome, PerfAutoApplyOutcome.applied);
      expect(report.appliedOverrides, 3);
      expect(h.engine.appliedPackage, 'com.a');
      expect(h.runner.current[_gov0], 'performance');
      expect(h.runner.current[_min0], '1800000');
      expect(h.runner.current[_max0], '2400000');
      // 会话登记了 3 个覆盖项（供还原）。
      expect(h.session.pendingCount, 3);
      expect(h.session.owns(_gov0), isTrue);
      // 命令自限时（与传输层契约一致）。
      for (final command in h.runner.commands) {
        expect(command.startsWith('timeout '), isTrue);
      }
    });

    test('四类动作全部映射：CPU + GPU + cpuset + thermal', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.all': _profileAll()},
        capabilities: _caps(),
        cpusetPids: <int>[1234],
      );

      final report = await h.engine.onForegroundPackage('com.all');

      expect(report.outcome, PerfAutoApplyOutcome.applied);
      expect(report.appliedOverrides, 6); // cpu 3 + gpu 1 + cpuset 1 + thermal 1
      expect(h.runner.current[_gov0], 'performance');
      expect(h.runner.current[_gpuPwr], '2');
      expect(h.runner.current[_thermal], 'enabled');
      expect(h.runner.current[_cpusetBgTasks], contains('1234'));
      expect(h.session.pendingCount, 6);
    });
  });

  group('离开前台 / 禁用 → 还原', () {
    test('package=null → 精确写回原值', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: _caps(),
      );
      await h.engine.onForegroundPackage('com.a');

      final report = await h.engine.onForegroundPackage(null);

      expect(report.outcome, PerfAutoApplyOutcome.reverted);
      expect(report.revertedOverrides, 3);
      expect(h.engine.appliedPackage, isNull);
      // 节点逐字节恢复。
      expect(h.runner.current[_gov0], 'schedutil');
      expect(h.runner.current[_min0], '300000');
      expect(h.runner.current[_max0], '2400000');
      expect(h.session.pendingCount, 0);
      expect(h.sessionStore.pending, isEmpty);
    });

    test('全局开关关闭 → 还原（全局关闭时不应用）', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: _caps(),
      );
      await h.engine.onForegroundPackage('com.a');

      h.globalEnabled = false;
      final report = await h.engine.refresh();

      expect(report.outcome, PerfAutoApplyOutcome.reverted);
      expect(h.runner.current[_gov0], 'schedutil');
      expect(h.engine.appliedPackage, isNull);
    });

    test('档案被禁用 → 还原', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: _caps(),
      );
      await h.engine.onForegroundPackage('com.a');

      await h.store.save(_profileA(enabled: false));
      final report = await h.engine.refresh();

      expect(report.outcome, PerfAutoApplyOutcome.reverted);
      expect(h.runner.current[_gov0], 'schedutil');
    });

    test('无待还原时离开 → no-op（零命令）', () async {
      final h = _Harness(capabilities: _caps());
      final before = h.runner.commands.length;
      final report = await h.engine.onForegroundPackage(null);
      expect(report.outcome, PerfAutoApplyOutcome.noop);
      expect(h.runner.commands.length, before);
    });
  });

  group('快速切换（去抖）', () {
    test('A→B→A 去抖合并 → 最终只应用 A', () {
      fakeAsync((async) {
        final h = _Harness(
          profiles: <String, PerfProfile>{
            'com.a': _profileA(),
            'com.b': _profileB(),
          },
          capabilities: _caps(),
          debounce: const Duration(milliseconds: 300),
        );

        // 三个快速事件（不 await），只在最后一个窗口结束后处理。
        unawaited(h.engine.onForegroundPackage('com.a'));
        unawaited(h.engine.onForegroundPackage('com.b'));
        final last = h.engine.onForegroundPackage('com.a');

        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();

        expect(h.engine.appliedPackage, 'com.a');
        expect(h.runner.current[_gov0], 'performance');
        expect(h.runner.current[_min0], '1800000');
        // B 从未被应用（去抖合并）。
        expect(h.runner.current[_gov0], isNot('powersave'));

        var done = false;
        unawaited(last.then((r) {
          done = true;
          expect(r.outcome, PerfAutoApplyOutcome.applied);
          expect(r.package, 'com.a');
        }));
        async.flushMicrotasks();
        expect(done, isTrue);
      });
    });

    test('串行 A→B 切换 → A 还原、B 应用', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{
          'com.a': _profileA(),
          'com.b': _profileB(),
        },
        capabilities: _caps(),
      );

      await h.engine.onForegroundPackage('com.a');
      final report = await h.engine.onForegroundPackage('com.b');

      expect(report.outcome, PerfAutoApplyOutcome.applied);
      expect(report.package, 'com.b');
      expect(h.engine.appliedPackage, 'com.b');
      expect(h.runner.current[_gov0], 'powersave');
      expect(h.runner.current[_min0], '300000');
      expect(h.runner.current[_max0], '1800000');
      // 会话只保留 B 的覆盖项（A 已还原）。
      expect(h.session.pendingCount, 3);
    });
  });

  group('部分失败 → 回滚（绝不半应用）', () {
    test('第二个簇失败 → 引擎回滚第一个簇，ok:false', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.two': _profileTwoClusters()},
        capabilities: _caps(),
        denyWrite: <String>{_gov4},
      );

      final report = await h.engine.onForegroundPackage('com.two');

      expect(report.outcome, PerfAutoApplyOutcome.failed);
      expect(report.reason, PerfAutoApplyReason.partialFailure);
      expect(report.failedStage, 'cpu');
      expect(report.revertRemaining, 0);
      // policy0 的覆盖项已被引擎回滚（无残留）。
      expect(h.runner.current[_gov0], 'schedutil');
      expect(h.engine.appliedPackage, isNull);
      expect(h.session.pendingCount, 0);
      expect(h.sessionStore.pending, isEmpty);
    });

    test('写成功但回读不符 → 动作内部回滚，引擎返回失败', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: _caps(),
        lieWrite: <String>{_min0},
      );

      final report = await h.engine.onForegroundPackage('com.a');

      expect(report.outcome, PerfAutoApplyOutcome.failed);
      expect(report.failedStage, 'cpu');
      // 节点 1（governor）已回滚到原值；节点 2（min）未生效。
      expect(h.runner.current[_gov0], 'schedutil');
      expect(h.runner.current[_min0], '300000');
      expect(h.session.pendingCount, 0);
    });
  });

  group('门禁（fail-closed）', () {
    test('能力 unknown → 跳过且零写入', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: null,
      );

      final report = await h.engine.onForegroundPackage('com.a');

      expect(report.outcome, PerfAutoApplyOutcome.skipped);
      expect(report.reason, PerfAutoApplyReason.capabilityUnknown);
      expect(h.runner.commands, isEmpty);
      expect(h.session.pendingCount, 0);
      expect(h.runner.current[_gov0], 'schedutil');
    });

    test('全局开关关闭 → 零写入', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: _caps(),
        globalEnabled: false,
      );

      final report = await h.engine.onForegroundPackage('com.a');

      expect(report.outcome, PerfAutoApplyOutcome.noop);
      expect(report.reason, PerfAutoApplyReason.globalDisabled);
      expect(h.runner.commands, isEmpty);
    });

    test('无档案 / 档案未启用 → 零写入', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA(enabled: false)},
        capabilities: _caps(),
      );

      final disabled = await h.engine.onForegroundPackage('com.a');
      expect(disabled.reason, PerfAutoApplyReason.profileDisabled);

      final missing = await h.engine.onForegroundPackage('com.zzz');
      expect(missing.reason, PerfAutoApplyReason.profileMissing);
      expect(h.runner.commands, isEmpty);
    });
  });

  group('对抗类：幂等 / 陈旧态 / 中断', () {
    test('重复进入同一档案 → 第二次 no-op（零新命令）', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: _caps(),
      );

      await h.engine.onForegroundPackage('com.a');
      final commandsAfterFirst = h.runner.commands.length;

      final second = await h.engine.onForegroundPackage('com.a');

      expect(second.outcome, PerfAutoApplyOutcome.noop);
      expect(second.reason, PerfAutoApplyReason.unchanged);
      expect(h.runner.commands.length, commandsAfterFirst);
      expect(h.session.pendingCount, 3);
    });

    test('仅 mode 变化 → 不被视为 unchanged（重新应用）', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: _caps(),
      );

      final first = await h.engine.onForegroundPackage('com.a');
      expect(first.outcome, PerfAutoApplyOutcome.applied);
      expect(h.engine.appliedProfile!.mode, PerfMode.balance);

      // 旋钮完全一致，仅把 mode 改成 fast → 依赖 PerfProfile.mode 的相等性。
      await h.store.save(_profileA().copyWith(mode: PerfMode.fast));
      final second = await h.engine.refresh();

      expect(second.outcome, PerfAutoApplyOutcome.applied);
      expect(second.reason, PerfAutoApplyReason.applied);
      expect(h.engine.appliedProfile!.mode, PerfMode.fast);
    });

    test('并发重复进入 → 串行且不重复应用', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: _caps(),
      );

      final reports = await Future.wait(<Future<PerfAutoApplyReport>>[
        h.engine.onForegroundPackage('com.a'),
        h.engine.onForegroundPackage('com.a'),
        h.engine.onForegroundPackage('com.a'),
      ]);

      expect(reports.first.outcome, PerfAutoApplyOutcome.applied);
      expect(
        reports.skip(1).every(
              (r) => r.outcome == PerfAutoApplyOutcome.noop,
            ),
        isTrue,
      );
      // 只登记一次（3 项），未翻倍。
      expect(h.session.pendingCount, 3);
    });

    test('陈旧态：应用后档案被删除 → refresh 还原', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: _caps(),
      );
      await h.engine.onForegroundPackage('com.a');

      await h.store.remove('com.a');
      final report = await h.engine.refresh();

      expect(report.outcome, PerfAutoApplyOutcome.reverted);
      expect(report.reason, PerfAutoApplyReason.profileMissing);
      expect(h.runner.current[_gov0], 'schedutil');
      expect(h.engine.appliedPackage, isNull);
    });

    test('切换发生在应用途中 → 最终收敛到最新前台包', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{
          'com.a': _profileA(),
          'com.b': _profileB(),
        },
        capabilities: _caps(),
      );

      final gate = Completer<void>();
      h.runner.gateNextWrite(gate);

      final futureA = h.engine.onForegroundPackage('com.a');
      // 让 A 的第一次写卡在 gate 上。
      await Future<void>.delayed(Duration.zero);
      // 切换请求在 A 应用途中到达。
      final futureB = h.engine.onForegroundPackage('com.b');
      await Future<void>.delayed(Duration.zero);

      gate.complete();
      await futureA;
      final reportB = await futureB;

      expect(reportB.package, 'com.b');
      expect(h.engine.appliedPackage, 'com.b');
      expect(h.runner.current[_gov0], 'powersave');
      expect(h.session.pendingCount, 3);
    });

    test('dispose 后事件为 superseded（不再收敛）', () async {
      final h = _Harness(
        profiles: <String, PerfProfile>{'com.a': _profileA()},
        capabilities: _caps(),
      );
      h.engine.dispose();
      final report = await h.engine.onForegroundPackage('com.a');
      expect(report.outcome, PerfAutoApplyOutcome.superseded);
      expect(h.runner.commands, isEmpty);
    });
  });
}
