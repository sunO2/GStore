/// 充电曲线数据模型（Scene 8 `charge8.records` 的 1:1 移植）——**纯 Dart**，
/// 无 Flutter / 引擎 / I/O 依赖。
///
/// ## 取证来源（todo 33）
/// 真实 Scene 表为 `com.omarea.store.n`（DB `charge8`）的 `records`，DDL 逐字为
/// （`.omo/evidence/task-33-scene-data-schema.md` §1 / §2）：
///
/// ```
/// create table records(time text primary key, session int, current INTEGER,
///                      voltage REAL, capacity INTEGER, temperature REAL)
/// ```
///
/// 写入路径 `n.a(session, current, voltage, capacity, temperature)`，
/// `time = System.currentTimeMillis()`。本文件的 [ChargeRecord] **逐字段**采用该
/// 表列名与语义（`time,session,current,voltage,capacity,temperature`）。
///
/// ## 机制偏差（相对 Scene SQLite）
/// GStore 沿用既有的 `shared_preferences` JSON 存储约定（见
/// `fps_session_store.dart`），**不用** SQLite。因此这里只保留与 SQLite 等价的
/// **行 / 列语义**：`time`（Scene 声明为 `text` 主键但写入 `long`）在 GStore 中以
/// `int`（Unix ms）承载；`voltage` / `temperature` 为 `double`（REAL）；`current` /
/// `capacity` 为 `int`（INTEGER）。查询 / 聚合（3 图序列、容量摆动、梯形积分）
/// 由读侧按 todo 33 的**逐字 SQL 口径**在内存重算，不预聚合。
///
/// ## 单位（provable，来自 Scene 自身 CSV 表头 `PerfWatchStore.txt:694`）
/// * [ChargeRecord.current] = mA（有符号；充电为正）
/// * [ChargeRecord.voltage] = V
/// * [ChargeRecord.capacity] = %
/// * [ChargeRecord.temperature] = ℃
///
/// 派生功率 `power = current * voltage / 1000`（Scene 三图之三）标
/// `unverified`：Scene 内部单位不一致（CSV 标 `Power(mW)`，却对 `mA×V` 再 `/1000`）。
/// 故本层**只持久化原始操作数**，功率留待读侧按逐字表达式计算。
library;

/// `charge8.records` 的单行（Scene `charge8.records` 列逐字移植）。
class ChargeRecord {
  const ChargeRecord({
    required this.time,
    required this.session,
    required this.current,
    required this.voltage,
    required this.capacity,
    required this.temperature,
  });

  /// `time`：采样时刻（Unix ms；Scene 写入 `System.currentTimeMillis()`）。
  final int time;

  /// `session`：充电会话 id（由调用方分配，见 `charge_history_recorder.dart`）。
  final int session;

  /// `current`：电池电流，mA（有符号；Scene `INTEGER`）。
  final int current;

  /// `voltage`：电池电压，V（Scene `REAL`）。
  final double voltage;

  /// `capacity`：电量百分比，%（Scene `INTEGER`）。
  final int capacity;

  /// `temperature`：电池温度，℃（Scene `REAL`）。
  final double temperature;

  /// 派生功率（mA×V/1000）—— **单位 `unverified`**（见库文档）。
  double get power => current * voltage / 1000.0;

  /// 复制并覆盖字段。
  ChargeRecord copyWith({
    int? time,
    int? session,
    int? current,
    double? voltage,
    int? capacity,
    double? temperature,
  }) =>
      ChargeRecord(
        time: time ?? this.time,
        session: session ?? this.session,
        current: current ?? this.current,
        voltage: voltage ?? this.voltage,
        capacity: capacity ?? this.capacity,
        temperature: temperature ?? this.temperature,
      );

  /// 序列化为 JSON 友好映射（列名逐字：键顺序固定）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'time': time,
        'session': session,
        'current': current,
        'voltage': voltage,
        'capacity': capacity,
        'temperature': temperature,
      };

  /// 宽容反序列化：缺失 / 非法字段降级为 `0`（`voltage` / `temperature` 为
  /// 非有限值时同样降级），**绝不抛出**。
  factory ChargeRecord.fromJson(Map<String, dynamic> json) {
    final voltage = _finiteDouble(json['voltage']);
    final temperature = _finiteDouble(json['temperature']);
    return ChargeRecord(
      time: _int(json['time']) ?? 0,
      session: _int(json['session']) ?? 0,
      current: _int(json['current']) ?? 0,
      voltage: voltage ?? 0,
      capacity: _int(json['capacity']) ?? 0,
      temperature: temperature ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChargeRecord &&
      other.time == time &&
      other.session == session &&
      other.current == current &&
      other.voltage == voltage &&
      other.capacity == capacity &&
      other.temperature == temperature;

  @override
  int get hashCode =>
      Object.hash(time, session, current, voltage, capacity, temperature);

  @override
  String toString() => 'ChargeRecord(time: $time, session: $session, '
      'current: $current, voltage: $voltage, capacity: $capacity, '
      'temperature: $temperature)';
}

/// 一次会话的汇总（Scene `n.h()` 的逐字查询口径）：
/// `session, MIN(time), MAX(time), MIN(capacity), MAX(capacity)`。
///
/// `capacityRatio = 首容量 − 末容量`（Scene `n.g().capacityRatio`，按时间首末行）。
class ChargeSession {
  const ChargeSession({
    required this.session,
    required this.startTime,
    required this.endTime,
    required this.startCapacity,
    required this.endCapacity,
    required this.sampleCount,
  });

  /// 会话 id。
  final int session;

  /// 首样本时间（Unix ms）。
  final int startTime;

  /// 末样本时间（Unix ms）。
  final int endTime;

  /// 首样本容量（%）。
  final int startCapacity;

  /// 末样本容量（%）。
  final int endCapacity;

  /// 样本条数。
  final int sampleCount;

  /// 容量摆动 `首容量 − 末容量`（Scene `capacityRatio`）。
  int get capacityRatio => startCapacity - endCapacity;

  /// 会话时长（ms）；非正时为 `0`。
  int get durationMs => endTime > startTime ? endTime - startTime : 0;

  @override
  String toString() => 'ChargeSession($session, ratio: $capacityRatio, '
      'durationMs: $durationMs, samples: $sampleCount)';
}

// ==================== 充电门控（todo 33 取证） ====================

/// 电流门限（mA）：Scene `ChargeStat.c()` 仅当 `|current| > 100` 才落库。
const int kChargeCurrentGateMa = 100;

/// 充电状态字符串（sysfs `status`）中代表「充电中」的取值。
///
/// Scene 门控为 `GlobalStatus.p.c() == 2`（Android `BatteryManager.
/// BATTERY_STATUS_CHARGING == 2`）；GStore 经 [PerfModule] 读到的是 sysfs 字符串
/// （`battery.rs` `status`），其直接映射为 `"Charging"` → `BATTERY_STATUS_CHARGING`。
/// 判定大小写不敏感。
const String kChargingStatusLabel = 'Charging';

/// 判断 sysfs 状态字符串是否为「充电中」（等价 Scene `status == 2`）。
bool isChargingStatus(String? status) =>
    status?.trim().toLowerCase() == kChargingStatusLabel.toLowerCase();

/// 一次实时电池读数（采样器输出，非持久化行）。
class ChargeSnapshot {
  const ChargeSnapshot({
    this.currentMa,
    this.voltageV,
    this.capacityPercent,
    this.temperatureC,
    this.status,
  });

  /// 电流，mA（有符号）。
  final double? currentMa;

  /// 电压，V。
  final double? voltageV;

  /// 电量，%。
  final double? capacityPercent;

  /// 温度，℃。
  final double? temperatureC;

  /// sysfs 状态字符串（如 `Charging` / `Discharging`）。
  final String? status;

  @override
  String toString() => 'ChargeSnapshot(currentMa: $currentMa, '
      'voltageV: $voltageV, capacityPercent: $capacityPercent, '
      'temperatureC: $temperatureC, status: $status)';
}

/// 门控判定（逐字复刻 Scene `ChargeStat.c()`）：
/// **仅当**充电中（[isChargingStatus]）**且** `|current| > 100`（[kChargeCurrentGateMa]）
/// 时才允许落库；`current` 缺失 / 非有限一律不落库。
bool passesChargeGate(ChargeSnapshot snapshot) {
  if (!isChargingStatus(snapshot.status)) return false;
  final current = snapshot.currentMa;
  if (current == null || !current.isFinite) return false;
  return current.abs() > kChargeCurrentGateMa;
}

/// 由实时读数构造一行 [ChargeRecord]（[time] 由调用方注入，保证确定性）。
///
/// 返回 `null`（不落库）当且仅当：
/// * 未通过 [passesChargeGate]；或
/// * 任一必需数值（`current` / `voltage` / `capacity` / `temperature`）缺失或非有限。
ChargeRecord? buildChargeRecord(
  ChargeSnapshot snapshot, {
  required int time,
  required int session,
}) {
  if (!passesChargeGate(snapshot)) return null;
  final current = snapshot.currentMa;
  final voltage = snapshot.voltageV;
  final capacity = snapshot.capacityPercent;
  final temperature = snapshot.temperatureC;
  if (current == null ||
      voltage == null ||
      !voltage.isFinite ||
      capacity == null ||
      !capacity.isFinite ||
      temperature == null ||
      !temperature.isFinite) {
    return null;
  }
  return ChargeRecord(
    time: time,
    session: session,
    current: current.round(),
    voltage: voltage,
    capacity: capacity.round(),
    temperature: temperature,
  );
}

// ==================== 纯函数：会话聚合 ====================

/// 按 [ChargeRecord.session] 分组并按 `time` 升序汇总（Scene `n.h()` 口径）。
///
/// 返回会话按 [ChargeSession.session] 升序；空输入返回空列表。
List<ChargeSession> summarizeChargeSessions(
  Iterable<ChargeRecord> records,
) {
  final grouped = <int, List<ChargeRecord>>{};
  for (final record in records) {
    grouped.putIfAbsent(record.session, () => <ChargeRecord>[]).add(record);
  }
  final sessions = <ChargeSession>[];
  grouped.forEach((session, rows) {
    final sorted = List<ChargeRecord>.of(rows)
      ..sort((a, b) => a.time.compareTo(b.time));
    sessions.add(
      ChargeSession(
        session: session,
        startTime: sorted.first.time,
        endTime: sorted.last.time,
        startCapacity: sorted.first.capacity,
        endCapacity: sorted.last.capacity,
        sampleCount: sorted.length,
      ),
    );
  });
  sessions.sort((a, b) => a.session.compareTo(b.session));
  return sessions;
}

// ==================== 宽容解析辅助 ====================

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? _finiteDouble(Object? value) {
  final parsed = _double(value);
  if (parsed == null || !parsed.isFinite) return null;
  return parsed;
}

double? _double(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}
