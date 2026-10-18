/// 性能监控 Agent 工具（设备快照 / 第三方应用指标 / 帧统计）。
///
/// 三个**只读**工具，供 in-app AI Agent 调用：
/// * [kPerfDeviceSnapshotSpec] → `perfDeviceSnapshot`：本机 CPU% / 内存% / 电池% /
///   温度 / 负载（`PerfModule.snapshot()`）；
/// * [kPerfThirdPartyMetricsSpec] → `perfThirdPartyMetrics`：目标应用 CPU% / PSS /
///   jank / FPS（`ThirdPartyPerfService`，需 Shizuku）；
/// * [kPerfFrameStatsSpec] → `perfFrameStats`：GStore 自身交付 FPS / jank
///   （`FrameMonitor.latestStats`）。
///
/// 设计要点（与内置工具保持一致）：
/// * 元数据复用 [AgentToolSpec]（同一 shape），经 [PerfToolModule] 派生为
///   [AgentToolModule]（对齐 [SpecBackedTool] 的做法），由 `PerfMonitorModule`
///   在上下线时注册 / 注销。
/// * 执行体**自包含**（不依赖 AgentService 的分发 switch），依赖经构造函数注入，
///   测试可用假 [PerfModule] / [ThirdPartyPerfService] / [FrameMonitor] 替换。
/// * 全部工具**绝不抛出**：模块缺失 / Shizuku 未授权 / 超时 / 任意异常一律降级为
///   结构化 JSON（`available:false` + 可读 message），并对调用加**有界超时**。
/// * 无 UI / 无新依赖；日志统一 `debugPrint`。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 单次模块 / 采样调用的有界超时（避免 Agent 运行时被长时间阻塞）。
const Duration kPerfToolTimeout = Duration(seconds: 6);

// ==================== 工具协议声明（元数据单一来源） ====================

/// 设备性能快照（无参数，只读）。
const AgentToolSpec kPerfDeviceSnapshotSpec = AgentToolSpec(
  name: 'perfDeviceSnapshot',
  group: AgentToolGroup.discover,
  label: '设备性能快照',
  brief: '读取本机实时性能：CPU%、内存占用%、电池%、温度、负载（无参数，只读）。',
  params: <AgentToolParam>[],
  protocol: '''
1. 用户问"现在 CPU/内存/电池/温度怎么样、设备卡不卡、负载多高"时调用。
2. 无参数；返回一段 JSON：available / cpu_percent / mem_used_percent /
   battery_percent / temperature_c / thermal_max_c / load1(5/15) / cores / ts_ms。
3. 需要原生性能模块；模块未安装时返回 available=false 与可读 message，
   不要谎称拿到了数据。
4. 只读快照，无副作用；不要据此执行任何清理/停止操作。''',
);

/// 第三方应用性能指标（需 Shizuku）。
const AgentToolSpec kPerfThirdPartyMetricsSpec = AgentToolSpec(
  name: 'perfThirdPartyMetrics',
  group: AgentToolGroup.discover,
  label: '第三方应用指标',
  brief: '读取指定应用的 CPU% / 内存 PSS / jank% / FPS（需 Shizuku；package 必填）。',
  params: <AgentToolParam>[
    AgentToolParam(name: 'package', description: '目标应用包名（如 com.x.y）', required: true),
    AgentToolParam(name: 'sort', description: '进程列表排序：rss（内存）或 cpu（默认保持原名）'),
  ],
  protocol: '''
1. 用户问"某个应用占多少 CPU/内存、卡不卡、多少帧"时调用。
2. package 必填（包名）；sort 可选，仅影响返回的进程列表排序（rss=rss_kb 降序）。
3. **依赖 Shizuku**：未授权/未运行时返回 available=false 与可读 message；
   不要提示用户在这里授权，引导其到性能页或设置操作。
4. FPS 由两次采样差值推导，单次调用可能为 null（无基线），属预期。
5. 返回 JSON：available / cpu_percent / mem_pss_kb / janky_percent / fps /
   frame_count / processes[] 等；数值缺失为 null，不要编造。
6. 只读，无副作用。''',
);

/// 应用自身帧统计（FPS / jank，无参数）。
const AgentToolSpec kPerfFrameStatsSpec = AgentToolSpec(
  name: 'perfFrameStats',
  group: AgentToolGroup.discover,
  label: '应用帧统计',
  brief: '读取 GStore 自身实时帧率与卡顿统计：FPS、jank 数/比例、帧耗时百分位（无参数）。',
  params: <AgentToolParam>[],
  protocol: '''
1. 用户问"软件自身流畅吗、多少帧、有没有卡顿/掉帧"时调用。
2. 无参数；返回 JSON：fps / frame_interval_ms / sampled_frames / jank_count /
   jank_ratio / window_jank_* / avg_total_ms / p90_total_ms / p99_total_ms /
   budget_ms / jank_threshold_ms。
3. 数据来自 Flutter 引擎帧时序，恒可用（纯 Dart），无模块依赖。
4. 只读，无副作用；样本不足时 fps 可能为 0（尚无足够帧）。''',
);

// ==================== 工具模块 ====================

/// 由 [AgentToolSpec] 派生元数据、执行体可覆写的 Agent 工具模块。
///
/// 与 [SpecBackedTool] 的唯一差异：本类**自行执行**（不委托 AgentService 分发），
/// 因为性能工具是运行时注册的扩展工具（不在内置协议注册表内）。
class PerfToolModule extends AgentToolModule {
  PerfToolModule(this.spec, this._run);

  /// 工具协议（名称 / 描述 / 参数）。
  final AgentToolSpec spec;

  final Future<String> Function(Map<String, dynamic> params) _run;

  @override
  String get toolName => spec.name;

  @override
  String get toolDescription => spec.brief;

  @override
  List<AgentToolParam> get toolParams => spec.params;

  @override
  bool get enabled => spec.enabled;

  @override
  String get moduleName => 'agent_tool_${spec.name}';

  @override
  Future<String> execute(
    AgentToolContext context,
    Map<String, dynamic> params,
  ) {
    if (context.cancelled) return Future<String>.value('已取消');
    return _run(params);
  }
}

// ==================== 工具套件（可注入依赖） ====================

/// 性能监控 Agent 工具套件。
///
/// 生产：`PerfTools()`（默认 [PerfModule.instance] / [ThirdPartyPerfService] /
/// [FrameMonitor.instance]）。
/// 测试：注入假实现，无需原生模块 / Shizuku。
class PerfTools {
  PerfTools({
    PerfModule? perfModule,
    ThirdPartyPerfService? thirdParty,
    FrameMonitor? frameMonitor,
  })  : _perfModule = perfModule,
        _thirdParty = thirdParty,
        _frameMonitor = frameMonitor;

  final PerfModule? _perfModule;
  final ThirdPartyPerfService? _thirdParty;
  final FrameMonitor? _frameMonitor;

  ThirdPartyPerfService? _thirdPartyCache;

  PerfModule get _perf => _perfModule ?? PerfModule.instance;

  ThirdPartyPerfService get _thirdPartyService {
    final injected = _thirdParty;
    if (injected != null) return injected;
    return _thirdPartyCache ??= ThirdPartyPerfService();
  }

  FrameMonitor get _frame => _frameMonitor ?? FrameMonitor.instance;

  /// 三个工具模块（构造 `PerfTools` 时不触碰任何原生服务；实例稳定，便于
  /// `onUnregister` 用同一批 `toolName` 注销）。
  late final List<AgentToolModule> tools = List<AgentToolModule>.unmodifiable(
    <AgentToolModule>[
      PerfToolModule(kPerfDeviceSnapshotSpec, _deviceSnapshot),
      PerfToolModule(kPerfThirdPartyMetricsSpec, _thirdPartyMetrics),
      PerfToolModule(kPerfFrameStatsSpec, _frameStats),
    ],
  );

  // ==================== 执行体 ====================

  /// `perfDeviceSnapshot`：聚合快照 → 精简设备摘要。
  Future<String> _deviceSnapshot(Map<String, dynamic> params) async {
    try {
      final snapshot = await _perf.snapshot().timeout(kPerfToolTimeout);
      return _encode(<String, Object?>{
        'available': true,
        'ts_ms': snapshot.tsMs,
        'cpu_percent': _round(snapshot.cpu?.usagePercent),
        'cores': snapshot.cpu?.coreCount,
        'load1': _round(snapshot.cpu?.loadavg?.load1),
        'load5': _round(snapshot.cpu?.loadavg?.load5),
        'load15': _round(snapshot.cpu?.loadavg?.load15),
        'mem_used_percent': _round(snapshot.memory?.usedPercent),
        'mem_used_kb': snapshot.memory?.usedKb,
        'mem_total_kb': snapshot.memory?.totalKb,
        'battery_percent': _round(snapshot.battery?.capacityPercent),
        'temperature_c': _round(
          snapshot.thermal?.maxTempC ?? snapshot.battery?.temperatureC,
        ),
        'thermal_max_c': _round(snapshot.thermal?.maxTempC),
      });
    } on PerfModuleUnavailableException catch (e) {
      debugPrint('[PerfTools] perfDeviceSnapshot 模块不可用: $e');
      return _unavailable('perf_module_unavailable', e.message);
    } on TimeoutException {
      return _unavailable('timeout', '性能监控模块调用超时');
    } catch (e) {
      debugPrint('[PerfTools] perfDeviceSnapshot 失败（降级）: $e');
      return _unavailable('error', '$e');
    }
  }

  /// `perfThirdPartyMetrics`：Shizuku 采样 + Rust 解析 → 精简指标。
  Future<String> _thirdPartyMetrics(Map<String, dynamic> params) async {
    final package = params['package']?.toString().trim() ?? '';
    if (package.isEmpty) {
      return _encode(<String, Object?>{
        'available': false,
        'error': 'missing_package',
        'message': '需要参数 package（目标应用包名）',
      });
    }

    final service = _thirdPartyService;
    try {
      // 不弹出授权窗，仅检测既有授权（页面/用户负责授权）。
      final granted =
          await service.refreshShizukuStatus().timeout(kPerfToolTimeout);
      if (!granted) {
        return _encode(<String, Object?>{
          'available': false,
          'error': 'shizuku_unavailable',
          'message': '需要 Shizuku 授权才能读取第三方应用指标'
              '（当前状态：${service.shizukuStatus.name}）',
        });
      }

      final metrics = await service.sample(package).timeout(kPerfToolTimeout);
      final processes = _sortProcesses(
        metrics.processes,
        params['sort']?.toString(),
      );
      return _encode(<String, Object?>{
        'available': true,
        'package': metrics.package.isEmpty ? package : metrics.package,
        'running': metrics.running,
        'pid': metrics.pid,
        'uid': metrics.uid,
        'threads': metrics.threads,
        'cpu_percent': _round(metrics.cpuPercent),
        'mem_pss_kb': metrics.memPssKb,
        'mem_rss_kb': metrics.memRssKb,
        'janky_percent': _round(metrics.jankyPercent),
        'janky_frames': metrics.jankyFrames,
        'fps': _round(metrics.fps),
        'frame_count': metrics.frameCount,
        'p50_ms': _round(metrics.p50Ms),
        'p90_ms': _round(metrics.p90Ms),
        'p99_ms': _round(metrics.p99Ms),
        'module_available': _perf.availability == PerfAvailability.ready,
        'processes': <Map<String, Object?>>[
          for (final p in processes)
            <String, Object?>{
              'pid': p.pid,
              'name': p.name,
              'rss_kb': p.rssKb,
              'cpu_percent': _round(p.cpuPercent),
            },
        ],
      });
    } on TimeoutException {
      return _unavailable('timeout', '第三方采样超时');
    } catch (e) {
      debugPrint('[PerfTools] perfThirdPartyMetrics 失败（降级）: $e');
      return _unavailable('error', '$e');
    }
  }

  /// `perfFrameStats`：应用自身帧统计（纯 Dart，恒可用）。
  Future<String> _frameStats(Map<String, dynamic> params) async {
    try {
      final stats = _frame.latestStats;
      return _encode(<String, Object?>{
        'available': true,
        'fps': _round(stats.fps, 1),
        'frame_interval_ms': _round(stats.frameIntervalMs),
        'sampled_frames': stats.sampledFrames,
        'window_size': stats.windowSize,
        'jank_count': stats.jankCount,
        'jank_ratio': _round(stats.jankRatio, 4),
        'window_jank_count': stats.windowJankCount,
        'window_jank_ratio': _round(stats.windowJankRatio, 4),
        'avg_total_ms': _round(stats.avgTotalMs),
        'p90_total_ms': _round(stats.p90TotalMs),
        'p99_total_ms': _round(stats.p99TotalMs),
        'budget_ms': _round(stats.budgetMs, 3),
        'jank_threshold_ms': _round(stats.jankThresholdMs, 3),
      });
    } catch (e) {
      debugPrint('[PerfTools] perfFrameStats 失败（降级）: $e');
      return _unavailable('error', '$e');
    }
  }

  // ==================== 工具函数 ====================

  /// 进程列表按 `sort` 排序：`rss`/`memory`/`mem` → rssKb 降序；`cpu` → CPU 降序；
  /// 其它（含缺省）保持原名。
  static List<PerfProcessInfo> _sortProcesses(
    List<PerfProcessInfo> processes,
    String? sort,
  ) {
    final key = (sort ?? '').toLowerCase();
    if (key.isEmpty) return processes;
    final list = List<PerfProcessInfo>.of(processes);
    if (key == 'rss' || key == 'memory' || key == 'mem') {
      list.sort((a, b) => b.rssKb.compareTo(a.rssKb));
    } else if (key == 'cpu') {
      list.sort((a, b) => b.cpuPercent.compareTo(a.cpuPercent));
    }
    return list;
  }

  static String _encode(Map<String, Object?> value) => jsonEncode(value);

  static String _unavailable(String error, String message) =>
      _encode(<String, Object?>{
        'available': false,
        'error': error,
        'message': message,
      });

  /// 有限值四舍五入到 [digits] 位小数；`null` / 非有限值返回 `null`。
  static double? _round(double? value, [int digits = 2]) {
    if (value == null || !value.isFinite) return null;
    return double.parse(value.toStringAsFixed(digits));
  }
}
