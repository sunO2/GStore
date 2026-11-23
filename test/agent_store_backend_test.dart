import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_memory_store.dart';
import 'package:gstore/core/agent/agent_session_store.dart';
import 'package:gstore/core/agent/agent_store_backend.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBackend implements AgentStoreBackend {
  String _sessions = '[]';
  String? _current;
  final Map<String, Map<String, dynamic>> _memories = {};
  int searchCalls = 0;

  /// 写调用计数：用于断言「只 upsert 变更会话」
  int replaceCalls = 0;
  int clearCalls = 0;
  final List<String> upsertedIds = [];
  final List<String> deletedIds = [];
  final List<String?> currentWrites = [];

  @override
  Future<String> sessionsJson() async => _sessions;

  @override
  Future<void> replaceSessionsJson(String json) async {
    replaceCalls++;
    _sessions = json;
  }

  @override
  Future<void> upsertSessionJson(String json) async {
    final session = jsonDecode(json) as Map<String, dynamic>;
    upsertedIds.add(session['id'] as String);
    final list = (jsonDecode(_sessions) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final index = list.indexWhere((e) => e['id'] == session['id']);
    if (index >= 0) {
      list[index] = session;
    } else {
      list.add(session);
    }
    _sessions = jsonEncode(list);
  }

  @override
  Future<void> deleteSession(String id) async {
    deletedIds.add(id);
    final list = (jsonDecode(_sessions) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['id'] != id)
        .toList();
    _sessions = jsonEncode(list);
  }

  @override
  Future<void> clearSessions() async {
    clearCalls++;
    _sessions = '[]';
    _current = null;
  }

  @override
  Future<String?> currentSessionId() async => _current;

  @override
  Future<void> setCurrentSessionId(String? id) async {
    currentWrites.add(id);
    _current = id;
  }

  @override
  Future<String> memoriesJson() async =>
      jsonEncode(_memories.values.toList());

  @override
  Future<String> searchMemoriesJson(String query, {int limit = 12}) async {
    searchCalls++;
    final matched = _memories.values
        .where((m) => (m['text'] as String).contains(query))
        .take(limit)
        .toList();
    return jsonEncode(matched.isEmpty ? _memories.values.take(limit).toList() : matched);
  }

  @override
  Future<String> addMemory(String text) async {
    final existing = _memories.values.where((m) => m['text'] == text).toList();
    if (existing.isNotEmpty) {
      final memory = existing.first;
      memory['hits'] = (memory['hits'] as int) + 1;
      return jsonEncode(memory);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final memory = <String, dynamic>{
      'id': 'fake-$now-${_memories.length}',
      'text': text,
      'createdAt': now,
      'lastUsedAt': now,
      'hits': 1,
    };
    _memories[memory['id'] as String] = memory;
    return jsonEncode(memory);
  }

  @override
  Future<int> removeMemory(String idOrText) async {
    final before = _memories.length;
    _memories.removeWhere((id, m) =>
        id == idOrText || (m['text'] as String).contains(idOrText));
    return before - _memories.length;
  }

  @override
  Future<void> clearMemories() async {
    _memories.clear();
  }

  @override
  Future<void> replaceMemoriesJson(String json) async {
    _memories.clear();
    for (final item in jsonDecode(json) as List) {
      final map = Map<String, dynamic>.from(item as Map);
      _memories[map['id'] as String] = map;
    }
  }

  final Map<String, Map<String, dynamic>> _traces = {};
  final Map<String, String> _meta = {};

  @override
  Future<void> insertTraceJson(String json) async {
    final map = jsonDecode(json) as Map<String, dynamic>;
    _traces[map['turnId'] as String] = map;
  }

  @override
  Future<String> tracesJson({int limit = 50}) async {
    final list = _traces.values.toList()
      ..sort((a, b) {
        final byTime =
            (b['createdAt'] as num).compareTo(a['createdAt'] as num);
        if (byTime != 0) return byTime;
        return (b['turnId'] as String).compareTo(a['turnId'] as String);
      });
    return jsonEncode(list.take(limit).toList());
  }

  @override
  Future<int> pruneTraces({int keep = 500}) async {
    final list = _traces.values.toList()
      ..sort((a, b) =>
          (b['createdAt'] as num).compareTo(a['createdAt'] as num));
    final drop = list.skip(keep).map((e) => e['turnId'] as String).toList();
    for (final id in drop) {
      _traces.remove(id);
    }
    return drop.length;
  }

  @override
  Future<void> clearTraces() async => _traces.clear();

  @override
  Future<String?> readMeta(String key) async => _meta[key];

  @override
  Future<void> writeMeta(String key, String? value) async {
    if (value == null) {
      _meta.remove(key);
    } else {
      _meta[key] = value;
    }
  }
}

/// 可注入失败的后端：用于验证「失败后清空基线 → 下次全量重写」
class _FlakyBackend extends _FakeBackend {
  bool failNextUpsert = false;
  bool failNextDelete = false;

  @override
  Future<void> upsertSessionJson(String json) async {
    if (failNextUpsert) {
      failNextUpsert = false;
      throw StateError('simulated upsert failure');
    }
    return super.upsertSessionJson(json);
  }

  @override
  Future<void> deleteSession(String id) async {
    if (failNextDelete) {
      failNextDelete = false;
      throw StateError('simulated delete failure');
    }
    return super.deleteSession(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('会话：SharedPreferences 一次性迁移到 backend，后续走 SQLite 语义', () async {
    final legacy = AgentSession(
      id: 's1',
      title: '旧会话',
      createdAt: 100,
      updatedAt: 200,
      messages: [
        SessionMessage(isUser: true, text: '你好', time: 100, seq: 0),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'agent_sessions': jsonEncode([legacy.toJson()]),
      'agent_current_session_id': 's1',
    });
    final backend = _FakeBackend();

    final store = await AgentSessionStore.loadWithBackend(backend);
    expect(store.sessions, hasLength(1));
    expect(store.currentSessionId, 's1');
    expect(backend._sessions, contains('旧会话'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('agent_sessions'), isNull, reason: '迁移后清理旧键');

    // 新建/切换/删除都写回 backend
    final created = await store.createSession(title: '新会话');
    await store.selectSession(created.id);
    expect(backend._current, created.id);
    expect(backend._sessions, contains('新会话'));

    await store.deleteSession('s1');
    expect(backend._sessions, isNot(contains('旧会话')));
  });

  test('记忆：迁移 + add/remove/clear + recallAsync 走 backend', () async {
    final legacy = AgentMemory(
      id: 'm1',
      text: '用户偏好使用 F-Droid 渠道',
      createdAt: 100,
      lastUsedAt: 100,
    );
    SharedPreferences.setMockInitialValues({
      'agent_memory_v1': jsonEncode([legacy.toJson()]),
    });
    final backend = _FakeBackend();

    final store = await AgentMemoryStore.loadWithBackend(backend);
    expect(store.all, hasLength(1));
    expect(backend._memories, hasLength(1));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('agent_memory_v1'), isNull, reason: '迁移后清理旧键');

    await store.add('用户喜欢深色主题');
    expect(store.all, hasLength(2));
    final recalled = await store.recallAsync(query: '主题');
    expect(backend.searchCalls, greaterThan(0));
    expect(recalled.map((m) => m.text), contains('用户喜欢深色主题'));

    final removed = await store.remove('F-Droid');
    expect(removed, 1);
    expect(store.all, hasLength(1));

    await store.clear();
    expect(store.all, isEmpty);
    expect(backend._memories, isEmpty);
  });

  test('会话保存只 upsert 变更的会话，不再整表 replace', () async {
    final backend = _FakeBackend();
    final store = await AgentSessionStore.loadWithBackend(backend);

    final s1 = await store.createSession(title: '会话一');
    final s2 = await store.createSession(title: '会话二');
    expect(backend.upsertedIds, [s1.id, s2.id]);
    expect(backend.replaceCalls, 0, reason: '正常保存不得整表重写');

    // 切会话只写 current_session_id，不重写任何会话
    await store.selectSession(s1.id);
    expect(backend.upsertedIds, [s1.id, s2.id], reason: '切会话不应 upsert');
    expect(backend._current, s1.id);

    // 只改 s1：只 upsert s1，s2 不动
    final updated = AgentSession(
      id: s1.id,
      title: '会话一',
      createdAt: s1.createdAt,
      updatedAt: s1.updatedAt + 1,
      messages: [
        SessionMessage(isUser: true, text: '你好', time: 1, seq: 0),
      ],
    );
    await store.updateCurrent(updated);
    expect(backend.upsertedIds, [s1.id, s2.id, s1.id]);
    expect(backend._sessions, contains('你好'));
    expect(
      backend._sessions.split('会话二').length - 1,
      1,
      reason: '未变更的会话不应被重复写入',
    );

    // 内容未变化 → 不产生写调用
    await store.save();
    expect(backend.upsertedIds, [s1.id, s2.id, s1.id]);

    // 删除单条会话走 deleteSession
    await store.deleteSession(s2.id);
    expect(backend.deletedIds, [s2.id]);
    expect(backend.clearCalls, 0);
    expect(backend._sessions, isNot(contains('会话二')));

    // 清空全部 → 批量 clearSessions
    await store.clearAll();
    expect(backend.clearCalls, 1);
    expect(backend._sessions, '[]');
    expect(backend._current, isNull);
  });

  test('会话写入失败后清空基线，下一次保存全量重写', () async {
    final backend = _FlakyBackend();
    final store = await AgentSessionStore.loadWithBackend(backend);
    final s1 = await store.createSession(title: '会话一');
    expect(backend.upsertedIds, [s1.id]);

    backend.failNextUpsert = true;
    // 保存失败时回退 SharedPreferences（异常被吞掉并打日志）
    await store.createSession(title: '会话二');

    // 回退写入的是 SharedPreferences 全量快照
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('agent_sessions'), contains('会话二'));

    // 恢复后下一次保存把两个会话都重新 upsert（基线已清空）
    backend.upsertedIds.clear();
    await store.save();
    expect(backend.upsertedIds.length, 2);
  });

  test('会话摘要随 agent_meta 持久化，删除会话时清理', () async {
    final backend = _FakeBackend();
    final store = await AgentSessionStore.loadWithBackend(backend);
    final s1 = await store.createSession(title: '摘要会话');

    expect(await store.readSummary(s1.id), isNull);
    await store.writeSummary(s1.id, '用户问过 F-Droid 渠道');
    expect(await store.readSummary(s1.id), '用户问过 F-Droid 渠道');
    expect(backend._meta['session_summary:${s1.id}'], '用户问过 F-Droid 渠道');

    await store.deleteSession(s1.id);
    expect(await store.readSummary(s1.id), isNull);
    expect(backend._meta.containsKey('session_summary:${s1.id}'), isFalse);
  });

  test('删除写入失败后下一次保存对齐库内 id，避免会话复活', () async {
    final backend = _FlakyBackend();
    final store = await AgentSessionStore.loadWithBackend(backend);
    final s1 = await store.createSession(title: '会话一');
    final s2 = await store.createSession(title: '会话二');
    expect(backend._sessions, allOf(contains(s1.id), contains(s2.id)));

    backend.failNextDelete = true;
    await store.deleteSession(s2.id);
    // 删除失败 → 库里仍残留 s2
    expect(backend._sessions, contains(s2.id));

    await store.save();
    expect(
      backend._sessions,
      isNot(contains(s2.id)),
      reason: '下一次保存必须清掉库内残留的已删除会话',
    );
    expect(backend._sessions, contains(s1.id));
  });
}
