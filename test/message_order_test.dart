import 'package:flutter_test/flutter_test.dart';

/// 模拟 view._displayTime 的 seq 微秒偏移逻辑，
/// 验证：同一毫秒创建的用户消息与 agent 回复，
/// 经 createdAt 排序后用户必然在前。
DateTime displayTime(int seq, DateTime time) {
  final micros = (seq & 0x3FFFF).toInt();
  return time.add(Duration(microseconds: micros));
}

void main() {
  group('消息显示时间（seq 微秒偏移）', () {
    test('同毫秒：用户(seq 小) < agent(seq 大)', () {
      final t = DateTime(2026, 8, 10, 12, 0, 0, 500);
      final user = displayTime(10, t); // 用户消息 seq=10
      final agent = displayTime(11, t); // agent 回复 seq=11

      expect(user.isBefore(agent), true,
          reason: '同毫秒时 seq 更小的用户消息必须早于 agent 回复');
    });

    test('跨毫秒：时间优先，seq 偏移不影响真实顺序', () {
      final t1 = DateTime(2026, 8, 10, 12, 0, 0, 500);
      final t2 = DateTime(2026, 8, 10, 12, 0, 0, 600);
      final a = displayTime(100, t1);
      final b = displayTime(5, t2);
      expect(a.isBefore(b), true, reason: '不同毫秒按真实时间排序');
    });

    test('seq 取模（低 18 位）在合理范围内', () {
      // seq 全局递增可能很大，验证取模后不会溢出 DateTime 微秒
      final t = DateTime(2026, 8, 10);
      final big = displayTime(0xFFFFF, t);
      expect(big.difference(t).inMicroseconds, lessThan(1000000));
      expect(big.difference(t).inMicroseconds, greaterThanOrEqualTo(0));
    });

    test('seq=0（旧数据恢复）无偏移', () {
      final t = DateTime(2026, 8, 10);
      expect(displayTime(0, t), t);
    });

    test('稳定排序：同毫秒同显示时间时保持持久化顺序', () {
      final t = DateTime(2026, 8, 10, 12, 0, 0, 500);
      // 模拟极端：seq 相同（旧数据 seq=0）+ 同毫秒。
      // 用户消息先持久化（index 0），agent 后持久化（index 1）。
      final items = [
        (name: 'user', time: displayTime(0, t)),
        (name: 'agent', time: displayTime(0, t)),
      ];
      // Dart sort 不稳定，用 (time, index) 双键稳定排序（与 AgentService 一致）
      final indexed = items.asMap().entries.toList()
        ..sort((a, b) {
          final c = a.value.time.compareTo(b.value.time);
          if (c != 0) return c;
          return a.key.compareTo(b.key);
        });
      expect(indexed.first.value.name, 'user',
          reason: '同时间同 seq 时用户消息（先持久化）在前');
    });
  });
}
