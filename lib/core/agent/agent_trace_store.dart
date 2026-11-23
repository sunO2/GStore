import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_store_backend.dart';
import 'agent_trace.dart';

/// 一条已落库的回合记录（P3-1 可观测性）。
///
/// 字段与 Rust `AgentTrace` / `agent_trace` 表一一对应；[detail] 保留完整
/// `AgentTurnTrace.toJson()`，调试页可以展示工具调用、错误原文，
/// 后续要做「失败回合回放」也不需要改表结构。
class AgentTurnRecord {
  AgentTurnRecord({
    required this.turnId,
    this.sessionId,
    required this.createdAt,
    this.status = 'ok',
    this.provider,
    this.model,
    this.toolsEnabled = true,
    this.promptChars = 0,
    this.messageCount = 0,
    this.toolsOffered = 0,
    this.modelSteps = 0,
    this.toolRequests = 0,
    this.toolResponses = 0,
    this.toolErrors = 0,
    this.firstTokenMs,
    this.totalMs = 0,
    this.responseChars = 0,
    this.reasoningChars = 0,
    this.inputTokens,
    this.outputTokens,
    this.finishReason,
    this.error,
    this.detail,
  });

  final String turnId;
  final String? sessionId;
  final int createdAt;

  /// `ok` | `error` | `cancelled`
  final String status;

  final String? provider;
  final String? model;
  final bool toolsEnabled;
  final int promptChars;
  final int messageCount;
  final int toolsOffered;
  final int modelSteps;
  final int toolRequests;
  final int toolResponses;
  final int toolErrors;
  final int? firstTokenMs;
  final int totalMs;
  final int responseChars;
  final int reasoningChars;
  final int? inputTokens;
  final int? outputTokens;
  final String? finishReason;
  final String? error;
  final String? detail;

  bool get isError => status == 'error';
  bool get isCancelled => status == 'cancelled';

  Map<String, dynamic> toJson() => {
        'turnId': turnId,
        'sessionId': sessionId,
        'createdAt': createdAt,
        'status': status,
        'provider': provider,
        'model': model,
        'toolsEnabled': toolsEnabled,
        'promptChars': promptChars,
        'messageCount': messageCount,
        'toolsOffered': toolsOffered,
        'modelSteps': modelSteps,
        'toolRequests': toolRequests,
        'toolResponses': toolResponses,
        'toolErrors': toolErrors,
        'firstTokenMs': firstTokenMs,
        'totalMs': totalMs,
        'responseChars': responseChars,
        'reasoningChars': reasoningChars,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'finishReason': finishReason,
        'error': error,
        'detail': detail,
      };

  factory AgentTurnRecord.fromJson(Map<String, dynamic> json) {
    int asInt(Object? value) => value is num ? value.toInt() : 0;
    return AgentTurnRecord(
      turnId: json['turnId'] as String? ?? '',
      sessionId: json['sessionId'] as String?,
      createdAt: asInt(json['createdAt']),
      status: json['status'] as String? ?? 'ok',
      provider: json['provider'] as String?,
      model: json['model'] as String?,
      toolsEnabled: json['toolsEnabled'] as bool? ?? true,
      promptChars: asInt(json['promptChars']),
      messageCount: asInt(json['messageCount']),
      toolsOffered: asInt(json['toolsOffered']),
      modelSteps: asInt(json['modelSteps']),
      toolRequests: asInt(json['toolRequests']),
      toolResponses: asInt(json['toolResponses']),
      toolErrors: asInt(json['toolErrors']),
      firstTokenMs: json['firstTokenMs'] == null
          ? null
          : asInt(json['firstTokenMs']),
      totalMs: asInt(json['totalMs']),
      responseChars: asInt(json['responseChars']),
      reasoningChars: asInt(json['reasoningChars']),
      inputTokens:
          json['inputTokens'] == null ? null : asInt(json['inputTokens']),
      outputTokens:
          json['outputTokens'] == null ? null : asInt(json['outputTokens']),
      finishReason: json['finishReason'] as String?,
      error: json['error'] as String?,
      detail: json['detail'] as String?,
    );
  }

  /// 详情里的完整 trace（解析失败返回空 map）。
  Map<String, dynamic> get parsedDetail {
    final raw = detail;
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// 把一回合的 [AgentTurnTrace] 落库格式（status 由结果推导）。
  static AgentTurnRecord fromTrace(
    AgentTurnTrace trace, {
    String? sessionId,
  }) {
    final status = trace.error != null
        ? 'error'
        : (trace.cancelled ? 'cancelled' : 'ok');
    return AgentTurnRecord(
      turnId: trace.turnId,
      sessionId: sessionId,
      createdAt: trace.startedAt.millisecondsSinceEpoch,
      status: status,
      provider: trace.provider,
      model: trace.model,
      toolsEnabled: trace.toolsEnabled,
      promptChars: trace.promptChars,
      messageCount: trace.messageCount,
      toolsOffered: trace.toolsOffered,
      modelSteps: trace.modelSteps,
      toolRequests: trace.toolRequests,
      toolResponses: trace.toolResponses,
      toolErrors: trace.toolErrors,
      firstTokenMs: trace.firstTokenMs,
      totalMs: trace.totalMs,
      responseChars: trace.responseChars,
      reasoningChars: trace.reasoningChars,
      inputTokens: trace.inputTokens,
      outputTokens: trace.outputTokens,
      finishReason: trace.finishReason,
      error: trace.error,
      detail: jsonEncode(trace.toJson()),
    );
  }
}

/// 回合记录存储：SQLite（core `agent_trace`）优先，SharedPreferences 兜底。
class AgentTraceStore {
  static const String _keyTraces = 'agent_traces_v1';

  /// SharedPreferences 兜底与启动裁剪共用上限。
  static const int defaultKeep = 500;

  AgentTraceStore({
    AgentStoreBackend? backend,
    List<AgentTurnRecord>? traces,
  })  : _backend = backend,
        _traces = traces ?? [];

  final AgentStoreBackend? _backend;
  final List<AgentTurnRecord> _traces;

  /// 串行写入，避免并发 insert 抢连接。
  Future<void> _chain = Future<void>.value();

  /// 最近的记录（SQLite 后端按需读，SP 兜底读内存缓存）。
  Future<List<AgentTurnRecord>> recent({int limit = 50}) async {
    final backend = _backend;
    if (backend == null) {
      return _traces.take(limit).toList(growable: false);
    }
    try {
      final raw = await backend.tracesJson(limit: limit);
      final list = jsonDecode(raw) as List;
      return [
        for (final item in list)
          AgentTurnRecord.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
    } catch (error) {
      debugPrint('AgentTraceStore: 读取回合记录失败 - $error');
      return const [];
    }
  }

  /// 记录一回合；失败只打日志，绝不影响对话。
  Future<void> record(AgentTurnRecord record) {
    final next = _chain.then((_) => _performRecord(record));
    _chain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _performRecord(AgentTurnRecord record) async {
    final backend = _backend;
    if (backend != null) {
      try {
        await backend.insertTraceJson(jsonEncode(record.toJson()));
        return;
      } catch (error) {
        debugPrint('AgentTraceStore: 写入回合记录失败 - $error');
        return;
      }
    }
    _traces.insert(0, record);
    if (_traces.length > defaultKeep) {
      _traces.removeRange(defaultKeep, _traces.length);
    }
    await _flushPrefs();
  }

  /// 裁剪到最近 [keep] 条（启动时调用一次）。
  Future<void> prune({int keep = defaultKeep}) async {
    final backend = _backend;
    if (backend != null) {
      try {
        final removed = await backend.pruneTraces(keep: keep);
        if (removed > 0) {
          debugPrint('AgentTraceStore: 已清理 $removed 条历史回合记录');
        }
        return;
      } catch (error) {
        debugPrint('AgentTraceStore: 裁剪回合记录失败 - $error');
        return;
      }
    }
    if (_traces.length > keep) {
      _traces.removeRange(keep, _traces.length);
      await _flushPrefs();
    }
  }

  Future<void> clear() async {
    final backend = _backend;
    if (backend != null) {
      try {
        await backend.clearTraces();
        return;
      } catch (error) {
        debugPrint('AgentTraceStore: 清空回合记录失败 - $error');
        return;
      }
    }
    _traces.clear();
    await _flushPrefs();
  }

  Future<void> _flushPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyTraces,
      jsonEncode([for (final t in _traces) t.toJson()]),
    );
  }

  /// 加载：SQLite 可用则读库并裁剪；否则读 SharedPreferences。
  static Future<AgentTraceStore> load({AgentStoreBackend? backend}) async {
    var resolved = backend;
    if (resolved == null) {
      try {
        resolved = await RustAgentStoreBackend.create();
      } catch (error) {
        debugPrint('AgentTraceStore: SQLite 后端不可用，回退 SP - $error');
      }
    }
    if (resolved != null) {
      final store = AgentTraceStore(backend: resolved);
      await store.prune();
      return store;
    }
    final prefs = await SharedPreferences.getInstance();
    return AgentTraceStore(traces: _decode(prefs.getString(_keyTraces) ?? ''));
  }

  /// 测试接缝：直接注入 backend（真实或 fake）。
  @visibleForTesting
  static Future<AgentTraceStore> loadWithBackend(
    AgentStoreBackend backend,
  ) async {
    final store = AgentTraceStore(backend: backend);
    await store.prune();
    return store;
  }

  static List<AgentTurnRecord> _decode(String raw) {
    if (raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final item in list)
          AgentTurnRecord.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
    } catch (error) {
      debugPrint('AgentTraceStore: 解析回合记录失败 - $error');
      return [];
    }
  }
}
