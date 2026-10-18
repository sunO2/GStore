/// 性能报告「自动/定时导出」服务。
///
/// 在**性能页处于实时 / 采样态且设置已启用**时，每 [intervalMinutes]（分钟，
/// 下限 1）构建并落盘一份报告（经 [PerfReportStore]，不重复任何文件 I/O 逻辑），
/// 随后裁剪到 [maxKeep] 份（删除最旧）。生命周期由调用方控制：
/// [start] / [stop]，页面释放时 [dispose] 取消定时器。
///
/// 设计要点：
/// * **可注入**：`store` / `buildContent` / `settings` / `clock` 全部注入，单测可
///   用内存 store + 受控时钟（`fakeAsync` 推进定时器）；
/// * **绝不抛出**：构建 / 落盘 / 清理任一失败仅记日志，返回已落盘份数；
/// * **诚实计数**：「两者」格式落 2 个文件，[exportNow] 返回真实份数。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/perf/perf_auto_export_settings.dart';
import 'package:gstore/core/perf/perf_report_store.dart';

/// 单份报告内容构建回调（给定时间戳与文件格式，返回可直接落盘的文本）。
typedef PerfAutoExportContentBuilder = Future<String> Function(
  DateTime timestamp,
  PerfReportFormat format,
);

/// 定时自动导出服务。
class PerfAutoExportService {
  PerfAutoExportService({
    required PerfReportStore store,
    required PerfAutoExportContentBuilder buildContent,
    required PerfAutoExportSettings Function() settings,
    DateTime Function()? clock,
  })  : _store = store,
        _buildContent = buildContent,
        _settings = settings,
        _clock = clock ?? DateTime.now;

  final PerfReportStore _store;
  final PerfAutoExportContentBuilder _buildContent;
  final PerfAutoExportSettings Function() _settings;
  final DateTime Function() _clock;

  Timer? _timer;
  bool _disposed = false;
  bool _running = false;
  bool _exporting = false;

  /// 是否正在按周期导出（已释放 / 未启用时为 false）。
  bool get isRunning => _running && !_disposed;

  /// 启动周期导出；未启用 / 已释放时为空操作（不建定时器）。
  ///
  /// 重复调用会先取消既有定时器再按当前设置重建，便于设置变更后重启。
  void start() {
    if (_disposed) return;
    _stopTimer();
    final settings = _settings();
    if (!settings.enabled) {
      _running = false;
      return;
    }
    _running = true;
    final minutes = settings.intervalMinutes < kPerfAutoExportMinIntervalMinutes
        ? kPerfAutoExportMinIntervalMinutes
        : settings.intervalMinutes;
    _timer = Timer.periodic(Duration(minutes: minutes), (_) => _exportOnce());
  }

  /// 停止周期导出（释放定时器）。
  void stop() {
    _stopTimer();
    _running = false;
  }

  /// 释放：标记释放并取消定时器。释放后 [start] / [exportNow] 均为空操作。
  void dispose() {
    _disposed = true;
    _stopTimer();
    _running = false;
  }

  /// 立即导出一次（手动触发 / 测试用），返回实际落盘的报告份数；绝不抛出。
  ///
  /// 未启用 / 已释放时返回 0。即使 [start] 未调用也可用于「立即导出」入口。
  Future<int> exportNow() async {
    if (_disposed) return 0;
    final settings = _settings();
    if (!settings.enabled) return 0;
    return _exportOnce();
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<int> _exportOnce() async {
    if (_disposed || _exporting) return 0;
    final settings = _settings();
    if (!settings.enabled) return 0;
    _exporting = true;
    var saved = 0;
    try {
      final timestamp = _clock();
      for (final format in settings.format.reportFormats) {
        final content = await _buildContent(timestamp, format);
        await _store.saveReport(
          format: format,
          content: content,
          timestamp: timestamp,
        );
        saved++;
      }
    } catch (error) {
      debugPrint('[PerfAutoExport] 自动导出失败（忽略）: $error');
    } finally {
      _exporting = false;
    }
    if (saved > 0) {
      await _prune(settings.maxKeep);
    }
    return saved;
  }

  /// 裁剪到 [maxKeep] 份：列表按时间降序，删除第 [maxKeep] 之后的（最旧）。
  Future<void> _prune(int maxKeep) async {
    final keep =
        maxKeep < kPerfAutoExportMinMaxKeep ? kPerfAutoExportMinMaxKeep : maxKeep;
    try {
      final reports = await _store.listReports();
      if (reports.length <= keep) return;
      for (final report in reports.skip(keep)) {
        await _store.deleteReport(report.path);
      }
    } catch (error) {
      debugPrint('[PerfAutoExport] 清理旧报告失败（忽略）: $error');
    }
  }
}
