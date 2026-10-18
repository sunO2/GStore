/// 性能报告文件存储 + 基线（baseline）存储 + 基线对比。
///
/// * **报告文件**：`<appDocs>/perf_reports/perf_<ts>.json|.csv`
///   （[getApplicationDocumentsDirectory]），提供 save / list / read / delete；
/// * **基线**：经 [PerfBaselineStore]（生产为 `shared_preferences`，测试可注入内存
///   实现）保存一组扁平指标（CPU% / 内存% / 温度 / FPS / jank%），供跨会话对比；
/// * **对比**：[compareToBaseline] 为纯函数，返回逐指标 delta 与百分比变化。
///
/// 读取类操作一律**静默降级**（返回空 / `null`，仅日志），与性能页容错语义一致；
/// [PerfReportStore.saveReport] 为显式用户动作，失败时抛出交由调用方提示。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

/// 报告导出格式。
enum PerfReportFormat {
  /// 结构化 JSON。
  json('json', 'application/json'),

  /// 扁平 CSV。
  csv('csv', 'text/csv');

  const PerfReportFormat(this.extension, this.mimeType);

  /// 文件扩展名（无点）。
  final String extension;

  /// 分享用 MIME 类型。
  final String mimeType;
}

/// 磁盘上一次保存的性能报告。
class SavedPerfReport {
  const SavedPerfReport({
    required this.path,
    required this.format,
    required this.timestamp,
  });

  /// 绝对路径。
  final String path;

  /// 格式。
  final PerfReportFormat format;

  /// 生成（文件名内）时间戳。
  final DateTime timestamp;

  /// 文件名。
  String get fileName => path.split(Platform.pathSeparator).last;
}

/// 目录提供者（默认 `getApplicationDocumentsDirectory`；测试注入临时目录）。
typedef PerfDirectoryProvider = Future<Directory> Function();

/// 性能报告 + 基线存储。
class PerfReportStore {
  PerfReportStore({
    PerfDirectoryProvider? directoryProvider,
    PerfBaselineStore? baselineStore,
  })  : _directoryProvider =
            directoryProvider ?? getApplicationDocumentsDirectory,
        _baselineStore = baselineStore ?? const SharedPrefsBaselineStore();

  /// 报告子目录名（位于 app documents 下）。
  static const String reportDirName = 'perf_reports';

  final PerfDirectoryProvider _directoryProvider;
  final PerfBaselineStore _baselineStore;

  Future<Directory> _reportsDir() async {
    final base = await _directoryProvider();
    final dir = Directory('${base.path}${Platform.pathSeparator}$reportDirName');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 保存一份报告文本到磁盘，返回落盘信息。
  ///
  /// 失败抛出（用户显式动作，调用方负责提示）。
  Future<SavedPerfReport> saveReport({
    required PerfReportFormat format,
    required String content,
    required DateTime timestamp,
  }) async {
    final dir = await _reportsDir();
    final name = 'perf_${timestamp.millisecondsSinceEpoch}.${format.extension}';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(content);
    return SavedPerfReport(
      path: file.path,
      format: format,
      timestamp: timestamp,
    );
  }

  /// 列出已保存报告（按时间戳降序）；读取失败返回空列表。
  Future<List<SavedPerfReport>> listReports() async {
    try {
      final dir = await _reportsDir();
      final entries = <SavedPerfReport>[];
      final pattern = RegExp(r'^perf_(\d+)\.(json|csv)$');
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        final match = pattern.firstMatch(name);
        if (match == null) continue;
        final ts = int.tryParse(match.group(1)!);
        final format = match.group(2) == PerfReportFormat.csv.extension
            ? PerfReportFormat.csv
            : PerfReportFormat.json;
        if (ts == null) continue;
        entries.add(
          SavedPerfReport(
            path: entity.path,
            format: format,
            timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
          ),
        );
      }
      entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return entries;
    } catch (error) {
      debugPrint('[PerfReportStore] 列出报告失败: $error');
      return const <SavedPerfReport>[];
    }
  }

  /// 读取报告文本；文件缺失 / 读取失败返回 `null`。
  Future<String?> readReport(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      return await file.readAsString();
    } catch (error) {
      debugPrint('[PerfReportStore] 读取报告失败: $error');
      return null;
    }
  }

  /// 删除报告；成功 / 已不存在返回 `true`，失败返回 `false`。
  Future<bool> deleteReport(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
      return true;
    } catch (error) {
      debugPrint('[PerfReportStore] 删除报告失败: $error');
      return false;
    }
  }

  // ==================== 基线 ====================

  /// 保存基线指标（扁平键值）。
  Future<void> saveBaseline(Map<String, dynamic> baseline) async {
    try {
      await _baselineStore.writeJson(jsonEncode(baseline));
    } catch (error) {
      debugPrint('[PerfReportStore] 保存基线失败: $error');
    }
  }

  /// 读取基线指标；无记录 / 解析失败返回 `null`。
  Future<Map<String, dynamic>?> loadBaseline() async {
    try {
      final raw = await _baselineStore.readJson();
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } catch (error) {
      debugPrint('[PerfReportStore] 读取基线失败: $error');
      return null;
    }
  }

  /// 清除基线。
  Future<void> clearBaseline() async {
    try {
      await _baselineStore.clear();
    } catch (error) {
      debugPrint('[PerfReportStore] 清除基线失败: $error');
    }
  }
}

// ==================== 基线指标 / 对比（纯函数） ====================

/// 基线对比的指标键 + 展示标签（顺序即 UI 展示顺序）。
const List<(String, String)> kPerfBaselineMetrics = <(String, String)>[
  ('cpu_percent', 'CPU'),
  ('memory_percent', '内存'),
  ('thermal_max_c', '温度'),
  ('fps', 'FPS'),
  ('jank_percent', 'Jank'),
];

/// 基线元数据键：记录采集时刻（Unix ms）。
const String kPerfBaselineTsKey = 'ts_ms';

/// 从各报告 + 帧统计抽取基线指标（缺失项不进 map）。
///
/// 纯函数：同一输入恒产出同一 map（键顺序固定）。
Map<String, dynamic> buildBaselineMetrics({
  CpuReport? cpu,
  MemoryReport? memory,
  ThermalReport? thermal,
  FrameStats? frameStats,
  DateTime? timestamp,
}) {
  final map = <String, dynamic>{
    if (timestamp != null) kPerfBaselineTsKey: timestamp.millisecondsSinceEpoch,
  };
  if (cpu != null) map['cpu_percent'] = cpu.usagePercent;
  if (memory != null) map['memory_percent'] = memory.usedPercent;
  if (thermal?.maxTempC != null) map['thermal_max_c'] = thermal!.maxTempC;
  if (frameStats != null) {
    map['fps'] = frameStats.fps;
    map['jank_percent'] = frameStats.jankRatio * 100;
  }
  return map;
}

/// 单个指标的基线对比结果。
class PerfMetricDelta {
  const PerfMetricDelta({
    required this.key,
    required this.label,
    this.current,
    this.baseline,
  });

  /// 指标键（如 `cpu_percent`）。
  final String key;

  /// 展示标签（如 `CPU`）。
  final String label;

  /// 当前值（缺失为 `null`）。
  final double? current;

  /// 基线值（缺失为 `null`）。
  final double? baseline;

  /// 绝对差值 `current - baseline`；任一缺失为 `null`。
  double? get delta {
    final c = current;
    final b = baseline;
    if (c == null || b == null) return null;
    return c - b;
  }

  /// 相对变化（%）= `delta / baseline × 100`；任一缺失或基线为 0 时为 `null`。
  double? get deltaPercent {
    final d = delta;
    final b = baseline;
    if (d == null || b == null || b == 0) return null;
    return d / b * 100;
  }

  /// 是否可比（当前与基线均存在）。
  bool get comparable => current != null && baseline != null;
}

/// 逐指标对比当前值与基线值（纯函数，顺序严格遵循 [kPerfBaselineMetrics]）。
List<PerfMetricDelta> compareToBaseline(
  Map<String, dynamic> current,
  Map<String, dynamic> baseline,
) {
  return <PerfMetricDelta>[
    for (final (key, label) in kPerfBaselineMetrics)
      PerfMetricDelta(
        key: key,
        label: label,
        current: _asDouble(current[key]),
        baseline: _asDouble(baseline[key]),
      ),
  ];
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value == null) return null;
  return double.tryParse(value.toString());
}

// ==================== 基线后端（可注入） ====================

/// 基线 JSON 持久化后端。
abstract class PerfBaselineStore {
  /// 读取原始 JSON；无记录返回 `null`。
  Future<String?> readJson();

  /// 写入原始 JSON。
  Future<void> writeJson(String json);

  /// 清除。
  Future<void> clear();
}

/// 生产实现：`shared_preferences`。
class SharedPrefsBaselineStore implements PerfBaselineStore {
  const SharedPrefsBaselineStore();

  /// 存储键。
  static const String storageKey = 'perf_baseline_metrics';

  @override
  Future<String?> readJson() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(storageKey);
    } catch (error) {
      debugPrint('[PerfBaselineStore] 读取基线失败: $error');
      return null;
    }
  }

  @override
  Future<void> writeJson(String json) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, json);
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
  }
}

/// 内存实现（测试 / 无持久化环境回退）。
class InMemoryBaselineStore implements PerfBaselineStore {
  InMemoryBaselineStore([this._json]);

  String? _json;

  @override
  Future<String?> readJson() async => _json;

  @override
  Future<void> writeJson(String json) async => _json = json;

  @override
  Future<void> clear() async => _json = null;
}
