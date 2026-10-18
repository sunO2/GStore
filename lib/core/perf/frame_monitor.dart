/// GStore 帧时序监控器（应用侧 FPS / jank 采集）。
///
/// 通过 Flutter 标准的 [SchedulerBinding.addTimingsCallback] 订阅 `FrameTiming`
/// （每帧 build + raster 耗时），转成纯时长喂给 [FrameStatsAccumulator]，并以
/// **节流**方式对外发布统计快照，避免每帧触发的通知造成 UI 抖动。
///
/// 设计要点：
/// * **不做 JNI / 平台通道**：完全基于 Flutter 引擎自身的 `FrameTiming`。
/// * **统计与采集分层**：统计逻辑全在纯 Dart 的 `frame_stats.dart`，可脱离引擎
///   单元测试；本文件只做 `FrameTiming` → 时长数字的转换与节流发布。
/// * **幂等 start / stop**：重复调用只生效一次，`removeTimingsCallback` 用同一
///   回调引用，避免泄漏或重复注册。
/// * **best-effort 日志**：任何注册/卸载异常都只经 `debugPrint` 记录，绝不抛出。
/// * 单位：`FrameTiming` 的 `Duration` 统一取 `.inMicroseconds`（µs）；对外
///   [FrameStats] 中的 `*Ms` 字段为毫秒。
library;

import 'dart:async';
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'frame_stats.dart';

/// 帧时序监控单例。
///
/// 生产入口：[FrameMonitor.instance]；启动时调用 [start]、退出/调试结束后调用
/// [stop]。测试可直接 `FrameMonitor(...)` 注入自定义 [FrameStatsAccumulator] /
/// 时钟 / 节流间隔（本类不依赖引擎即可构造，但真实采集需要 binding）。
class FrameMonitor {
  /// 可注入构造（测试用）。生产请使用 [instance]。
  FrameMonitor({
    FrameStatsAccumulator? accumulator,
    Duration notifyInterval = const Duration(milliseconds: 500),
    DateTime Function()? clock,
  })  : _accumulator = accumulator ?? FrameStatsAccumulator(),
        _notifyInterval = notifyInterval,
        _clock = clock ?? DateTime.now {
    _latest = ValueNotifier<FrameStats>(_accumulator.snapshot());
  }

  /// 生产单例。
  static final FrameMonitor instance = FrameMonitor();

  final FrameStatsAccumulator _accumulator;
  final Duration _notifyInterval;
  final DateTime Function() _clock;

  /// 稳定的回调引用（保证 `addTimingsCallback` / `removeTimingsCallback` 成对）。
  late final void Function(List<FrameTiming> timings) _timingsCallback =
      _onTimings;

  final StreamController<FrameStats> _stream =
      StreamController<FrameStats>.broadcast();

  late final ValueNotifier<FrameStats> _latest;

  bool _started = false;
  DateTime? _lastNotify;

  /// 是否已注册帧回调。
  bool get isRunning => _started;

  /// 最近一次计算出的统计快照。
  FrameStats get latestStats => _latest.value;

  /// 统计变化通知（节流）。
  ValueListenable<FrameStats> get valueListenable => _latest;

  /// 统计变化流（broadcast，节流）。
  Stream<FrameStats> get stream => _stream.stream;

  /// 滚动窗口大小（来自累加器配置）。
  int get windowSize => _accumulator.window;

  /// 单帧预算（毫秒，来自累加器配置）。
  double get budgetMs => _accumulator.budgetMs;

  /// 注册 `FrameTiming` 回调并开始采集（幂等；重复调用为 no-op）。
  void start() {
    if (_started) return;
    try {
      SchedulerBinding.instance.addTimingsCallback(_timingsCallback);
      _started = true;
      debugPrint('[FrameMonitor] 已启动帧时序采集');
    } catch (e) {
      debugPrint('[FrameMonitor] 启动失败（已忽略）: $e');
    }
  }

  /// 卸载帧回调（幂等）并强制发布一次收尾快照。
  void stop() {
    if (!_started) return;
    try {
      SchedulerBinding.instance.removeTimingsCallback(_timingsCallback);
    } catch (e) {
      debugPrint('[FrameMonitor] 卸载回调失败（已忽略）: $e');
    }
    _started = false;
    _lastNotify = null;
    _publish(force: true);
    debugPrint('[FrameMonitor] 已停止帧时序采集');
  }

  /// 清空累计统计并强制发布一次空快照。
  void reset() {
    _accumulator.reset();
    _lastNotify = null;
    _publish(force: true);
  }

  // ==================== 内部 ====================

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final buildUs = timing.buildDuration.inMicroseconds;
      final rasterUs = timing.rasterDuration.inMicroseconds;
      final vsyncUs = timing.vsyncOverhead.inMicroseconds;
      var totalUs = timing.totalSpan.inMicroseconds;
      if (totalUs <= 0) {
        totalUs = buildUs + rasterUs + vsyncUs;
      }
      _accumulator.addFrame(
        buildUs: buildUs,
        rasterUs: rasterUs,
        vsyncUs: vsyncUs,
        totalUs: totalUs,
        vsyncTimestampUs:
            timing.timestampInMicroseconds(FramePhase.vsyncStart),
      );
    }
    _publish();
  }

  /// 按 [notifyInterval] 节流发布统计；[force] 绕过节流。
  void _publish({bool force = false}) {
    final now = _clock();
    final last = _lastNotify;
    if (!force && last != null && now.difference(last) < _notifyInterval) {
      return;
    }
    _lastNotify = now;
    final stats = _accumulator.snapshot();
    _latest.value = stats;
    if (!_stream.isClosed) {
      _stream.add(stats);
    }
  }
}
