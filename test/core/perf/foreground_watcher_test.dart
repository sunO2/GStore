// fake_async 是 flutter_test 的传递依赖（未直接列入 pubspec，故忽略该 lint）。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/foreground_watcher.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 假 perf 网关：按顺序返回预设前台包名；可挂起 / 抛不可用；不触碰 FFI。
class _FakeGateway implements PerfModuleGateway {
  _FakeGateway(this.packages);

  final List<String?> packages;
  final List<String> activityTexts = <String>[];
  int _index = 0;

  /// 挂起所有调用（模拟模块不可用 / 卡死）。
  bool hang = false;
  Completer<void>? _gate;

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    expect(method, PerfMethods.foreground);
    final text = payload == null ? '' : utf8.decode(payload);
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    activityTexts.add(decoded['activity']?.toString() ?? '');
    if (hang) {
      _gate ??= Completer<void>();
      await _gate!.future;
    }
    final pkg = packages.isEmpty
        ? null
        : packages[_index.clamp(0, packages.length - 1)];
    _index++;
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{'package': pkg},
        }),
      ),
    );
  }

  @override
  Stream<PerfRawEvent> get events => const Stream<PerfRawEvent>.empty();
}

/// 记录命令 + 返回罐头 dumpsys 输出的假 runner（不触碰 Shizuku / 真机）。
class _FakeRunner {
  _FakeRunner();

  final List<String> commands = <String>[];
  String activityOutput = 'ResumedActivity: ActivityRecord{com.a/.Main t1}';
  String powerOutput = 'mWakefulness=Awake';
  bool failDumpsys = false;

  int get dumpsysCalls =>
      commands.where((c) => c.contains('dumpsys activity activities')).length;

  Future<String?> run(String command) async {
    commands.add(command);
    if (command.contains('dumpsys activity activities')) {
      if (failDumpsys) return 'GSTORE_RESULT err=1';
      return '$activityOutput\nGSTORE_RESULT ok=1';
    }
    if (command.contains('dumpsys power')) {
      return '$powerOutput\nGSTORE_RESULT ok=1';
    }
    return 'GSTORE_RESULT ok=1';
  }
}

/// 单线程串行 executor 的假 runner：命令**按入队顺序**串行执行，一条未完成则
/// 后续命令不得开始（模拟 Shizuku 插件的单线程 executor）。
class _SerialRunner {
  final List<String> enqueued = <String>[];
  final List<String> started = <String>[];
  final List<Completer<String?>> _pending = <Completer<String?>>[];
  Future<void> _tail = Future<void>.value();

  Future<String?> run(String command) {
    enqueued.add(command);
    final completer = Completer<String?>();
    _pending.add(completer);
    final result = _tail.then((_) {
      started.add(command);
      return completer.future;
    });
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// 完成按入队顺序第 [index] 条命令。
  void complete(int index, String value) => _pending[index].complete(value);

  int get pendingCount => _pending.where((c) => !c.isCompleted).length;
}

ForegroundWatcher _watcher({
  required _FakeRunner runner,
  required _FakeGateway gateway,
  ScreenOnProbe? screen,
  ShizukuAvailabilityProbe? shizuku,
  Duration interval = const Duration(seconds: 5),
  Duration telemetry = const Duration(seconds: 2),
  Duration budget = const Duration(seconds: 30),
  int maxFailures = 3,
}) =>
    ForegroundWatcher(
      module: PerfModule(gateway: gateway),
      shell: PrivilegedShell(
        runner: runner.run,
        timeout: const Duration(seconds: 60),
      ),
      screenOnProbe: screen ?? () async => true,
      shizukuProbe: shizuku ?? () async => true,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
      interval: interval,
      telemetryInterval: telemetry,
      maxPollBudget: budget,
      maxConsecutiveFailures: maxFailures,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('两个不同前台包 → 发出两个事件（相同包去重）', () {
    fakeAsync((async) {
      final runner = _FakeRunner();
      final gateway = _FakeGateway(<String?>['com.a', 'com.a', 'com.b']);
      final watcher = _watcher(runner: runner, gateway: gateway);
      final events = <ForegroundEvent>[];
      watcher.events.listen(events.add);

      watcher.start();
      async.flushMicrotasks();
      expect(events.map((e) => e.package).toList(), <String?>['com.a']);

      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(events.length, 1, reason: '相同包不重复发事件');

      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(
        events.map((e) => e.package).toList(),
        <String?>['com.a', 'com.b'],
      );
      expect(events.last.previousPackage, 'com.a');
      expect(watcher.status, ForegroundWatcherStatus.running);

      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('离开前台（包名变 null）→ 发一条清除事件', () {
    fakeAsync((async) {
      final gateway = _FakeGateway(<String?>['com.a', null, null]);
      final watcher = _watcher(runner: _FakeRunner(), gateway: gateway);
      final events = <ForegroundEvent>[];
      watcher.events.listen(events.add);

      watcher.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();

      expect(events.map((e) => e.package).toList(), <String?>['com.a', null]);
      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('首拍无法判定（null）→ 不发噪音事件', () {
    fakeAsync((async) {
      final watcher = _watcher(
        runner: _FakeRunner(),
        gateway: _FakeGateway(<String?>[null, 'com.a']),
      );
      final events = <ForegroundEvent>[];
      watcher.events.listen(events.add);

      watcher.start();
      async.flushMicrotasks();
      expect(events, isEmpty);

      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(events.map((e) => e.package).toList(), <String?>['com.a']);
      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('dispose 干净停止：不再轮询 / 不再发事件', () {
    fakeAsync((async) {
      final runner = _FakeRunner();
      final watcher = _watcher(
        runner: runner,
        gateway: _FakeGateway(<String?>['com.a', 'com.b']),
      );
      final events = <ForegroundEvent>[];
      watcher.events.listen(events.add);

      watcher.start();
      async.flushMicrotasks();
      expect(events.length, 1);

      unawaited(watcher.dispose());
      async.flushMicrotasks();
      final polls = runner.dumpsysCalls;
      final emitted = events.length;

      async.elapse(const Duration(seconds: 60));
      async.flushMicrotasks();
      expect(runner.dumpsysCalls, polls, reason: 'dispose 后不得再轮询');
      expect(events.length, emitted, reason: 'dispose 后不得再发事件');
      expect(watcher.status, ForegroundWatcherStatus.disposed);
      expect(watcher.isRunning, isFalse);
    });
  });

  test('dispose 幂等；dispose 后 start 为 no-op', () {
    fakeAsync((async) {
      final runner = _FakeRunner();
      final watcher = _watcher(
        runner: runner,
        gateway: _FakeGateway(<String?>['com.a']),
      );
      unawaited(watcher.dispose());
      unawaited(watcher.dispose());
      async.flushMicrotasks();

      watcher.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(runner.commands, isEmpty);
      expect(watcher.status, ForegroundWatcherStatus.disposed);
    });
  });

  test('Shizuku 不可用 → disabled + 结构化原因 + 零命令', () {
    fakeAsync((async) {
      final runner = _FakeRunner();
      final watcher = _watcher(
        runner: runner,
        gateway: _FakeGateway(<String?>['com.a']),
        shizuku: () async => false,
      );

      watcher.start();
      async.flushMicrotasks();
      expect(watcher.status, ForegroundWatcherStatus.disabled);
      expect(
        watcher.disabledReason,
        ForegroundDisabledReason.shizukuUnavailable,
      );
      expect(runner.commands, isEmpty, reason: '不可用时零轮询');

      async.elapse(const Duration(seconds: 60));
      async.flushMicrotasks();
      expect(runner.commands, isEmpty, reason: 'disabled 后零轮询');
      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('熄屏 → 暂停轮询（零前台命令）；亮屏 → 自动恢复', () {
    fakeAsync((async) {
      final runner = _FakeRunner();
      var screenOn = false;
      final watcher = _watcher(
        runner: runner,
        gateway: _FakeGateway(<String?>['com.a']),
        screen: () async => screenOn,
      );

      watcher.start();
      async.flushMicrotasks();
      expect(watcher.status, ForegroundWatcherStatus.paused);
      expect(runner.dumpsysCalls, 0, reason: '熄屏不得进行前台轮询');

      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(runner.dumpsysCalls, 0, reason: '持续熄屏 → 零前台轮询');

      screenOn = true;
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(watcher.status, ForegroundWatcherStatus.running);
      expect(runner.dumpsysCalls, greaterThan(0));
      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('轮询挂起时控制写不饿死：串行执行 + 顺序正确 + 不堆叠', () {
    fakeAsync((async) {
      final runner = _SerialRunner();
      final gateway = _FakeGateway(<String?>['com.a']);
      final shell = PrivilegedShell(
        runner: runner.run,
        timeout: const Duration(seconds: 120),
      );
      final watcher = ForegroundWatcher(
        module: PerfModule(gateway: gateway),
        shell: shell,
        screenOnProbe: () async => true,
        shizukuProbe: () async => true,
        interval: const Duration(seconds: 5),
        maxPollBudget: const Duration(seconds: 60),
      );

      watcher.start();
      async.flushMicrotasks();
      // 第一拍 dumpsys 已开始并挂起。
      expect(runner.started.length, 1);
      expect(
        runner.started.first,
        contains('dumpsys activity activities'),
      );

      // 轮询挂起期间经同一单线程 executor 发出控制写。
      PrivilegedResult? writeResult;
      shell
          .write(
            path: '/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor',
            value: 'performance',
          )
          .then((r) => writeResult = r);
      async.flushMicrotasks();

      expect(runner.enqueued.length, 2);
      expect(runner.enqueued[1], contains('scaling_governor'));
      expect(runner.started.length, 1, reason: '单线程 executor 串行');

      // 多拍过去：单飞守卫阻止监视器继续堆命令。
      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(runner.enqueued.length, 2, reason: '监视器不得堆叠特权命令');

      // 完成第一拍 → 控制写紧接着执行（未被饿死）。
      runner.complete(
        0,
        'ResumedActivity: ActivityRecord{com.a/.Main t1}\n'
        'GSTORE_RESULT ok=1',
      );
      async.flushMicrotasks();
      expect(runner.started.length, 2);
      expect(runner.started[1], contains('scaling_governor'));

      runner.complete(1, 'GSTORE_RESULT ok=1');
      async.flushMicrotasks();
      expect(writeResult?.ok, isTrue);
      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('单次轮询超预算 → 跳过且不崩溃，下一拍可恢复', () {
    fakeAsync((async) {
      final runner = _FakeRunner();
      final gateway = _FakeGateway(<String?>['com.a'])..hang = true;
      final watcher = _watcher(
        runner: runner,
        gateway: gateway,
        budget: const Duration(seconds: 2),
      );
      final events = <ForegroundEvent>[];
      watcher.events.listen(events.add);

      watcher.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2)); // module 挂起 → 超预算
      async.flushMicrotasks();
      expect(events, isEmpty);
      expect(watcher.skippedCount, greaterThan(0));

      gateway.hang = false;
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(events.map((e) => e.package).toList(), <String?>['com.a']);
      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('连续失败达上限 → disabled，之后零轮询', () {
    fakeAsync((async) {
      final runner = _FakeRunner()..failDumpsys = true;
      final watcher = _watcher(
        runner: runner,
        gateway: _FakeGateway(<String?>['com.a']),
        maxFailures: 3,
      );

      watcher.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();

      expect(watcher.status, ForegroundWatcherStatus.disabled);
      expect(
        watcher.disabledReason,
        ForegroundDisabledReason.shizukuUnavailable,
      );
      final polls = runner.dumpsysCalls;
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(runner.dumpsysCalls, polls, reason: 'disabled 后零轮询');
      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('命令自限时 + 当前 dumpsys 原文转发给 perf.foreground', () {
    fakeAsync((async) {
      final runner = _FakeRunner();
      final gateway = _FakeGateway(<String?>['com.a']);
      final watcher = _watcher(runner: runner, gateway: gateway);

      watcher.start();
      async.flushMicrotasks();

      expect(runner.commands, isNotEmpty);
      expect(runner.commands.first, startsWith('timeout '));
      expect(runner.commands.first, contains('sh -c'));
      expect(runner.commands.first, contains('dumpsys activity activities'));
      expect(runner.commands.first, contains('GSTORE_RESULT'));
      expect(gateway.activityTexts.single, contains('com.a'));
      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('默认屏幕探测：dumpsys power 报 Asleep → 暂停（零前台轮询）', () {
    fakeAsync((async) {
      final runner = _FakeRunner()..powerOutput = 'mWakefulness=Asleep';
      final watcher = ForegroundWatcher(
        module: PerfModule(gateway: _FakeGateway(<String?>['com.a'])),
        shell: PrivilegedShell(
          runner: runner.run,
          timeout: const Duration(seconds: 60),
        ),
        shizukuProbe: () async => true,
        interval: const Duration(seconds: 5),
      );

      watcher.start();
      async.flushMicrotasks();
      expect(
        runner.commands.any((c) => c.contains('dumpsys power')),
        isTrue,
      );
      expect(runner.dumpsysCalls, 0);
      expect(watcher.status, ForegroundWatcherStatus.paused);
      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('间隔钳制 ≥ 遥测间隔与下限', () {
    final clamped = _watcher(
      runner: _FakeRunner(),
      gateway: _FakeGateway(<String?>[]),
      interval: const Duration(seconds: 1),
      telemetry: const Duration(seconds: 10),
    );
    expect(clamped.interval, const Duration(seconds: 10));

    final floored = _watcher(
      runner: _FakeRunner(),
      gateway: _FakeGateway(<String?>[]),
      interval: const Duration(milliseconds: 100),
      telemetry: const Duration(milliseconds: 100),
    );
    expect(floored.interval, ForegroundWatcher.minPollInterval);
  });

  test('stop 后停止轮询且可再次启动', () {
    fakeAsync((async) {
      final runner = _FakeRunner();
      final watcher = _watcher(
        runner: runner,
        gateway: _FakeGateway(<String?>['com.a']),
      );

      watcher.start();
      async.flushMicrotasks();
      final polls = runner.dumpsysCalls;
      watcher.stop();
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(runner.dumpsysCalls, polls);
      expect(watcher.status, ForegroundWatcherStatus.idle);

      watcher.start();
      async.flushMicrotasks();
      expect(runner.dumpsysCalls, greaterThan(polls));
      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('parseScreenOn', () {
    expect(ForegroundWatcher.parseScreenOn('mWakefulness=Awake'), isTrue);
    expect(ForegroundWatcher.parseScreenOn('mWakefulness=Asleep'), isFalse);
    expect(ForegroundWatcher.parseScreenOn('mWakefulness=Dozing'), isFalse);
    expect(ForegroundWatcher.parseScreenOn('Display Power: state=ON'), isTrue);
    expect(ForegroundWatcher.parseScreenOn('Display Power: state=OFF'), isFalse);
    expect(ForegroundWatcher.parseScreenOn('mScreenOn=true'), isTrue);
    expect(ForegroundWatcher.parseScreenOn('mScreenOn=false'), isFalse);
    expect(ForegroundWatcher.parseScreenOn('unparseable'), isTrue);
  });
}
