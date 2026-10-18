/// 性能监控页模型与 UI 状态（Riverpod 不可变 state）。
library;

import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 进程排行排序维度（与 Rust `perf.processes` 的 `sort` 字段一致）。
enum PerfProcessSort {
  /// 按 CPU 占用降序。
  cpu('cpu', 'CPU'),

  /// 按常驻内存（RSS）降序。
  rss('rss', '内存');

  const PerfProcessSort(this.value, this.label);

  /// 传给模块的 `sort` 值（`cpu` / `rss`）。
  final String value;

  /// 展示用中文短标签。
  final String label;
}

/// 无帧样本时的兜底快照（与 [FrameStatsAccumulator] 默认配置一致）。
///
/// 仅用于首帧渲染；[PerfMonitorNotifier] 一旦拿到 [FrameMonitor] 的快照即替换。
final FrameStats emptyFrameStats = FrameStats.empty(
  windowSize: 120,
  budgetMs: 16.666,
  jankThresholdMs: 33.332,
);

/// 单个指标滚动历史的最大样本数（≈1.5 分钟 @1s；FPS 由帧流驱动，速率更高）。
const int kPerfHistoryCapacity = 90;

/// 性能监控页 UI 状态。
///
/// 所有字段均为**可空 / 默认安全**：模块未安装、无电池、无 GPU 等都是预期状态，
/// 页面据此降级展示而非崩溃。错误一律以**友好文案**（[error]）承载，绝不透传裸异常。
class PerfPageState {
  const PerfPageState({
    this.loading = true,
    this.availability = PerfAvailability.absent,
    this.error,
    this.frameStats,
    this.frameMonitorRunning = false,
    this.cpu,
    this.memory,
    this.battery,
    this.thermal,
    this.gpu,
    this.network,
    this.processes,
    this.pressure,
    this.cooling,
    this.batteryHealth,
    this.storage,
    this.processSort = PerfProcessSort.cpu,
    this.sampling = false,
    this.sampleCount = 0,
    this.lastSampleTsMs,
    this.live = false,
    this.fpsHistory = const <double>[],
    this.cpuUsageHistory = const <double>[],
    this.memoryUsedHistory = const <double>[],
    this.thermalMaxHistory = const <double>[],
    this.batteryCurrentHistory = const <double>[],
    this.networkRxHistory = const <double>[],
    this.networkTxHistory = const <double>[],
  });

  /// 是否正在读取模块数据（首次 / 手动刷新 / 切换排序）。
  final bool loading;

  /// 模块自举阶段（来自 [PerfModule.watchAvailability]）。
  final PerfAvailability availability;

  /// 友好错误文案（如「读取失败，请稍后重试」）；非空时展示错误卡片。
  final String? error;

  /// 最近一次帧统计快照（来自 [FrameMonitor]，纯 Dart，恒可用）。
  final FrameStats? frameStats;

  /// 帧监控是否正在采集。
  final bool frameMonitorRunning;

  final CpuReport? cpu;
  final MemoryReport? memory;
  final BatteryReport? battery;
  final ThermalReport? thermal;
  final GpuReport? gpu;
  final NetworkReport? network;
  final ProcessReport? processes;

  /// `/proc/pressure/*` PSI 压力报告；模块未提供 / 不可用时为 `null`。
  final PerfPressureReport? pressure;

  /// 散热设备报告；不可用时为 `null`。
  final PerfCoolingReport? cooling;

  /// 电池健康深读报告；无电池 / 不可用时为 `null`。
  final PerfBatteryHealthReport? batteryHealth;

  /// 存储卷用量报告；不可用时为 `null`。
  final PerfStorageReport? storage;

  /// 进程排行当前排序维度。
  final PerfProcessSort processSort;

  /// 后台实时采样开关（默认 OFF，绝不自动启动）。
  final bool sampling;

  /// 本次会话收到的采样条数。
  final int sampleCount;

  /// 最近一条采样的时间戳（Unix ms；无则为 null）。
  final int? lastSampleTsMs;

  /// 实时刷新开关（`Timer.periodic` 1s；默认 OFF，显式开启）。
  final bool live;

  /// FPS 滚动历史（来自 [FrameMonitor]，纯 Dart，恒可用）。
  final List<double> fpsHistory;

  /// CPU 总占用（%）滚动历史。
  final List<double> cpuUsageHistory;

  /// 内存占用率（%）滚动历史。
  final List<double> memoryUsedHistory;

  /// 最高温度（°C）滚动历史。
  final List<double> thermalMaxHistory;

  /// 电池电流（mA）滚动历史。
  final List<double> batteryCurrentHistory;

  /// 网络接收速率（B/s）滚动历史。
  final List<double> networkRxHistory;

  /// 网络发送速率（B/s）滚动历史。
  final List<double> networkTxHistory;

  /// 模块实例是否可用（[PerfAvailability.ready]）。
  bool get moduleReady => availability == PerfAvailability.ready;

  /// 模块是否处于「准备中」（下载 / 挂载阶段）。
  bool get modulePreparing =>
      availability == PerfAvailability.downloading ||
      availability == PerfAvailability.initializing;

  /// 帧统计快照（无则兜底为空统计，保证 FPS 区恒可渲染）。
  FrameStats get effectiveFrameStats => frameStats ?? emptyFrameStats;

  PerfPageState copyWith({
    bool? loading,
    PerfAvailability? availability,
    String? error,
    bool clearError = false,
    FrameStats? frameStats,
    bool? frameMonitorRunning,
    CpuReport? cpu,
    MemoryReport? memory,
    BatteryReport? battery,
    ThermalReport? thermal,
    GpuReport? gpu,
    NetworkReport? network,
    ProcessReport? processes,
    PerfPressureReport? pressure,
    PerfCoolingReport? cooling,
    PerfBatteryHealthReport? batteryHealth,
    PerfStorageReport? storage,
    PerfProcessSort? processSort,
    bool? sampling,
    int? sampleCount,
    int? lastSampleTsMs,
    bool? live,
    List<double>? fpsHistory,
    List<double>? cpuUsageHistory,
    List<double>? memoryUsedHistory,
    List<double>? thermalMaxHistory,
    List<double>? batteryCurrentHistory,
    List<double>? networkRxHistory,
    List<double>? networkTxHistory,
  }) {
    return PerfPageState(
      loading: loading ?? this.loading,
      availability: availability ?? this.availability,
      error: clearError ? null : (error ?? this.error),
      frameStats: frameStats ?? this.frameStats,
      frameMonitorRunning: frameMonitorRunning ?? this.frameMonitorRunning,
      cpu: cpu ?? this.cpu,
      memory: memory ?? this.memory,
      battery: battery ?? this.battery,
      thermal: thermal ?? this.thermal,
      gpu: gpu ?? this.gpu,
      network: network ?? this.network,
      processes: processes ?? this.processes,
      pressure: pressure ?? this.pressure,
      cooling: cooling ?? this.cooling,
      batteryHealth: batteryHealth ?? this.batteryHealth,
      storage: storage ?? this.storage,
      processSort: processSort ?? this.processSort,
      sampling: sampling ?? this.sampling,
      sampleCount: sampleCount ?? this.sampleCount,
      lastSampleTsMs: lastSampleTsMs ?? this.lastSampleTsMs,
      live: live ?? this.live,
      fpsHistory: fpsHistory ?? this.fpsHistory,
      cpuUsageHistory: cpuUsageHistory ?? this.cpuUsageHistory,
      memoryUsedHistory: memoryUsedHistory ?? this.memoryUsedHistory,
      thermalMaxHistory: thermalMaxHistory ?? this.thermalMaxHistory,
      batteryCurrentHistory: batteryCurrentHistory ?? this.batteryCurrentHistory,
      networkRxHistory: networkRxHistory ?? this.networkRxHistory,
      networkTxHistory: networkTxHistory ?? this.networkTxHistory,
    );
  }
}
