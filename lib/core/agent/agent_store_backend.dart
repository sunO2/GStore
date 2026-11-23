/// Agent session/memory storage backend (P2: SQLite + FTS5 in the Rust core).
///
/// The Rust `AgentStoreApi` owns the tables; this interface keeps the Dart
/// stores testable and allows a SharedPreferences fallback when the native
/// bridge is unavailable (unit tests / desktop tooling).
library;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

abstract class AgentStoreBackend {
  Future<String> sessionsJson();
  Future<void> replaceSessionsJson(String json);
  Future<void> upsertSessionJson(String json);
  Future<void> deleteSession(String id);
  Future<void> clearSessions();
  Future<String?> currentSessionId();
  Future<void> setCurrentSessionId(String? id);

  Future<String> memoriesJson();
  Future<String> searchMemoriesJson(String query, {int limit = 12});
  Future<String> addMemory(String text);
  Future<int> removeMemory(String idOrText);
  Future<void> clearMemories();
  Future<void> replaceMemoriesJson(String json);

  /// Turn traces (P3-1 observability).
  Future<void> insertTraceJson(String json);
  Future<String> tracesJson({int limit = 50});
  Future<int> pruneTraces({int keep = 500});
  Future<void> clearTraces();

  /// Generic `agent_meta` small state (rolling context summary).
  Future<String?> readMeta(String key);
  Future<void> writeMeta(String key, String? value);
}

/// Production backend: Rust core SQLite (`agent_session` / `agent_memory` + FTS5).
class RustAgentStoreBackend implements AgentStoreBackend {
  RustAgentStoreBackend._(this._api);

  final rust.AgentStoreApi _api;

  /// Opens the same core DB used by catalog/update (`<support>/gstore_core/data`).
  static Future<RustAgentStoreBackend?> create() async {
    try {
      await RustBridge.ensureInitialized();
      final support = await getApplicationSupportDirectory();
      final dataDir = '${support.path}/gstore_core/data';
      final api = await rust.AgentStoreApi.init(dataDir: dataDir);
      return RustAgentStoreBackend._(api);
    } catch (error) {
      debugPrint('RustAgentStoreBackend: 不可用，回退 SharedPreferences - $error');
      return null;
    }
  }

  @override
  Future<String> sessionsJson() => _api.sessionsJson();

  @override
  Future<void> replaceSessionsJson(String json) =>
      _api.replaceSessionsJson(json: json);

  @override
  Future<void> upsertSessionJson(String json) =>
      _api.upsertSessionJson(json: json);

  @override
  Future<void> deleteSession(String id) => _api.deleteSession(id: id);

  @override
  Future<void> clearSessions() => _api.clearSessions();

  @override
  Future<String?> currentSessionId() => _api.currentSessionId();

  @override
  Future<void> setCurrentSessionId(String? id) =>
      _api.setCurrentSessionId(id: id);

  @override
  Future<String> memoriesJson() => _api.memoriesJson();

  @override
  Future<String> searchMemoriesJson(String query, {int limit = 12}) =>
      _api.searchMemoriesJson(query: query, limit: limit);

  @override
  Future<String> addMemory(String text) => _api.addMemory(text: text);

  @override
  Future<int> removeMemory(String idOrText) async {
    final removed = await _api.removeMemory(idOrText: idOrText);
    return removed.toInt();
  }

  @override
  Future<void> clearMemories() => _api.clearMemories();

  @override
  Future<void> replaceMemoriesJson(String json) =>
      _api.replaceMemoriesJson(json: json);

  @override
  Future<void> insertTraceJson(String json) =>
      _api.insertTraceJson(json: json);

  @override
  Future<String> tracesJson({int limit = 50}) =>
      _api.tracesJson(limit: limit);

  @override
  Future<int> pruneTraces({int keep = 500}) async {
    final removed = await _api.pruneTraces(keep: keep);
    return removed.toInt();
  }

  @override
  Future<void> clearTraces() => _api.clearTraces();

  @override
  Future<String?> readMeta(String key) => _api.readMeta(key: key);

  @override
  Future<void> writeMeta(String key, String? value) =>
      _api.writeMeta(key: key, value: value);
}
