import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';

/// 模拟 _groupTimeline 的分组顺序逻辑
/// older 序列：U(用户) A(agent) T(工具) 交替
/// 期望输出：用户独立，agent+工具合成回合，顺序 U,G,U,G...
void main() {
  group('分组顺序', () {
    List<String> groupTimeline(List<({bool isUser, bool isTool, String turnId})> msgs) {
      final result = <String>[];
      var currentTurnId = '';
      var currentTurn = 0;

      void flushTurn() {
        if (currentTurn > 0) {
          result.add('G');
          currentTurn = 0;
        }
        currentTurnId = '';
      }

      for (final msg in msgs) {
        if (msg.isUser) {
          flushTurn();
          result.add('U');
        } else if (msg.isTool) {
          final turnId = msg.turnId;
          if (currentTurn > 0 && turnId != currentTurnId && turnId.isNotEmpty) {
            flushTurn();
          }
          if (currentTurnId.isEmpty) currentTurnId = turnId;
          currentTurn++;
        } else {
          final turnId = msg.turnId;
          if (currentTurn > 0 && turnId != currentTurnId && turnId.isNotEmpty) {
            flushTurn();
          }
          if (currentTurnId.isEmpty) currentTurnId = turnId;
          currentTurn++;
        }
      }
      flushTurn();
      return result;
    }

    test('标准多回合 U,A,T,U,A,T → U,G,U,G', () {
      final msgs = [
        (isUser: true, isTool: false, turnId: 't1'),
        (isUser: false, isTool: false, turnId: 't1'),
        (isUser: false, isTool: true, turnId: 't1'),
        (isUser: true, isTool: false, turnId: 't2'),
        (isUser: false, isTool: false, turnId: 't2'),
        (isUser: false, isTool: true, turnId: 't2'),
      ];
      final result = groupTimeline(msgs);
      expect(result, ['U', 'G', 'U', 'G']);
    });

    test('用户消息 turnId 为空不影响分组', () {
      final msgs = [
        (isUser: true, isTool: false, turnId: ''),
        (isUser: false, isTool: false, turnId: 't1'),
        (isUser: false, isTool: true, turnId: 't1'),
        (isUser: true, isTool: false, turnId: ''),
        (isUser: false, isTool: false, turnId: 't2'),
      ];
      final result = groupTimeline(msgs);
      expect(result, ['U', 'G', 'U', 'G']);
    });

    test('回合开头直接工具（无agent文本）', () {
      final msgs = [
        (isUser: true, isTool: false, turnId: 't1'),
        (isUser: false, isTool: true, turnId: 't1'),
        (isUser: false, isTool: false, turnId: 't1'),
        (isUser: true, isTool: false, turnId: 't2'),
      ];
      final result = groupTimeline(msgs);
      expect(result, ['U', 'G', 'U']);
    });
  });
}
