import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/control_refresh_rate.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/perf/refresh_auto_engine.dart';
import 'package:gstore/core/perf/refresh_auto_store.dart';

// ==================== 假 shell（controller 侧：settings get/put） ====================

/// 模拟 `settings get/put` 的可注入 runner（记录命令 + 可变 settings 值）。
class _FakeRefreshShell {
  _FakeRefreshShell({Map<String, String>? initial, this.failAll = false})
      : values = <String, String>{
          'min_refresh_rate': '120',
          'peak_refresh_rate': '120',
          ...?initial,
        };

  final Map<String, String> values;
  final List<String> commands = <String>[];
  bool failAll;

  Iterable<String> get putCommands =>
      commands.where((c) => c.contains('settings put'));

  Future<String?> run(String command) async {
    commands.add(command);
    if (failAll) return null;
    if (command.contains('settings put')) {
      final match =
          RegExp(r'settings put system (\w+) (\d+)').firstMatch(command);
      if (match != null) values[match.group(1)!] = match.group(2)!;
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

/// 前台探测假 runner：返回当前前台包的 `topResumedActivity` 文本（`null` → 无行）。
class _ForegroundRunner {
  String? foreground = 'com.a';

  Future<String?> run(String command) async {
    final pkg = foreground;
    if (pkg == null) return 'no focus here';
    return 'topResumedActivity=ActivityRecord{123 u0 $pkg/.MainActivity t1}';
  }
}

RefreshAutoEntry _entry(String pkg, {int min = 60, int peak = 120}) =>
    RefreshAutoEntry(package: pkg, label: pkg, min: min, peak: peak);

class _Harness {
  _Harness({RefreshAutoConfig? config, bool failController = false}) {
    shell = _FakeRefreshShell(failAll: failController);
    fg = _ForegroundRunner();
    controller = RefreshRateController(shell: PrivilegedShell(runner: shell.run));
    store = InMemoryRefreshAutoStore(config);
    engine = RefreshAutoEngine(
      controller: controller,
      store: store,
      runner: fg.run,
      interval: const Duration(milliseconds: 50),
    );
  }

  late final _FakeRefreshShell shell;
  late final _ForegroundRunner fg;
  late final RefreshRateController controller;
  late final InMemoryRefreshAutoStore store;
  late final RefreshAutoEngine engine;

  int get putCount => shell.putCommands.length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseForegroundPackage', () {
    test('topResumedActivity → 包名', () {
      expect(
        RefreshAutoEngine.parseForegroundPackage(
          'topResumedActivity=ActivityRecord{abc u0 com.a/.MainActivity t1}',
        ),
        'com.a',
      );
    });

    test('mCurrentFocus → 包名', () {
      expect(
        RefreshAutoEngine.parseForegroundPackage(
          'mCurrentFocus=Window{abc u0 com.b/com.b.MainActivity}',
        ),
        'com.b',
      );
    });

    test('无焦点 / null → null', () {
      expect(RefreshAutoEngine.parseForegroundPackage('mCurrentFocus=null'), isNull);
      expect(RefreshAutoEngine.parseForegroundPackage('random text'), isNull);
      expect(RefreshAutoEngine.parseForegroundPackage(null), isNull);
    });
  });

  group('前台变化 → 应用 / 恢复', () {
    test('前台进入已配置应用 → apply(min, peak)', () async {
      final h = _Harness(
        config: RefreshAutoConfig(
          enabled: true,
          entries: <String, RefreshAutoEntry>{
            'com.a': _entry('com.a', min: 120, peak: 120),
          },
        ),
      );

      await h.engine.pollOnce();

      expect(h.shell.values['min_refresh_rate'], '120');
      expect(h.shell.values['peak_refresh_rate'], '120');
      expect(h.engine.appliedPackage, 'com.a');
      expect(h.engine.lastStatus, RefreshRateStatus.ok);
    });

    test('同一前台包重复轮询 → 幂等，不重复写', () async {
      final h = _Harness(
        config: RefreshAutoConfig(
          enabled: true,
          entries: <String, RefreshAutoEntry>{'com.a': _entry('com.a')},
        ),
      );

      await h.engine.pollOnce();
      final afterFirst = h.putCount;
      await h.engine.pollOnce();
      await h.engine.pollOnce();

      expect(h.putCount, afterFirst);
    });

    test('切到无配置应用（有默认值）→ 恢复默认', () async {
      final h = _Harness(
        config: RefreshAutoConfig(
          enabled: true,
          defaultMin: 60,
          defaultPeak: 60,
          entries: <String, RefreshAutoEntry>{
            'com.a': _entry('com.a', min: 120, peak: 120),
          },
        ),
      );
      await h.engine.pollOnce();

      h.fg.foreground = 'com.b';
      await h.engine.pollOnce();

      expect(h.shell.values['min_refresh_rate'], '60');
      expect(h.shell.values['peak_refresh_rate'], '60');
      expect(h.engine.appliedPackage, isNull);
    });

    test('无配置且无默认值 → 保持现状（零写入）', () async {
      final h = _Harness(
        config: const RefreshAutoConfig(enabled: true),
      );
      h.fg.foreground = 'com.zzz';

      await h.engine.pollOnce();

      expect(h.putCount, 0);
      expect(h.engine.appliedPackage, isNull);
    });

    test('disable → 零写入（即使有配置）', () async {
      final h = _Harness(
        config: RefreshAutoConfig(
          enabled: false,
          entries: <String, RefreshAutoEntry>{'com.a': _entry('com.a')},
        ),
      );

      await h.engine.pollOnce();

      expect(h.putCount, 0);
      expect(h.engine.appliedPackage, isNull);
    });

    test('前台无法判定（runner 无焦点行）→ 不写', () async {
      final h = _Harness(
        config: RefreshAutoConfig(
          enabled: true,
          defaultMin: 60,
          defaultPeak: 60,
          entries: <String, RefreshAutoEntry>{'com.a': _entry('com.a')},
        ),
      );
      h.fg.foreground = null;

      await h.engine.pollOnce();

      expect(h.putCount, 0);
    });
  });

  group('失败静默 / 生命周期', () {
    test('Shizuku 不可用（controller 写失败）→ 静默，不抛', () async {
      final h = _Harness(
        config: RefreshAutoConfig(
          enabled: true,
          entries: <String, RefreshAutoEntry>{'com.a': _entry('com.a')},
        ),
        failController: true,
      );

      await expectLater(h.engine.pollOnce(), completes);
      expect(h.engine.appliedPackage, isNull);
    });

    test('前台 runner 抛异常 → 静默，不崩', () async {
      final shell = _FakeRefreshShell();
      final controller =
          RefreshRateController(shell: PrivilegedShell(runner: shell.run));
      final store = InMemoryRefreshAutoStore(
        const RefreshAutoConfig(enabled: true),
      );
      final engine = RefreshAutoEngine(
        controller: controller,
        store: store,
        runner: (command) async => throw StateError('boom'),
      );

      await expectLater(engine.pollOnce(), completes);
      engine.dispose();
    });

    test('start → 立即轮询；dispose → 停止且不再轮询', () async {
      final h = _Harness(
        config: RefreshAutoConfig(
          enabled: true,
          entries: <String, RefreshAutoEntry>{'com.a': _entry('com.a')},
        ),
      );

      h.engine.start();
      expect(h.engine.isRunning, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(h.putCount, greaterThan(0));

      h.engine.dispose();
      expect(h.engine.isRunning, isFalse);
      expect(h.engine.isDisposed, isTrue);

      final afterDispose = h.putCount;
      h.fg.foreground = 'com.b';
      await h.engine.pollOnce();
      expect(h.putCount, afterDispose);
    });
  });
}
