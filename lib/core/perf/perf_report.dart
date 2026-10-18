/// 性能报告纯构建器（JSON / CSV）—— **无 I/O、无 Flutter 依赖、确定性**。
///
/// 报告内容来自性能页已持有的各类型化报告（[CpuReport] / [MemoryReport] /
/// [BatteryReport] / [ThermalReport] / [GpuReport] / [NetworkReport]）+
/// 帧统计 [FrameStats] + 可选的第三方应用指标 [ThirdPartyAppMetrics] / 采样
/// [ThirdPartySample]。
///
/// 设计要点：
/// * **确定性**：时间戳由调用方传入（不在此处取 `DateTime.now()`），同一输入
///   恒产出同一字节序列，便于单测快照断言；
/// * **纯函数**：不触碰文件 / 平台通道 / 全局状态；
/// * **缺失即空**：任一分节为 `null` 时对应键为 `null`（JSON）或整段跳过（CSV），
///   绝不臆造数据 —— 原生模块可能缺席，此页需在「只有 FPS」时也能导出。
library;

import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

/// 报告 schema 版本（字段变更时递增，导出消费者据此做兼容）。
const int kPerfReportSchema = 1;

/// 构建性能报告 JSON（返回可 `jsonEncode` 的 Map；键顺序固定）。
///
/// [timestamp] 为报告生成时刻（调用方注入，保证确定性）。
/// [thirdPartySample] 若提供则优先于 [thirdParty]（前者额外携带采样时间戳）。
/// [targetLabel] 为可选的第三方应用展示名（用于报告元信息）。
Map<String, dynamic> buildPerfReportJson({
  required DateTime timestamp,
  CpuReport? cpu,
  MemoryReport? memory,
  BatteryReport? battery,
  ThermalReport? thermal,
  GpuReport? gpu,
  NetworkReport? network,
  FrameStats? frameStats,
  ThirdPartyAppMetrics? thirdParty,
  ThirdPartySample? thirdPartySample,
  String? targetLabel,
}) {
  final metrics = thirdPartySample?.metrics ?? thirdParty;
  return <String, dynamic>{
    'schema': kPerfReportSchema,
    'generated_at_ms': timestamp.millisecondsSinceEpoch,
    'generated_at': timestamp.toIso8601String(),
    'target_label': targetLabel,
    'frame': frameStats == null ? null : _frameSection(frameStats),
    'cpu': cpu == null ? null : _cpuSection(cpu),
    'memory': memory == null ? null : _memorySection(memory),
    'battery': battery == null ? null : _batterySection(battery),
    'thermal': thermal == null ? null : _thermalSection(thermal),
    'gpu': gpu == null ? null : _gpuSection(gpu),
    'network': network == null ? null : _networkSection(network),
    'third_party': metrics == null
        ? null
        : _thirdPartySection(metrics, thirdPartySample?.tsMs),
  };
}

/// 构建性能报告 CSV（`section,metric,value` 三列，固定行序）。
///
/// 与 [buildPerfReportJson] 复用同一底层结构，保证两种格式语义一致。
/// 值为 `null` 时输出空字段（而非臆造）。嵌套分节以 `.` 连接（如 `cpu.usage`）。
/// 列表按元素拼接（标量）或输出长度（对象列表）。
String buildPerfReportCsv({
  required DateTime timestamp,
  CpuReport? cpu,
  MemoryReport? memory,
  BatteryReport? battery,
  ThermalReport? thermal,
  GpuReport? gpu,
  NetworkReport? network,
  FrameStats? frameStats,
  ThirdPartyAppMetrics? thirdParty,
  ThirdPartySample? thirdPartySample,
  String? targetLabel,
}) {
  final map = buildPerfReportJson(
    timestamp: timestamp,
    cpu: cpu,
    memory: memory,
    battery: battery,
    thermal: thermal,
    gpu: gpu,
    network: network,
    frameStats: frameStats,
    thirdParty: thirdParty,
    thirdPartySample: thirdPartySample,
    targetLabel: targetLabel,
  );
  final rows = <List<String>>[
    const <String>['section', 'metric', 'value'],
  ];
  _flatten('', map, rows);
  return rows.map(_csvRow).join('\n');
}

// ==================== 分节 ====================

Map<String, dynamic> _frameSection(FrameStats s) => <String, dynamic>{
      'fps': s.fps,
      'avg_total_ms': s.avgTotalMs,
      'p50_total_ms': s.p50TotalMs,
      'p90_total_ms': s.p90TotalMs,
      'p99_total_ms': s.p99TotalMs,
      'max_total_ms': s.maxTotalMs,
      'jank_count': s.jankCount,
      'jank_ratio': s.jankRatio,
      'window_jank_count': s.windowJankCount,
      'window_jank_ratio': s.windowJankRatio,
      'sampled_frames': s.sampledFrames,
      'window_size': s.windowSize,
      'budget_ms': s.budgetMs,
      'jank_threshold_ms': s.jankThresholdMs,
    };

Map<String, dynamic> _cpuSection(CpuReport c) => <String, dynamic>{
      'usage_percent': c.usagePercent,
      'core_count': c.coreCount,
      'governor': c.governor,
      'min_freq_mhz': c.minFreqMhz,
      'max_freq_mhz': c.maxFreqMhz,
      'load1': c.loadavg?.load1,
      'load5': c.loadavg?.load5,
      'load15': c.loadavg?.load15,
    };

Map<String, dynamic> _memorySection(MemoryReport m) => <String, dynamic>{
      'total_kb': m.totalKb,
      'used_kb': m.usedKb,
      'available_kb': m.availableKb,
      'used_percent': m.usedPercent,
      'swap_total_kb': m.swapTotalKb,
      'swap_used_kb': m.swapUsedKb,
      'swap_percent': m.swapPercent,
    };

Map<String, dynamic> _batterySection(BatteryReport b) => <String, dynamic>{
      'present': b.present,
      'capacity_percent': b.capacityPercent,
      'voltage_v': b.voltageV,
      'current_ma': b.currentMa,
      'temperature_c': b.temperatureC,
      'status': b.status,
      'health': b.health,
    };

Map<String, dynamic> _thermalSection(ThermalReport t) => <String, dynamic>{
      'zone_count': t.zoneCount,
      'max_temp_c': t.maxTempC,
    };

Map<String, dynamic> _gpuSection(GpuReport g) => <String, dynamic>{
      'name': g.name,
      'freq_mhz': g.freqMhz,
      'busy_percent': g.busyPercent,
    };

Map<String, dynamic> _networkSection(NetworkReport n) => <String, dynamic>{
      'rx_bytes': n.rxBytes,
      'tx_bytes': n.txBytes,
      'rx_bytes_per_sec': n.rxBytesPerSec,
      'tx_bytes_per_sec': n.txBytesPerSec,
      'interface_count': n.interfaces.length,
    };

Map<String, dynamic> _thirdPartySection(ThirdPartyAppMetrics m, int? tsMs) =>
    <String, dynamic>{
      'ts_ms': tsMs,
      'package': m.package,
      'running': m.running,
      'pid': m.pid,
      'uid': m.uid,
      'cpu_percent': m.cpuPercent,
      'mem_pss_kb': m.memPssKb,
      'mem_rss_kb': m.memRssKb,
      'frame_count': m.frameCount,
      'janky_percent': m.jankyPercent,
      'fps': m.fps,
      'version_name': m.appInfo?.versionName,
      'crash_count': m.crashes?.crashCount,
      'anr_count': m.crashes?.anrCount,
    };

// ==================== CSV 扁平化 ====================

void _flatten(String prefix, Object? node, List<List<String>> rows) {
  if (node is Map) {
    node.forEach((key, value) {
      final path = prefix.isEmpty ? '$key' : '$prefix.$key';
      _flatten(path, value, rows);
    });
    return;
  }
  if (node is List) {
    final allScalar = node.every((e) => e is! Map && e is! List);
    rows.add(<String>[
      _sectionOf(prefix),
      _leafOf(prefix),
      allScalar ? node.map((e) => _scalar(e)).join('|') : 'count:${node.length}',
    ]);
    return;
  }
  rows.add(<String>[_sectionOf(prefix), _leafOf(prefix), _scalar(node)]);
}

String _sectionOf(String path) {
  final index = path.lastIndexOf('.');
  return index <= 0 ? 'meta' : path.substring(0, index);
}

String _leafOf(String path) {
  final index = path.lastIndexOf('.');
  return index < 0 ? path : path.substring(index + 1);
}

String _scalar(Object? value) {
  if (value == null) return '';
  if (value is double) {
    if (!value.isFinite) return '';
    return value.toString();
  }
  return value.toString();
}

String _csvRow(List<String> fields) => fields.map(_csvField).join(',');

String _csvField(String value) {
  if (value.contains(',') || value.contains('"') || value.contains('\n')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}
