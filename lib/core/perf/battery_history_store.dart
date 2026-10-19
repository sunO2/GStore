/// 电池/功耗历史记录的持久化（`shared_preferences` JSON 列表，容量有界）。
///
/// ## 机制选择（与 Scene 的差异，已记录）
/// Scene 8 用 **SQLite**（DB `power8` / 表 `records`，见
/// `.omo/evidence/task-33-scene-data-schema.md`）。GStore 既有 store 约定（`fps_session_store.dart`
/// / `refresh_auto_store.dart` / `perf_profile_store.dart` 等）统一使用
/// **`shared_preferences` 单键 JSON**，无 SQLite 依赖。本 store **沿用 GStore 约定**
/// （单键 JSON，键 [SharedPrefsBatteryHistoryStore.storageKey]），而**字段 schema /
/// 聚合公式逐字采用 Scene `power8.records`**（见 `battery_history.dart`）。
///
/// ## 有界（Scene 裁剪规则）
/// Scene `f0.l()` 裁剪**会话**数 ≤ 99（task-33）。本 store 同样按**会话**粒度裁剪：
/// 超出 [kBatteryHistorySessionCapacity] 时保留**最新**的 99 个会话（其全部记录），
/// 丢弃更旧会话的全部记录。
///
/// ## 静默
/// 任何读写 / 解析失败都只记日志并降级（空列表 / 无操作），绝不抛出，与性能页整体
/// 容错语义一致。
///
/// ## 顺序
/// 记录按 `time`（ms）升序存放（时间正序）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/battery_history.dart';

/// 会话数上限（超出裁剪最旧会话）—— Scene `f0.l()` 的 `≤ 99` 规则。
const int kBatteryHistorySessionCapacity = 99;

/// 电池历史持久化接口（查询 / 聚合见 `battery_history.dart` 纯函数）。
///
/// 全部方法**绝不抛出**：读取失败返回空列表，写入失败静默（仅日志）。
abstract class BatteryHistoryStore {
  /// 读取全部记录（`time` 升序）；无记录 / 读取失败返回空列表。
  Future<List<BatteryHistoryRecord>> load();

  /// 覆盖写入记录列表（内部按会话裁剪到容量上限、按 `time` 升序）。
  Future<void> save(List<BatteryHistoryRecord> records);

  /// 追加一条记录（超出会话容量裁剪最旧）。
  Future<void> append(BatteryHistoryRecord record);

  /// 追加多条记录（超出会话容量裁剪最旧）。
  Future<void> appendAll(Iterable<BatteryHistoryRecord> records);

  /// 清空全部记录。
  Future<void> clear();

  /// 查询某会话的全部记录（`time` 升序）。
  Future<List<BatteryHistoryRecord>> recordsForSession(int session);

  /// 某会话按 `(package, mode)` 分组聚合（Scene SQL，见 [aggregateAppPower]）。
  Future<List<BatteryAppPowerStat>> appPowerForSession(int session);

  /// 某会话整体功耗（Scene SQL，见 [aggregateSessionPower]）。
  Future<double> sessionPower(int session);
}

/// 生产实现：`shared_preferences`（单键 JSON 数组）。
class SharedPrefsBatteryHistoryStore implements BatteryHistoryStore {
  const SharedPrefsBatteryHistoryStore({
    this.capacity = kBatteryHistorySessionCapacity,
  });

  /// 存储键。
  static const String storageKey = 'battery_history_records';

  /// 会话容量上限。
  final int capacity;

  @override
  Future<List<BatteryHistoryRecord>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      return decodeBatteryHistory(raw, capacity: capacity);
    } catch (error) {
      debugPrint('[BatteryHistoryStore] 读取记录失败（降级为空）: $error');
      return <BatteryHistoryRecord>[];
    }
  }

  @override
  Future<void> save(List<BatteryHistoryRecord> records) async {
    try {
      final normalized = normalizeBatteryHistory(records, capacity);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        storageKey,
        jsonEncode(normalized.map((r) => r.toJson()).toList()),
      );
    } catch (error) {
      debugPrint('[BatteryHistoryStore] 保存记录失败（忽略）: $error');
    }
  }

  @override
  Future<void> append(BatteryHistoryRecord record) =>
      appendAll(<BatteryHistoryRecord>[record]);

  @override
  Future<void> appendAll(Iterable<BatteryHistoryRecord> records) async {
    final existing = await load();
    await save(<BatteryHistoryRecord>[...existing, ...records]);
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (error) {
      debugPrint('[BatteryHistoryStore] 清空记录失败（忽略）: $error');
    }
  }

  @override
  Future<List<BatteryHistoryRecord>> recordsForSession(int session) async =>
      batteryRecordsForSession(await load(), session: session);

  @override
  Future<List<BatteryAppPowerStat>> appPowerForSession(int session) async =>
      aggregateAppPower(await load(), session: session);

  @override
  Future<double> sessionPower(int session) async =>
      aggregateSessionPower(await load(), session: session);
}

/// 内存实现（测试 / 无持久化环境回退）。
class InMemoryBatteryHistoryStore implements BatteryHistoryStore {
  InMemoryBatteryHistoryStore({
    List<BatteryHistoryRecord> seed = const <BatteryHistoryRecord>[],
    this.capacity = kBatteryHistorySessionCapacity,
  }) : _records = normalizeBatteryHistory(seed, capacity);

  /// 会话容量上限。
  final int capacity;
  List<BatteryHistoryRecord> _records;

  @override
  Future<List<BatteryHistoryRecord>> load() async =>
      List<BatteryHistoryRecord>.of(_records);

  @override
  Future<void> save(List<BatteryHistoryRecord> records) async {
    _records = normalizeBatteryHistory(records, capacity);
  }

  @override
  Future<void> append(BatteryHistoryRecord record) async {
    _records = normalizeBatteryHistory(
      <BatteryHistoryRecord>[..._records, record],
      capacity,
    );
  }

  @override
  Future<void> appendAll(Iterable<BatteryHistoryRecord> records) async {
    _records = normalizeBatteryHistory(
      <BatteryHistoryRecord>[..._records, ...records],
      capacity,
    );
  }

  @override
  Future<void> clear() async => _records = <BatteryHistoryRecord>[];

  @override
  Future<List<BatteryHistoryRecord>> recordsForSession(int session) async =>
      batteryRecordsForSession(_records, session: session);

  @override
  Future<List<BatteryAppPowerStat>> appPowerForSession(int session) async =>
      aggregateAppPower(_records, session: session);

  @override
  Future<double> sessionPower(int session) async =>
      aggregateSessionPower(_records, session: session);
}

/// 宽容解码 JSON 文本为记录列表（纯函数，**绝不抛**）。
///
/// [raw] 为 `null` / 空串 / 非法 JSON / 非数组 → 空列表；数组内损坏条目 → 跳过。
/// 结果按会话裁剪到 [capacity]（保留最新会话的记录），并按 `time` 升序排序。
List<BatteryHistoryRecord> decodeBatteryHistory(
  Object? raw, {
  int capacity = kBatteryHistorySessionCapacity,
}) {
  if (raw == null) return <BatteryHistoryRecord>[];
  Object? decoded = raw;
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <BatteryHistoryRecord>[];
    try {
      decoded = jsonDecode(trimmed);
    } catch (error) {
      debugPrint('[BatteryHistoryStore] JSON 解析失败，按空列表处理: $error');
      return <BatteryHistoryRecord>[];
    }
  }
  if (decoded is! List) return <BatteryHistoryRecord>[];
  final records = <BatteryHistoryRecord>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    try {
      records.add(
        BatteryHistoryRecord.fromJson(
          item.map((k, v) => MapEntry(k.toString(), v)),
        ),
      );
    } catch (error) {
      debugPrint('[BatteryHistoryStore] 跳过损坏条目: $error');
    }
  }
  return normalizeBatteryHistory(records, capacity);
}

/// 按会话裁剪到 [capacity] 个**最新会话**，并按 `time` 升序排序（纯函数）。
///
/// 会话新旧由该会话记录的**最大 `time`** 判定（不可解析则回退会话 id）；保留
/// [capacity] 个最新会话的全部记录。`capacity <= 0` 视为不裁剪。
List<BatteryHistoryRecord> normalizeBatteryHistory(
  List<BatteryHistoryRecord> records, [
  int capacity = kBatteryHistorySessionCapacity,
]) {
  if (capacity <= 0) {
    return _sortedByTime(records);
  }
  // 会话 → 最新 time（用于判定新旧）。
  final latest = <int, int>{};
  for (final r in records) {
    final t = _parseTime(r.time);
    final prev = latest[r.session];
    if (prev == null || t > prev) latest[r.session] = t;
  }
  if (latest.length <= capacity) {
    return _sortedByTime(records);
  }
  final sessions = latest.keys.toList()
    ..sort((a, b) {
      final byTime = latest[b]!.compareTo(latest[a]!); // 新→旧
      if (byTime != 0) return byTime;
      return b.compareTo(a); // 同刻回退按 session id 新→旧
    });
  final keep = sessions.take(capacity).toSet();
  return _sortedByTime(
    <BatteryHistoryRecord>[
      for (final r in records)
        if (keep.contains(r.session)) r,
    ],
  );
}

/// 会话内记录查询纯函数（`time` 升序）。
List<BatteryHistoryRecord> _sortedByTime(List<BatteryHistoryRecord> records) {
  final sorted = List<BatteryHistoryRecord>.of(records)
    ..sort((a, b) {
      final byTime = _parseTime(a.time).compareTo(_parseTime(b.time));
      if (byTime != 0) return byTime;
      return a.session.compareTo(b.session);
    });
  return sorted;
}

int _parseTime(String time) => int.tryParse(time.trim()) ?? 0;
