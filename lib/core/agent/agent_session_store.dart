import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_store_backend.dart';

/// Agent 会话（一次对话）
class AgentSession {
  /// 会话唯一 ID
  final String id;

  /// 会话标题（默认用首条用户消息）
  String title;

  /// 创建时间
  final int createdAt;

  /// 最后更新时间
  int updatedAt;

  /// 对话消息（轻量存储，仅文本）
  List<SessionMessage> messages;

  AgentSession({
    required this.id,
    this.title = '新对话',
    int? createdAt,
    int? updatedAt,
    List<SessionMessage>? messages,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        messages = messages ?? [];

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'messages': messages.map((e) => e.toJson()).toList(),
    };
  }

  factory AgentSession.fromJson(Map<String, dynamic> json) {
    return AgentSession(
      id: json['id'] as String,
      title: json['title'] as String? ?? '新对话',
      createdAt: json['createdAt'] as int?,
      updatedAt: json['updatedAt'] as int?,
      messages: (json['messages'] as List? ?? [])
          .map((e) => SessionMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 会话中的单条消息（持久化用）
class SessionMessage {
  /// 是否用户消息
  final bool isUser;

  /// 消息文本
  final String text;

  /// 是否是工具结果
  final bool isToolResult;

  /// 工具类型（工具消息专用，存储工具枚举名）
  final String? toolType;

  /// 工具执行状态（工具消息专用）
  final String? toolStatus;

  /// 工具调用参数描述（如关键词/应用名/操作）
  final String? toolDetail;

  /// 创建时间
  final int time;

  /// 消息序号（用于恢复时保持实时显示顺序）
  final int seq;

  /// 回合 ID（同一轮"用户提问→助手回复→工具调用"共享，用于绑定工具记录）
  final String? turnId;

  /// 确认工具的选项列表（B3：待确认消息持久化，退出/重启后可恢复确认 UI）
  final List<String>? confirmOptions;

  /// 是否为多选确认（勾选多个选项后统一确认；B3 持久化）
  final bool confirmMultiSelect;

  /// 工具名（function calling 名，如 downloadApp；工具消息专用）
  final String? toolName;

  /// 工具调用参数（JSON 字符串；工具消息专用）
  final String? toolArgs;

  /// 工具执行结果（原始返回文本；工具消息专用）
  final String? toolResult;

  /// 思考过程（reasoning / 内联 think 内容；助手消息专用）
  final String? reasoning;

  SessionMessage({
    required this.isUser,
    required this.text,
    this.isToolResult = false,
    this.toolType,
    this.toolStatus,
    this.toolDetail,
    int? time,
    this.seq = 0,
    this.turnId,
    this.confirmOptions,
    this.confirmMultiSelect = false,
    this.toolName,
    this.toolArgs,
    this.toolResult,
    this.reasoning,
  }) : time = time ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() {
    return {
      'isUser': isUser,
      'text': text,
      'isToolResult': isToolResult,
      'toolType': toolType,
      'toolStatus': toolStatus,
      'toolDetail': toolDetail,
      'time': time,
      'seq': seq,
      'turnId': turnId,
      if (confirmOptions != null) 'confirmOptions': confirmOptions,
      if (confirmMultiSelect) 'confirmMultiSelect': true,
      if (toolName != null) 'toolName': toolName,
      if (toolArgs != null) 'toolArgs': toolArgs,
      if (toolResult != null) 'toolResult': toolResult,
      if (reasoning != null && reasoning!.isNotEmpty) 'reasoning': reasoning,
    };
  }

  factory SessionMessage.fromJson(Map<String, dynamic> json) {
    return SessionMessage(
      isUser: json['isUser'] as bool? ?? false,
      text: json['text'] as String? ?? '',
      isToolResult: json['isToolResult'] as bool? ?? false,
      toolType: json['toolType'] as String?,
      toolStatus: json['toolStatus'] as String?,
      toolDetail: json['toolDetail'] as String?,
      time: json['time'] as int?,
      seq: json['seq'] as int? ?? 0,
      turnId: json['turnId'] as String?,
      confirmOptions: (json['confirmOptions'] as List?)
          ?.map((e) => e.toString())
          .toList(),
      confirmMultiSelect: json['confirmMultiSelect'] as bool? ?? false,
      toolName: json['toolName'] as String?,
      toolArgs: json['toolArgs'] as String?,
      toolResult: json['toolResult'] as String?,
      reasoning: json['reasoning'] as String?,
    );
  }
}

/// 会话存储管理器
/// 持久化所有对话到本地，支持多会话
class AgentSessionStore {
  static const String _keySessions = 'agent_sessions';
  static const String _keyCurrentId = 'agent_current_session_id';

  /// 所有会话（按更新时间倒序）
  List<AgentSession> sessions;

  /// 当前会话 ID
  String? currentSessionId;

  AgentSessionStore({
    List<AgentSession>? sessions,
    this.currentSessionId,
    AgentStoreBackend? backend,
  })  : sessions = sessions ?? [],
        _backend = backend;

  /// SQLite backend; null → SharedPreferences fallback (tests/desktop).
  final AgentStoreBackend? _backend;

  /// Serializes async saves so an older snapshot can never overwrite a newer one.
  Future<void> _saveChain = Future<void>.value();

  /// Last committed payload per session id (`id → session JSON`).
  ///
  /// Drives the diff in [save]: only sessions whose JSON changed are upserted,
  /// so a long history no longer rewrites every row on each turn.
  final Map<String, String> _savedPayloads = {};

  /// Last committed `current_session_id`.
  String? _savedCurrentId;

  /// 写失败后置位：下一次保存先与库内 id 集合对齐（清残留、全量 upsert）。
  bool _needsFullReconcile = false;

  /// 当前会话
  AgentSession? get current =>
      currentSessionId == null ? null : _findById(currentSessionId!);

  AgentSession? _findById(String id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 从 SQLite 加载；不可用时回退 SharedPreferences。
  ///
  /// 首次使用 SQLite 且表为空时，会把旧的 SharedPreferences 会话导入并清理，
  /// 完成一次性迁移。
  static Future<AgentSessionStore> load() async {
    AgentStoreBackend? backend;
    try {
      backend = await RustAgentStoreBackend.create();
    } catch (error) {
      debugPrint('AgentSessionStore: SQLite 后端不可用，回退 SP - $error');
    }

    if (backend != null) {
      try {
        return await loadWithBackend(backend);
      } catch (error) {
        debugPrint('AgentSessionStore: SQLite 读取失败，回退 SP - $error');
      }
    }

    final prefs = await SharedPreferences.getInstance();
    return AgentSessionStore(
      sessions: _decode(prefs.getString(_keySessions) ?? ''),
      currentSessionId: prefs.getString(_keyCurrentId),
    );
  }

  /// 测试接缝：注入 fake backend（不触碰原生桥）
  @visibleForTesting
  static Future<AgentSessionStore> loadWithBackend(
    AgentStoreBackend backend,
  ) async {
    var sessions = _decode(await backend.sessionsJson());
    var currentId = await backend.currentSessionId();
    if (sessions.isEmpty) {
      final migrated = await _migrateFromPrefs(backend);
      sessions = migrated.sessions;
      currentId ??= migrated.currentId;
    }
    final store = AgentSessionStore(
      sessions: sessions,
      currentSessionId: currentId,
      backend: backend,
    );
    // 基线：库里已存在的内容，后续 [save] 只写差异
    store._seedSavedState();
    return store;
  }

  /// 以当前内存状态作为「已落库」基线（仅当确实刚从 backend 读出来时调用）。
  void _seedSavedState() {
    _savedPayloads.clear();
    for (final session in sessions) {
      _savedPayloads[session.id] = jsonEncode(session.toJson());
    }
    _savedCurrentId = currentSessionId;
  }

  static List<AgentSession> _decode(String raw) {
    if (raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => AgentSession.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (error) {
      debugPrint('AgentSessionStore: 解析会话失败 - $error');
      return [];
    }
  }

  static Future<({List<AgentSession> sessions, String? currentId})>
      _migrateFromPrefs(AgentStoreBackend backend) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySessions);
    if (raw == null || raw.isEmpty) {
      return (sessions: <AgentSession>[], currentId: null);
    }
    final sessions = _decode(raw);
    final currentId = prefs.getString(_keyCurrentId);
    if (sessions.isNotEmpty) {
      await backend
          .replaceSessionsJson(jsonEncode([for (final s in sessions) s.toJson()]));
      await backend.setCurrentSessionId(currentId);
      await prefs.remove(_keySessions);
      await prefs.remove(_keyCurrentId);
      debugPrint('AgentSessionStore: 已迁移 ${sessions.length} 个会话到 SQLite');
    }
    return (sessions: sessions, currentId: currentId);
  }

  /// 保存到本地存储（SQLite 优先；失败回退 SharedPreferences）。
  ///
  /// 调用方经常 fire-and-forget；这里用 [_saveChain] 串行化，避免较早的
  /// 全量快照覆盖较新的快照。差异在调用瞬间算好：只 upsert 变更过的会话、
  /// 只删除已被移除的会话，切会话这类小改动不会重写历史消息。
  Future<void> save() {
    final pending = _buildPendingSave();
    final next = _saveChain.then((_) => _performSave(pending));
    _saveChain = next.catchError((Object _) {});
    return next;
  }

  /// 计算本次保存的差异（会话 JSON 基线见 [_savedPayloads]）。
  _PendingSave _buildPendingSave() {
    final liveIds = <String>{};
    final payloads = <String, String>{};
    final upserts = <String, String>{};
    for (final session in sessions) {
      liveIds.add(session.id);
      final payload = jsonEncode(session.toJson());
      payloads[session.id] = payload;
      if (_savedPayloads[session.id] != payload) {
        upserts[session.id] = payload;
      }
    }
    return _PendingSave(
      payloads: payloads,
      upserts: upserts,
      deletes: [
        for (final id in _savedPayloads.keys)
          if (!liveIds.contains(id)) id,
      ],
      // 逐会话 payload 拼接即为整表 JSON（顺序跟随 [sessions]）
      rawSessions: '[${payloads.values.join(',')}]',
      currentId: currentSessionId,
    );
  }

  Future<void> _performSave(_PendingSave pending) async {
    final backend = _backend;
    if (backend != null) {
      try {
        await _performBackendSave(backend, pending);
        return;
      } catch (error) {
        // 失败后清空基线并请求一次全量对齐：下一次保存先读库内 id 集合，
        // 删掉库里有、内存里没有的会话，再把所有会话重写一遍。否则中途失败
        // 可能让已删除的会话在下次启动时"复活"。
        _savedPayloads.clear();
        _needsFullReconcile = true;
        debugPrint('AgentSessionStore: SQLite 写入失败，回退 SP - $error');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySessions, pending.rawSessions);
    final currentId = pending.currentId;
    if (currentId != null) {
      await prefs.setString(_keyCurrentId, currentId);
    } else {
      await prefs.remove(_keyCurrentId);
    }
  }

  Future<void> _performBackendSave(
    AgentStoreBackend backend,
    _PendingSave pending,
  ) async {
    if (_needsFullReconcile) {
      await _reconcileBackend(backend, pending);
      _needsFullReconcile = false;
      return;
    }
    // 清空会话：批量删除比逐条 delete 更省事务
    if (pending.payloads.isEmpty) {
      await backend.clearSessions();
      _savedPayloads.clear();
      _savedCurrentId = null;
      return;
    }
    for (final id in pending.deletes) {
      if (!_savedPayloads.containsKey(id)) continue;
      await backend.deleteSession(id);
      _savedPayloads.remove(id);
    }
    for (final entry in pending.upserts.entries) {
      // 排队期间可能已被更早的保存写上同样的内容
      if (_savedPayloads[entry.key] == entry.value) continue;
      await backend.upsertSessionJson(entry.value);
      _savedPayloads[entry.key] = entry.value;
    }
    if (_savedCurrentId != pending.currentId) {
      await backend.setCurrentSessionId(pending.currentId);
      _savedCurrentId = pending.currentId;
    }
  }

  /// 失败恢复：以库内实际 id 集合为准，删残留 + 全量 upsert。
  Future<void> _reconcileBackend(
    AgentStoreBackend backend,
    _PendingSave pending,
  ) async {
    if (pending.payloads.isEmpty) {
      await backend.clearSessions();
      _savedPayloads.clear();
      _savedCurrentId = null;
      return;
    }
    final dbIds = <String>{};
    try {
      for (final item in jsonDecode(await backend.sessionsJson()) as List) {
        final id = (item as Map)['id'];
        if (id is String) dbIds.add(id);
      }
    } catch (error) {
      debugPrint('AgentSessionStore: 对齐历史会话失败（忽略） - $error');
    }
    for (final id in dbIds.difference(pending.payloads.keys.toSet())) {
      await backend.deleteSession(id);
    }
    for (final entry in pending.payloads.entries) {
      await backend.upsertSessionJson(entry.value);
    }
    _savedPayloads
      ..clear()
      ..addAll(pending.payloads);
    if (_savedCurrentId != pending.currentId) {
      await backend.setCurrentSessionId(pending.currentId);
      _savedCurrentId = pending.currentId;
    }
  }

  /// 创建新会话
  Future<AgentSession> createSession({String? title}) async {
    final session = AgentSession(
      id: generateSessionId(),
      title: title ?? '新对话',
    );
    sessions.insert(0, session);
    currentSessionId = session.id;
    await save();
    return session;
  }

  /// 选择会话
  Future<void> selectSession(String id) async {
    currentSessionId = id;
    await save();
  }

  /// 删除会话
  Future<void> deleteSession(String id) async {
    sessions.removeWhere((e) => e.id == id);
    if (currentSessionId == id) {
      currentSessionId = sessions.isNotEmpty ? sessions.first.id : null;
    }
    await save();
    // 摘要随之清理，避免同名 id 复用/残留
    await writeSummary(id, null);
  }

  /// 更新当前会话（标题/消息）
  Future<void> updateCurrent(AgentSession session) async {
    final idx = sessions.indexWhere((e) => e.id == session.id);
    if (idx >= 0) {
      sessions[idx] = session;
    }
    await save();
  }

  // -------------------------------------------------------------------------
  // 滚动上下文摘要（P3-2）：按会话存在 `agent_meta` 里，重启后可复用
  // -------------------------------------------------------------------------

  static const String _summaryMetaPrefix = 'session_summary:';
  static const String _summaryPrefsPrefix = 'agent_summary_';

  /// 读取会话摘要（无则 null）。
  Future<String?> readSummary(String sessionId) async {
    final backend = _backend;
    if (backend != null) {
      try {
        return await backend.readMeta('$_summaryMetaPrefix$sessionId');
      } catch (error) {
        debugPrint('AgentSessionStore: 读取会话摘要失败 - $error');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_summaryPrefsPrefix$sessionId');
  }

  /// 写入会话摘要（null = 删除）。
  Future<void> writeSummary(String sessionId, String? value) async {
    final backend = _backend;
    if (backend != null) {
      try {
        await backend.writeMeta('$_summaryMetaPrefix$sessionId', value);
        return;
      } catch (error) {
        debugPrint('AgentSessionStore: 写入会话摘要失败 - $error');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove('$_summaryPrefsPrefix$sessionId');
    } else {
      await prefs.setString('$_summaryPrefsPrefix$sessionId', value);
    }
  }

  /// 清空所有会话
  Future<void> clearAll() async {
    sessions.clear();
    currentSessionId = null;
    await save();
  }
}

/// 生成会话 ID
String generateSessionId() {
  return 'session-${DateTime.now().microsecondsSinceEpoch}';
}

/// [AgentSessionStore.save] 的差异快照。
///
/// 在调用 `save()` 的瞬间算好，交给 [_saveChain] 顺序执行；这样即使随后
/// 内存里的 [AgentSessionStore.sessions] 又被修改，写入内容也是稳定的。
class _PendingSave {
  const _PendingSave({
    required this.payloads,
    required this.upserts,
    required this.deletes,
    required this.rawSessions,
    required this.currentId,
  });

  /// 当前内存中所有会话（id → JSON），用于判断删除与整表回退。
  final Map<String, String> payloads;

  /// 需要 upsert 的会话（id → JSON）。
  final Map<String, String> upserts;

  /// 不再存在的会话 id。
  final List<String> deletes;

  /// 整表 JSON（SharedPreferences 回退用）。
  final String rawSessions;

  /// 当前会话 id。
  final String? currentId;
}
