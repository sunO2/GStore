import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/control_cpu.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/control_thermal.dart';
import 'package:gstore/core/perf/perf_control_session.dart';
import 'package:gstore/core/perf/privileged_shell.dart';

// ==================== 假 runner（内存节点，绝不触碰真实 Shizuku / 真机） ====================

/// 解析写节点命令并维护内存节点值。
///
/// * `printf %s <value> > <path>` 且未在 [deniedWrites] → 写成功并更新 [values]；
/// * 在 [deniedWrites] → 返回失败哨兵（`err=1`，不更新值）；
/// * 其它命令 → `err=1`。
class _FakeRunner {
  _FakeRunner({
    Map<String, String>? values,
    Set<String>? deniedWrites,
  })  : values = <String, String>{...?values},
        deniedWrites = deniedWrites ?? <String>{};

  final Map<String, String> values;
  final Set<String> deniedWrites;
  final List<String> commands = <String>[];

  static final RegExp _write = RegExp(r'printf %s (\S+) > (\S+)');

  Future<String?> run(String command) async {
    commands.add(command);
    final match = _write.firstMatch(command);
    if (match == null) return 'GSTORE_RESULT err=1';
    final value = match.group(1)!;
    final path = match.group(2)!;
    if (deniedWrites.contains(path)) return 'GSTORE_RESULT err=1';
    values[path] = value;
    return 'GSTORE_RESULT ok=1';
  }

  /// 实际尝试写过的 (path -> value) 列表（含被拒），用于「零写入 / 未触碰」断言。
  List<MapEntry<String, String>> get attemptedWrites => <MapEntry<String, String>>[
        for (final command in commands)
          if (_write.firstMatch(command) case final match?)
            MapEntry(match.group(2)!, match.group(1)!),
      ];

  bool touched(String path) => commands.any((c) => c.contains(path));
}

// ==================== 节点常量 ====================

const String _governor =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor';
const String _minFreq = '/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq';
const String _pwrlevel = '/sys/class/kgsl/kgsl-3d0/min_pwrlevel';
const String _gpuGovernor = '/sys/class/kgsl/kgsl-3d0/governor';
const String _thermalMode = '/sys/class/thermal/thermal_zone0/mode';
const String _cpusetTasks = '/dev/cpuset/foreground/tasks';

// ==================== 会话构造 ====================

PerfControlSession _session(
  _FakeRunner runner, {
  PerfControlSessionStore? store,
  Duration? timeout,
}) =>
    PerfControlSession(
      shell: PrivilegedShell(
        runner: runner.run,
        timeout: const Duration(seconds: 1),
      ),
      store: store,
      sessionTimeout: timeout,
    );

// ==================== 动作结果 fixture ====================

CpuPolicyResult _cpuApplied(List<CpuPolicyChange> changes) => CpuPolicyResult(
      ok: true,
      status: CpuPolicyStatus.ok,
      applied: changes,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('revertAll 精确还原（happy）', () {
    test('登记 3 个覆盖项 → revertAll 逐字节写回原值', () async {
      final runner = _FakeRunner(values: <String, String>{
        _governor: 'performance',
        _minFreq: '1800000',
        _thermalMode: 'disabled',
      });
      final session = _session(runner);

      await session.recordAll(<PerfOverride>[
        const PerfOverride(path: _governor, originalValue: 'schedutil', source: 'cpu'),
        const PerfOverride(
            path: _minFreq, originalValue: '300000', numeric: true, source: 'cpu'),
        const PerfOverride(
            path: _thermalMode, originalValue: 'enabled', source: 'thermal'),
      ]);

      expect(session.pendingCount, 3);
      expect(session.hasPendingRevert, isTrue);

      final report = await session.revertAll();

      expect(report.ok, isTrue);
      expect(report.revertedCount, 3);
      expect(report.failedCount, 0);
      expect(report.remaining, isEmpty);
      expect(session.hasPendingRevert, isFalse);
      // 逐字节还原：内存节点值 == 记录的原值。
      expect(runner.values[_governor], 'schedutil');
      expect(runner.values[_minFreq], '300000');
      expect(runner.values[_thermalMode], 'enabled');
      // 失败的写一个都不该有。
      expect(report.failed, isEmpty);
    });

    test('还原写按**逆登记序**发出（后写先还原）', () async {
      final runner = _FakeRunner(values: <String, String>{
        _governor: 'performance',
        _minFreq: '1800000',
        _pwrlevel: '5',
      });
      final session = _session(runner);
      await session.recordAll(const <PerfOverride>[
        PerfOverride(path: _governor, originalValue: 'schedutil'),
        PerfOverride(path: _minFreq, originalValue: '300000', numeric: true),
        PerfOverride(path: _pwrlevel, originalValue: '3', numeric: true),
      ]);

      final report = await session.revertAll();
      expect(report.ok, isTrue);

      final restored = runner.attemptedWrites;
      expect(restored.map((e) => e.key).toList(),
          <String>[_pwrlevel, _minFreq, _governor]);
    });

    test('同一节点重复登记 → 保留最早原值（可还原到会话前）', () async {
      final runner = _FakeRunner(values: <String, String>{_governor: 'ondemand'});
      final session = _session(runner);
      await session.recordAll(const <PerfOverride>[
        PerfOverride(path: _governor, originalValue: 'schedutil'),
      ]);
      await session.recordAll(const <PerfOverride>[
        PerfOverride(path: _governor, originalValue: 'performance'),
      ]);

      expect(session.pendingCount, 1);
      await session.revertAll();
      expect(runner.values[_governor], 'schedutil');
    });
  });

  group('崩溃 / 重启恢复（pending state → revert on init）', () {
    test('有持久化待还原状态 → restorePendingOnInit 还原并清理状态', () async {
      final store = InMemoryPerfControlSessionStore(<PerfOverride>[
        const PerfOverride(path: _governor, originalValue: 'schedutil', source: 'cpu'),
        const PerfOverride(
            path: _thermalMode, originalValue: 'enabled', source: 'thermal'),
      ]);
      final runner = _FakeRunner(values: <String, String>{
        _governor: 'performance',
        _thermalMode: 'disabled',
      });
      final session = _session(runner, store: store);

      final report = await session.restorePendingOnInit();

      expect(report, isNotNull);
      expect(report!.ok, isTrue);
      expect(report.reason, PerfRevertReason.restartRecovery);
      expect(report.revertedCount, 2);
      expect(runner.values[_governor], 'schedutil');
      expect(runner.values[_thermalMode], 'enabled');
      expect(store.pending, isEmpty, reason: '成功还原后必须清理 stale pending state');
    });

    test('无待还原状态 → restorePendingOnInit 返回 null 且零命令', () async {
      final store = InMemoryPerfControlSessionStore();
      final runner = _FakeRunner();
      final session = _session(runner, store: store);

      expect(await session.restorePendingOnInit(), isNull);
      expect(runner.commands, isEmpty);
    });

    test('SharedPreferences 持久化：会话 A 登记 → 会话 B 启动时还原', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const store = SharedPrefsPerfControlSessionStore();
      final runner = _FakeRunner(values: <String, String>{_governor: 'performance'});

      final sessionA = _session(runner, store: store);
      await sessionA.recordAll(const <PerfOverride>[
        PerfOverride(path: _governor, originalValue: 'schedutil'),
      ]);
      // 模拟崩溃：不调用 revertAll，直接新建会话（同一持久化后端）。
      final sessionB = _session(runner, store: store);
      final report = await sessionB.restorePendingOnInit();

      expect(report, isNotNull);
      expect(report!.reason, PerfRevertReason.restartRecovery);
      expect(runner.values[_governor], 'schedutil');
    });
  });

  group('无原值的节点绝不触碰', () {
    test('GPU 结果含 previousValue="" 的节点 → 不登记、不还原', () async {
      final runner = _FakeRunner(values: <String, String>{
        _pwrlevel: '5',
        _gpuGovernor: 'msm-adreno-tz',
      });
      final session = _session(runner);
      final result = GpuPolicyResult.applied(<GpuPolicyWrite>[
        GpuPolicyWrite(path: _gpuGovernor, value: 'simple_ondemand', previousValue: ''),
        GpuPolicyWrite(path: _pwrlevel, value: '1', previousValue: '5'),
      ]);

      await session.recordGpu(result);
      expect(session.pendingCount, 1);
      expect(session.owns(_gpuGovernor), isFalse);

      await session.revertAll();
      expect(runner.touched(_gpuGovernor), isFalse,
          reason: '没有记录原值的节点绝不发还原命令');
      expect(runner.values[_pwrlevel], '5');
    });

    test('CPU 结果含 before=null 的变更 → 不登记、不还原', () async {
      final runner = _FakeRunner(values: <String, String>{_minFreq: '1800000'});
      final session = _session(runner);
      final result = _cpuApplied(<CpuPolicyChange>[
        const CpuPolicyChange(path: _governor, before: null, after: 'schedutil'),
        const CpuPolicyChange(path: _minFreq, before: '300000', after: '1800000'),
      ]);

      await session.recordCpu(result);
      expect(session.pendingCount, 1);
      await session.revertAll();
      expect(runner.touched(_governor), isFalse);
      expect(runner.values[_minFreq], '300000');
    });

    test('空路径 / 空原值 → 登记时被过滤', () async {
      final runner = _FakeRunner();
      final session = _session(runner);
      await session.recordAll(const <PerfOverride>[
        PerfOverride(path: '', originalValue: 'x'),
        PerfOverride(path: _governor, originalValue: ''),
      ]);
      expect(session.pendingCount, 0);
      await session.revertAll();
      expect(runner.commands, isEmpty);
    });
  });

  group('部分写入失败（partial writes）', () {
    test('动作中途失败（applied 为空）→ 登记 0 项，无残留「假覆盖」', () async {
      final runner = _FakeRunner();
      final session = _session(runner);
      // 模拟 todo 16 的 readback_mismatch：ok:false，已回滚，applied 为空。
      const failed = CpuPolicyResult(
        ok: false,
        status: CpuPolicyStatus.readbackMismatch,
        applied: <CpuPolicyChange>[],
        rollback: <CpuPolicyChange>[
          CpuPolicyChange(path: _minFreq, before: '1800000', after: '300000'),
        ],
        rolledBack: true,
      );
      await session.recordCpu(failed);

      expect(session.pendingCount, 0);
      expect(session.hasPendingRevert, isFalse);
      final report = await session.revertAll();
      expect(report.ok, isTrue);
      expect(report.hadPending, isFalse);
      expect(runner.commands, isEmpty);
    });

    test('还原中途失败 → 成功者移出、失败者保留（可重试）', () async {
      final runner = _FakeRunner(
        values: <String, String>{
          _governor: 'performance',
          _minFreq: '1800000',
          _thermalMode: 'disabled',
        },
        deniedWrites: <String>{_minFreq},
      );
      final store = InMemoryPerfControlSessionStore();
      final session = _session(runner, store: store);
      await session.recordAll(const <PerfOverride>[
        PerfOverride(path: _governor, originalValue: 'schedutil'),
        PerfOverride(path: _minFreq, originalValue: '300000', numeric: true),
        PerfOverride(path: _thermalMode, originalValue: 'enabled'),
      ]);

      final report = await session.revertAll();

      expect(report.ok, isFalse);
      expect(report.revertedCount, 2);
      expect(report.failedCount, 1);
      expect(report.remaining.map((o) => o.path), <String>[_minFreq]);
      expect(session.pendingCount, 1);
      // 持久化状态**不**提前清除，保留失败项待重试。
      expect(store.pending.map((o) => o.path), <String>[_minFreq]);

      // 解除拒绝后重试 → 全部还原、状态清空。
      runner.deniedWrites.clear();
      final retry = await session.revertAll();
      expect(retry.ok, isTrue);
      expect(session.pendingCount, 0);
      expect(runner.values[_minFreq], '300000');
      expect(store.pending, isEmpty);
    });

    test('路径不在白名单 / 还原值非法 → 不发命令且保留待重试', () async {
      final runner = _FakeRunner();
      final session = _session(runner);
      await session.recordAll(const <PerfOverride>[
        PerfOverride(path: '/etc/passwd', originalValue: 'x'),
      ]);
      // 白名单外路径在还原时才被拒（登记不做白名单门禁，登记只保证有原值）。
      final report = await session.revertAll();
      expect(report.ok, isFalse);
      expect(report.failedCount, 1);
      expect(runner.commands, isEmpty);
    });
  });

  group('幂等 / 并发合并', () {
    test('连续两次 revertAll → 第二次零命令且 ok', () async {
      final runner = _FakeRunner(values: <String, String>{_governor: 'performance'});
      final session = _session(runner);
      await session.recordAll(const <PerfOverride>[
        PerfOverride(path: _governor, originalValue: 'schedutil'),
      ]);

      final first = await session.revertAll();
      final commandsAfterFirst = runner.commands.length;
      final second = await session.revertAll();

      expect(first.ok, isTrue);
      expect(second.ok, isTrue);
      expect(second.hadPending, isFalse);
      expect(runner.commands.length, commandsAfterFirst);
    });

    test('并发触发被合并为同一次还原', () async {
      final runner = _FakeRunner(values: <String, String>{_governor: 'performance'});
      final session = _session(runner);
      await session.recordAll(const <PerfOverride>[
        PerfOverride(path: _governor, originalValue: 'schedutil'),
      ]);

      final results = await Future.wait(<Future<PerfRevertReport>>[
        session.stop(),
        session.onAppExit(),
        session.onSessionTimeout(),
      ]);
      expect(results.every((r) => r.ok), isTrue);
      expect(runner.commands, hasLength(1));
    });
  });

  group('自动还原触发点', () {
    Future<void> expectTrigger(
      Future<PerfRevertReport> Function(PerfControlSession) trigger,
      String expectedReason,
    ) async {
      final runner = _FakeRunner(values: <String, String>{_governor: 'performance'});
      final session = _session(runner);
      await session.recordAll(const <PerfOverride>[
        PerfOverride(path: _governor, originalValue: 'schedutil'),
      ]);
      final report = await trigger(session);
      expect(report.ok, isTrue, reason: expectedReason);
      expect(report.reason, expectedReason);
      expect(runner.values[_governor], 'schedutil');
    }

    test('显式 stop', () => expectTrigger((s) => s.stop(), PerfRevertReason.explicitStop));
    test('模块禁用', () =>
        expectTrigger((s) => s.onModuleDisabled(), PerfRevertReason.moduleDisabled));
    test('App 退出', () => expectTrigger((s) => s.onAppExit(), PerfRevertReason.appExit));
    test('后台超时', () =>
        expectTrigger((s) => s.onBackgroundTimeout(), PerfRevertReason.backgroundTimeout));
    test('会话超时（显式）', () =>
        expectTrigger((s) => s.onSessionTimeout(), PerfRevertReason.sessionTimeout));

    test('会话超时（计时器自动触发）', () async {
      final runner = _FakeRunner(values: <String, String>{_governor: 'performance'});
      final session = _session(
        runner,
        timeout: const Duration(milliseconds: 20),
      );
      await session.recordAll(const <PerfOverride>[
        PerfOverride(path: _governor, originalValue: 'schedutil'),
      ]);

      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(runner.values[_governor], 'schedutil');
      expect(session.hasPendingRevert, isFalse);
      session.dispose();
    });
  });

  group('适配器（todos 16-19 结果 → PerfOverride）', () {
    test('CPU：governor 非数字、频率数字', () {
      final overrides = PerfOverrideAdapters.fromCpu(_cpuApplied(<CpuPolicyChange>[
        const CpuPolicyChange(path: _governor, before: 'schedutil', after: 'performance'),
        const CpuPolicyChange(path: _minFreq, before: '300000', after: '1800000'),
      ]));
      expect(overrides, hasLength(2));
      expect(overrides[0].numeric, isFalse);
      expect(overrides[0].source, 'cpu');
      expect(overrides[1].numeric, isTrue);
    });

    test('GPU：governor 非数字、pwrlevel 数字', () {
      final overrides = PerfOverrideAdapters.fromGpu(
        GpuPolicyResult.applied(<GpuPolicyWrite>[
          GpuPolicyWrite(path: _gpuGovernor, value: 'simple_ondemand', previousValue: 'msm-adreno-tz'),
          GpuPolicyWrite(path: _pwrlevel, value: '1', previousValue: '5'),
        ]),
      );
      expect(overrides, hasLength(2));
      expect(overrides[0].numeric, isFalse);
      expect(overrides[1].numeric, isTrue);
      expect(overrides[1].source, 'gpu');
    });

    test('thermal：原值记录 → 覆盖项（非数字）', () {
      final overrides = PerfOverrideAdapters.fromThermal(
        const ThermalToggleResult(
          ok: true,
          requestedEnabled: false,
          applied: <ThermalOverrideRecord>[
            ThermalOverrideRecord(
              path: _thermalMode,
              originalValue: 'enabled',
              appliedValue: 'disabled',
            ),
          ],
        ),
      );
      expect(overrides, hasLength(1));
      expect(overrides.single.originalValue, 'enabled');
      expect(overrides.single.numeric, isFalse);
      expect(overrides.single.source, 'thermal');
    });

    test('cpuset：只对已知原 cpuset 的 pid 产出补偿写', () {
      final overrides = PerfOverrideAdapters.fromCpuset(
        const CpusetResult(
          ok: true,
          status: kCpusetStatusApplied,
          message: '',
          cpuset: 'top-app',
          appliedPids: <int>[1234, 5678, 9999],
          originalCpusets: <int, String?>{
            1234: 'foreground',
            5678: null,
            9999: 'top-app',
          },
        ),
      );
      expect(overrides, hasLength(1));
      expect(overrides.single.path, _cpusetTasks);
      expect(overrides.single.originalValue, '1234');
      expect(overrides.single.numeric, isTrue);
      expect(overrides.single.source, 'cpuset');
    });

    test('失败结果一律不产出覆盖项', () {
      expect(
        PerfOverrideAdapters.fromGpu(
          GpuPolicyResult.failed('write_failed', 'boom', writes: <GpuPolicyWrite>[]),
        ),
        isEmpty,
      );
      expect(
        PerfOverrideAdapters.fromThermal(
          const ThermalToggleResult(
            ok: false,
            requestedEnabled: false,
            applied: <ThermalOverrideRecord>[
              ThermalOverrideRecord(
                path: _thermalMode,
                originalValue: 'enabled',
                appliedValue: 'disabled',
              ),
            ],
          ),
        ),
        isEmpty,
      );
    });
  });

  group('持久化模型', () {
    test('PerfOverride JSON 往返', () {
      const override = PerfOverride(
        path: _minFreq,
        originalValue: '300000',
        numeric: true,
        source: 'cpu',
      );
      final restored = PerfOverride.fromJson(override.toJson());
      expect(restored.path, override.path);
      expect(restored.originalValue, override.originalValue);
      expect(restored.numeric, isTrue);
      expect(restored.source, 'cpu');
    });

    test('PerfOverride.fromJson 宽容（缺字段 → 空值默认）', () {
      final restored = PerfOverride.fromJson(<String, dynamic>{});
      expect(restored.path, isEmpty);
      expect(restored.originalValue, isEmpty);
      expect(restored.numeric, isFalse);
      expect(restored.source, 'unknown');
    });

    test('SharedPrefs store：save → load → clear 往返', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const store = SharedPrefsPerfControlSessionStore();
      const override = PerfOverride(
        path: _thermalMode,
        originalValue: 'enabled',
        source: 'thermal',
      );

      await store.savePending(const <PerfOverride>[override]);
      final loaded = await store.loadPending();
      expect(loaded, hasLength(1));
      expect(loaded.single.path, _thermalMode);

      await store.clearPending();
      expect(await store.loadPending(), isEmpty);
    });
  });
}
