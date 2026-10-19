/// 充电采样器（Scene `ChargeStat` 的 GStore 等价物）——**可注入** sampler / 时钟 /
/// 存储，故单元测试无需真机 / Rust 模块 / 计时等待。
///
/// ## 取证来源（todo 33）
/// Scene `com.omarea.data.customer.ChargeStat`：
/// * `d()` 起定时器 `a0.e(5000L, 1000L)` —— **初始延迟 5s，周期 1s**（充电中采样）；
/// * `c()` 落库门控（**逐字**）：
///   ```java
///   if (GlobalStatus.p.c() != 2) { b(); }              // 非充电 → 停表
///   else if (Math.abs(GlobalStatus.p.b()) > 100) {     // |current| > 100 mA
///       this.f.a(this.g, p.b(), p.p(), p.a(), p.o());  // session,current,voltage,capacity,temp
///   }
///   ```
///   即 **`status == 2`（`BATTERY_STATUS_CHARGING`）且 `|current| > 100`** 才 `insert`。
/// * 落库 `n.a(session, current, voltage, capacity, temperature)`，
///   `time = System.currentTimeMillis()`。
///
/// GStore 的门控逐字落在 [passesChargeGate] / [buildChargeRecord]（见
/// `charge_history.dart`）：`PerfModule` 读到的 sysfs 状态字符串 `"Charging"` 直接
/// 对应 `BATTERY_STATUS_CHARGING == 2`（`rust/gstore_mod_perf/src/collectors/
/// battery.rs` 读 `status` 节点）。
///
/// ## 设计
/// * **可注入**：[ChargeSampler]（返回 `null` 表示本拍无数据）、[ChargeHistoryStore]、
///   [ChargeRecorderClock]、[interval] / [initialDelay] / [session] 全部可注入；
/// * **软失败**：sampler 抛异常（如 `PerfModuleUnavailableException`）/ 返回 `null`
///   / 未过门控 / 数值缺失 → **跳过**该拍（不落库、不中断、不抛出）；
/// * **即写**：每拍通过门控即直接 [ChargeHistoryStore.append]（**无**内存缓冲，与
///   Scene 一致），故 `stop` 只是停表；
/// * **可观测**：[ChangeNotifier]，起停 / 每拍成功落库后通知 UI。
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;

import 'package:gstore/core/perf/charge_history.dart';
import 'package:gstore/core/perf/charge_history_store.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart' show BatteryReport;
import 'package:gstore/core/rust/perf/PerfModule.dart' show PerfModule;

/// 采样器：返回本拍实时电池读数；无数据返回 `null`。
typedef ChargeSampler = Future<ChargeSnapshot?> Function();

/// 时钟（Unix 时间源）；测试注入以便 `time` 可复现。
typedef ChargeRecorderClock = DateTime Function();

/// 默认采样间隔（1 秒；Scene `a0.e(5000L, 1000L)` 的周期）。
const Duration kChargeHistoryDefaultInterval = Duration(seconds: 1);

/// 默认初始延迟（5 秒；Scene `a0.e(5000L, 1000L)` 的首参）。
const Duration kChargeHistoryDefaultInitialDelay = Duration(seconds: 5);

/// 充电采样器。
class ChargeHistoryRecorder extends ChangeNotifier {
  ChargeHistoryRecorder({
    ChargeSampler? sampler,
    required ChargeHistoryStore store,
    ChargeRecorderClock? clock,
    this.interval = kChargeHistoryDefaultInterval,
    this.initialDelay = kChargeHistoryDefaultInitialDelay,
    int session = 0,
  })  : _sampler = sampler ?? _defaultSampler,
        _store = store,
        _clock = clock ?? DateTime.now,
        _sessionId = session;

  /// 采样间隔。
  final Duration interval;

  /// 首次采样前的延迟。
  final Duration initialDelay;

  final ChargeSampler _sampler;
  final ChargeHistoryStore _store;
  final ChargeRecorderClock _clock;

  /// 默认采样器（生产）：`PerfModule.instance.battery()` → [ChargeSnapshot]。
  static Future<ChargeSnapshot?> _defaultSampler() async {
    try {
      final BatteryReport report = await PerfModule.instance.battery();
      if (!report.present) return null;
      return ChargeSnapshot(
        currentMa: report.currentMa,
        voltageV: report.voltageV,
        capacityPercent: report.capacityPercent,
        temperatureC: report.temperatureC,
        status: report.status,
      );
    } catch (error) {
      debugPrint('[ChargeHistoryRecorder] 默认采样失败（跳过）: $error');
      return null;
    }
  }

  bool _disposed = false;
  bool _recording = false;
  Timer? _timer;
  int _sessionId;
  int _insertedCount = 0;
  ChargeSnapshot? _lastSnapshot;

  /// 是否正在录制。
  bool get isRecording => _recording;

  /// 是否已释放（释放后所有操作 no-op）。
  bool get isDisposed => _disposed;

  /// 当前会话 id。
  int get sessionId => _sessionId;

  /// 已成功落库的行数。
  int get insertedCount => _insertedCount;

  /// 最近一拍的原始读数（无论是否落库）；尚无采样时为 `null`。
  ChargeSnapshot? get lastSnapshot => _lastSnapshot;

  /// 开始采样（幂等：采样中调用为 no-op）。
  ///
  /// [session] 非空时覆盖当前会话 id。
  void start({int? session}) {
    if (_disposed || _recording) return;
    if (session != null) _sessionId = session;
    _recording = true;
    // Scene `a0.e(5000L, 1000L)`：先延迟，再按周期采样。
    _timer = Timer(initialDelay, () {
      if (_disposed || !_recording) return;
      unawaited(_onTick());
      _timer = Timer.periodic(interval, (_) => unawaited(_onTick()));
    });
    notifyListeners();
  }

  /// 停止采样（停表；未在采样时为 no-op）。
  Future<void> stop() async {
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
    ChargeSnapshot? snapshot;
    try {
      snapshot = await _sampler();
    } catch (error) {
      debugPrint('[ChargeHistoryRecorder] 采样异常（跳过本拍）: $error');
      return false;
    }
    if (_disposed || snapshot == null) return false;
    _lastSnapshot = snapshot;
    final record = buildChargeRecord(
      snapshot,
      time: _clock().millisecondsSinceEpoch,
      session: _sessionId,
    );
    if (record == null) return false;
    try {
      await _store.append(record);
    } catch (error) {
      debugPrint('[ChargeHistoryRecorder] 落库失败（忽略）: $error');
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
