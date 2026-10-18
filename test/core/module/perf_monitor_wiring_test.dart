// Todo 30：PerfMonitorModule 生命周期接线（每应用性能模式）端到端测试。
//
// 断言：
//  * 全局开关 OFF（默认）→ **不构造**运行时协调器：零轮询、零 Shizuku / FFI
//    （假 runner 调用数 0）；
//  * 开关 ON（启动时已开 / 运行期打开）→ 启动监视器 + 自动应用引擎；
//  * 开关运行期关闭（陈旧态）→ 停止并**还原**会话登记项；
//  * onUnregister → 停止运行时 + 与 onRegister 对称注销 agent 工具；
//  * AgentToolsModule.tools 含新工具名（perfTunables / perfControl）。
//
// 全部密闭：ConfigStore 用内存存储；运行时经 coordinatorFactoryOverride 注入
// 假 shell + 假监视器；无 Shizuku / 真机 / 原生模块 / 平台通道。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/module_base.dart';
import 'package:gstore/core/perf/foreground_watcher.dart';
import 'package:gstore/core/perf/perf_control_session.dart';
import 'package:gstore/core/perf/perf_profile_store.dart';
import 'package:gstore/core/perf/perf_profiles_coordinator.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

/// 假命令执行器：记录每条命令，默认回哨兵成功。
class _FakeRunner {
  final List<String> commands = <String>[];
  String response = 'GSTORE_RESULT ok=1';

  Future<String?> call(String command) async {
    commands.add(command);
    return response;
  }
}

/// 假前台监视器：无定时器 / 无 shell。
class _FakeWatcher extends ForegroundWatcher {
  _FakeWatcher();

  final StreamController<ForegroundEvent> _events =
      StreamController<ForegroundEvent>.broadcast(sync: true);

  bool started = false;
  bool disposed = false;

  @override
  Stream<ForegroundEvent> get events => _events.stream;

  @override
  bool get isRunning => started && !disposed;

  @override
  Future<void> start() async => started = true;

  @override
  void stop() => started = false;

  @override
  Future<void> dispose() async {
    disposed = true;
    started = false;
    if (!_events.isClosed) await _events.close();
  }
}

Future<void> _waitUntil(bool Function() condition, {int timeoutMs = 2000}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRunner runner;
  late PrivilegedShell shell;
  late PerfControlSession session;
  late InMemoryPerfControlSessionStore sessionStore;
  late List<_FakeWatcher> watchers;
  late int factoryCalls;
  late PerfMonitorModule module;

  PerfProfilesCoordinator buildCoordinator() {
    factoryCalls++;
    final watcher = _FakeWatcher();
    watchers.add(watcher);
    return PerfProfilesCoordinator(
      store: InMemoryPerfProfileStore(),
      session: session,
      shell: shell,
      tunablesLoader: () async => const TunablesReport(),
      isGloballyEnabled: () => true,
      watcherFactory: () => watcher,
    );
  }

  ModuleContext context({void Function(List<String>)? unregisterAgentTools}) =>
      ModuleContext(
        config: ConfigService.instance,
        unregisterAgentTools: unregisterAgentTools,
      );

  setUp(() async {
    PerfMonitorModule.coordinatorFactoryOverride = null;
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(storages: <ConfigStorage>[
      MemoryConfigStorage(),
      MemoryConfigStorage(),
    ]);
    ConfigRegistry.registerAll(ConfigService.instance);
    runner = _FakeRunner();
    shell = PrivilegedShell(runner: runner.call);
    sessionStore = InMemoryPerfControlSessionStore();
    session = PerfControlSession(shell: shell, store: sessionStore);
    watchers = <_FakeWatcher>[];
    factoryCalls = 0;
    module = PerfMonitorModule();
  });

  tearDown(() {
    PerfMonitorModule.coordinatorFactoryOverride = null;
    setSharedPerfControlSessionForTest(null);
  });

  test('BOOT OFF（默认）：不构造运行时协调器 → 零 Shizuku / FFI 调用', () async {
    PerfMonitorModule.coordinatorFactoryOverride = buildCoordinator;
    final ctx = context();

    await module.onInit(ctx);
    await module.onRegister(ctx);

    expect(factoryCalls, 0, reason: 'OFF 时绝不构造协调器');
    expect(module.perfProfiles, isNull);
    expect(runner.commands, isEmpty,
        reason: 'fake runner 调用数必须为 0（无轮询 / 无探测）');

    // 下线同样零命令（无待还原项）。
    await module.onUnregister(ctx);
    expect(runner.commands, isEmpty);
  });

  test('BOOT ON：启动监视器 + 自动应用引擎', () async {
    await ConfigStore.instance.write(ConfigKeys.perfProfilesEnabled, true);
    PerfMonitorModule.coordinatorFactoryOverride = buildCoordinator;
    final ctx = context();

    await module.onInit(ctx);
    await module.onRegister(ctx);

    expect(factoryCalls, 1);
    expect(module.perfProfiles, isNotNull);
    expect(module.perfProfiles!.isRunning, isTrue);
    expect(module.perfProfiles!.engine, isNotNull);
    expect(watchers.single.started, isTrue);
    expect(runner.commands, isNotEmpty, reason: 'ON 时能力探测会发命令');

    await module.onUnregister(ctx);
    expect(module.perfProfiles, isNull);
    expect(watchers.single.disposed, isTrue);
  });

  test('陈旧态：开关 OFF→ON 启动，ON→OFF 停止 + 还原', () async {
    // 预置一个覆盖项，关闭时必须被还原。
    await session.recordAll(<PerfOverride>[
      const PerfOverride(
        path: '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor',
        originalValue: 'schedutil',
      ),
    ]);

    PerfMonitorModule.coordinatorFactoryOverride = buildCoordinator;
    final ctx = context();
    await module.onInit(ctx);
    await module.onRegister(ctx);
    expect(module.perfProfiles, isNull, reason: '默认 OFF 未启动');

    // OFF → ON：启动。
    await ConfigStore.instance.write(ConfigKeys.perfProfilesEnabled, true);
    await _waitUntil(() => module.perfProfiles != null);
    expect(module.perfProfiles, isNotNull, reason: '开关打开必须启动运行时');
    expect(module.perfProfiles!.isRunning, isTrue);
    expect(watchers.single.started, isTrue);

    // ON → OFF：停止 + 还原。
    runner.commands.clear();
    await ConfigStore.instance.write(ConfigKeys.perfProfilesEnabled, false);
    await _waitUntil(
      () => module.perfProfiles == null && session.pendingCount == 0,
    );
    expect(module.perfProfiles, isNull, reason: '开关关闭必须停止运行时');
    expect(watchers.single.disposed, isTrue);
    expect(session.pendingCount, 0, reason: '关闭必须还原会话登记项');
    expect(
      runner.commands.where((c) => c.contains('schedutil')),
      isNotEmpty,
      reason: '还原必须把原值写回节点',
    );
  });

  test('onUnregister：停止运行时 + 与 onRegister 对称注销 agent 工具', () async {
    await ConfigStore.instance.write(ConfigKeys.perfProfilesEnabled, true);
    PerfMonitorModule.coordinatorFactoryOverride = buildCoordinator;

    List<String>? unregistered;
    final ctx = context(unregisterAgentTools: (names) => unregistered = names);

    await module.onInit(ctx);
    await module.onRegister(ctx);
    expect(module.perfProfiles, isNotNull);

    await module.onUnregister(ctx);

    expect(module.perfProfiles, isNull, reason: '下线必须停止运行时');
    expect(watchers.single.disposed, isTrue);
    expect(unregistered, isNotNull, reason: '下线必须注销 agent 工具');
    expect(
      unregistered!.toSet(),
      containsAll(<String>[
        'perfDeviceSnapshot',
        'perfThirdPartyMetrics',
        'perfFrameStats',
      ]),
      reason: '注销集合必须与 PerfMonitorModule 注册的只读工具对称',
    );
  });

  test('AgentToolsModule.tools 含新工具名 perfTunables / perfControl', () {
    final names =
        AgentToolsModule().tools.map((t) => t.toolName).toSet();
    expect(names, containsAll(<String>['perfTunables', 'perfControl']));
  });
}
