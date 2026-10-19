import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/control_refresh_rate.dart';
import 'package:gstore/core/perf/privileged_shell.dart';

class _FakeShell {
  _FakeShell({this.dumpsysOutput});

  final List<String> commands = <String>[];
  final String? dumpsysOutput;

  Future<String?> run(String command) async {
    commands.add(command);
    if (command.contains('dumpsys display')) {
      final output = dumpsysOutput;
      return '${output ?? ''}\nGSTORE_RESULT ok=1';
    }
    if (command.contains('settings get system min_refresh_rate')) {
      return '60\nGSTORE_RESULT ok=1';
    }
    if (command.contains('settings get system peak_refresh_rate')) {
      return '120\nGSTORE_RESULT ok=1';
    }
    return 'GSTORE_RESULT ok=1';
  }
}

RefreshRateController _controller(
  _FakeShell shell, {
  Future<List<int>> Function()? levelsProvider,
}) =>
    RefreshRateController(
      shell: PrivilegedShell(runner: shell.run),
      levelsProvider: levelsProvider,
    );

void main() {
  group('RefreshRateController · levelsProvider seam', () {
    test('注入 levelsProvider 时使用它，且不执行 dumpsys display', () async {
      final shell = _FakeShell(dumpsysOutput: 'refreshRate=30.0');
      final controller = _controller(shell, levelsProvider: () async {
        return <int>[120, 60, 90, 120];
      });

      final state = await controller.read();

      expect(state.available, isTrue);
      expect(state.levels, equals(<int>[60, 90, 120]));
      expect(
        shell.commands.any((command) => command.contains('dumpsys display')),
        isFalse,
      );
    });

    test('levelsProvider 为空 → 回退 dumpsys display 解析', () async {
      final shell = _FakeShell(dumpsysOutput: 'refreshRate=90.0 refreshRate=144.0');
      final controller = _controller(shell);

      final state = await controller.read();

      expect(state.levels, containsAll(<int>[90, 144]));
      expect(
        shell.commands.any((command) => command.contains('dumpsys display')),
        isTrue,
      );
    });

    test('levelsProvider 返回空列表 → 回退 dumpsys display', () async {
      final shell = _FakeShell(dumpsysOutput: 'refreshRate=90.0');
      final controller =
          _controller(shell, levelsProvider: () async => const <int>[]);

      final state = await controller.read();

      expect(state.levels, contains(90));
      expect(
        shell.commands.any((command) => command.contains('dumpsys display')),
        isTrue,
      );
    });

    test('levelsProvider 抛异常 → 回退 dumpsys display（绝不抛出）', () async {
      final shell = _FakeShell(dumpsysOutput: 'refreshRate=120.0');
      final controller = _controller(
        shell,
        levelsProvider: () async => throw StateError('bridge down'),
      );

      final state = await controller.read();

      expect(state.available, isTrue);
      expect(state.levels, contains(120));
    });

    test('levelsProvider 越界值被过滤；全越界 → 回退 dumpsys', () async {
      final shell = _FakeShell(dumpsysOutput: 'refreshRate=60.0');
      final controller =
          _controller(shell, levelsProvider: () async => <int>[5, 1000]);

      final state = await controller.read();

      expect(state.levels, contains(60));
      expect(state.levels, isNot(contains(5)));
      expect(state.levels, isNot(contains(1000)));
    });
  });
}
