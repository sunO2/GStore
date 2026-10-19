/// 本应用帧指标（FrameMetrics）的 Dart 模型与容错解析层。
///
/// Kotlin `FrameMetricsCollector.readJson` 经 Rust JNI 暴露为一次 FRB 调用；
/// 本文件把它解析为 [FrameMetricsReading]，并提供可注入的
/// [RustJniFrameMetricsBridge]。单测无需 FFI / 真机。
///
/// 同时提供纯 Dart 的 [frameMetricsFromDurations]，用与 Kotlin 侧一致的
/// 口径（最近秩百分位 + 1.5 × 标称帧间隔 jank）由帧耗时计算摘要，便于
/// 单元测试与降级计算。
///
/// 所有解析入口**绝不抛出**：非法 / 非对象 JSON → `null`，缺失字段 → `null`。
library;

import 'dart:convert' show jsonDecode;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:gstore/core/rust/generated/bridge.dart' as rust_bridge;

/// 一次帧指标摘要（毫秒口径；[jankPercent] 为 0–100）。
class FrameMetricsReading {
  const FrameMetricsReading({
    required this.count,
    required this.avgMs,
    required this.p90Ms,
    required this.p99Ms,
    required this.jankPercent,
    required this.lastMs,
    this.refreshRate,
    this.windowSize,
  });

  /// 窗口内帧数。
  final int count;

  /// 平均帧耗时（ms）。
  final double avgMs;

  /// P90 帧耗时（ms，最近秩）。
  final double p90Ms;

  /// P99 帧耗时（ms，最近秩）。
  final double p99Ms;

  /// jank 占比（0–100）：帧耗时 > 1.5 × 标称帧间隔。
  final double jankPercent;

  /// 最近一帧耗时（ms）。
  final double lastMs;

  /// 标称刷新率（Hz）；`null` = 未提供。
  final double? refreshRate;

  /// 环形缓冲容量；`null` = 未提供。
  final int? windowSize;

  /// 是否已采集到帧。
  bool get hasSamples => count > 0;

  @override
  String toString() => 'FrameMetricsReading(count: $count, '
      'avgMs: ${avgMs.toStringAsFixed(2)}, p90Ms: ${p90Ms.toStringAsFixed(2)}, '
      'p99Ms: ${p99Ms.toStringAsFixed(2)}, '
      'jankPercent: ${jankPercent.toStringAsFixed(1)}, '
      'lastMs: ${lastMs.toStringAsFixed(2)})';
}

/// 把 `frame_metrics_read_json` 的 JSON 解析为 [FrameMetricsReading]。
///
/// 非法 JSON / 非对象 → `null`；数值字段缺失 / 非法 → 0。
/// **绝不抛出**。
FrameMetricsReading? frameMetricsFromJson(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final map = <String, Object?>{
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
    };
    final count = _asInt(map['count']) ?? 0;
    if (count <= 0) return null;
    return FrameMetricsReading(
      count: count,
      avgMs: _asDouble(map['avgMs']) ?? 0,
      p90Ms: _asDouble(map['p90Ms']) ?? 0,
      p99Ms: _asDouble(map['p99Ms']) ?? 0,
      jankPercent: (_asDouble(map['jankPercent']) ?? 0).clamp(0, 100),
      lastMs: _asDouble(map['lastMs']) ?? 0,
      refreshRate: _asDouble(map['refreshRate']),
      windowSize: _asInt(map['windowSize']),
    );
  } catch (error) {
    debugPrint('[FrameMetrics] JSON 解析失败: $error');
    return null;
  }
}

/// 由帧耗时（毫秒）计算与 Kotlin 侧一致的摘要。
///
/// - `avgMs`：算术平均；
/// - `p90Ms` / `p99Ms`：最近秩法 `index = ceil(p/100 × N) - 1`；
/// - `jankPercent`：`duration > 1.5 × (1000 / refreshRate)` 的帧占比（0–100）；
/// - `lastMs`：最后一帧。
///
/// [durationsMs] 为空 → `count = 0` 的零摘要。
FrameMetricsReading frameMetricsFromDurations(
  List<double> durationsMs, {
  double refreshRate = 60,
}) {
  final frames = durationsMs
      .where((value) => value.isFinite && value >= 0)
      .toList(growable: false);
  if (frames.isEmpty) {
    return FrameMetricsReading(
      count: 0,
      avgMs: 0,
      p90Ms: 0,
      p99Ms: 0,
      jankPercent: 0,
      lastMs: 0,
      refreshRate: refreshRate,
    );
  }
  final rate = refreshRate.isFinite && refreshRate > 0 ? refreshRate : 60.0;
  final sorted = List<double>.from(frames)..sort();
  final threshold = 1.5 * 1000 / rate;
  final jankCount = frames.where((value) => value > threshold).length;
  return FrameMetricsReading(
    count: frames.length,
    avgMs: frames.reduce((a, b) => a + b) / frames.length,
    p90Ms: _percentile(sorted, 90),
    p99Ms: _percentile(sorted, 99),
    jankPercent: jankCount * 100 / frames.length,
    lastMs: frames.last,
    refreshRate: rate,
    windowSize: frames.length,
  );
}

double _percentile(List<double> sorted, double percentile) {
  if (sorted.isEmpty) return 0;
  final rank = (percentile / 100 * sorted.length).ceil();
  final index = rank.clamp(1, sorted.length) - 1;
  return sorted[index];
}

/// Rust JNI 帧指标读取 seam（生产：FRB `frame_metrics_read_json`）。
typedef RustFrameMetricsJsonReader = Future<String?> Function();

/// Rust JNI → Kotlin `FrameMetricsCollector` 的 Dart 门面。
///
/// 生产默认走生成的 FRB 函数；[readJson] 可注入，单测无需 FFI。
/// 所有入口**绝不抛出**（异常 / 未初始化 / 非法 JSON → `null`）。
class RustJniFrameMetricsBridge {
  RustJniFrameMetricsBridge({RustFrameMetricsJsonReader? readJson})
      : _readJson = readJson ?? rust_bridge.frameMetricsReadJson;

  final RustFrameMetricsJsonReader _readJson;

  /// 读取一次并解析；不可用 / 无样本 / 失败 → `null`。
  Future<FrameMetricsReading?> read() async {
    try {
      final json = await _readJson();
      if (json == null || json.isEmpty) return null;
      return frameMetricsFromJson(json);
    } catch (error) {
      debugPrint('[RustJniFrameMetricsBridge] read 失败: $error');
      return null;
    }
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) {
    return value.isFinite ? value.round() : null;
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

double? _asDouble(Object? value) {
  if (value is double) return value.isFinite ? value : null;
  if (value is num) {
    final asDouble = value.toDouble();
    return asDouble.isFinite ? asDouble : null;
  }
  if (value is String) {
    final parsed = double.tryParse(value.trim());
    return parsed != null && parsed.isFinite ? parsed : null;
  }
  return null;
}
