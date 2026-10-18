/// 性能告警核心 —— **纯 Dart 阈值评估 + 节流/去重派发**（无 Flutter 依赖）。
///
/// 本文件只做两件事，均不触碰 Flutter 运行时，可在 `flutter_test` / 纯 Dart
/// 测试中直接实例化与断言：
/// 1. [evaluate]：把最新报告（[CpuReport] / [ThermalReport] / [FrameStats] /
///    [ThirdPartyAppMetrics]）与 [PerfAlertSettings] 比阈值，产出 [PerfAlert]
///    列表。判定为纯函数：CPU/温度/Jank **严格大于**阈值告警，FPS **严格小于**
///    阈值告警；输入为空 / 字段为 `null` / `NaN` 一律跳过（不猜）。
/// 2. [PerfAlertDispatcher]：按 kind **去重 + 节流**（同一 kind 在 N 秒内只发一次），
///    再分别经 [PerfAlertNotifier] 出口发「应用内横幅」与「系统通知」。绝不抛错。
///
/// Flutter 侧的出口实现（Snackbar + `flutter_local_notifications`）在
/// `perf_alert_notifier.dart`，使本文件保持纯净、可单测。
library;

import 'dart:math' as math;

import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_alert_settings.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

// ==================== 告警模型 ====================

/// 告警种类（同时作为去重 / 节流的键）。
enum PerfAlertKind {
  /// CPU 总占用过高。
  cpu,

  /// 温度过高。
  temperature,

  /// Jank 帧占比过高。
  jank,

  /// FPS 过低。
  fps;

  /// 展示用中文短标签。
  String get label => switch (this) {
        PerfAlertKind.cpu => 'CPU 占用',
        PerfAlertKind.temperature => '温度',
        PerfAlertKind.jank => 'Jank 比例',
        PerfAlertKind.fps => '帧率',
      };

  /// 数值单位后缀（拼接展示用）。
  String get unit => switch (this) {
        PerfAlertKind.cpu => '%',
        PerfAlertKind.temperature => '°C',
        PerfAlertKind.jank => '%',
        PerfAlertKind.fps => 'fps',
      };
}

/// 一条触发的告警。
class PerfAlert {
  const PerfAlert({
    required this.kind,
    required this.value,
    required this.threshold,
  });

  /// 告警种类。
  final PerfAlertKind kind;

  /// 触发时的实测值。
  final double value;

  /// 触发的阈值。
  final double threshold;

  /// 人类可读文案（如「CPU 占用 92.0% 超过阈值 80%」）。
  String get message {
    final valueText = _format(value);
    final thresholdText = _format(threshold);
    return switch (kind) {
      PerfAlertKind.fps => '帧率 $valueText ${kind.unit} 低于阈值 $thresholdText',
      _ => '${kind.label} $valueText${kind.unit} 超过阈值 $thresholdText',
    };
  }

  /// 去掉无意义的小数尾零（80.0 → 80，92.5 → 92.5）。
  static String _format(double value) {
    if (!value.isFinite) return '$value';
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }

  @override
  bool operator ==(Object other) =>
      other is PerfAlert &&
      other.kind == kind &&
      other.value == value &&
      other.threshold == threshold;

  @override
  int get hashCode => Object.hash(kind, value, threshold);

  @override
  String toString() => 'PerfAlert(${kind.name}, value=$value, '
      'threshold=$threshold)';
}

// ==================== 纯评估 ====================

/// 纯阈值评估：返回本次触发的告警列表。
///
/// * [settings] 的 `enabled` 为 `false` 时直接返回空列表（默认不打扰）；
/// * CPU 取 [CpuReport.usagePercent]；温度取 [ThermalReport.maxTempC]；
/// * Jank 取 [ThirdPartyAppMetrics.jankyPercent] 与窗口 Jank 比例
///   （[FrameStats.windowJankRatio] × 100）中的**较大者**；
/// * FPS 取 [ThirdPartyAppMetrics.fps] 与 [FrameStats.fps] 中的**较小者**
///   （帧统计需 ≥2 帧且有有效间隔，避免把「无样本」误判为 0fps）；
/// * 每个 kind 最多产出**一条**告警，便于上层按 kind 去重/节流。
List<PerfAlert> evaluate({
  CpuReport? cpu,
  ThermalReport? thermal,
  FrameStats? frames,
  ThirdPartyAppMetrics? thirdParty,
  required PerfAlertSettings settings,
}) {
  if (!settings.enabled) return const <PerfAlert>[];
  final alerts = <PerfAlert>[];

  final cpuUsage = cpu?.usagePercent;
  if (cpuUsage != null && cpuUsage.isFinite && cpuUsage > settings.cpuPercent) {
    alerts.add(
      PerfAlert(
        kind: PerfAlertKind.cpu,
        value: cpuUsage,
        threshold: settings.cpuPercent,
      ),
    );
  }

  final temp = thermal?.maxTempC;
  if (temp != null && temp.isFinite && temp > settings.temperatureC) {
    alerts.add(
      PerfAlert(
        kind: PerfAlertKind.temperature,
        value: temp,
        threshold: settings.temperatureC,
      ),
    );
  }

  final jankCandidates = <double>[];
  final thirdPartyJank = thirdParty?.jankyPercent;
  if (thirdPartyJank != null && thirdPartyJank.isFinite) {
    jankCandidates.add(thirdPartyJank);
  }
  if (frames != null && frames.sampledFrames > 0) {
    final windowJank = frames.windowJankRatio * 100;
    if (windowJank.isFinite) jankCandidates.add(windowJank);
  }
  if (jankCandidates.isNotEmpty) {
    final maxJank = jankCandidates.reduce(math.max);
    if (maxJank > settings.jankPercent) {
      alerts.add(
        PerfAlert(
          kind: PerfAlertKind.jank,
          value: maxJank,
          threshold: settings.jankPercent,
        ),
      );
    }
  }

  final fpsCandidates = <double>[];
  final thirdPartyFps = thirdParty?.fps;
  if (thirdPartyFps != null && thirdPartyFps.isFinite) {
    fpsCandidates.add(thirdPartyFps);
  }
  if (frames != null &&
      frames.sampledFrames >= 2 &&
      frames.frameIntervalMs > 0 &&
      frames.fps.isFinite) {
    fpsCandidates.add(frames.fps);
  }
  if (fpsCandidates.isNotEmpty) {
    final minFps = fpsCandidates.reduce(math.min);
    if (minFps < settings.minFps) {
      alerts.add(
        PerfAlert(
          kind: PerfAlertKind.fps,
          value: minFps,
          threshold: settings.minFps,
        ),
      );
    }
  }

  return alerts;
}

// ==================== 出口接缝 ====================

/// 告警出口：应用内横幅（Snackbar）+ 系统通知。
///
/// 生产实现见 `perf_alert_notifier.dart` 的 `LocalPerfAlertNotifier`；
/// 测试注入 spy / 内存实现即可，无需 Flutter binding 或原生通道。
abstract class PerfAlertNotifier {
  /// 展示应用内横幅（Snackbar）。
  Future<void> showBanner(PerfAlert alert);

  /// 推送系统通知。
  Future<void> notify(PerfAlert alert);
}

/// 一次派发的结果（分别记录实际发出的横幅 / 通知，供测试与诊断）。
class PerfDispatchResult {
  const PerfDispatchResult({
    this.banners = const <PerfAlert>[],
    this.notifications = const <PerfAlert>[],
  });

  /// 实际发出的横幅告警。
  final List<PerfAlert> banners;

  /// 实际发出的系统通知告警。
  final List<PerfAlert> notifications;

  /// 是否未派发任何告警。
  bool get isEmpty => banners.isEmpty && notifications.isEmpty;
}

// ==================== 节流 / 派发 ====================

/// 告警派发器：按 kind 去重 + 节流后经 [notifier] 发横幅 / 通知。
///
/// * 同一 kind 在 [bannerThrottle] / [notifyThrottle] 内最多各发一次；
/// * 横幅与通知各自独立节流（受 [PerfAlertSettings.banner] /
///   [PerfAlertSettings.notify] 开关控制）；
/// * [clock] 可注入，测试可用受控时间验证节流窗口；
/// * 出口调用一律 `try/catch` 兜底——通知 / 横幅失败绝不向上抛错。
class PerfAlertDispatcher {
  PerfAlertDispatcher({
    required PerfAlertNotifier notifier,
    DateTime Function()? clock,
    this.bannerThrottle = const Duration(seconds: 60),
    this.notifyThrottle = const Duration(seconds: 60),
  })  : _notifier = notifier,
        _clock = clock ?? DateTime.now;

  final PerfAlertNotifier _notifier;
  final DateTime Function() _clock;

  /// 同一 kind 的横幅最小间隔。
  final Duration bannerThrottle;

  /// 同一 kind 的通知最小间隔。
  final Duration notifyThrottle;

  final Map<PerfAlertKind, DateTime> _lastBanner = {};
  final Map<PerfAlertKind, DateTime> _lastNotify = {};

  /// 按 kind 去重 + 节流后派发 [alerts]；返回实际发出的告警。
  ///
  /// [settings] 的 `enabled` 为 `false` 时直接返回空结果。绝不抛错。
  Future<PerfDispatchResult> dispatch(
    List<PerfAlert> alerts, {
    required PerfAlertSettings settings,
  }) async {
    if (!settings.enabled || alerts.isEmpty) {
      return const PerfDispatchResult();
    }
    final now = _clock();
    final banners = <PerfAlert>[];
    final notifications = <PerfAlert>[];

    // 同一批内同 kind 只处理一次（去重）。
    final seen = <PerfAlertKind>{};
    for (final alert in alerts) {
      if (!seen.add(alert.kind)) continue;

      if (settings.banner && _shouldEmit(_lastBanner, alert.kind, now,
          bannerThrottle)) {
        _lastBanner[alert.kind] = now;
        banners.add(alert);
        await _safe(() => _notifier.showBanner(alert));
      }

      if (settings.notify && _shouldEmit(_lastNotify, alert.kind, now,
          notifyThrottle)) {
        _lastNotify[alert.kind] = now;
        notifications.add(alert);
        await _safe(() => _notifier.notify(alert));
      }
    }

    return PerfDispatchResult(banners: banners, notifications: notifications);
  }

  /// 该 kind 距上次发出是否已过 [throttle]（无记录恒为真）。
  static bool _shouldEmit(
    Map<PerfAlertKind, DateTime> last,
    PerfAlertKind kind,
    DateTime now,
    Duration throttle,
  ) {
    final previous = last[kind];
    if (previous == null) return true;
    return now.difference(previous) >= throttle;
  }

  /// 出口调用兜底：任何异常都吞掉（仅记录），绝不打断采样循环。
  static Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // 通知 / 横幅失败不影响主流程；此处静默（避免引入 Flutter 依赖）。
    }
  }
}
