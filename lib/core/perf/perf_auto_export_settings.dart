/// 性能报告「自动/定时导出」设置 + 持久化（`shared_preferences`）。
///
/// * [PerfAutoExportFormat]：导出格式（JSON / CSV / 两者）；
/// * [PerfAutoExportSettings]：开关 / 间隔（分钟）/ 格式 / 保留份数；
/// * [PerfAutoExportSettingsStore]：持久化接口，生产实现
///   [SharedPrefsPerfAutoExportSettingsStore]（JSON 单键），测试可注入
///   [InMemoryPerfAutoExportSettingsStore]。
///
/// 模型为纯 Dart（仅借用 [PerfReportFormat] 做格式映射，无 I/O）；生产实现失败
/// 一律静默降级（`null` / 仅日志，不抛），与性能页整体容错语义一致。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/perf_report_store.dart' show PerfReportFormat;

/// 自动导出的最短间隔（分钟）。
const int kPerfAutoExportMinIntervalMinutes = 1;

/// 自动导出的默认间隔（分钟）。
const int kPerfAutoExportDefaultIntervalMinutes = 5;

/// 自动导出保留报告数下限。
const int kPerfAutoExportMinMaxKeep = 1;

/// 自动导出默认保留报告数。
const int kPerfAutoExportDefaultMaxKeep = 20;

/// 自动导出格式。
enum PerfAutoExportFormat {
  /// 仅结构化 JSON。
  json('json', 'JSON 结构化'),

  /// 仅扁平 CSV。
  csv('csv', 'CSV 扁平'),

  /// 同时导出 JSON 与 CSV。
  both('both', 'JSON + CSV');

  const PerfAutoExportFormat(this.value, this.label);

  /// 持久化值（`json` / `csv` / `both`）。
  final String value;

  /// 展示用短标签（刻意区别于手动导出弹层的裸 `JSON` / `CSV`，避免文案撞车）。
  final String label;

  /// 映射到文件层格式列表（一次导出可能落盘多个文件）。
  List<PerfReportFormat> get reportFormats => switch (this) {
        PerfAutoExportFormat.json => const <PerfReportFormat>[
            PerfReportFormat.json,
          ],
        PerfAutoExportFormat.csv => const <PerfReportFormat>[
            PerfReportFormat.csv,
          ],
        PerfAutoExportFormat.both => const <PerfReportFormat>[
            PerfReportFormat.json,
            PerfReportFormat.csv,
          ],
      };

  /// 宽容解码：未知 / 缺省回退 [PerfAutoExportFormat.json]。
  static PerfAutoExportFormat fromValue(Object? value) {
    final raw = value?.toString();
    for (final format in values) {
      if (format.value == raw) return format;
    }
    return PerfAutoExportFormat.json;
  }
}

/// 自动导出设置。
///
/// 默认 [enabled] 为 `false`（绝不主动落盘）；[intervalMinutes] 下限 1；
/// [maxKeep] 下限 1。
class PerfAutoExportSettings {
  const PerfAutoExportSettings({
    this.enabled = false,
    this.intervalMinutes = kPerfAutoExportDefaultIntervalMinutes,
    this.format = PerfAutoExportFormat.json,
    this.maxKeep = kPerfAutoExportDefaultMaxKeep,
  });

  /// 默认设置（自动导出关闭）。
  static const PerfAutoExportSettings defaults = PerfAutoExportSettings();

  /// 总开关（默认 OFF）。
  final bool enabled;

  /// 导出间隔（分钟，≥1）。
  final int intervalMinutes;

  /// 导出格式。
  final PerfAutoExportFormat format;

  /// 保留的最近报告份数（≥1，超出删除最旧）。
  final int maxKeep;

  PerfAutoExportSettings copyWith({
    bool? enabled,
    int? intervalMinutes,
    PerfAutoExportFormat? format,
    int? maxKeep,
  }) {
    return PerfAutoExportSettings(
      enabled: enabled ?? this.enabled,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      format: format ?? this.format,
      maxKeep: maxKeep ?? this.maxKeep,
    );
  }

  /// 序列化为 JSON 友好映射。
  Map<String, dynamic> toMap() => <String, dynamic>{
        'enabled': enabled,
        'interval_minutes': intervalMinutes,
        'format': format.value,
        'max_keep': maxKeep,
      };

  /// 宽容解码：缺失 / 非法字段回退默认值（间隔 / 保留数做下限钳制）。
  factory PerfAutoExportSettings.fromMap(Map<String, dynamic> map) {
    final interval = _asInt(
      map['interval_minutes'],
      kPerfAutoExportDefaultIntervalMinutes,
    );
    final keep = _asInt(map['max_keep'], kPerfAutoExportDefaultMaxKeep);
    return PerfAutoExportSettings(
      enabled: map['enabled'] == true,
      intervalMinutes: interval < kPerfAutoExportMinIntervalMinutes
          ? kPerfAutoExportMinIntervalMinutes
          : interval,
      format: PerfAutoExportFormat.fromValue(map['format']),
      maxKeep: keep < kPerfAutoExportMinMaxKeep ? kPerfAutoExportMinMaxKeep : keep,
    );
  }

  static int _asInt(Object? value, int fallback) {
    if (value is int) return value;
    if (value is num && value.isFinite) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  @override
  bool operator ==(Object other) =>
      other is PerfAutoExportSettings &&
      other.enabled == enabled &&
      other.intervalMinutes == intervalMinutes &&
      other.format == format &&
      other.maxKeep == maxKeep;

  @override
  int get hashCode => Object.hash(enabled, intervalMinutes, format, maxKeep);

  @override
  String toString() => 'PerfAutoExportSettings(enabled=$enabled, '
      'intervalMinutes=$intervalMinutes, format=${format.value}, '
      'maxKeep=$maxKeep)';
}

/// 自动导出设置持久化接口。
abstract class PerfAutoExportSettingsStore {
  /// 读取已保存设置；无记录 / 读取失败返回 `null`。
  Future<PerfAutoExportSettings?> load();

  /// 保存设置；失败静默（仅日志，不抛）。
  Future<void> save(PerfAutoExportSettings settings);
}

/// 生产实现：`shared_preferences`（JSON 字符串，单键存储）。
class SharedPrefsPerfAutoExportSettingsStore
    implements PerfAutoExportSettingsStore {
  const SharedPrefsPerfAutoExportSettingsStore();

  /// 存储键。
  static const String storageKey = 'perf_auto_export_settings';

  @override
  Future<PerfAutoExportSettings?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return PerfAutoExportSettings.fromMap(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (error) {
      debugPrint('[PerfAutoExport] 读取自动导出设置失败: $error');
      return null;
    }
  }

  @override
  Future<void> save(PerfAutoExportSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(settings.toMap()));
    } catch (error) {
      debugPrint('[PerfAutoExport] 保存自动导出设置失败: $error');
    }
  }
}

/// 内存实现（测试 / 无持久化环境回退）。
class InMemoryPerfAutoExportSettingsStore
    implements PerfAutoExportSettingsStore {
  InMemoryPerfAutoExportSettingsStore([this._settings]);

  PerfAutoExportSettings? _settings;

  @override
  Future<PerfAutoExportSettings?> load() async => _settings;

  @override
  Future<void> save(PerfAutoExportSettings settings) async =>
      _settings = settings;
}
