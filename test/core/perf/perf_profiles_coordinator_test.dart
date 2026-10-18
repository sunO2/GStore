// Todo 30：每应用性能模式运行时协调器（PerfProfilesCoordinator）的单测。
//
// 验证：start() 启动监视器 + 自动应用引擎（并跑能力探测）；stop() 停监视器 +
// dispose 引擎 + **有保证还原**会话；tunables 加载失败 → fail-closed 不启动、
// 零命令；未启动时 stop() 零命令。全部注入假 shell / 罐头 tunables / 假监视器，
// 无 Shizuku / 真机 / 原生模块。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

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

/// 假前台监视器：无定时器、无 shell；start/stop/dispose 只翻标志位。
class _FakeWatcher extends ForegroundWatcher {
  _FakeWatcher();

  final StreamController<ForegroundEvent> _events =
      StreamController<ForegroundEvent>.broadcast(sync: true);

  bool started = false;
  bool disposed = false;
  int startCalls = 0;

  @override
  Stream<ForegroundEvent> get events => _events.stream;

  @override
  bool get isRunning => started && !disposed;

  @override
  Future<void> start() async {
    startCalls++;
    started = true;
  }

  @override
  void stop() {
    started = false;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    started = false;
    if (!_events.isClosed) await _events.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PerfProfilesCoordinator 生命周期', () {
    late _FakeRunner runner;
    late PrivilegedShell shell;
    late PerfControlSession session;
    late InMemoryPerfControlSessionStore sessionStore;
    late _FakeWatcher watcher;

    setUp(() {
      runner = _FakeRunner();
      shell = PrivilegedShell(runner: runner.call);
      sessionStore = InMemoryPerfControlSessionStore();
      session = PerfControlSession(shell: shell, store: sessionStore);
      watcher = _FakeWatcher();
    });

    PerfProfilesCoordinator build({
      Future<TunablesReport> Function()? tunablesLoader,
    }) =>
        PerfProfilesCoordinator(
          store: InMemoryPerfProfileStore(),
          session: session,
          shell: shell,
          tunablesLoader:
              tunablesLoader ?? () async => const TunablesReport(),
          isGloballyEnabled: () => true,
          watcherFactory: () => watcher,
        );

    test('start() 启动监视器 + 引擎，并跑能力探测（有命令）', () async {
      final coordinator = build();

      expect(coordinator.isRunning, isFalse, reason: 'start 前不得运行');
      expect(runner.commands, isEmpty, reason: 'start 前零命令');

      final started = await coordinator.start();

      expect(started, isTrue);
      expect(coordinator.isRunning, isTrue);
      expect(coordinator.watcher, same(watcher));
      expect(watcher.started, isTrue);
      expect(watcher.startCalls, 1);
      expect(coordinator.engine, isNotNull);
      expect(coordinator.capabilities, isNotNull,
          reason: 'start 后能力探测已运行');
      expect(runner.commands, isNotEmpty,
          reason: '能力探测（test -w / 杠杆）必须发出命令');
    });

    test('start() 幂等：重复调用不重建监视器', () async {
      final coordinator = build();
      await coordinator.start();
      await coordinator.start();
      expect(watcher.startCalls, 1, reason: '运行中重复 start 应无操作');
    });

    test('stop() 停监视器 + dispose 引擎 + 还原会话（写回原值）', () async {
      // 先登记一个覆盖项，模拟已应用的控制。
      await session.recordAll(<PerfOverride>[
        const PerfOverride(
          path: '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor',
          originalValue: 'schedutil',
        ),
      ]);
      expect(session.pendingCount, 1);

      final coordinator = build();
      await coordinator.start();
      runner.commands.clear();

      await coordinator.stop();

      expect(coordinator.isRunning, isFalse);
      expect(watcher.disposed, isTrue, reason: 'stop 必须 dispose 监视器');
      expect(session.pendingCount, 0, reason: 'stop 必须还原全部覆盖项');
      expect(
        runner.commands.where((c) => c.contains('schedutil')),
        isNotEmpty,
        reason: '还原必须把原值写回节点',
      );
    });

    test('未启动时 stop() 零命令（幂等、无残留）', () async {
      final coordinator = build();
      await coordinator.stop();
      expect(coordinator.isRunning, isFalse);
      expect(runner.commands, isEmpty, reason: '未启动 + 无待还原 → 零命令');
    });

    test('tunables 加载失败 → fail-closed：不启动、零命令', () async {
      final coordinator = build(
        tunablesLoader: () async => throw StateError('perf module 不可用'),
      );

      final started = await coordinator.start();

      expect(started, isFalse, reason: 'tunables 不可用不得启动');
      expect(coordinator.isRunning, isFalse);
      expect(coordinator.watcher, isNull);
      expect(coordinator.engine, isNull);
      expect(runner.commands, isEmpty,
          reason: 'fail-closed：不得发出任何 Shizuku 命令');
    });

    test('start → stop → start 可重启（每次新监视器）', () async {
      final coordinator = build();
      await coordinator.start();
      expect(watcher.startCalls, 1);
      await coordinator.stop();

      final second = _FakeWatcher();
      final coordinator2 = PerfProfilesCoordinator(
        store: InMemoryPerfProfileStore(),
        session: session,
        shell: shell,
        tunablesLoader: () async => const TunablesReport(),
        isGloballyEnabled: () => true,
        watcherFactory: () => second,
      );
      await coordinator2.start();
      expect(second.started, isTrue);
      expect(coordinator2.isRunning, isTrue);
    });
  });
}
