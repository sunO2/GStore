/// 电池/功耗历史采样器（Scene `com.omarea.data.customer.PowerStat` 的 GStore 等价物）
/// ——**可注入** sampler / 时钟 / 存储，故单元测试无需真机 / Shizuku / 计时等待。
///
/// ## 取证来源（todo 33 + 反编译 `PowerStat`）
/// Scene 真实写入器 `com.omarea.data.customer.PowerStat`（写入 DB `power8` /
/// 表 `records`，逐字取自 `.omo/evidence/task-33-scene-data-schema.md` 与
/// `/tmp/opencode/scene8/rea_t33_out.txt`）：
///
/// ```java
/// private final void e() {
///     if (!this.f.d() && this.h.c() && this.f.e(1000L, 3000L)) {   // 屏幕亮 → 起表 (1s, 3s)
///         GlobalStatus.z(GlobalStatus.p, 0L, 1, null);
///     }
/// }
/// private final void d() {
///     ...
///     if (GlobalStatus.p.h()) { return; }          // status==2(CHARGING)||5(FULL) → 不采样
///     boolean zC = this.h.c();                      // screen_on
///     long now = System.currentTimeMillis();
///     if (now - this.k > 86400000) { c(); }         // 每 24h 轮换会话
///     long jAbs = Math.abs(GlobalStatus.p.b());     // |current|
///     if (GlobalStatus.p.c() != 2 ? jAbs > 10000 : jAbs > 60000) { ... return; } // 功率尖峰 → 轮换会话
///     BatteryStatus batteryStatus = new BatteryStatus();
///     batteryStatus.time = now;
///     batteryStatus.session = this.i;
///     batteryStatus.temperature = GlobalStatus.p.o();
///     batteryStatus.status = GlobalStatus.p.c();
///     batteryStatus.current = (int) GlobalStatus.p.b();
///     double dP = GlobalStatus.p.p();
///     if (dP > 0) { batteryStatus.voltage = dP; }
///     batteryStatus.screenOn = zC;
///     batteryStatus.capacity = GlobalStatus.p.a();
///     batteryStatus.packageName = GlobalStatus.p.i();
///     batteryStatus.mode = ModeSwitcher.v.d();
///     this.g.k(batteryStatus);                       // insert into power8.records
///     if (zC) { return; }
///     b();                                          // 熄屏 → 停表
/// }
/// ```
///
/// ## 门控（CITED，逐条落码见 [buildBatteryHistoryRecord] / [passesBatteryHistoryGate]）
/// 1. **采样节拍**：初始延迟 1s、周期 3s（Scene `a0.e(1000L, 3000L)`，常量
///    [kBatteryHistoryDefaultInitialDelay] / [kBatteryHistoryDefaultInterval]）。
/// 2. **屏幕条件**：仅**亮屏**采样（Scene 熄屏停表）；本记录器对熄屏样本**跳过**
///    （不落库、不抛）。GStore 屏幕状态经 Shizuku `dumpsys power` 解析
///    （复用 [ForegroundWatcher.parseScreenOn]，与 23 号前台监视器同口径）；
///    无法判定时 **fail-open 视为亮屏**（与 `ForegroundWatcher` 一致，避免静默停摆）。
/// 3. **状态条件**：`status == 2 (CHARGING) || status == 5 (FULL)` 时**不采样**
///    （Scene `GlobalStatus.p.h()` 短路）；即仅记录放电 / 未充电（及 UNKNOWN）行。
///    查询侧仍按 Scene SQL 过滤 `screen_on = 1 and status in (3, 4)`
///    （见 `battery_history.dart`）。
/// 4. **数值完整性**：`temperature` / `current` / `voltage` / `capacity` 缺失或非有限
///    → 跳过该拍（**安全偏差**：Scene 会以默认值 `-1` / `0` 落库，但那会污染聚合；
///    GStore 选择丢弃不完整读数，已在证据中标注）。
///
/// ## 会话 id
/// Scene 从 `f0.l()` 取「下一个会话号」（自增 + 裁剪）。GStore 无需 SQLite 会话表，
/// 默认以**启动时刻**（`clock().millisecondsSinceEpoch`）作为会话 id（每次 App 启动
/// 唯一），并允许经 [start] / 构造注入覆盖；容量裁剪由
/// [SharedPrefsBatteryHistoryStore]（≤ 99 会话，见 todo 18）负责。
///
/// ## 机制 / 单位偏差（相对 Scene）
/// * **持久化**：Scene 用 SQLite（`power8`）；GStore 沿用既有约定经
///   [SharedPrefsBatteryHistoryStore]（单键 JSON）。字段 schema 逐字沿用 Scene。
/// * **`mode`**：Scene 取 `ModeSwitcher.v.d()`（功耗模式标签）；GStore 的「当前生效
///   profile 标签」映射由 todo 24/25 拥有，本记录器默认留**空串**（自由字段），
///   不猜测、不硬编码。
/// * **功率单位 `unverified`**：`power8` 用原始 `avg(current * voltage)`（不 `/1000`），
///   见 `battery_history.dart` / todo 33；本记录器只持久化原始操作数。
///
/// ## 静默（务必遵守）
/// * sampler 抛异常（如 `PerfModuleUnavailableException`）/ 返回 `null` / 未过门控
///   / 数值缺失 → **跳过**该拍（不落库、不中断、不抛出）；
/// * Shizuku 不可用 / 未授权 / 平台通道缺失 → 屏幕 / 前台探测降级（不抛），
///   记录器仍按 fail-open 语义运行或静默跳过；
/// * 落库失败静默（仅日志）。
///
/// ## 可观测
/// [ChangeNotifier]：`start` / `stop` / 每拍成功落库后通知 UI。
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;

import 'package:gstore/core/perf/battery_history.dart';
import 'package:gstore/core/perf/battery_history_store.dart';
import 'package:gstore/core/perf/foreground_watcher.dart' show ForegroundWatcher;
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart' show BatteryReport;
import 'package:gstore/core/rust/perf/PerfModule.dart' show PerfModule;

/// 采样器：返回本拍实时读数（含屏幕 / 前台包 / 模式）；无数据返回 `null`。
typedef BatteryHistorySampler = Future<BatteryHistorySample?> Function();

/// 时钟（Unix 时间源）；测试注入以便 `time` / 会话 id 可复现。
typedef BatteryRecorderClock = DateTime Function();

/// 默认采样初始延迟（1 秒；Scene `PowerStat.e()` → `a0.e(1000L, 3000L)` 首参）。
const Duration kBatteryHistoryDefaultInitialDelay = Duration(seconds: 1);

/// 默认采样间隔（3 秒；Scene `PowerStat.e()` → `a0.e(1000L, 3000L)` 周期）。
const Duration kBatteryHistoryDefaultInterval = Duration(seconds: 3);

/// Android `BATTERY_STATUS_UNKNOWN`（无法判定状态的兜底）。
const int kBatteryStatusUnknown = 1;

/// Android `BATTERY_STATUS_CHARGING`（Scene `h()` 短路状态之一）。
const int kBatteryStatusCharging = 2;

/// Android `BATTERY_STATUS_FULL`（Scene `h()` 短路状态之一）。
const int kBatteryStatusFull = 5;

/// sysfs `status` 字符串 → Android `BATTERY_STATUS_*` 整型（大小写不敏感）。
///
/// GStore 经 [PerfModule] 读到的是 sysfs 字符串（`battery.rs`），其映射为：
/// `Charging`→2 / `Discharging`→3 / `Not charging`→4 / `Full`→5；其余（含
/// `Unknown` / `null`）→1。查询侧过滤 `status in (3,4)`（见 `battery_history.dart`）。
int batteryStatusFromLabel(String? label) {
  switch (label?.trim().toLowerCase()) {
    case 'charging':
      return kBatteryStatusCharging;
    case 'discharging':
      return kBatteryStatusDischarging; // 3
    case 'not charging':
      return kBatteryStatusNotCharging; // 4
    case 'full':
      return kBatteryStatusFull;
    default:
      return kBatteryStatusUnknown;
  }
}

/// 一次实时读数（采样器输出，非持久化行）。字段语义对齐 `power8.records`。
class BatteryHistorySample {
  const BatteryHistorySample({
    required this.status,
    required this.screenOn,
    this.temperatureC,
    this.currentMa,
    this.voltageV,
    this.capacityPercent,
    this.package = '',
    this.mode = '',
  });

  /// Android `BATTERY_STATUS_*`（见 [batteryStatusFromLabel]）。
  final int status;

  /// 屏幕是否点亮（`screen_on` 门控；`true` 才可能落库）。
  final bool screenOn;

  /// 电池温度（℃）。
  final double? temperatureC;

  /// 电池电流（mA，有符号）。
  final double? currentMa;

  /// 电池电压（V）。
  final double? voltageV;

  /// 电量（%）。
  final double? capacityPercent;

  /// 前台包名（无法判定为空串）。
  final String package;

  /// Scene 功耗模式标签（自由文本；GStore 默认空串，见库文档）。
  final String mode;

  @override
  String toString() => 'BatteryHistorySample(status: $status, '
      'screenOn: $screenOn, temperatureC: $temperatureC, currentMa: $currentMa, '
      'voltageV: $voltageV, capacityPercent: $capacityPercent, '
      'package: $package, mode: $mode)';
}

/// 门控判定（逐条复刻 Scene `PowerStat`）：
/// * **亮屏**（[BatteryHistorySample.screenOn]）；
/// * **非充电 / 满电**（`status != 2 && status != 5`）；
/// * `temperature` / `current` / `voltage` / `capacity` 均存在且有限，`voltage > 0`。
bool passesBatteryHistoryGate(BatteryHistorySample sample) {
  if (!sample.screenOn) return false;
  if (sample.status == kBatteryStatusCharging ||
      sample.status == kBatteryStatusFull) {
    return false;
  }
  final temperature = sample.temperatureC;
  final current = sample.currentMa;
  final voltage = sample.voltageV;
  final capacity = sample.capacityPercent;
  if (temperature == null || !temperature.isFinite) return false;
  if (current == null || !current.isFinite) return false;
  if (voltage == null || !voltage.isFinite || voltage <= 0) return false;
  if (capacity == null || !capacity.isFinite) return false;
  return true;
}

/// 由实时读数构造一行 [BatteryHistoryRecord]（[time] / [session] 由调用方注入，
/// 保证确定性）。返回 `null`（不落库）当且仅当未过 [passesBatteryHistoryGate]。
BatteryHistoryRecord? buildBatteryHistoryRecord(
  BatteryHistorySample sample, {
  required int time,
  required int session,
}) {
  if (!passesBatteryHistoryGate(sample)) return null;
  return BatteryHistoryRecord(
    time: time.toString(),
    session: session,
    temperature: sample.temperatureC!,
    status: sample.status,
    mode: sample.mode,
    current: sample.currentMa!.round(),
    voltage: sample.voltageV!,
    package: sample.package,
    screenOn: sample.screenOn ? 1 : 0,
    capacity: sample.capacityPercent!.round(),
  );
}

/// 电池/功耗历史采样器（Scene `PowerStat` 等价）。
///
/// 生产：`BatteryHistoryRecorder(store: const SharedPrefsBatteryHistoryStore())`
/// （默认经 [PerfModule] + [PrivilegedShell] 探测屏幕 / 前台）。
/// 测试：注入假 [BatteryHistorySampler] + 假时钟 + [InMemoryBatteryHistoryStore]。
class BatteryHistoryRecorder extends ChangeNotifier {
  BatteryHistoryRecorder({
    BatteryHistorySampler? sampler,
    required BatteryHistoryStore store,
    BatteryRecorderClock? clock,
    this.interval = kBatteryHistoryDefaultInterval,
    this.initialDelay = kBatteryHistoryDefaultInitialDelay,
    int? session,
  })  : _sampler = sampler ?? _defaultSampler,
        _store = store,
        _clock = clock ?? DateTime.now {
    // 默认会话 id = 启动时刻（ms）；调用方可经 `session` 覆盖。
    _sessionId = session ?? _clock().millisecondsSinceEpoch;
  }

  /// 采样间隔（默认 3s）。
  final Duration interval;

  /// 首次采样前的延迟（默认 1s）。
  final Duration initialDelay;

  final BatteryHistorySampler _sampler;
  final BatteryHistoryStore _store;
  final BatteryRecorderClock _clock;

  /// 共享特权 shell（生产：经 [rustShizukuRunner]；不校验固定命令体）。
  static final PrivilegedShell _sharedShell = PrivilegedShell(
    timeout: const Duration(seconds: 5),
    inShellTimeoutSeconds: 3,
  );

  /// 屏幕探测命令（`dumpsys power`）。
  static const String screenCommand = 'dumpsys power';

  /// 前台探测命令（`dumpsys activity activities`）。
  static const String foregroundCommand = 'dumpsys activity activities';

  /// 默认采样器（生产）：先探屏幕（熄屏 → 直接返回熄屏样本，不读电池 / 前台），
  /// 再经 [PerfModule] 读电池、经 Shizuku 探前台包名。**绝不抛出**。
  static Future<BatteryHistorySample?> _defaultSampler() async {
    final screenOn = await _probeScreenOn();
    if (!screenOn) {
      return const BatteryHistorySample(
        status: kBatteryStatusUnknown,
        screenOn: false,
      );
    }
    final BatteryReport report;
    try {
      report = await PerfModule.instance.battery();
    } catch (error) {
      debugPrint('[BatteryHistoryRecorder] 电池读取失败（跳过本拍）: $error');
      return null;
    }
    if (!report.present) return null;
    final package = await _probeForegroundPackage();
    return BatteryHistorySample(
      status: batteryStatusFromLabel(report.status),
      screenOn: true,
      temperatureC: report.temperatureC,
      currentMa: report.currentMa,
      voltageV: report.voltageV,
      capacityPercent: report.capacityPercent,
      package: package,
      // Scene `ModeSwitcher.v.d()` 等价标签由 todo 24/25 提供；此处留空。
      mode: '',
    );
  }

  /// 屏幕是否点亮；命令失败 / 解析不确定 → `true`（fail-open，同 ForegroundWatcher）。
  static Future<bool> _probeScreenOn() async {
    try {
      final result =
          await _sharedShell.run(_sharedShell.buildCommand(screenCommand));
      if (!result.ok) return true;
      return ForegroundWatcher.parseScreenOn(result.output);
    } catch (error) {
      debugPrint('[BatteryHistoryRecorder] 屏幕探测异常（按亮屏处理）: $error');
      return true;
    }
  }

  /// 前台包名；Shizuku 不可用 / 解析失败 → 空串（不猜测）。**绝不抛出**。
  static Future<String> _probeForegroundPackage() async {
    try {
      final result = await _sharedShell
          .run(_sharedShell.buildCommand(foregroundCommand));
      if (!result.ok) return '';
      final report = await PerfModule.instance.foreground(result.output);
      return report.package ?? '';
    } catch (error) {
      debugPrint('[BatteryHistoryRecorder] 前台探测失败（按空包名处理）: $error');
      return '';
    }
  }

  bool _disposed = false;
  bool _recording = false;
  Timer? _timer;
  late int _sessionId;
  int _insertedCount = 0;
  int _skippedForScreenOffCount = 0;
  BatteryHistorySample? _lastSample;

  /// 是否正在录制。
  bool get isRecording => _recording;

  /// 是否已释放（释放后所有操作 no-op）。
  bool get isDisposed => _disposed;

  /// 当前会话 id。
  int get sessionId => _sessionId;

  /// 已成功落库的行数。
  int get insertedCount => _insertedCount;

  /// 因熄屏而跳过的拍数。
  int get skippedForScreenOffCount => _skippedForScreenOffCount;

  /// 最近一拍的原始读数（无论是否落库）；尚无采样时为 `null`。
  BatteryHistorySample? get lastSample => _lastSample;

  /// 开始采样（幂等：采样中调用为 no-op）。
  ///
  /// [session] 非空时覆盖当前会话 id。
  void start({int? session}) {
    if (_disposed || _recording) return;
    if (session != null) _sessionId = session;
    _recording = true;
    // Scene `a0.e(1000L, 3000L)`：先延迟，再按周期采样。
    _timer = Timer(initialDelay, () {
      if (_disposed || !_recording) return;
      unawaited(_onTick());
      _timer = Timer.periodic(interval, (_) => unawaited(_onTick()));
    });
    notifyListeners();
  }

  /// 停止采样（停表；未在采样时为 no-op）。
  void stop() {
    if (_disposed || !_recording) return;
    _recording = false;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
  }

  /// 采样并（在通过门控时）落库一拍；返回本拍是否落库。
  ///
  /// 供定时器调用，亦可直接用于确定性单元测试。**绝不抛出**。
  @visibleForTesting
  Future<bool> sampleOnce() async {
    if (_disposed) return false;
    BatteryHistorySample? sample;
    try {
      sample = await _sampler();
    } catch (error) {
      debugPrint('[BatteryHistoryRecorder] 采样异常（跳过本拍）: $error');
      return false;
    }
    if (_disposed || sample == null) return false;
    _lastSample = sample;
    if (!sample.screenOn) {
      _skippedForScreenOffCount++;
      return false;
    }
    final record = buildBatteryHistoryRecord(
      sample,
      time: _clock().millisecondsSinceEpoch,
      session: _sessionId,
    );
    if (record == null) return false;
    try {
      await _store.append(record);
    } catch (error) {
      debugPrint('[BatteryHistoryRecorder] 落库失败（忽略）: $error');
      return false;
    }
    if (_disposed) return false;
    _insertedCount++;
    notifyListeners();
    return true;
  }

  Future<void> _onTick() async {
    if (_disposed || !_recording) return;
    await sampleOnce();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// App 级单例（[main] 启动；惰性创建，首次访问前无副作用）。
final BatteryHistoryRecorder batteryHistoryRecorder = BatteryHistoryRecorder(
  store: const SharedPrefsBatteryHistoryStore(),
);
