/// 电池/功耗历史采样器的**门控启动**（默认 OFF）。
///
/// 采样器本身（[BatteryHistoryRecorder]）只负责「起表 / 停表 / 采样落库」；
/// **何时启动**是策略问题，由本文件承担：
///
/// * 持久化开关为 [ConfigKeys.perfHistoryEnabled]（`perf.history.enabled`），
///   **默认 false**（fail-closed）；
/// * App 启动（`lib/main.dart`）经 [startBatteryHistoryRecorderIfEnabled] 读取该键，
///   仅当为 `true` 时才 `start()`；关闭时**不启动、也不触碰 Rust `PerfModule`**
///   （单例惰性构造，`start()` 前不采样，故不会实例化 perf 模块）；
/// * 用户经性能页「后台采样」开关显式开启/关闭（见 `lib/page/perf/logic.dart`
///   `toggleSampling`），该开关会写回本键，故下次启动由本门控恢复。
///
/// **best-effort**：读取配置失败按「关闭」处理；启动失败仅记录日志，绝不抛出、
/// 绝不阻塞启动。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/config/config_registry.dart' show ConfigKeys;
import 'package:gstore/core/config/config_store.dart' show ConfigStore;
import 'package:gstore/core/perf/battery_history_recorder.dart'
    show BatteryHistoryRecorder, batteryHistoryRecorder;

/// 读取门控开关（生产走 [ConfigStore]；测试注入）。
typedef BatteryHistoryEnabledReader = Future<bool?> Function();

/// 取采样器实例（生产返回 App 级单例 [batteryHistoryRecorder]；测试注入假记录器）。
///
/// **惰性**：关闭时不会调用该 getter，故不会构造单例、不会触碰 Rust `PerfModule`。
typedef BatteryHistoryRecorderGetter = BatteryHistoryRecorder Function();

/// 启动日志回调（生产经 `appLog.info`；测试捕获）。
typedef BatteryHistoryStartLog = void Function(String message);

/// 读取生产门控值：读 [ConfigKeys.perfHistoryEnabled]；未设置 → `null`（按关闭处理）。
Future<bool?> readBatteryHistoryEnabled() =>
    ConfigStore.instance.readBool(ConfigKeys.perfHistoryEnabled);

/// 门控启动电池历史采样器（**默认 OFF**），返回是否实际启动了采样器。
///
/// * 读取 [ConfigKeys.perfHistoryEnabled]（默认 false）；仅 `true` 时 `start()`；
/// * 关闭 / 未设置 / 读取失败 → 返回 `false`，**不调用** [recorder] getter，
///   因此**不构造**单例、**不触碰** Rust `PerfModule`；
/// * `start()` 自身幂等，重复调用不会起多个定时器；
/// * **绝不抛出**：任何异常都降级为「未启动」。
Future<bool> startBatteryHistoryRecorderIfEnabled({
  BatteryHistoryEnabledReader? readEnabled,
  BatteryHistoryRecorderGetter? recorder,
  BatteryHistoryStartLog? log,
}) async {
  bool enabled;
  try {
    enabled = (await (readEnabled ?? readBatteryHistoryEnabled)()) ?? false;
  } catch (error) {
    debugPrint('[BatteryHistoryGate] 读取门控开关失败（按关闭处理）: $error');
    enabled = false;
  }
  if (!enabled) return false;
  try {
    final target = (recorder ?? () => batteryHistoryRecorder)();
    target.start();
    log?.call('电池历史采样器已启动（session=${target.sessionId}）');
    return true;
  } catch (error, stack) {
    debugPrint('[BatteryHistoryGate] 启动失败（已忽略，不影响启动）: $error\n$stack');
    return false;
  }
}
