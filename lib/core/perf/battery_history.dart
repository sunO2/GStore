/// 电池/功耗历史记录模型 + 聚合纯函数（Scene 8 `battery-history` 等价）。
///
/// ## Scene 取证（`.omo/evidence/task-33-scene-data-schema.md`）
/// 计划别名 `battery-history` 在 APK 中**不存在**；真实等价物是
/// `com.omarea.store.f0`（单例）→ DB `power8` / 表 `records`。表 DDL **逐字**取自
/// task-33（`t33_src/store_f0.txt:314`）：
///
/// ```sql
/// create table records(
///   time text primary key, session int, temperature REAL default(-1),
///   status int default(-1), mode text, current int default(-1), voltage int,
///   package text, screen_on INTEGER, capacity INTEGER)
/// ```
///
/// [BatteryHistoryRecord] 字段名 / 顺序与该表 **VERBATIM** 对齐。
///
/// ## 单位（task-33：provable vs unverified）
/// * `temperature` = ℃、`current` = mA、`voltage` = volt、`capacity` = %（Scene 自有
///   CSV 表头佐证）；
/// * `time` = 时间戳（ms，DB 中声明为 `text` 主键）；
/// * `status` = Android `BATTERY_STATUS_*`（查询过滤 `status in (3,4)` =
///   DISCHARGING / NOT_CHARGING）；
/// * `mode` = Scene 功耗模式标签（自由文本）；
/// * `package` = 前台包名；`screen_on` = 0/1。
/// * **功率单位 `unverified`**：`power8.records` 用原始 `avg(current * voltage)`，
///   **不**除以 1000（对照 `fps_history` 的 `battery_io * voltage / 1000`）。见
///   [BatteryAppPowerStat.power]。
///
/// ## 设计要点
/// * **纯 Dart**：无 Flutter / 引擎 / I/O 依赖；
/// * **宽容反序列化**：缺失 / 非法字段一律降级（空串 / `-1` / `0`），绝不抛出；
/// * 聚合公式**逐字**复用 task-33 的 Scene SQL（见 [aggregateAppPower] /
///   [aggregateSessionPower]），不做任何猜测。
library;

/// Android `BATTERY_STATUS_DISCHARGING`（Scene 查询 `status in (3,4)` 之一）。
const int kBatteryStatusDischarging = 3;

/// Android `BATTERY_STATUS_NOT_CHARGING`（Scene 查询 `status in (3,4)` 之一）。
const int kBatteryStatusNotCharging = 4;

/// 一次采样记录（对应 `power8.records` 一行）。
///
/// 字段名 / 顺序与 Scene DDL 逐字一致。
class BatteryHistoryRecord {
  const BatteryHistoryRecord({
    required this.time,
    required this.session,
    this.temperature = -1,
    this.status = -1,
    this.mode = '',
    this.current = -1,
    this.voltage = 0,
    this.package = '',
    this.screenOn = 0,
    this.capacity = 0,
  });

  /// `time`（DB 主键，声明为 `text`）—— 采样时间戳（ms）。
  final String time;

  /// `session` —— 录制会话 id。
  final int session;

  /// `temperature`（REAL default `-1`）—— 电池温度（℃）。
  final double temperature;

  /// `status`（int default `-1`）—— Android `BATTERY_STATUS_*`。
  final int status;

  /// `mode`（text）—— Scene 功耗模式标签。
  final String mode;

  /// `current`（int default `-1`）—— 电池电流（mA）。
  final int current;

  /// `voltage` —— 电池电压（volt）。
  ///
  /// DDL 声明为 `int`，但 Scene 插入时绑定 `Double.valueOf(...)`，SQLite 实际按
  /// REAL 存储（task-33）；此处按 `double` 承载**原始操作数**，不做单位换算。
  final double voltage;

  /// `package`（text）—— 前台包名。
  final String package;

  /// `screen_on`（INTEGER）—— 0/1。
  final int screenOn;

  /// `capacity`（INTEGER）—— 电量（%）。
  final int capacity;

  /// 是否为「点亮屏幕且处于放电/未充电」的有效功耗样本。
  ///
  /// 即 Scene 聚合 SQL 的过滤条件 `screen_on = 1 and status in (3, 4)`。
  bool get isPowerSample =>
      screenOn == 1 &&
      (status == kBatteryStatusDischarging ||
          status == kBatteryStatusNotCharging);

  /// 复制并覆盖字段。
  BatteryHistoryRecord copyWith({
    String? time,
    int? session,
    double? temperature,
    int? status,
    String? mode,
    int? current,
    double? voltage,
    String? package,
    int? screenOn,
    int? capacity,
  }) =>
      BatteryHistoryRecord(
        time: time ?? this.time,
        session: session ?? this.session,
        temperature: temperature ?? this.temperature,
        status: status ?? this.status,
        mode: mode ?? this.mode,
        current: current ?? this.current,
        voltage: voltage ?? this.voltage,
        package: package ?? this.package,
        screenOn: screenOn ?? this.screenOn,
        capacity: capacity ?? this.capacity,
      );

  /// 序列化为 JSON 友好映射（键 = Scene 列名，顺序固定）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'time': time,
        'session': session,
        'temperature': temperature,
        'status': status,
        'mode': mode,
        'current': current,
        'voltage': voltage,
        'package': package,
        'screen_on': screenOn,
        'capacity': capacity,
      };

  /// 宽容反序列化：缺失 / 非法字段降级为 Scene 默认值（`temperature`/`status`/
  /// `current` 缺省 `-1`，其余 `0` / 空串），绝不抛出。
  factory BatteryHistoryRecord.fromJson(Map<String, dynamic> json) =>
      BatteryHistoryRecord(
        time: _string(json['time']) ?? '',
        session: _int(json['session']) ?? 0,
        temperature: _finiteDouble(json['temperature']) ?? -1,
        status: _int(json['status']) ?? -1,
        mode: _string(json['mode']) ?? '',
        current: _int(json['current']) ?? -1,
        voltage: _finiteDouble(json['voltage']) ?? 0,
        package: _string(json['package']) ?? '',
        screenOn: _int(json['screen_on']) ?? 0,
        capacity: _int(json['capacity']) ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is BatteryHistoryRecord &&
      other.time == time &&
      other.session == session &&
      other.temperature == temperature &&
      other.status == status &&
      other.mode == mode &&
      other.current == current &&
      other.voltage == voltage &&
      other.package == package &&
      other.screenOn == screenOn &&
      other.capacity == capacity;

  @override
  int get hashCode => Object.hash(
        time,
        session,
        temperature,
        status,
        mode,
        current,
        voltage,
        package,
        screenOn,
        capacity,
      );

  @override
  String toString() => 'BatteryHistoryRecord(time: $time, session: $session, '
      'package: $package, mode: $mode, current: $current, voltage: $voltage, '
      'temperature: $temperature, status: $status, screen_on: $screenOn, '
      'capacity: $capacity)';
}

/// 一个 `(package, mode)` 分组内的功耗统计（Scene `AdapterBatteryStats` 口径）。
class BatteryAppPowerStat {
  const BatteryAppPowerStat({
    required this.package,
    required this.mode,
    required this.current,
    required this.power,
    required this.avgTemperature,
    required this.minTemperature,
    required this.maxTemperature,
    required this.count,
  });

  /// 前台包名（分组键之一）。
  final String package;

  /// 功耗模式标签（分组键之一）。
  final String mode;

  /// 平均电流（mA）= Scene `avg(current)`。
  final double current;

  /// 平均功率 = Scene `avg(current * voltage)`。
  ///
  /// **单位 `unverified`**：Scene `power8` 不做 `/1000` 换算；本值即原始
  /// `avg(current[ mA] * voltage[volt])`，物理单位未经真机交叉验证（task-33）。
  final double power;

  /// 平均温度（℃）= Scene `avg(temperature)`。
  final double avgTemperature;

  /// 最低温度（℃）= Scene `min(temperature)`。
  final double minTemperature;

  /// 最高温度（℃）= Scene `max(temperature)`。
  final double maxTemperature;

  /// 参与统计的样本数 = Scene `count(current)`。
  final int count;

  @override
  bool operator ==(Object other) =>
      other is BatteryAppPowerStat &&
      other.package == package &&
      other.mode == mode &&
      other.current == current &&
      other.power == power &&
      other.avgTemperature == avgTemperature &&
      other.minTemperature == minTemperature &&
      other.maxTemperature == maxTemperature &&
      other.count == count;

  @override
  int get hashCode => Object.hash(package, mode, current, power, avgTemperature,
      minTemperature, maxTemperature, count);

  @override
  String toString() => 'BatteryAppPowerStat(package: $package, mode: $mode, '
      'current: $current, power: $power, avgTemperature: $avgTemperature, '
      'minTemperature: $minTemperature, maxTemperature: $maxTemperature, '
      'count: $count)';
}

/// 会话功耗聚合的过滤条件（Scene SQL `where session = ? and status in (?, ?)
/// and screen_on = 1`；per-app 另加 `and package != ''`）。
bool _matchesSession(BatteryHistoryRecord r, int session) =>
    r.session == session && r.isPowerSample;

/// 按 `(package, mode)` 分组聚合（**逐字**复用 task-33 的 Scene SQL）：
///
/// ```sql
/// select avg(current) AS current, avg(current * voltage) AS power,
///        avg(temperature) as avg, min(temperature) as min,
///        max(temperature) as max, package, mode, count(current)
/// from records
/// where session = ? and status in (?, ?) and screen_on = 1 and package != ''
/// group by package, mode ... order by current
/// ```
///
/// 返回按 `current` 升序（Scene `order by current`）的统计列表；无匹配样本返回空。
List<BatteryAppPowerStat> aggregateAppPower(
  Iterable<BatteryHistoryRecord> records, {
  required int session,
}) {
  // group by package, mode —— 用复合键保持确定性。
  final groups = <String, List<BatteryHistoryRecord>>{};
  for (final r in records) {
    if (!_matchesSession(r, session)) continue;
    if (r.package.isEmpty) continue; // Scene: package != ''
    groups.putIfAbsent('${r.package}\u0000${r.mode}', () => <BatteryHistoryRecord>[])
        .add(r);
  }

  final stats = <BatteryAppPowerStat>[];
  for (final group in groups.values) {
    var sumCurrent = 0.0;
    var sumPower = 0.0;
    var sumTemp = 0.0;
    var minTemp = double.infinity;
    var maxTemp = double.negativeInfinity;
    for (final r in group) {
      sumCurrent += r.current;
      sumPower += r.current * r.voltage;
      sumTemp += r.temperature;
      if (r.temperature < minTemp) minTemp = r.temperature;
      if (r.temperature > maxTemp) maxTemp = r.temperature;
    }
    final n = group.length;
    stats.add(
      BatteryAppPowerStat(
        package: group.first.package,
        mode: group.first.mode,
        current: sumCurrent / n,
        power: sumPower / n,
        avgTemperature: sumTemp / n,
        minTemperature: minTemp,
        maxTemperature: maxTemp,
        count: n,
      ),
    );
  }

  stats.sort((a, b) {
    final byCurrent = a.current.compareTo(b.current);
    if (byCurrent != 0) return byCurrent;
    final byPackage = a.package.compareTo(b.package);
    if (byPackage != 0) return byPackage;
    return a.mode.compareTo(b.mode);
  });
  return stats;
}

/// 会话整体功耗（**逐字**复用 task-33 的 Scene SQL）：
///
/// ```sql
/// select avg(current * voltage) AS power
/// from records where session = ? and status in (?, ?) and screen_on = 1
/// ```
///
/// 注意：Scene 读取该值时用 `getInt`（截断为整数）；本函数返回**未截断**的
/// `double`，交由调用方按需取整。无匹配样本返回 `0`。
double aggregateSessionPower(
  Iterable<BatteryHistoryRecord> records, {
  required int session,
}) {
  var sum = 0.0;
  var n = 0;
  for (final r in records) {
    if (!_matchesSession(r, session)) continue;
    sum += r.current * r.voltage;
    n++;
  }
  return n == 0 ? 0 : sum / n;
}

/// 会话有效样本数（**逐字**复用 task-33 的 Scene SQL）：
///
/// ```sql
/// select count(current) from records
/// where session = ? and status in (?, ?) and screen_on = 1
/// ```
int countSessionSamples(
  Iterable<BatteryHistoryRecord> records, {
  required int session,
}) {
  var n = 0;
  for (final r in records) {
    if (_matchesSession(r, session)) n++;
  }
  return n;
}

/// 从 [records] 中筛选出 [session] 会话的全部记录（按 `time` 升序）。
List<BatteryHistoryRecord> batteryRecordsForSession(
  Iterable<BatteryHistoryRecord> records, {
  required int session,
}) {
  final out = <BatteryHistoryRecord>[
    for (final r in records)
      if (r.session == session) r,
  ];
  out.sort((a, b) => _timeValue(a).compareTo(_timeValue(b)));
  return out;
}

// ==================== 宽容解析辅助 ====================

String? _string(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? _finiteDouble(Object? value) {
  if (value is num) {
    final d = value.toDouble();
    return d.isFinite ? d : null;
  }
  if (value is String) {
    final d = double.tryParse(value.trim());
    if (d != null && d.isFinite) return d;
  }
  return null;
}

/// 记录时间戳（ms）；不可解析时为 `0`（排序用，非语义）。
int _timeValue(BatteryHistoryRecord r) => int.tryParse(r.time.trim()) ?? 0;
