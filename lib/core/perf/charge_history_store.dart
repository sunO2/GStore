/// 充电曲线持久化（Scene `charge8.records` 的 GStore 等价物）。
///
/// ## 机制偏差（相对 Scene SQLite）—— 显式记录
/// Scene 用 `SQLiteOpenHelper`（DB `charge8`，表 `records`，逐字 DDL 见
/// `.omo/evidence/task-33-scene-data-schema.md` §1）逐行 `insert`。GStore **不引入
/// SQLite**，沿用既有约定（[SharedPrefsChargeHistoryStore]）：单个
/// `shared_preferences` 键承载整份 JSON 数组，每元素为一条 [ChargeRecord]（列名
/// 逐字：`time,session,current,voltage,capacity,temperature`）。SQL 级查询由读侧
/// 在内存重算（[summarizeChargeSessions] 等），语义与 todo 33 取证口径一致。
///
/// ## 语义
/// * **宽容**：读取失败 / 损坏 JSON / 单个坏条目 → 降级（空 / 跳过），绝不抛出；
/// * **有界**：容量裁剪复刻 Scene `n.l()` 的「≤ 99 会话」上限；超出时按
///   **容量摆动幅度**（`|capacityRatio|`，`capacityRatio = 首容量 − 末容量`，
///   Scene `n.g()` 口径）升序丢弃幅度最小者（同比值时丢弃更旧会话），即保留更有
///   意义的充电曲线；
/// * **有序**：始终按 `time` 升序（Scene 查询 `order by time`）。
///
/// 注：Scene `n.l()` 里还有两条更激进的删除（`capacityRatio < {5,10,20}`、
/// 时长 `< 30000ms` 且摆动 `< 5`），且其实现重复删除 `get(0)` 存在缺陷；本层只采
/// 纳其**核心可辩护规则**——「≤ 99 会话 + 按容量摆动保留」，其余不照搬以保持确定
/// 性与可测试性。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/charge_history.dart';

/// 保留的最大会话数（Scene `n.l()`：`if (h().size() > 99) { ... }`）。
const int kChargeHistoryMaxSessions = 99;

/// 按 [ChargeRecord.time] 升序排序，并按会话数上限裁剪（保留容量摆动更大的会话）。
///
/// 纯函数：同一输入恒产出同一结果，**绝不抛出**。
List<ChargeRecord> pruneChargeHistory(
  List<ChargeRecord> records, {
  int maxSessions = kChargeHistoryMaxSessions,
}) {
  final sorted = List<ChargeRecord>.of(records)
    ..sort((a, b) => a.time.compareTo(b.time));
  if (maxSessions <= 0) return sorted;
  final sessions = summarizeChargeSessions(sorted);
  if (sessions.length <= maxSessions) return sorted;

  // 升序：容量摆动幅度最小者在前（同比值时更旧会话在前）→ 优先丢弃。
  final ranked = List<ChargeSession>.of(sessions)
    ..sort((a, b) {
      final byRatio =
          a.capacityRatio.abs().compareTo(b.capacityRatio.abs());
      if (byRatio != 0) return byRatio;
      return a.session.compareTo(b.session);
    });
  final drop = ranked
      .take(sessions.length - maxSessions)
      .map((session) => session.session)
      .toSet();
  return sorted.where((record) => !drop.contains(record.session)).toList();
}

/// 充电曲线持久化接口。
///
/// 全部方法**绝不抛出**：读取失败返回空列表，写入失败静默（仅日志）。
abstract class ChargeHistoryStore {
  /// 读取全部记录（按 `time` 升序）；无记录 / 读取失败返回空列表。
  Future<List<ChargeRecord>> load();

  /// 覆盖写入记录列表（内部按 `time` 升序 + 会话数裁剪）。
  Future<void> save(List<ChargeRecord> records);

  /// 追加一条记录（新条按 `time` 归位；超出会话上限裁剪容量摆动最小者）。
  Future<void> append(ChargeRecord record);

  /// 清空全部记录。
  Future<void> clear();
}

/// 生产实现：`shared_preferences`（单键 JSON 数组）。
class SharedPrefsChargeHistoryStore implements ChargeHistoryStore {
  const SharedPrefsChargeHistoryStore({
    this.maxSessions = kChargeHistoryMaxSessions,
  });

  /// 存储键。
  static const String storageKey = 'charge_history';

  /// 会话数上限。
  final int maxSessions;

  @override
  Future<List<ChargeRecord>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.trim().isEmpty) return <ChargeRecord>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <ChargeRecord>[];
      final records = <ChargeRecord>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          records.add(
            ChargeRecord.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
            ),
          );
        } catch (error) {
          debugPrint('[ChargeHistoryStore] 跳过损坏条目: $error');
        }
      }
      return pruneChargeHistory(records, maxSessions: maxSessions);
    } catch (error) {
      debugPrint('[ChargeHistoryStore] 读取记录失败（降级为空）: $error');
      return <ChargeRecord>[];
    }
  }

  @override
  Future<void> save(List<ChargeRecord> records) async {
    try {
      final normalized = pruneChargeHistory(records, maxSessions: maxSessions);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        storageKey,
        jsonEncode(normalized.map((r) => r.toJson()).toList()),
      );
    } catch (error) {
      debugPrint('[ChargeHistoryStore] 保存记录失败（忽略）: $error');
    }
  }

  @override
  Future<void> append(ChargeRecord record) async {
    final records = await load();
    await save(<ChargeRecord>[...records, record]);
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (error) {
      debugPrint('[ChargeHistoryStore] 清空记录失败（忽略）: $error');
    }
  }
}

/// 内存实现（测试 / 无持久化环境回退）。
class InMemoryChargeHistoryStore implements ChargeHistoryStore {
  InMemoryChargeHistoryStore({
    List<ChargeRecord> seed = const <ChargeRecord>[],
    this.maxSessions = kChargeHistoryMaxSessions,
  }) : _records = pruneChargeHistory(seed, maxSessions: maxSessions);

  /// 会话数上限。
  final int maxSessions;
  List<ChargeRecord> _records;

  @override
  Future<List<ChargeRecord>> load() async => List<ChargeRecord>.of(_records);

  @override
  Future<void> save(List<ChargeRecord> records) async {
    _records = pruneChargeHistory(records, maxSessions: maxSessions);
  }

  @override
  Future<void> append(ChargeRecord record) async {
    _records = pruneChargeHistory(
      <ChargeRecord>[..._records, record],
      maxSessions: maxSessions,
    );
  }

  @override
  Future<void> clear() async => _records = <ChargeRecord>[];
}
