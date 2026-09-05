import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

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

  AgentSessionStore({List<AgentSession>? sessions, this.currentSessionId})
      : sessions = sessions ?? [];

  /// 当前会话
  AgentSession? get current =>
      currentSessionId == null ? null : _findById(currentSessionId!);

  AgentSession? _findById(String id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 从本地存储加载
  static Future<AgentSessionStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySessions);
    List<AgentSession> sessions = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        sessions = list
            .map((e) => AgentSession.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        // 解析失败返回空
      }
    }
    return AgentSessionStore(
      sessions: sessions,
      currentSessionId: prefs.getString(_keyCurrentId),
    );
  }

  /// 保存到本地存储
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(sessions.map((e) => e.toJson()).toList());
    await prefs.setString(_keySessions, raw);
    if (currentSessionId != null) {
      await prefs.setString(_keyCurrentId, currentSessionId!);
    } else {
      await prefs.remove(_keyCurrentId);
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
  }

  /// 更新当前会话（标题/消息）
  Future<void> updateCurrent(AgentSession session) async {
    final idx = sessions.indexWhere((e) => e.id == session.id);
    if (idx >= 0) {
      sessions[idx] = session;
    }
    await save();
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
