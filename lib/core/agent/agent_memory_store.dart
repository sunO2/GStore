/// Agent 长期记忆（P1）
///
/// 只保存用户**明确要求记住**的长期偏好/事实（如"我习惯用 F-Droid"、
/// "以后下载都安装到 /sdcard/Download"），不保存一次性任务。
///
/// 存储用 SharedPreferences 的小型 JSON 列表：数据量小（上限 200 条），
/// 读写简单；后续如果要做语义检索，再迁移到 core SQLite + embedding。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_store_backend.dart';
import 'agent_tool_selector.dart';

/// 单条长期记忆
class AgentMemory {
  AgentMemory({
    required this.id,
    required this.text,
    required this.createdAt,
    int? lastUsedAt,
    this.hits = 1,
  }) : lastUsedAt = lastUsedAt ?? createdAt;

  final String id;
  final String text;
  final int createdAt;
  int lastUsedAt;
  int hits;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'createdAt': createdAt,
        'lastUsedAt': lastUsedAt,
        'hits': hits,
      };

  factory AgentMemory.fromJson(Map<String, dynamic> json) => AgentMemory(
        id: json['id']?.toString() ?? '',
        text: json['text']?.toString() ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
        lastUsedAt: (json['lastUsedAt'] as num?)?.toInt(),
        hits: (json['hits'] as num?)?.toInt() ?? 1,
      );
}

/// 长期记忆存储
class AgentMemoryStore {
  AgentMemoryStore._(this._prefs, this._items, this._backend);

  static const String storageKey = 'agent_memory_v1';

  /// 单条记忆最大字符数（防止把整段对话塞进来）
  static const int maxTextLength = 500;

  /// 最多保留条数（超出淘汰最久未使用）
  static const int maxItems = 200;

  /// 注入提示词的默认条数
  static const int promptLimit = 12;

  final SharedPreferences _prefs;
  final List<AgentMemory> _items;

  /// SQLite backend; null → SharedPreferences fallback (tests/desktop).
  final AgentStoreBackend? _backend;

  /// 全部记忆（最近使用在前）
  List<AgentMemory> get all => List<AgentMemory>.unmodifiable(
        [..._items]..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt)),
      );

  /// 读取并解码；SQLite 优先，不可用时回退 SharedPreferences。
  ///
  /// 首次使用 SQLite 且表为空时，会把旧的 SharedPreferences 记忆导入并清理。
  static Future<AgentMemoryStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    AgentStoreBackend? backend;
    try {
      backend = await RustAgentStoreBackend.create();
    } catch (error) {
      debugPrint('AgentMemoryStore: SQLite 后端不可用，回退 SP - $error');
    }

    if (backend != null) {
      try {
        return await loadWithBackend(backend);
      } catch (error) {
        debugPrint('AgentMemoryStore: SQLite 读取失败，回退 SP - $error');
      }
    }
    return AgentMemoryStore._(
      prefs,
      _decode(prefs.getString(storageKey) ?? ''),
      null,
    );
  }

  /// 测试接缝：注入 fake backend（不触碰原生桥）
  @visibleForTesting
  static Future<AgentMemoryStore> loadWithBackend(
    AgentStoreBackend backend,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    var items = _decode(await backend.memoriesJson());
    if (items.isEmpty) {
      final legacy = _decode(prefs.getString(storageKey) ?? '');
      if (legacy.isNotEmpty) {
        await backend.replaceMemoriesJson(
          jsonEncode([for (final m in legacy) m.toJson()]),
        );
        await prefs.remove(storageKey);
        items = legacy;
        debugPrint('AgentMemoryStore: 已迁移 ${legacy.length} 条记忆到 SQLite');
      }
    }
    return AgentMemoryStore._(prefs, items, backend);
  }

  static List<AgentMemory> _decode(String raw) {
    if (raw.isEmpty) return [];
    final items = <AgentMemory>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            final memory = AgentMemory.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
            );
            if (memory.id.isNotEmpty && memory.text.isNotEmpty) {
              items.add(memory);
            }
          }
        }
      }
    } catch (error) {
      debugPrint('AgentMemoryStore: 解析记忆失败（按空处理） - $error');
    }
    return items;
  }

  static AgentMemory _fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    return AgentMemory.fromJson(
      (decoded as Map).map((k, v) => MapEntry(k.toString(), v)),
    );
  }

  static List<AgentMemory> _listFromJsonString(String raw) =>
      _decode(raw);

  /// 新增（同文本去重：更新 hits/lastUsedAt）
  Future<AgentMemory> add(String text) async {
    final normalized = normalize(text);
    if (normalized.isEmpty) {
      throw ArgumentError('记忆内容不能为空');
    }
    final backend = _backend;
    if (backend != null) {
      final memory = _fromJsonString(await backend.addMemory(normalized));
      _items.removeWhere(
        (m) => m.id == memory.id || m.text == memory.text,
      );
      _items.add(memory);
      return memory;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = _items.where((m) => m.text == normalized).toList();
    if (existing.isNotEmpty) {
      final memory = existing.first;
      memory.hits += 1;
      memory.lastUsedAt = now;
      await _save();
      return memory;
    }
    final memory = AgentMemory(
      id: 'mem-$now-${_items.length}',
      text: normalized,
      createdAt: now,
    );
    _items.add(memory);
    if (_items.length > maxItems) {
      _items.sort((a, b) => a.lastUsedAt.compareTo(b.lastUsedAt));
      _items.removeRange(0, _items.length - maxItems);
    }
    await _save();
    return memory;
  }

  /// 按 id 或文本（包含匹配）删除；返回删除条数
  Future<int> remove(String idOrText) async {
    final key = idOrText.trim();
    if (key.isEmpty) return 0;
    final backend = _backend;
    if (backend != null) {
      final removed = await backend.removeMemory(key);
      _items.removeWhere((m) => m.id == key || m.text.contains(key));
      return removed;
    }
    final before = _items.length;
    _items.removeWhere((m) => m.id == key || m.text.contains(key));
    final removed = before - _items.length;
    if (removed > 0) await _save();
    return removed;
  }

  /// 清空
  Future<void> clear() async {
    final backend = _backend;
    if (backend != null) {
      await backend.clearMemories();
      _items.clear();
      return;
    }
    _items.clear();
    await _save();
  }

  /// 用 SQLite FTS5 召回（prompt 构建前调用）；失败时回退内存词法召回。
  Future<List<AgentMemory>> recallAsync({String? query, int limit = promptLimit}) async {
    final backend = _backend;
    if (backend != null) {
      try {
        final raw = await backend.searchMemoriesJson(
          query ?? '',
          limit: limit,
        );
        final items = _listFromJsonString(raw);
        if (items.isNotEmpty) return items;
      } catch (error) {
        debugPrint('AgentMemoryStore: FTS 召回失败，回退词法 - $error');
      }
    }
    return recall(query: query, limit: limit);
  }

  /// 渲染为系统提示词片段（异步，优先 FTS5）
  Future<String?> renderForPromptAsync({
    String? query,
    int limit = promptLimit,
  }) async {
    final items = await recallAsync(query: query, limit: limit);
    if (items.isEmpty) return null;
    return items.map((m) => '- ${m.text}').join('\n');
  }

  /// 渲染为系统提示词片段（空则返回 null）。
  ///
  /// [query] 非空时按词法相关性召回（中文 bigram/trigram + 英文单词），
  /// 不足 [limit] 条时用最近记忆补齐；这样 200 条记忆也不会全量塞进 prompt。
  String? renderForPrompt({String? query, int limit = promptLimit}) {
    final items = recall(query: query, limit: limit);
    if (items.isEmpty) return null;
    return items.map((m) => '- ${m.text}').join('\n');
  }

  /// 按相关性召回记忆（公开给测试/调试页）
  List<AgentMemory> recall({String? query, int limit = promptLimit}) {
    final ordered = all;
    if (ordered.isEmpty || limit <= 0) return const [];
    final q = query?.trim() ?? '';
    if (q.isEmpty) return ordered.take(limit).toList();

    final tokens = AgentToolSelector.tokenize(q);
    if (tokens.isEmpty) return ordered.take(limit).toList();

    final scored = <({AgentMemory memory, int score})>[];
    for (final memory in ordered) {
      final text = memory.text.toLowerCase();
      var score = 0;
      for (final token in tokens) {
        if (text.contains(token)) {
          score += token.length >= 2 ? 2 : 1;
        }
      }
      if (score > 0) scored.add((memory: memory, score: score));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return b.memory.lastUsedAt.compareTo(a.memory.lastUsedAt);
    });

    final out = <AgentMemory>[for (final item in scored) item.memory];
    if (out.length < limit) {
      for (final memory in ordered) {
        if (out.length >= limit) break;
        if (!out.contains(memory)) out.add(memory);
      }
    }
    return out.take(limit).toList();
  }

  /// 归一化：去首尾空白、压缩空白、限长
  static String normalize(String text) {
    var value = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (value.length > maxTextLength) {
      value = value.substring(0, maxTextLength);
    }
    return value;
  }

  Future<void> _save() async {
    await _prefs.setString(
      storageKey,
      jsonEncode([for (final m in _items) m.toJson()]),
    );
  }
}
