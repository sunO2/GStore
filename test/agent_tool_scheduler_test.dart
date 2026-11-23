import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_tool_scheduler.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';

void main() {
  group('AgentToolScheduler', () {
    test('只读且不同名 → 并行，返回顺序不变', () async {
      var active = 0;
      var peak = 0;
      final done = <int>[];
      final result = await AgentToolScheduler.run<int>(
        count: 3,
        parallelSafe: (_) => true,
        groupKey: (i) => 'tool$i',
        execute: (i) async {
          active++;
          peak = math.max(peak, active);
          await Future<void>.delayed(const Duration(milliseconds: 15));
          active--;
          done.add(i);
          return i * 10;
        },
      );
      expect(result, [0, 10, 20]);
      expect(peak, 3, reason: '三个只读工具应同时执行');
      expect(done.length, 3);
    });

    test('同名只读 → 串行（避免 executionId 冲突）', () async {
      var active = 0;
      var peak = 0;
      final result = await AgentToolScheduler.run<int>(
        count: 2,
        parallelSafe: (_) => true,
        groupKey: (_) => 'sameTool',
        execute: (i) async {
          active++;
          peak = math.max(peak, active);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          active--;
          return i;
        },
      );
      expect(result, [0, 1]);
      expect(peak, 1);
    });

    test('混合：只读并行、写操作串行且最后执行', () async {
      final events = <String>[];
      final result = await AgentToolScheduler.run<int>(
        count: 4,
        parallelSafe: (i) => i < 2,
        groupKey: (i) => 't$i',
        execute: (i) async {
          events.add('start$i');
          await Future<void>.delayed(const Duration(milliseconds: 10));
          events.add('end$i');
          return i;
        },
      );
      expect(result, [0, 1, 2, 3]);
      // 0/1 并发：两个 start 都在 end 之前
      expect(events.indexOf('start0'), lessThan(events.indexOf('end1')));
      // 写操作在只读批次结束后才开始
      expect(events.indexOf('start2'), greaterThan(events.indexOf('end0')));
      expect(events.indexOf('start2'), greaterThan(events.indexOf('end1')));
    });
  });

  group('工具只读标记', () {
    test('searchApp/getAppInfo 只读；configManager 按 action 判定', () {
      expect(AgentToolCatalog.byName('searchApp')!.readOnly, true);
      expect(AgentToolCatalog.byName('getAppInfo')!.readOnly, true);

      final config = AgentToolCatalog.byName('configManager')!;
      expect(config.isReadOnlyCall({'action': 'list'}), true);
      expect(config.isReadOnlyCall({'action': 'get'}), true);
      expect(config.isReadOnlyCall({'action': 'set'}), false);
      expect(config.isReadOnlyCall({'action': 'clear'}), false);
    });

    test('下载/安装/备份等写操作默认不并行', () {
      for (final name in ['downloadApp', 'installApp', 'backup', 'remember']) {
        final spec = AgentToolCatalog.byName(name)!;
        expect(spec.isReadOnlyCall({}), false, reason: name);
      }
    });
  });
}
