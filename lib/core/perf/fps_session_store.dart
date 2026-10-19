/// FPS 会话录制的持久化（`shared_preferences` JSON 列表，容量有界）。
///
/// * [FpsSessionStore]：持久化接口（`load` / `save` / `append` / `delete` /
///   `clear`）；生产实现 [SharedPrefsFpsSessionStore]（单键 JSON 数组），测试可
///   注入 [InMemoryFpsSessionStore]。
/// * **有界**：最多保留 [kFpsSessionStoreCapacity] 条，超出裁剪**最旧**；
/// * **静默**：任何读写 / 解析失败都只记日志并降级（空列表 / 无操作），绝不抛出，
///   与性能页整体容错语义一致。
///
/// 列表顺序统一为**新→旧**（按 [FpsSession.startMs] 降序）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/fps_session.dart';

/// 会话列表持久化容量上限（超出裁剪最旧）。
const int kFpsSessionStoreCapacity = 50;

/// FPS 会话持久化接口。
///
/// 全部方法**绝不抛出**：读取失败返回空列表，写入失败静默（仅日志）。
abstract class FpsSessionStore {
  /// 读取全部会话（新→旧）；无记录 / 读取失败返回空列表。
  Future<List<FpsSession>> load();

  /// 覆盖写入会话列表（内部裁剪到容量上限、按时间降序）。
  Future<void> save(List<FpsSession> sessions);

  /// 追加一条会话（新条在前；超出容量裁剪最旧）。
  Future<void> append(FpsSession session);

  /// 按 [id] 删除；成功 / 不存在返回 `true`，写入失败返回 `false`。
  Future<bool> delete(String id);

  /// 清空全部会话。
  Future<void> clear();
}

/// 生产实现：`shared_preferences`（单键 JSON 数组）。
class SharedPrefsFpsSessionStore implements FpsSessionStore {
  const SharedPrefsFpsSessionStore({this.capacity = kFpsSessionStoreCapacity});

  /// 存储键。
  static const String storageKey = 'fps_sessions';

  /// 容量上限。
  final int capacity;

  @override
  Future<List<FpsSession>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.trim().isEmpty) return <FpsSession>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <FpsSession>[];
      final sessions = <FpsSession>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          sessions.add(
            FpsSession.fromJson(item.map((k, v) => MapEntry(k.toString(), v))),
          );
        } catch (error) {
          debugPrint('[FpsSessionStore] 跳过损坏条目: $error');
        }
      }
      return _normalize(sessions, capacity);
    } catch (error) {
      debugPrint('[FpsSessionStore] 读取会话失败（降级为空）: $error');
      return <FpsSession>[];
    }
  }

  @override
  Future<void> save(List<FpsSession> sessions) async {
    try {
      final normalized = _normalize(sessions, capacity);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        storageKey,
        jsonEncode(normalized.map((s) => s.toJson()).toList()),
      );
    } catch (error) {
      debugPrint('[FpsSessionStore] 保存会话失败（忽略）: $error');
    }
  }

  @override
  Future<void> append(FpsSession session) async {
    final sessions = await load();
    await save(<FpsSession>[session, ...sessions]);
  }

  @override
  Future<bool> delete(String id) async {
    try {
      final sessions = await load();
      final next = sessions.where((s) => s.id != id).toList();
      if (next.length == sessions.length) return true;
      await save(next);
      return true;
    } catch (error) {
      debugPrint('[FpsSessionStore] 删除会话失败: $error');
      return false;
    }
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (error) {
      debugPrint('[FpsSessionStore] 清空会话失败（忽略）: $error');
    }
  }
}

/// 内存实现（测试 / 无持久化环境回退）。
class InMemoryFpsSessionStore implements FpsSessionStore {
  InMemoryFpsSessionStore({
    List<FpsSession> seed = const <FpsSession>[],
    this.capacity = kFpsSessionStoreCapacity,
  }) : _sessions = _normalize(seed, capacity);

  /// 容量上限。
  final int capacity;
  List<FpsSession> _sessions;

  @override
  Future<List<FpsSession>> load() async => List<FpsSession>.of(_sessions);

  @override
  Future<void> save(List<FpsSession> sessions) async {
    _sessions = _normalize(sessions, capacity);
  }

  @override
  Future<void> append(FpsSession session) async {
    _sessions = _normalize(<FpsSession>[session, ..._sessions], capacity);
  }

  @override
  Future<bool> delete(String id) async {
    _sessions = _sessions.where((s) => s.id != id).toList();
    return true;
  }

  @override
  Future<void> clear() async => _sessions = <FpsSession>[];
}

/// 按 [FpsSession.startMs] 降序排序并裁剪到 [capacity]（保留最新）。
List<FpsSession> _normalize(
  List<FpsSession> sessions, [
  int capacity = kFpsSessionStoreCapacity,
]) {
  final sorted = List<FpsSession>.of(sessions)
    ..sort((a, b) => b.startMs.compareTo(a.startMs));
  if (capacity > 0 && sorted.length > capacity) {
    return sorted.sublist(0, capacity);
  }
  return sorted;
}
