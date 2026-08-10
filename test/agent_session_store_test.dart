import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_session_store.dart';

void main() {
  group('SessionMessage 工具记录持久化', () {
    test('工具消息完整序列化往返', () {
      final msg = SessionMessage(
        isUser: false,
        text: '找到 3 个应用',
        isToolResult: true,
        toolType: 'search',
        toolStatus: 'done',
        toolDetail: '搜索"termux"',
      );

      final json = msg.toJson();
      expect(json['isToolResult'], true);
      expect(json['toolType'], 'search');
      expect(json['toolStatus'], 'done');
      expect(json['toolDetail'], '搜索"termux"');

      final restored = SessionMessage.fromJson(json);
      expect(restored.isToolResult, true);
      expect(restored.toolType, 'search');
      expect(restored.toolStatus, 'done');
      expect(restored.toolDetail, '搜索"termux"');
      expect(restored.text, '找到 3 个应用');
    });

    test('普通消息无工具字段', () {
      final msg = SessionMessage(isUser: true, text: '你好');
      final json = msg.toJson();
      expect(json['isToolResult'], false);
      expect(json['toolType'], isNull);
      expect(json['toolStatus'], isNull);
      expect(json['toolDetail'], isNull);

      final restored = SessionMessage.fromJson(json);
      expect(restored.isUser, true);
      expect(restored.text, '你好');
      expect(restored.toolType, isNull);
    });

    test('旧版本数据（无工具字段）兼容', () {
      // 模拟旧版本 JSON（无 toolType/toolStatus/toolDetail）
      final oldJson = {
        'isUser': false,
        'text': '结果',
        'isToolResult': true,
        'time': 1710000000000,
      };
      final restored = SessionMessage.fromJson(oldJson);
      expect(restored.isToolResult, true);
      expect(restored.toolType, isNull);
      expect(restored.toolStatus, isNull);
      expect(restored.text, '结果');
    });

    test('AgentSession 整体序列化含工具记录', () {
      final session = AgentSession(id: 's1', title: '测试会话');
      session.messages.add(SessionMessage(isUser: true, text: '帮我下载termux', seq: 0));
      session.messages.add(SessionMessage(
        isUser: false,
        text: '找到 1 个应用',
        isToolResult: true,
        toolType: 'search',
        toolStatus: 'done',
        toolDetail: '搜索"termux"',
        seq: 2,
      ));
      session.messages.add(SessionMessage(
        isUser: false,
        text: '已下载 termux',
        isToolResult: true,
        toolType: 'download',
        toolStatus: 'done',
        toolDetail: '下载 termux (0.118.1)',
        seq: 3,
      ));
      session.messages.add(SessionMessage(
        isUser: false,
        text: '已为你下载 Termux，是否安装？',
        seq: 1,
      ));

      final raw = jsonEncode(session.toJson());
      final restored = AgentSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);

      expect(restored.messages.length, 4);
      // 工具记录完整还原
      final toolMsgs = restored.messages.where((m) => m.isToolResult).toList();
      expect(toolMsgs.length, 2);
      expect(toolMsgs[0].toolType, 'search');
      expect(toolMsgs[0].toolDetail, '搜索"termux"');
      expect(toolMsgs[1].toolType, 'download');
      expect(toolMsgs[1].toolStatus, 'done');
    });

    test('seq 序列化往返并支持排序', () {
      final msgs = [
        SessionMessage(isUser: true, text: '用户问题', seq: 0, turnId: 't1'),
        SessionMessage(isUser: false, text: '工具记录', isToolResult: true,
            toolType: 'search', toolStatus: 'done', seq: 2, turnId: 't1'),
        SessionMessage(isUser: false, text: '助手回答', seq: 1, turnId: 't1'),
      ];

      // 模拟持久化顺序（工具先存，助手后存）
      final restored = msgs
          .map((m) => SessionMessage.fromJson(m.toJson()))
          .toList();
      // 按 seq 排序后，助手(1)应在工具(2)之前
      restored.sort((a, b) => a.seq.compareTo(b.seq));
      expect(restored[0].text, '用户问题');
      expect(restored[1].text, '助手回答');
      expect(restored[2].text, '工具记录');
      expect(restored[1].isToolResult, false);
      expect(restored[2].isToolResult, true);
      // turnId 往返保持
      expect(restored[0].turnId, 't1');
      expect(restored[2].turnId, 't1');
    });

    test('turnId 归属绑定：同一回合消息共享 turnId', () {
      final turnMessages = [
        SessionMessage(isUser: true, text: '帮我下载termux', turnId: 'turn-100'),
        SessionMessage(isUser: false, text: '正在搜索...', isToolResult: true,
            toolType: 'search', toolStatus: 'done', turnId: 'turn-100'),
        SessionMessage(isUser: false, text: '找到 Termux', isToolResult: true,
            toolType: 'download', toolStatus: 'done', turnId: 'turn-100'),
        SessionMessage(isUser: false, text: '已为你找到 Termux', turnId: 'turn-100'),
      ];
      // 下一回合
      final nextTurnMessages = [
        SessionMessage(isUser: true, text: '帮我备份', turnId: 'turn-101'),
        SessionMessage(isUser: false, text: '备份完成', isToolResult: true,
            toolType: 'backup', toolStatus: 'done', turnId: 'turn-101'),
      ];

      final all = [...turnMessages, ...nextTurnMessages];
      final restored = all.map((m) => SessionMessage.fromJson(m.toJson())).toList();

      // 工具消息的 turnId 与其所属回合一致
      final search = restored.firstWhere((m) => m.toolType == 'search');
      final download = restored.firstWhere((m) => m.toolType == 'download');
      final backup = restored.firstWhere((m) => m.toolType == 'backup');
      expect(search.turnId, 'turn-100');
      expect(download.turnId, 'turn-100');
      expect(backup.turnId, 'turn-101');
      // 助手回复与工具同回合
      final assistant = restored[3];
      expect(assistant.turnId, 'turn-100');
      expect(assistant.isToolResult, false);
    });

    test('旧版本数据（无 seq）默认 seq=0 不崩溃', () {
      final oldJson = {
        'isUser': true,
        'text': '旧消息',
        'isToolResult': false,
        'time': 1710000000000,
      };
      final restored = SessionMessage.fromJson(oldJson);
      expect(restored.seq, 0);
      expect(restored.text, '旧消息');
      expect(restored.turnId, isNull);
    });

    test('稳定排序：同毫秒 + 同 seq 时保持持久化顺序（用户在前）', () {
      // 模拟极端场景：用户消息与 agent 回复同一毫秒、seq 相同（旧数据 seq=0）。
      // 用户消息总是先持久化（index 更小），稳定排序应保证用户在前。
      final msgs = [
        SessionMessage(
          isUser: true, // 用户消息（先持久化，index 0）
          text: '提问',
          time: 1710000000000,
          seq: 0,
        ),
        SessionMessage(
          isUser: false, // agent 回复（后持久化，index 1）
          text: '回复',
          time: 1710000000000,
          seq: 0,
        ),
      ];
      // 与 AgentService 稳定排序一致的逻辑
      final indexed = msgs.asMap().entries.toList();
      indexed.sort((a, b) {
        final t = a.value.time.compareTo(b.value.time);
        if (t != 0) return t;
        final s = a.value.seq.compareTo(b.value.seq);
        if (s != 0) return s;
        return a.key.compareTo(b.key);
      });
      final sorted = indexed.map((e) => e.value).toList();
      expect(sorted.first.isUser, true, reason: '同毫秒同 seq 时用户消息必须在前');
      expect(sorted.last.isUser, false);
    });

    test('稳定排序：同毫秒不同 seq 时按 seq 排序', () {
      final msgs = [
        SessionMessage(isUser: true, text: '提问', time: 1710000000000, seq: 5),
        SessionMessage(isUser: false, text: '回复', time: 1710000000000, seq: 6),
      ];
      final indexed = msgs.asMap().entries.toList();
      indexed.sort((a, b) {
        final t = a.value.time.compareTo(b.value.time);
        if (t != 0) return t;
        final s = a.value.seq.compareTo(b.value.seq);
        if (s != 0) return s;
        return a.key.compareTo(b.key);
      });
      final sorted = indexed.map((e) => e.value).toList();
      expect(sorted.first.isUser, true);
    });
  });
}
