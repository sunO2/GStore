import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/perf/control_cpu.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/control_refresh_rate.dart';
import 'package:gstore/core/perf/control_thermal.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/page/perf/control_page.dart';
import 'package:gstore/page/perf/perf_control_actions.dart';

// ==================== 假 shell（记录命令 + 可变 settings 值） ====================

/// 模拟 `settings get/put` 与 `dumpsys display` 的可注入 shell runner。
///
/// * [values] = 当前 settings 值（`settings put` 会就地更新，除非 [suppressPutEffect]）；
/// * [commands] = 收到的完整命令行（断言命令序列）；
/// * [failAll] = 模拟 Shizuku 不可用（runner 返回 `null`）；
/// * [suppressPutEffect] = 模拟「写入被接受但未生效」（回读不匹配用例）；
/// * [dumpsysOutput] = `dumpsys display` 罐头输出（`null` → 解析退化）。
class _FakeShell {
  _FakeShell({
    Map<String, String>? initial,
    this.dumpsysOutput,
    this.failAll = false,
    this.suppressPutEffect = false,
  }) : values = <String, String>{
          'min_refresh_rate': '120',
          'peak_refresh_rate': '120',
          ...?initial,
        };

  final Map<String, String> values;
  final List<String> commands = <String>[];
  final String? dumpsysOutput;
  bool failAll;
  bool suppressPutEffect;

  Future<String?> run(String command) async {
    commands.add(command);
    if (failAll) return null;
    if (command.contains('dumpsys display')) {
      final out = dumpsysOutput;
      if (out == null) return null;
      return '$out\nGSTORE_RESULT ok=1';
    }
    if (command.contains('settings put')) {
      final match =
          RegExp(r'settings put system (\w+) (\d+)').firstMatch(command);
      if (match != null && !suppressPutEffect) {
        values[match.group(1)!] = match.group(2)!;
      }
      return 'GSTORE_RESULT ok=1';
    }
    if (command.contains('settings get')) {
      final match = RegExp(r'settings get system (\w+)').firstMatch(command);
      final key = match?.group(1) ?? '';
      return '${values[key] ?? 'null'}\nGSTORE_RESULT ok=1';
    }
    return 'GSTORE_RESULT ok=1';
  }
}

// ==================== 控制动作假实现（不触碰 Shizuku / 真机） ====================

class _FakeActions implements PerfControlActions {
  @override
  Future<CpuPolicyResult> applyCpu({
    required String cluster,
    String? governor,
    double? minFreqMhz,
    double? maxFreqMhz,
  }) async =>
      CpuPolicyResult(ok: true, status: CpuPolicyStatus.ok, cluster: cluster);

  @override
  Future<GpuPolicyResult> applyGpu(GpuPolicy policy) async =>
      GpuPolicyResult.applied(const <GpuPolicyWrite>[]);

  @override
  Future<CpusetResult> applyCpuset({
    required String pkgOrPid,
    required String cpuset,
  }) async =>
      const CpusetResult(ok: true, status: kCpusetStatusApplied, message: 'ok');

  @override
  Future<ThermalToggleResult> setThermal(
    bool enabled, {
    required bool confirmed,
  }) async =>
      ThermalToggleResult(ok: true, requestedEnabled: enabled);
}

TunablesReport _tunables() => const TunablesReport(
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
        PerfThermalTunable(zone: 'thermal_zone0', mode: 'enabled'),
      ],
      gpu: PerfGpuTunables(
        availableFrequenciesMhz: <double>[100, 200],
        powerLevels: 4,
      ),
    );

PerfControlCapabilities _caps() => const PerfControlCapabilities(
      nodeAvailability: <String, bool>{},
      binderLevers: <String, bool>{},
      categoryAvailability: <PerfControlCategory, bool>{
        PerfControlCategory.cpu: true,
        PerfControlCategory.gpu: true,
        PerfControlCategory.cpuset: true,
        PerfControlCategory.thermal: true,
        PerfControlCategory.binderLevers: false,
      },
      nodeCounts: <PerfControlCategory, int>{},
      timeoutAvailable: true,
      probedAtMs: 0,
    );

/// 铺满超大视口（ListView / 组卡片在页面底部，需可命中）。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 20000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _harness({required RefreshRateController refresh}) {
  return ProviderScope(
    overrides: [
      perfControlTunablesLoaderProvider.overrideWithValue(() async => _tunables()),
      perfControlCapabilitiesLoaderProvider
          .overrideWithValue(({bool refresh = false}) async => _caps()),
      perfControlActionsFactoryProvider.overrideWithValue((t, c) => _FakeActions()),
      perfRefreshRateControllerProvider.overrideWithValue(refresh),
    ],
    child: MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const Scaffold(body: PerfControlPage()),
    ),
  );
}

/// 推进若干帧（[AppLoading] 无限动画，不能用 pumpAndSettle）。
Future<void> _settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

String _currentText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('perf_refresh_current'))).data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RefreshRateController · 读取', () {
    test('read：解析 min/peak + dumpsys display 档位', () async {
      final shell = _FakeShell(
        dumpsysOutput: 'mSupportedModes refreshRate=60.0\n'
            'refreshRate=120.00001 fps',
      );
      final controller = RefreshRateController(shell: PrivilegedShell(runner: shell.run));

      final state = await controller.read();

      expect(state.available, isTrue);
      expect(state.min, 120);
      expect(state.peak, 120);
      expect(state.levels, contains(60));
      expect(state.levels, contains(120));
      expect(shell.commands.any((c) => c.contains('settings get system min_refresh_rate')), isTrue);
      expect(shell.commands.any((c) => c.contains('dumpsys display')), isTrue);
    });

    test('read：dumpsys 无输出 → 档位退化 60/90/120', () async {
      final shell = _FakeShell();
      final controller = RefreshRateController(shell: PrivilegedShell(runner: shell.run));

      final state = await controller.read();

      expect(state.available, isTrue);
      expect(state.levels, equals(RefreshRateController.fallbackLevels));
    });

    test('read：Shizuku 不可用（runner null）→ available=false + 原因', () async {
      final shell = _FakeShell(failAll: true);
      final controller = RefreshRateController(shell: PrivilegedShell(runner: shell.run));

      final state = await controller.read();

      expect(state.available, isFalse);
      expect(state.reason, isNotNull);
    });

    test('parseRefreshLevels：识别 fps=/refreshRate= 并过滤越界值', () {
      final levels = RefreshRateController.parseRefreshLevels(
        'refreshRate=90.0 fps=120.0 60 fps refreshRate=1000.0',
      );
      expect(levels, equals(<int>[60, 90, 120]));
      expect(RefreshRateController.parseRefreshLevels('no rates here'), isEmpty);
    });
  });

  group('RefreshRateController · 应用', () {
    test('apply 成功：写入 min+peak 并回读确认', () async {
      final shell = _FakeShell();
      final controller = RefreshRateController(shell: PrivilegedShell(runner: shell.run));

      final result = await controller.apply(min: 90, peak: 90);

      expect(result.ok, isTrue);
      expect(result.status, RefreshRateStatus.ok);
      expect(
        shell.commands
            .any((c) => c.contains('settings put system min_refresh_rate 90')),
        isTrue,
      );
      expect(
        shell.commands
            .any((c) => c.contains('settings put system peak_refresh_rate 90')),
        isTrue,
      );
      // 回读校验命令存在。
      expect(
        shell.commands
            .where((c) => c.contains('settings get system min_refresh_rate'))
            .length,
        greaterThanOrEqualTo(1),
      );
    });

    test('apply 回读不匹配：不假成功（readback_mismatch）', () async {
      final shell = _FakeShell(suppressPutEffect: true);
      final controller = RefreshRateController(shell: PrivilegedShell(runner: shell.run));

      final result = await controller.apply(min: 90, peak: 90);

      expect(result.ok, isFalse);
      expect(result.status, RefreshRateStatus.readbackMismatch);
    });

    test('apply 越界 / min>peak：零写入 invalid_arg', () async {
      final shell = _FakeShell();
      final controller = RefreshRateController(shell: PrivilegedShell(runner: shell.run));

      final outOfRange = await controller.apply(min: 300, peak: 300);
      final inverted = await controller.apply(min: 120, peak: 60);

      expect(outOfRange.status, RefreshRateStatus.invalidArg);
      expect(inverted.status, RefreshRateStatus.invalidArg);
      expect(shell.commands.any((c) => c.contains('settings put')), isFalse);
    });
  });

  group('屏幕刷新率组 · UI', () {
    testWidgets('渲染当前 min/peak + 档位按钮', (tester) async {
      _useTallViewport(tester);
      final shell = _FakeShell();
      await tester.pumpWidget(
        _harness(refresh: RefreshRateController(shell: PrivilegedShell(runner: shell.run))),
      );
      await _settle(tester);

      expect(find.byKey(const Key('perf_refresh_group')), findsOneWidget);
      expect(_currentText(tester), contains('120'));
      for (final level in <int>[60, 90, 120]) {
        expect(find.byKey(Key('perf_refresh_set_$level')), findsOneWidget);
      }
      expect(find.byKey(const Key('perf_refresh_set_max')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('选择档位 → 确认 → 写命令序列正确 + 当前值刷新', (tester) async {
      _useTallViewport(tester);
      final shell = _FakeShell();
      await tester.pumpWidget(
        _harness(refresh: RefreshRateController(shell: PrivilegedShell(runner: shell.run))),
      );
      await _settle(tester);

      await tester.tap(find.byKey(const Key('perf_refresh_set_90')));
      await _settle(tester);
      expect(find.text('应用屏幕刷新率？'), findsOneWidget);
      // 未确认前不写入。
      expect(shell.commands.any((c) => c.contains('settings put')), isFalse);

      await tester.tap(find.text('确认应用'));
      await _settle(tester);

      expect(
        shell.commands
            .any((c) => c.contains('settings put system min_refresh_rate 90')),
        isTrue,
      );
      expect(
        shell.commands
            .any((c) => c.contains('settings put system peak_refresh_rate 90')),
        isTrue,
      );
      expect(_currentText(tester), contains('90'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('取消确认：不写入且当前值不变', (tester) async {
      _useTallViewport(tester);
      final shell = _FakeShell();
      await tester.pumpWidget(
        _harness(refresh: RefreshRateController(shell: PrivilegedShell(runner: shell.run))),
      );
      await _settle(tester);

      await tester.tap(find.byKey(const Key('perf_refresh_set_90')));
      await _settle(tester);
      await tester.tap(find.text('取消'));
      await _settle(tester);

      expect(shell.commands.any((c) => c.contains('settings put')), isFalse);
      expect(_currentText(tester), contains('120'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('回读失败：显式报错且不假成功', (tester) async {
      _useTallViewport(tester);
      final shell = _FakeShell(suppressPutEffect: true);
      await tester.pumpWidget(
        _harness(refresh: RefreshRateController(shell: PrivilegedShell(runner: shell.run))),
      );
      await _settle(tester);

      await tester.tap(find.byKey(const Key('perf_refresh_set_90')));
      await _settle(tester);
      await tester.tap(find.text('确认应用'));
      await _settle(tester);

      expect(find.textContaining('应用失败'), findsOneWidget);
      expect(_currentText(tester), contains('120'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Shizuku 不可用：档位禁用 + 可见原因', (tester) async {
      _useTallViewport(tester);
      final shell = _FakeShell(failAll: true);
      await tester.pumpWidget(
        _harness(refresh: RefreshRateController(shell: PrivilegedShell(runner: shell.run))),
      );
      await _settle(tester);

      expect(find.byKey(const Key('perf_refresh_group')), findsOneWidget);
      expect(find.textContaining('不可用'), findsWidgets);
      for (final key in const <String>[
        'perf_refresh_set_60',
        'perf_refresh_set_90',
        'perf_refresh_set_120',
        'perf_refresh_set_max',
      ]) {
        final button = tester.widget<FilledButton>(find.byKey(Key(key)));
        expect(button.onPressed, isNull, reason: '$key 应禁用');
      }
      expect(shell.commands.any((c) => c.contains('settings put')), isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
