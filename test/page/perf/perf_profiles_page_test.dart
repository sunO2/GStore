import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shizuku_api/shizuku_api.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/perf_profile.dart';
import 'package:gstore/core/perf/perf_profile_store.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/page/perf/perf_profiles_page.dart';

/// 假 Shizuku：不触达平台通道。
class _FakeShizuku extends ShizukuApi {
  @override
  Future<bool?> pingBinder() async => false;

  @override
  Future<bool?> checkPermission() async => false;

  @override
  Future<bool?> requestPermission() async => false;

  @override
  Future<String?> runCommand(String command) async => null;
}

/// 假服务：绕过 `installed_apps` 平台通道（测试环境无宿主，调用会挂起）。
class _FakeService extends ThirdPartyPerfService {
  _FakeService()
      : super(runner: (cmd) async => null, shizukuApi: _FakeShizuku());

  @override
  Future<List<AppTarget>> listInstalledApps() async => const <AppTarget>[
        AppTarget(package: 'com.example.app', label: '示例应用'),
      ];
}

// ---- 能力探测路径（与下面 tunables 对应）----

const String _govNode =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor';
const String _minNode =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq';
const String _maxNode =
    '/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq';

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

PerfControlCapabilities _caps({required bool available}) =>
    PerfControlCapabilities(
      nodeAvailability: <String, bool>{
        _govNode: available,
        _minNode: available,
        _maxNode: available,
      },
      binderLevers: const <String, bool>{},
      categoryAvailability: <PerfControlCategory, bool>{
        PerfControlCategory.cpu: available,
        PerfControlCategory.gpu: available,
        PerfControlCategory.cpuset: available,
        PerfControlCategory.thermal: available,
        PerfControlCategory.binderLevers: false,
      },
      nodeCounts: const <PerfControlCategory, int>{},
      timeoutAvailable: true,
      probedAtMs: 0,
    );

Widget _harness({
  required PerfProfileStore store,
  bool available = true,
  bool capsNull = false,
}) =>
    MaterialApp(
      // 挂载全局弹层 / Snackbar 通道（[AppDialogs] 统一走全局 key）。
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: PerfProfilesPage(
        store: store,
        service: _FakeService(),
        tunablesLoader: () async => _tunables(),
        capabilitiesLoader: (tunables) async =>
            capsNull ? null : _caps(available: available),
      ),
    );

/// 推进若干帧（不用 pumpAndSettle：[AppLoading] 无限动画会超时）。
Future<void> _pump(WidgetTester tester, [int frames = 16]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// 经「新增档案 → 应用选择弹层」打开编辑弹层。
Future<void> _openEditorViaAdd(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('perf_profiles_add')));
  await _pump(tester);
  await tester.tap(
    find.byKey(const Key('perf_profile_picker_item_com.example.app')),
  );
  await _pump(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('列表渲染已配置档案', (tester) async {
    final store = InMemoryPerfProfileStore(<String, PerfProfile>{
      'com.example.app': const PerfProfile(
        package: 'com.example.app',
        enabled: true,
      ),
    });
    await tester.pumpWidget(_harness(store: store));
    await _pump(tester);

    expect(
      find.byKey(const Key('perf_profile_tile_com.example.app')),
      findsOneWidget,
    );
    expect(find.text('com.example.app'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新增档案 round-trip：选择应用 → 启用 → 保存 → 列表出现', (tester) async {
    final store = InMemoryPerfProfileStore();
    await tester.pumpWidget(_harness(store: store));
    await _pump(tester);

    await _openEditorViaAdd(tester);
    await tester.tap(find.byKey(const Key('perf_profile_editor_enabled')));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('perf_profile_editor_save')));
    await _pump(tester);

    final saved = await store.load('com.example.app');
    expect(saved, isNotNull);
    expect(saved!.enabled, isTrue);
    expect(
      find.byKey(const Key('perf_profile_tile_com.example.app')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑档案 round-trip：切换启用 → 保存 → store 更新', (tester) async {
    final store = InMemoryPerfProfileStore(<String, PerfProfile>{
      'com.example.app': const PerfProfile(package: 'com.example.app'),
    });
    await tester.pumpWidget(_harness(store: store));
    await _pump(tester);

    await tester.tap(find.byKey(const Key('perf_profile_edit_com.example.app')));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('perf_profile_editor_enabled')));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('perf_profile_editor_save')));
    await _pump(tester);

    final saved = await store.load('com.example.app');
    expect(saved!.enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除档案 round-trip：危险确认后移除', (tester) async {
    final store = InMemoryPerfProfileStore(<String, PerfProfile>{
      'com.example.app': const PerfProfile(
        package: 'com.example.app',
        enabled: true,
      ),
    });
    await tester.pumpWidget(_harness(store: store));
    await _pump(tester);

    await tester
        .tap(find.byKey(const Key('perf_profile_delete_com.example.app')));
    await _pump(tester);
    expect(find.text('删除性能档案？'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await _pump(tester);

    expect(await store.load('com.example.app'), isNull);
    expect(
      find.byKey(const Key('perf_profile_tile_com.example.app')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('能力不可用：调优控件 fail-closed 禁用且给出原因', (tester) async {
    final store = InMemoryPerfProfileStore();
    await tester.pumpWidget(_harness(store: store, available: false));
    await _pump(tester);
    await _openEditorViaAdd(tester);

    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('perf_profile_editor_min_policy0')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('perf_profile_editor_max_policy0')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('perf_profile_editor_gpu')))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<Switch>(
            find.byKey(const Key('perf_profile_editor_thermal')),
          )
          .onChanged,
      isNull,
    );
    final cpuset = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: find.byKey(const Key('perf_profile_editor_cpuset')),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    expect(cpuset.onChanged, isNull);
    expect(find.textContaining('不可用'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('能力未探测（null）：调优控件同样禁用', (tester) async {
    final store = InMemoryPerfProfileStore();
    await tester.pumpWidget(_harness(store: store, capsNull: true));
    await _pump(tester);
    await _openEditorViaAdd(tester);

    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('perf_profile_editor_min_policy0')),
          )
          .enabled,
      isFalse,
    );
    expect(find.textContaining('未探测'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('频率不在可用列表内 → 就地拒绝保存（store 不变）', (tester) async {
    final store = InMemoryPerfProfileStore();
    await tester.pumpWidget(_harness(store: store));
    await _pump(tester);
    await _openEditorViaAdd(tester);

    await tester.enterText(
      find.byKey(const Key('perf_profile_editor_min_policy0')),
      '1234',
    );
    await _pump(tester);
    await tester.tap(find.byKey(const Key('perf_profile_editor_save')));
    await _pump(tester);

    expect(
      find.byKey(const Key('perf_profile_editor_error')),
      findsOneWidget,
    );
    // 弹层未关闭。
    expect(
      find.byKey(const Key('perf_profile_editor_save')),
      findsOneWidget,
    );
    expect(await store.load('com.example.app'), isNull);
    expect(tester.takeException(), isNull);
  });
}
