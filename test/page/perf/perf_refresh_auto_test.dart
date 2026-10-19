import 'package:flutter/foundation.dart';
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
import 'package:gstore/core/perf/refresh_auto_engine.dart';
import 'package:gstore/core/perf/refresh_auto_store.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/page/perf/control_page.dart';
import 'package:gstore/page/perf/perf_control_actions.dart';

// ==================== 假 shell（controller 侧） ====================

class _FakeShell {
  _FakeShell({this.failAll = false});

  final bool failAll;
  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);
    if (failAll) return null;
    if (command.contains('settings get')) {
      return 'null\nGSTORE_RESULT ok=1';
    }
    return 'GSTORE_RESULT ok=1';
  }
}

// ==================== 假控制动作 ====================

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

// ==================== 假 store / 假 driver ====================

/// 记录写调用次数的内存 store。
class _RecordingStore extends InMemoryRefreshAutoStore {
  _RecordingStore([super.seed]);

  int setEnabledCalls = 0;
  int setDefaultsCalls = 0;

  @override
  Future<bool> setEnabled(bool enabled) {
    setEnabledCalls++;
    return super.setEnabled(enabled);
  }

  @override
  Future<bool> setDefaults({int? min, int? peak}) {
    setDefaultsCalls++;
    return super.setDefaults(min: min, peak: peak);
  }
}

/// 不启动定时器的假引擎驱动（记录生命周期调用）。
class _FakeDriver implements RefreshAutoDriver {
  final ValueNotifier<String?> _foreground = ValueNotifier<String?>(null);
  bool started = false;
  bool stopped = false;
  bool disposed = false;

  @override
  bool get isRunning => started && !disposed;

  @override
  ValueListenable<String?> get foregroundPackage => _foreground;

  @override
  void start() => started = true;

  @override
  void stop() {
    stopped = true;
    started = false;
  }

  @override
  void dispose() {
    disposed = true;
    _foreground.dispose();
  }
}

RefreshAutoEntry _entry(String pkg, {int min = 60, int peak = 120}) =>
    RefreshAutoEntry(package: pkg, label: pkg, min: min, peak: peak);

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

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 20000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester, [int frames = 14]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Widget _harness({
  required _RecordingStore store,
  required _FakeDriver driver,
  required RefreshRateController controller,
}) {
  return ProviderScope(
    overrides: [
      perfControlTunablesLoaderProvider.overrideWithValue(() async => _tunables()),
      perfControlCapabilitiesLoaderProvider
          .overrideWithValue(({bool refresh = false}) async => _caps()),
      perfControlActionsFactoryProvider.overrideWithValue((t, c) => _FakeActions()),
      perfRefreshRateControllerProvider.overrideWithValue(controller),
      perfRefreshAutoStoreProvider.overrideWithValue(store),
      perfRefreshAutoDriverFactoryProvider.overrideWithValue(
        ({
          required RefreshRateController controller,
          required RefreshAutoStore store,
        }) =>
            driver,
      ),
    ],
    child: MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const Scaffold(body: PerfControlPage()),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('按前台自动切换 · UI', () {
    testWidgets('渲染开关（默认关闭）+ 已配置应用列表', (tester) async {
      _useTallViewport(tester);
      final store = _RecordingStore(
        RefreshAutoConfig(
          enabled: false,
          entries: <String, RefreshAutoEntry>{'com.demo': _entry('com.demo')},
        ),
      );
      final driver = _FakeDriver();
      await tester.pumpWidget(
        _harness(
          store: store,
          driver: driver,
          controller: RefreshRateController(
            shell: PrivilegedShell(runner: _FakeShell().run),
          ),
        ),
      );
      await _settle(tester);

      final switchTile = tester.widget<SwitchListTile>(
        find.byKey(const Key('perf_refresh_auto_switch')),
      );
      expect(switchTile.value, isFalse);
      expect(find.byKey(const Key('perf_refresh_auto_list')), findsOneWidget);
      expect(find.byKey(const Key('perf_refresh_auto_item_com.demo')), findsOneWidget);
      expect(find.textContaining('min 60 Hz'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('打开开关 → 持久化 enabled + 启动引擎', (tester) async {
      _useTallViewport(tester);
      final store = _RecordingStore();
      final driver = _FakeDriver();
      await tester.pumpWidget(
        _harness(
          store: store,
          driver: driver,
          controller: RefreshRateController(
            shell: PrivilegedShell(runner: _FakeShell().run),
          ),
        ),
      );
      await _settle(tester);

      await tester.tap(find.byKey(const Key('perf_refresh_auto_switch')));
      await _settle(tester);

      expect(store.config.enabled, isTrue);
      expect(store.setEnabledCalls, greaterThan(0));
      expect(driver.started, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('添加应用 → 弹层保存 → store.upsert', (tester) async {
      _useTallViewport(tester);
      final store = _RecordingStore();
      final driver = _FakeDriver();
      await tester.pumpWidget(
        _harness(
          store: store,
          driver: driver,
          controller: RefreshRateController(
            shell: PrivilegedShell(runner: _FakeShell().run),
          ),
        ),
      );
      await _settle(tester);

      await tester.tap(find.byKey(const Key('perf_refresh_auto_add')));
      await _settle(tester);
      expect(find.byKey(const Key('perf_refresh_auto_pkg_field')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('perf_refresh_auto_pkg_field')),
        'com.new',
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('perf_refresh_auto_save')));
      await _settle(tester);

      final entry = store.config.entries['com.new'];
      expect(entry, isNotNull);
      expect(entry!.label, 'com.new');
      expect(entry.min, 60);
      expect(entry.peak, 120);
      expect(find.byKey(const Key('perf_refresh_auto_item_com.new')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('删除应用 → 危险确认 → store.remove', (tester) async {
      _useTallViewport(tester);
      final store = _RecordingStore(
        RefreshAutoConfig(
          enabled: false,
          entries: <String, RefreshAutoEntry>{'com.demo': _entry('com.demo')},
        ),
      );
      final driver = _FakeDriver();
      await tester.pumpWidget(
        _harness(
          store: store,
          driver: driver,
          controller: RefreshRateController(
            shell: PrivilegedShell(runner: _FakeShell().run),
          ),
        ),
      );
      await _settle(tester);

      await tester.tap(find.byKey(const Key('perf_refresh_auto_delete_com.demo')));
      await _settle(tester);
      expect(find.text('删除应用配置？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await _settle(tester);

      expect(store.config.entries.containsKey('com.demo'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('默认恢复值弹层保存 → store.setDefaults', (tester) async {
      _useTallViewport(tester);
      final store = _RecordingStore();
      final driver = _FakeDriver();
      await tester.pumpWidget(
        _harness(
          store: store,
          driver: driver,
          controller: RefreshRateController(
            shell: PrivilegedShell(runner: _FakeShell().run),
          ),
        ),
      );
      await _settle(tester);

      await tester.tap(find.byKey(const Key('perf_refresh_auto_default')));
      await _settle(tester);
      expect(
        find.byKey(const Key('perf_refresh_auto_default_save')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('perf_refresh_auto_default_save')));
      await _settle(tester);

      expect(store.setDefaultsCalls, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Shizuku 不可用 → 开关禁用 + 添加按钮禁用 + 原因', (tester) async {
      _useTallViewport(tester);
      final store = _RecordingStore();
      final driver = _FakeDriver();
      await tester.pumpWidget(
        _harness(
          store: store,
          driver: driver,
          controller: RefreshRateController(
            shell: PrivilegedShell(runner: _FakeShell(failAll: true).run),
          ),
        ),
      );
      await _settle(tester);

      final switchTile = tester.widget<SwitchListTile>(
        find.byKey(const Key('perf_refresh_auto_switch')),
      );
      expect(switchTile.onChanged, isNull);
      final addButton = tester.widget<TextButton>(
        find.byKey(const Key('perf_refresh_auto_add')),
      );
      expect(addButton.onPressed, isNull);
      expect(find.textContaining('自动刷新率不可用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
