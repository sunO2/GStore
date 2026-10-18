import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 记录命令 + 返回罐头输出的假 runner（**不触碰真实 Shizuku / 真机**）。
///
/// * `pidof <pkg>` → [pidof];  `pidof` 失败由 [pidofOk] 控制；
/// * `test -w <path>` → 仅 [writable] 命中返回成功哨兵；
/// * `cat <path>` → [nodes]（原始文件）或 [tasks]（pid 表）；
/// * `printf %s <v> > <path>` → 仅 [writable] 命中才接受，并把它并入 [tasks]。
class _FakeRunner {
  _FakeRunner({
    this.writable = const <String>[],
    this.nodes = const <String, String>{},
    Map<String, List<int>> tasks = const <String, List<int>>{},
    this.pidof = const <int>[],
    this.pidofOk = true,
    this.hangOnProbe = false,
  }) : tasks = <String, List<int>>{
          for (final entry in tasks.entries) entry.key: List<int>.of(entry.value),
        };

  final List<String> writable;
  final Map<String, String> nodes;
  final Map<String, List<int>> tasks;
  final List<int> pidof;
  final bool pidofOk;
  final bool hangOnProbe;
  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);

    final pidofMatch = RegExp(r'pidof (\S+)').firstMatch(command);
    if (pidofMatch != null) {
      if (!pidofOk) return 'GSTORE_RESULT err=1';
      return '${pidof.join(' ')}\nGSTORE_RESULT ok=1';
    }

    final writeMatch = RegExp(r'printf %s (\S+) > (\S+)').firstMatch(command);
    if (writeMatch != null) {
      final value = int.parse(writeMatch.group(1)!);
      final path = writeMatch.group(2)!;
      if (!writable.contains(path)) return 'GSTORE_RESULT err=1';
      final list = tasks.putIfAbsent(path, () => <int>[]);
      if (!list.contains(value)) list.add(value);
      return 'GSTORE_RESULT ok=1';
    }

    final probeMatch = RegExp(r'test -w (\S+)').firstMatch(command);
    if (probeMatch != null) {
      if (hangOnProbe) return Completer<String?>().future; // 永不返回 → Dart 侧超时
      final path = probeMatch.group(1)!;
      return writable.contains(path)
          ? 'GSTORE_RESULT ok=1'
          : 'GSTORE_RESULT err=1';
    }

    final catMatch = RegExp(r'cat (\S+)').firstMatch(command);
    if (catMatch != null) {
      final path = catMatch.group(1)!;
      if (nodes.containsKey(path)) {
        return '${nodes[path]}\nGSTORE_RESULT ok=1';
      }
      if (tasks.containsKey(path)) {
        return '${(tasks[path] ?? const <int>[]).join('\n')}\nGSTORE_RESULT ok=1';
      }
      return 'GSTORE_RESULT err=1';
    }

    return 'GSTORE_RESULT err=1';
  }
}

/// 假 perf 网关：对任意方法返回罐头 `{ok:true,data:{...}}`。
class _FakeGateway implements PerfModuleGateway {
  _FakeGateway([this.responses = const <String, Map<String, dynamic>>{}]);

  final Map<String, Map<String, dynamic>> responses;

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    final data = responses[method] ?? const <String, dynamic>{};
    return Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );
  }

  @override
  Stream<PerfRawEvent> get events => const Stream<PerfRawEvent>.empty();
}

CpusetController _controller(_FakeRunner runner, {PerfModule? module}) =>
    CpusetController(
      shell: PrivilegedShell(runner: runner.run),
      perfModule: module ?? PerfModule(gateway: _FakeGateway()),
    );

const String _tasks = '/dev/cpuset/top-app/tasks';
const String _cpus = '/dev/cpuset/top-app/cpus';

void main() {
  group('CpusetController.applyCpuset', () {
    test('happy: resolvable pid + writable cpuset → applied + read-back ok', () async {
      final runner = _FakeRunner(
        writable: const <String>[_tasks],
        nodes: const <String, String>{_cpus: '0-7'},
        tasks: const <String, List<int>>{_tasks: <int>[1]},
        pidof: const <int>[1234],
      );
      final result = await _controller(runner)
          .applyCpuset(pkgOrPid: 'com.example.app', cpuset: 'top-app');

      expect(result.ok, isTrue);
      expect(result.status, kCpusetStatusApplied);
      expect(result.appliedPids, equals(<int>[1234]));
      // 回读确认：写命令确实发过，且 tasks 现含 1234。
      expect(runner.commands.where((c) => c.contains('printf %s 1234 >')), isNotEmpty);
      expect(result.originals[_cpus], equals('0-7'));
      // 每条命令都自限时（toybox timeout）。
      expect(
        runner.commands.every((c) => c.startsWith('timeout ') && c.contains('sh -c')),
        isTrue,
      );
      debugPrint('HAPPY ${jsonEncode(result.toJson())}');
    });

    test('not_found: unknown package → structured not_found, zero writes', () async {
      final runner = _FakeRunner(pidofOk: false, writable: const <String>[_tasks]);
      final result = await _controller(runner)
          .applyCpuset(pkgOrPid: 'com.unknown.app', cpuset: 'top-app');

      expect(result.ok, isFalse);
      expect(result.status, CpusetError.notFound);
      expect(result.appliedPids, isEmpty);
      // 零写入、零探测（解析失败即返回）。
      expect(runner.commands.where((c) => c.contains('printf')), isEmpty);
      expect(runner.commands.where((c) => c.contains('test -w')), isEmpty);
      expect(
        runner.commands.where((c) => c.contains('pidof com.unknown.app')),
        isNotEmpty,
      );
      debugPrint('FAILURE ${jsonEncode(result.toJson())}');
    });

    test('not_found fallback: pidof fails and PerfModule.processes empty', () async {
      final runner = _FakeRunner(pidofOk: false);
      final module = PerfModule(
        gateway: _FakeGateway(<String, Map<String, dynamic>>{
          'perf.processes': <String, dynamic>{
            'total': 0,
            'sort': 'cpu',
            'processes': <dynamic>[],
          },
        }),
      );
      final result = await _controller(runner, module: module)
          .applyCpuset(pkgOrPid: 'com.absent.app', cpuset: 'background');

      expect(result.status, CpusetError.notFound);
      expect(runner.commands.where((c) => c.contains('printf')), isEmpty);
    });

    test('PerfModule.processes fallback resolves pid when pidof empty', () async {
      final runner = _FakeRunner(
        writable: const <String>[_tasks],
        tasks: const <String, List<int>>{_tasks: <int>[1]},
      );
      final module = PerfModule(
        gateway: _FakeGateway(<String, Map<String, dynamic>>{
          'perf.processes': <String, dynamic>{
            'total': 1,
            'sort': 'cpu',
            'processes': <dynamic>[
              <String, dynamic>{'pid': 4242, 'name': 'com.fallback.app'},
            ],
          },
        }),
      );
      final result = await _controller(runner, module: module)
          .applyCpuset(pkgOrPid: 'com.fallback.app', cpuset: 'top-app');

      expect(result.ok, isTrue);
      expect(result.appliedPids, equals(<int>[4242]));
    });

    test('unavailable: cpuset tasks not writable → zero writes', () async {
      final runner = _FakeRunner(
        writable: const <String>[], // test -w 全部失败
        pidof: const <int>[1234],
      );
      final result = await _controller(runner)
          .applyCpuset(pkgOrPid: 'com.example.app', cpuset: 'top-app');

      expect(result.ok, isFalse);
      expect(result.status, CpusetError.unavailable);
      expect(runner.commands.where((c) => c.contains('printf')), isEmpty);
      expect(
        runner.commands.where((c) => c.contains('test -w $_tasks')),
        isNotEmpty,
      );
    });

    test('malformed package → invalid_arg with zero commands', () async {
      final runner = _FakeRunner();
      final result = await _controller(runner)
          .applyCpuset(pkgOrPid: 'com.bad app', cpuset: 'top-app');

      expect(result.status, CpusetError.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('injection package → invalid_arg with zero commands', () async {
      final runner = _FakeRunner();
      final result = await _controller(runner).applyCpuset(
        pkgOrPid: 'com.x;rm -rf /data',
        cpuset: 'top-app',
      );

      expect(result.status, CpusetError.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('malformed cpuset name (traversal) → invalid_arg, zero commands', () async {
      final runner = _FakeRunner();
      final result = await _controller(runner)
          .applyCpuset(pkgOrPid: 'com.example.app', cpuset: '../../etc');

      expect(result.status, CpusetError.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('cpuset name with injection token → invalid_arg, zero commands', () async {
      final runner = _FakeRunner();
      final result = await _controller(runner)
          .applyCpuset(pkgOrPid: 'com.example.app', cpuset: 'top-app;sh');

      expect(result.status, CpusetError.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('critical system daemon → refused_critical, zero commands', () async {
      final runner = _FakeRunner();
      final result = await _controller(runner).applyCpuset(
        pkgOrPid: 'com.android.systemui',
        cpuset: 'top-app',
      );

      expect(result.status, CpusetError.refusedCritical);
      expect(runner.commands, isEmpty);
    });

    test('pid literal 1 (init) → refused_critical, zero commands', () async {
      final runner = _FakeRunner();
      final result = await _controller(runner)
          .applyCpuset(pkgOrPid: '1', cpuset: 'top-app');

      expect(result.status, CpusetError.refusedCritical);
      expect(result.appliedPids, isEmpty);
      expect(runner.commands, isEmpty);
    });

    test('pid literal valid → writes that pid directly', () async {
      final runner = _FakeRunner(
        writable: const <String>[_tasks],
        tasks: const <String, List<int>>{_tasks: <int>[1]},
      );
      final result = await _controller(runner)
          .applyCpuset(pkgOrPid: '4242', cpuset: 'top-app');

      expect(result.ok, isTrue);
      expect(result.appliedPids, equals(<int>[4242]));
      expect(runner.commands.where((c) => c.contains('pidof')), isEmpty);
    });

    test('read-back mismatch → structured failure + rollback to original cpuset',
        () async {
      const original = '/dev/cpuset/foreground/tasks';
      final runner = _FakeRunner(
        writable: const <String>[_tasks, original],
        // pid 4242 当前在 foreground。
        tasks: const <String, List<int>>{
          original: <int>[4242],
          _tasks: <int>[1],
        },
        pidof: const <int>[4242],
      );
      // 用只读回读失败的假 runner：写入后 tasks 仍不含 4242（回读 mismatch）。
      Future<String?> run(String command) async {
        final out = await runner.run(command);
        if (command.contains('cat $_tasks')) {
          // 强制回读为「未包含 4242」。
          return '1\nGSTORE_RESULT ok=1';
        }
        return out;
      }

      final controller = CpusetController(
        shell: PrivilegedShell(runner: run),
        perfModule: PerfModule(gateway: _FakeGateway()),
      );
      final result = await controller
          .applyCpuset(pkgOrPid: '4242', cpuset: 'top-app');

      expect(result.ok, isFalse);
      expect(result.status, CpusetError.readbackMismatch);
      expect(result.rolledBack, isTrue);
      expect(
        runner.commands.where((c) => c.contains('printf %s 4242 > $original')),
        isNotEmpty,
      );
    });

    test('hung probe is self-bounded → unavailable, no hang in test', () async {
      final runner = _FakeRunner(
        writable: const <String>[_tasks],
        pidof: const <int>[1234],
        hangOnProbe: true,
      );
      final controller = CpusetController(
        shell: PrivilegedShell(
          runner: runner.run,
          timeout: const Duration(milliseconds: 50),
        ),
        perfModule: PerfModule(gateway: _FakeGateway()),
      );
      final result = await controller
          .applyCpuset(pkgOrPid: 'com.example.app', cpuset: 'top-app');

      expect(result.status, CpusetError.unavailable);
      expect(runner.commands.where((c) => c.contains('printf')), isEmpty);
    });
  });
}
