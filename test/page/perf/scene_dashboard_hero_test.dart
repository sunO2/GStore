import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/perf_profile.dart';
import 'package:gstore/core/perf/perf_profile_store.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/scene_dashboard_hero.dart';
import 'package:gstore/page/perf/scene_ring_gauge.dart';
import 'package:gstore/page/perf/state.dart';

// ==================== 夹具 ====================

/// 完整数据状态（内存 91% / 交换 82% / CPU 90% / GPU 70% / 3 核 / 电池 / 温度）。
PerfPageState _fullState() => const PerfPageState(
      loading: false,
      availability: PerfAvailability.ready,
      cpu: CpuReport(
        usagePercent: 90,
        perCoreUsage: <double>[10, 95, 50],
        coreCount: 3,
        governor: 'schedutil',
        maxFreqMhz: 2400,
        cores: <PerfCpuCore>[
          PerfCpuCore(id: 0, freqMhz: 1800),
          PerfCpuCore(id: 1, freqMhz: 2200),
          PerfCpuCore(id: 2, freqMhz: 2400),
        ],
      ),
      memory: MemoryReport(
        usedPercent: 91,
        swapPercent: 82,
        usedKb: 3145728,
        usedHuman: '3.0 GB',
        swapUsedKb: 524288,
        swapUsedHuman: '512 MB',
      ),
      gpu: GpuReport(busyPercent: 70, freqMhz: 800, name: 'Adreno'),
      battery: BatteryReport(
        present: true,
        capacityPercent: 88,
        status: 'Charging',
        currentMa: 1200,
        voltageV: 4.2,
        temperatureC: 45,
      ),
      thermal: ThermalReport(
        maxTempC: 47,
        zones: <ThermalZone>[
          ThermalZone(zone: 'thermal_zone0', kind: 'cpu', tempC: 47),
        ],
      ),
    );

PerfControlCapabilities _caps({required bool anyWritable}) =>
    PerfControlCapabilities(
      nodeAvailability: const <String, bool>{},
      binderLevers: const <String, bool>{},
      categoryAvailability: <PerfControlCategory, bool>{
        for (final PerfControlCategory c in PerfControlCategory.values)
          c: anyWritable && c == PerfControlCategory.cpu,
      },
      nodeCounts: <PerfControlCategory, int>{
        for (final PerfControlCategory c in PerfControlCategory.values)
          c: anyWritable ? 1 : 0,
      },
      timeoutAvailable: true,
      probedAtMs: 0,
    );

/// 仅 `loadAll` 抛错的存储（验证应用失败降级为 `null`）。
class _FailingStore extends InMemoryPerfProfileStore {
  @override
  Future<Map<String, PerfProfile>> loadAll() async =>
      throw StateError('loadAll boom');
}

Future<void> _pump(WidgetTester tester, Widget hero) async {
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: hero))),
  );
  await tester.pump();
}

OutlinedButton _modeButton(WidgetTester tester, String wire) =>
    tester.widget<OutlinedButton>(find.byKey(Key('scene_hero_mode_$wire')));

void main() {
  testWidgets('无数据（state:null）降级渲染，不抛异常', (tester) async {
    await _pump(tester, const SceneDashboardHero());

    expect(tester.takeException(), isNull);
    expect(find.byType(SceneDashboardHero), findsOneWidget);
    // 四个环仍在（空环），逐核 / 热区显式空态。
    expect(find.byType(SceneRingGauge), findsNWidgets(4));
    expect(find.byKey(const Key('scene_hero_per_core_empty')), findsOneWidget);
    expect(find.byKey(const Key('scene_hero_thermal_empty')), findsOneWidget);
    expect(find.text('无电池'), findsOneWidget);
    // 未探测能力 → 四按钮可用（未知不阻断）。
    for (final String wire in <String>[
      'powersave',
      'balance',
      'performance',
      'fast',
    ]) {
      expect(_modeButton(tester, wire).onPressed, isNotNull);
    }
  });

  testWidgets('全量数据渲染：环 / 逐核网格 / 电池 / 温度', (tester) async {
    await _pump(tester, SceneDashboardHero(state: _fullState()));

    expect(tester.takeException(), isNull);
    expect(find.byType(SceneRingGauge), findsNWidgets(4));
    // 逐核网格：3 个单元。
    expect(find.byKey(const Key('scene_hero_core_0')), findsOneWidget);
    expect(find.byKey(const Key('scene_hero_core_1')), findsOneWidget);
    expect(find.byKey(const Key('scene_hero_core_2')), findsOneWidget);
    expect(find.text('3 核'), findsOneWidget);
    // 电池 / 温度卡片。
    expect(find.text('88%'), findsOneWidget);
    expect(find.text('充电中'), findsOneWidget);
    expect(find.text('45.0 °C'), findsOneWidget);
    expect(find.textContaining('最高 47.0'), findsOneWidget);
  });

  testWidgets('电池状态缺失：按电流方向推断放电中，并显示电池温度', (tester) async {
    const state = PerfPageState(
      loading: false,
      availability: PerfAvailability.ready,
      battery: BatteryReport(
        present: true,
        capacityPercent: 60,
        currentMa: -520,
        voltageV: 3.9,
        temperatureC: 33.5,
      ),
    );

    await _pump(tester, const SceneDashboardHero(state: state));

    expect(tester.takeException(), isNull);
    expect(find.text('放电中'), findsOneWidget);
    expect(find.text('33.5 °C'), findsOneWidget);
    expect(find.text('60%'), findsOneWidget);
  });

  testWidgets('环色随阈值档位（RAM 91% → veryHigh → error；CPU 90% → error）',
      (tester) async {
    await _pump(tester, SceneDashboardHero(state: _fullState()));

    final BuildContext ctx =
        tester.element(find.byType(SceneDashboardHero));
    final ColorScheme scheme = Theme.of(ctx).colorScheme;

    final ram = tester.widget<SceneRingGauge>(
      find.byKey(const Key('scene_hero_ring_ram')),
    );
    final cpu = tester.widget<SceneRingGauge>(
      find.byKey(const Key('scene_hero_ring_cpu')),
    );
    expect(ram.tierColor, scheme.error);
    expect(cpu.tierColor, scheme.error);
    expect(ram.fraction, closeTo(0.91, 0.0001));
  });

  testWidgets('能力可用 → 四按钮可用；null 能力 → 不阻断', (tester) async {
    await _pump(
      tester,
      const SceneDashboardHero(capabilities: PerfControlCapabilities(
        nodeAvailability: <String, bool>{},
        binderLevers: <String, bool>{},
        categoryAvailability: <PerfControlCategory, bool>{
          PerfControlCategory.cpu: true,
        },
        nodeCounts: <PerfControlCategory, int>{},
        timeoutAvailable: false,
        probedAtMs: 0,
      )),
    );
    expect(_modeButton(tester, 'fast').onPressed, isNotNull);

    await _pump(tester, SceneDashboardHero(capabilities: _caps(anyWritable: true)));
    expect(_modeButton(tester, 'fast').onPressed, isNotNull);
  });

  testWidgets('能力不可用（无任一可写类别）→ 四按钮禁用 + 可见原因', (tester) async {
    await _pump(
      tester,
      SceneDashboardHero(capabilities: _caps(anyWritable: false)),
    );

    for (final String wire in <String>[
      'powersave',
      'balance',
      'performance',
      'fast',
    ]) {
      expect(_modeButton(tester, wire).onPressed, isNull);
    }
    expect(find.textContaining('禁用'), findsOneWidget);
    expect(find.textContaining('无可用性能控制类别'), findsOneWidget);
  });

  testWidgets('点击模式 → 经既有 store 应用到全部档案 + 高亮 + 状态文案',
      (tester) async {
    final store = InMemoryPerfProfileStore(<String, PerfProfile>{
      'com.a': const PerfProfile(package: 'com.a', mode: PerfMode.balance),
      'com.b': const PerfProfile(package: 'com.b', mode: PerfMode.balance),
    });
    final List<(PerfMode, int?)> applied = <(PerfMode, int?)>[];

    await _pump(
      tester,
      SceneDashboardHero(
        state: _fullState(),
        store: store,
        capabilities: _caps(anyWritable: true),
        onModeApplied: (PerfMode mode, int? count) => applied.add((mode, count)),
      ),
    );

    await tester.tap(find.byKey(const Key('scene_hero_mode_fast')));
    await tester.pumpAndSettle();

    expect(applied, <(PerfMode, int?)>[(PerfMode.fast, 2)]);
    expect((await store.loadAll())['com.a']!.mode, PerfMode.fast);
    expect((await store.loadAll())['com.b']!.mode, PerfMode.fast);
    expect(find.textContaining('已应用「极速」到 2 个档案'), findsOneWidget);
  });

  testWidgets('无档案时点击模式 → 不持久化 + 提示文案', (tester) async {
    final applied = <(PerfMode, int?)>[];
    await _pump(
      tester,
      SceneDashboardHero(
        store: InMemoryPerfProfileStore(),
        onModeApplied: (PerfMode mode, int? count) => applied.add((mode, count)),
      ),
    );

    await tester.tap(find.byKey(const Key('scene_hero_mode_balance')));
    await tester.pumpAndSettle();

    expect(applied, <(PerfMode, int?)>[(PerfMode.balance, 0)]);
    expect(find.textContaining('尚无按应用性能档案'), findsOneWidget);
  });

  testWidgets('存储失败 → 应用降级为失败提示（不抛异常）', (tester) async {
    final applied = <(PerfMode, int?)>[];
    await _pump(
      tester,
      SceneDashboardHero(
        store: _FailingStore(),
        onModeApplied: (PerfMode mode, int? count) => applied.add((mode, count)),
      ),
    );

    await tester.tap(find.byKey(const Key('scene_hero_mode_performance')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(applied, <(PerfMode, int?)>[(PerfMode.performance, null)]);
    expect(find.textContaining('失败'), findsOneWidget);
  });

  testWidgets('逐核占用缺失（Android 8+ 无 Shizuku）→ 显示 — 并提示', (tester) async {
    const state = PerfPageState(
      loading: false,
      availability: PerfAvailability.ready,
      cpu: CpuReport(
        usagePercent: 0,
        perCoreUsage: <double>[],
        coreCount: 2,
        cores: <PerfCpuCore>[
          PerfCpuCore(id: 0, freqMhz: 1800),
          PerfCpuCore(id: 1, freqMhz: 2400),
        ],
      ),
    );
    await _pump(tester, const SceneDashboardHero(state: state));

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(const Key('scene_hero_core_0')),
        matching: find.text('—'),
      ),
      findsOneWidget,
      reason: '占用未知时应显示「—」，不能伪装成 0%',
    );
    expect(find.byKey(const Key('scene_hero_per_core_hint')), findsOneWidget);
    expect(find.text('1800MHz'), findsOneWidget, reason: '频率仍应展示');
  });
}
