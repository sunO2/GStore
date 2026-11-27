import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';

AgentMessage _user(String id) =>
    AgentMessage(id: id, isUser: true, text: 'hi', seq: 1);

AgentMessage _assistant(
  String id, {
  int seq = 2,
  List<Map<String, Object?>>? a2ui,
}) =>
    AgentMessage(
      id: id,
      isUser: false,
      text: a2ui == null ? 'text' : '',
      seq: seq,
      a2uiMessages: a2ui,
      a2uiRevision: a2ui?.length ?? 0,
    );

void main() {
  group('hasRecentA2uiSurface', () {
    test('上一回合渲染过界面时返回 true', () {
      final messages = [
        _user('u1'),
        _assistant('a1', a2ui: [
          {'version': '1.0'},
        ]),
        _user('u2'), // 本回合刚加入
      ];
      expect(hasRecentA2uiSurface(messages), isTrue);
    });

    test('上一回合只有文字时返回 false', () {
      final messages = [_user('u1'), _assistant('a1'), _user('u2')];
      expect(hasRecentA2uiSurface(messages), isFalse);
    });

    test('更早回合的界面不会一直触发', () {
      final messages = [
        _user('u1'),
        _assistant('a1', a2ui: [
          {'version': '1.0'},
        ]),
        _user('u2'),
        _assistant('a2', seq: 4),
        _user('u3'),
      ];
      expect(hasRecentA2uiSurface(messages), isFalse);
    });

    test('回合内工具消息不影响判断', () {
      final messages = [
        _user('u1'),
        AgentMessage(
          id: 't1',
          isUser: false,
          text: '',
          isToolResult: true,
          toolType: AgentToolType.a2ui,
          seq: 2,
        ),
        _assistant('a1', seq: 3, a2ui: [
          {'version': '1.0'},
        ]),
        _user('u2'),
      ];
      expect(hasRecentA2uiSurface(messages), isTrue);
    });
  });
}
