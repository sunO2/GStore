import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/privileged_shell.dart';

/// 记录命令并返回罐头输出的假 [CommandRunner]（**不触碰真实 Shizuku**）。
class _RecordingRunner {
  _RecordingRunner(this._responder);

  final Future<String?> Function(String command) _responder;
  final List<String> commands = <String>[];

  Future<String?> run(String command) {
    commands.add(command);
    return _responder(command);
  }
}

/// 白名单内的一个真实路径（cpu0 的 scaling_max_freq）。
const String _allowedCpuPath =
    '/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq';

/// 白名单外的「近似路径」（scaling_cur_freq 不在 tunables 写白名单里）。
const String _nonAllowlistedCpuPath =
    '/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq';

PrivilegedShell _shellReturning(String? output) {
  final runner = _RecordingRunner((_) async => output);
  return PrivilegedShell(runner: runner.run);
}

void main() {
  group('命令拼装与哨兵（&&/|| 而非 ;）', () {
    test('chainSentinel 用 &&/|| 链哨兵，绝不用 ;', () {
      final chained = PrivilegedShell.chainSentinel('printf x > /path');
      expect(
        chained,
        'printf x > /path && echo GSTORE_RESULT ok=1 '
        '|| echo GSTORE_RESULT err=\$?',
      );
      expect(chained.contains('; echo'), isFalse);
    });

    test('buildWriteCommand 以 timeout 开头并链哨兵', () {
      final shell = _shellReturning('GSTORE_RESULT ok=1');
      final built = shell.buildWriteCommand(path: _allowedCpuPath, value: '1');

      expect(built.startsWith('timeout '), isTrue);
      expect(
        built.contains(
          '&& echo GSTORE_RESULT ok=1 || echo GSTORE_RESULT err=\$?',
        ),
        isTrue,
      );
      // 输出经单引号包裹传给内层 `sh -c`，`$?` 留给内层求值。
      expect(built.contains("sh -c '"), isTrue);
    });

    test('buildReadCommand 同样自限时', () {
      final shell = _shellReturning('0');
      final built = shell.buildReadCommand(path: _allowedCpuPath);
      expect(built.startsWith('timeout '), isTrue);
      expect(built, contains(_allowedCpuPath));
    });

    test('`; echo ok=1` 变体不是 builder 的产物（防假成功回归）', () {
      final shell = _shellReturning('GSTORE_RESULT ok=1');
      final built = shell.buildWriteCommand(path: _allowedCpuPath, value: '1');

      // 危险写法：写失败也会无条件打印 ok=1 → 解析器会误判成功。
      expect(PrivilegedResult.fromOutput('GSTORE_RESULT ok=1').ok, isTrue);
      // 但 builder 从不产出该写法：只产出 &&/|| 链。
      expect(RegExp(r'; echo GSTORE_RESULT ok=1').hasMatch(built), isFalse);
      expect(RegExp(r'&& echo GSTORE_RESULT ok=1').hasMatch(built), isTrue);
    });
  });

  group('结果解析：取最后一条哨兵', () {
    test('ok=1 → 成功', () {
      final result = PrivilegedResult.fromOutput('noise\nGSTORE_RESULT ok=1');
      expect(result.ok, isTrue);
      expect(result.error, isNull);
      expect(result.exitHint, isNull);
    });

    test('err=<n> → 失败 + exitHint（非退出码）', () {
      final result = PrivilegedResult.fromOutput('denied\nGSTORE_RESULT err=13');
      expect(result.ok, isFalse);
      expect(result.error, PrivilegedError.commandFailed);
      expect(result.exitHint, 13);
    });

    test('多个哨兵 → 最后一条生效（先 ok 后 err 判为失败）', () {
      final result = PrivilegedResult.fromOutput(
        'GSTORE_RESULT ok=1\nsomething\nGSTORE_RESULT err=1',
      );
      expect(result.ok, isFalse);
      expect(result.exitHint, 1);
    });

    test('缺哨兵 → sentinel_missing', () {
      final result = PrivilegedResult.fromOutput('just some output\n');
      expect(result.ok, isFalse);
      expect(result.error, PrivilegedError.sentinelMissing);
    });
  });

  group('执行入口（注入假 runner）', () {
    test('fake runner 被使用且无需真实 Shizuku；happy write → ok:true', () async {
      final runner = _RecordingRunner((_) async => 'GSTORE_RESULT ok=1');
      final shell = PrivilegedShell(runner: runner.run);

      final result = await shell.write(path: _allowedCpuPath, value: '1800000');

      expect(result.ok, isTrue);
      expect(runner.commands, hasLength(1));
      expect(runner.commands.single.startsWith('timeout '), isTrue);
      expect(runner.commands.single, contains(_allowedCpuPath));
    });

    test('模拟写被拒（err=）→ ok:false', () async {
      final shell = _shellReturning(
        'sh: write error: Permission denied\nGSTORE_RESULT err=1',
      );
      final result = await shell.write(path: _allowedCpuPath, value: '1');
      expect(result.ok, isFalse);
      expect(result.error, PrivilegedError.commandFailed);
      expect(result.exitHint, 1);
    });

    test('read happy → ok:true', () async {
      final runner = _RecordingRunner(
        (_) async => '1800000\nGSTORE_RESULT ok=1',
      );
      final shell = PrivilegedShell(runner: runner.run);
      final result = await shell.read(path: _allowedCpuPath);
      expect(result.ok, isTrue);
      expect(runner.commands.single, startsWith('timeout '));
    });

    test('runner 返回 null → no_output', () async {
      final shell = PrivilegedShell(runner: (_) async => null);
      final result = await shell.write(path: _allowedCpuPath, value: '1');
      expect(result.ok, isFalse);
      expect(result.error, PrivilegedError.noOutput);
    });

    test('runner 抛异常 → 结构化 execution_error（绝不抛出）', () async {
      final shell = PrivilegedShell(
        runner: (_) async => throw StateError('boom'),
      );
      final result = await shell.write(path: _allowedCpuPath, value: '1');
      expect(result.ok, isFalse);
      expect(result.error, PrivilegedError.executionError);
    });
  });

  group('超时：自限时 + 结构化失败', () {
    test('hung 命令 → timeout，且命令以 timeout 自限时', () async {
      final runner = _RecordingRunner((_) => Completer<String?>().future);
      final shell = PrivilegedShell(
        runner: runner.run,
        timeout: const Duration(milliseconds: 50),
      );

      final result = await shell.write(path: _allowedCpuPath, value: '1');

      expect(result.ok, isFalse);
      expect(result.error, PrivilegedError.timeout);
      // 自限时证明：即便 Dart 侧放弃等待，内层 `timeout` 也会让原生进程退出。
      expect(runner.commands.single.startsWith('timeout '), isTrue);
    });
  });

  group('注入负数：invalid_arg 且零命令执行', () {
    test('白名单外路径被拒', () async {
      final runner = _RecordingRunner((_) async => 'GSTORE_RESULT ok=1');
      final shell = PrivilegedShell(runner: runner.run);

      final result = await shell.write(path: _nonAllowlistedCpuPath, value: '1');

      expect(result.error, PrivilegedError.invalidArg);
      expect(result.ok, isFalse);
      expect(runner.commands, isEmpty);
    });

    test('非 sysfs 路径（/etc/passwd）被拒', () async {
      final runner = _RecordingRunner((_) async => 'GSTORE_RESULT ok=1');
      final shell = PrivilegedShell(runner: runner.run);

      final result = await shell.read(path: '/etc/passwd');

      expect(result.error, PrivilegedError.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('值 `1 && rm -rf /` 被拒', () async {
      final runner = _RecordingRunner((_) async => 'GSTORE_RESULT ok=1');
      final shell = PrivilegedShell(runner: runner.run);

      final result = await shell.write(path: _allowedCpuPath, value: '1 && rm -rf /');

      expect(result.error, PrivilegedError.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('包名 `x; pm uninstall y` 被拒', () {
      final runner = _RecordingRunner((_) async => 'GSTORE_RESULT ok=1');
      final shell = PrivilegedShell(runner: runner.run);

      final result = shell.validatePackage('x; pm uninstall y');

      expect(result, isNotNull);
      expect(result!.error, PrivilegedError.invalidArg);
      expect(runner.commands, isEmpty);
    });

    test('数值非整数被拒 / 反引号 token 被拒', () {
      final shell = PrivilegedShell(runner: (_) async => 'x');
      expect(shell.validateValue('abc', numeric: true)!.error,
          PrivilegedError.invalidArg);
      expect(shell.validateValue('1`whoami`')!.error, PrivilegedError.invalidArg);
      expect(shell.validateValue(r'$HOME')!.error, PrivilegedError.invalidArg);
      expect(shell.validateValue('a\nb')!.error, PrivilegedError.invalidArg);
    });

    test('白名单内路径通过校验（对照）', () {
      final shell = PrivilegedShell(runner: (_) async => 'x');
      expect(shell.validateSysfsPath(_allowedCpuPath), isNull);
      expect(shell.validatePackage('com.example.app'), isNull);
      expect(shell.validateValue('1800000', numeric: true), isNull);
    });
  });

  group('白名单可配置（供后续 Todo 复用）', () {
    test('自定义白名单只放行传入的模式', () {
      final validator = PrivilegedInputValidator(
        sysfsPatterns: const <String>['/sys/class/devfreq/*/min_freq'],
      );
      final shell = PrivilegedShell(runner: (_) async => 'x', validator: validator);
      expect(shell.validateSysfsPath('/sys/class/devfreq/5000000.gpu/min_freq'),
          isNull);
      expect(shell.validateSysfsPath(_allowedCpuPath), isNotNull);
    });
  });
}
