/// Wave 4 控制动作的**硬门禁**：能力探测（fail-closed）。
///
/// 本层回答唯一的问题：**在这一台设备上、经 Shizuku（uid 2000）shell，
/// 到底哪些控制旋钮真的可用？** 它**从不**写任何节点，只用两类**正向**信号：
///
/// 1. 候选 sysfs / cpuset 控制节点 → `test -w <node>`（退出 0 = 可写）；
/// 2. Binder 命令杠杆（`cmd power` / `cmd thermal` / `settings` /
///    `device_config` / `am`）→ **只读 / help** 调用 + 输出标记；
/// 3. `command -v timeout` → 自我限时工具是否存在（供调用方判断）。
///
/// ## FAIL-CLOSED（不可协商）
/// **只有正向信号才判为可用。** 任何超时 / 无输出 / 哨兵缺失 / 命令失败 /
/// 抛异常 / 白名单外 / 路径推导失败 → 一律 `unavailable`。**绝不**因为「路径存在」
/// 就假定可写（DAC + SELinux 是每次写入时才裁决的）。
///
/// ## 为什么是 `test -w` 而不是真写
/// 探测阶段**禁止**任何破坏性写入：`test -w` 是 shell 对该 uid 的 DAC 可写性
/// 判定，是**必要非充分**信号（SELinux 可能在真正写入时拒绝）。因此 Wave 4 的
/// 真正动作仍必须「写完回读对账」，本层只做**门禁**，不替代写后校验。
///
/// ## 消费方式（Wave 4 / todos 16-19、28、37）
/// * [PerfControlCapabilities.isCategoryAvailable]：某类别（CPU/GPU/cpuset/thermal）
///   存在**至少一个**可用节点才为 `true`；否则该类别动作必须**关闭**。
/// * [PerfControlCapabilities.binderLevers]：Binder 命令杠杆单独成类
///   （[PerfControlCategory.binderLevers]）。
/// * 结果**按会话缓存**在 [PerfCapabilityProbe] 内，`probe()` 默认复用缓存，
///   `refresh: true` 才重新探测。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

// ==================== 类别 / 杠杆常量 ====================

/// Wave 4 消费的控制能力类别。
enum PerfControlCategory {
  /// CPU cpufreq（governor / min / max）。
  cpu,

  /// GPU 频率 / 功耗档位。
  gpu,

  /// cpuset / affinity。
  cpuset,

  /// 热区 `mode` / 散热。
  thermal,

  /// Binder 命令杠杆（非 sysfs：`cmd power` / `cmd thermal` / `settings` /
  /// `device_config` / `am set-standby-bucket`）。
  binderLevers;

  /// 稳定的字符串标识（用于日志 / 报告）。
  String get id => switch (this) {
        PerfControlCategory.cpu => 'cpu',
        PerfControlCategory.gpu => 'gpu',
        PerfControlCategory.cpuset => 'cpuset',
        PerfControlCategory.thermal => 'thermal',
        PerfControlCategory.binderLevers => 'binder-levers',
      };
}

/// Binder 命令杠杆 id（可在 shell 上驱动的非 sysfs 旋钮）。
abstract final class PerfControlLevers {
  /// `cmd power set-fixed-performance-mode-enabled`。
  static const String powerFixedPerf =
      'cmd.power.set-fixed-performance-mode-enabled';

  /// `cmd thermal`。
  static const String thermal = 'cmd.thermal';

  /// `settings get/put`。
  static const String settings = 'settings.get_put';

  /// `device_config`。
  static const String deviceConfig = 'device_config';

  /// `am set-standby-bucket`。
  static const String amStandbyBucket = 'am.set-standby-bucket';

  /// 全部杠杆 id（顺序稳定）。
  static const List<String> all = <String>[
    powerFixedPerf,
    thermal,
    settings,
    deviceConfig,
    amStandbyBucket,
  ];
}

/// 探测用的 sysfs / cpuset 白名单：默认写白名单 + GPU 功耗档位节点。
///
/// 探测**只读**（`test -w`），因此可以比写白名单略宽；但每条候选路径仍必须
/// 命中此白名单，否则**直接判不可用**（绝不对任意路径拼命令）。
const List<String> kControlProbeAllowlist = <String>[
  ...kDefaultSysfsAllowlist,
  '/sys/class/kgsl/kgsl-3d0/devfreq/governor',
  '/sys/class/kgsl/kgsl-3d0/governor',
  '/sys/class/kgsl/kgsl-3d0/min_pwrlevel',
  '/sys/class/kgsl/kgsl-3d0/max_pwrlevel',
];

// ==================== 结果模型 ====================

/// 一次完整能力探测的结果（**不可变快照**，供 Wave 4 gating 消费）。
class PerfControlCapabilities {
  const PerfControlCapabilities({
    required this.nodeAvailability,
    required this.binderLevers,
    required this.categoryAvailability,
    required this.nodeCounts,
    required this.timeoutAvailable,
    required this.probedAtMs,
  });

  /// 每个候选控制节点的可用性（`path -> bool`；值只可能来自正向信号）。
  final Map<String, bool> nodeAvailability;

  /// 每个 Binder 杠杆的可用性（`lever id -> bool`）。
  final Map<String, bool> binderLevers;

  /// 每个类别的可用性（**至少一个**可用节点 / 杠杆才为 `true`）。
  final Map<PerfControlCategory, bool> categoryAvailability;

  /// 每个类别可用节点计数（可用 / 候选）。
  final Map<PerfControlCategory, int> nodeCounts;

  /// `command -v timeout` 是否存在（自我限时工具）。
  final bool timeoutAvailable;

  /// 探测时间（Unix ms）。
  final int probedAtMs;

  /// 某类别是否可用（Wave 4 门禁入口）。
  bool isCategoryAvailable(PerfControlCategory category) =>
      categoryAvailability[category] == true;

  /// 某节点是否可用（**只有显式 `true` 才算可用**）。
  bool isNodeAvailable(String path) => nodeAvailability[path] == true;

  /// 某 Binder 杠杆是否可用。
  bool isLeverAvailable(String leverId) => binderLevers[leverId] == true;

  /// 可用节点总数（跨类别）。
  int get availableNodeCount =>
      nodeAvailability.values.where((v) => v).length;

  /// 可序列化摘要（日志 / 报告 / 证据）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'probed_at_ms': probedAtMs,
        'timeout_available': timeoutAvailable,
        'nodes': Map<String, bool>.from(nodeAvailability),
        'binder_levers': Map<String, bool>.from(binderLevers),
        'categories': <String, dynamic>{
          for (final category in PerfControlCategory.values)
            category.id: <String, dynamic>{
              'available': isCategoryAvailable(category),
              'writable_nodes': nodeCounts[category] ?? 0,
              if (category == PerfControlCategory.binderLevers)
                'available_levers':
                    binderLevers.values.where((v) => v).length,
            },
        },
      };

  /// 人类可读的多行摘要（证据 / 日志）。
  String describe() {
    final buffer = StringBuffer()
      ..writeln('timeout_available=$timeoutAvailable')
      ..writeln('available_nodes=$availableNodeCount/${nodeAvailability.length}');
    for (final category in PerfControlCategory.values) {
      final available = isCategoryAvailable(category) ? 'AVAILABLE' : 'DISABLED';
      if (category == PerfControlCategory.binderLevers) {
        final levers = binderLevers.values.where((v) => v).length;
        buffer.writeln('category ${category.id}: $available '
            '(levers $levers/${binderLevers.length})');
      } else {
        buffer.writeln('category ${category.id}: $available '
            '(writable ${nodeCounts[category] ?? 0})');
      }
    }
    buffer.writeln('nodes:');
    final paths = nodeAvailability.keys.toList()..sort();
    for (final path in paths) {
      buffer.writeln('  ${nodeAvailability[path]! ? 'writable' : 'denied  '} $path');
    }
    buffer.writeln('binder_levers:');
    for (final lever in PerfControlLevers.all) {
      buffer.writeln(
          '  ${isLeverAvailable(lever) ? 'available' : 'absent   '} $lever');
    }
    return buffer.toString();
  }
}

// ==================== 探测服务 ====================

/// 单个 Binder 杠杆的探测定义。
class _LeverSpec {
  const _LeverSpec({required this.id, required this.body, this.marker});

  /// 杠杆 id（见 [PerfControlLevers]）。
  final String id;

  /// 只读 / help 调用体（**绝不写入**）。
  final String body;

  /// 正向标记：输出中必须出现该子串才判可用；`null` = 命令退出 0 即判可用。
  final String? marker;
}

/// FAIL-CLOSED 的控制能力探测器。
///
/// 生产：`PerfCapabilityProbe(shell: PrivilegedShell())`。
/// 测试：注入带假 [CommandRunner] 的 [PrivilegedShell]，**无需 Shizuku / 真机**。
class PerfCapabilityProbe {
  PerfCapabilityProbe({
    required PrivilegedShell shell,
    PrivilegedInputValidator? validator,
  })  : _shell = shell,
        _validator = validator ??
            PrivilegedInputValidator(sysfsPatterns: kControlProbeAllowlist);

  final PrivilegedShell _shell;
  final PrivilegedInputValidator _validator;

  PerfControlCapabilities? _cached;

  /// 会话缓存（未探测时为 `null`）。
  PerfControlCapabilities? get cached => _cached;

  /// Binder 杠杆探测表（顺序稳定）。
  static const List<_LeverSpec> _leverSpecs = <_LeverSpec>[
    _LeverSpec(
      id: PerfControlLevers.powerFixedPerf,
      body: 'cmd power',
      marker: 'set-fixed-performance-mode-enabled',
    ),
    // `cmd thermal` 无稳定子命令标记 → 退出 0 即正向信号（best-effort）。
    _LeverSpec(id: PerfControlLevers.thermal, body: 'cmd thermal'),
    // `settings get` 是只读调用（读取一个无副作用键）。
    _LeverSpec(
      id: PerfControlLevers.settings,
      body: 'settings get global bluetooth_on',
    ),
    // `device_config` 无参数打印 help（只读）。
    _LeverSpec(id: PerfControlLevers.deviceConfig, body: 'device_config'),
    _LeverSpec(
      id: PerfControlLevers.amStandbyBucket,
      body: 'am help',
      marker: 'set-standby-bucket',
    ),
  ];

  /// 探测全部候选节点 + Binder 杠杆 + `timeout` 工具。
  ///
  /// [refresh] 为假（默认）时复用会话缓存；为真时重新探测并覆盖缓存。
  /// **绝不抛出**：单个候选探测失败只影响该候选（判不可用）。
  Future<PerfControlCapabilities> probe(
    TunablesReport tunables, {
    bool refresh = false,
  }) async {
    final cached = _cached;
    if (!refresh && cached != null) return cached;

    final availability = <String, bool>{};
    for (final path in _candidateNodes(tunables)) {
      availability[path] = await _probeNode(path);
    }

    final levers = <String, bool>{};
    for (final spec in _leverSpecs) {
      levers[spec.id] = await _probeLever(spec);
    }

    final timeoutAvailable = await _probeTimeoutTool();

    final capabilities = PerfControlCapabilities(
      nodeAvailability: Map<String, bool>.unmodifiable(availability),
      binderLevers: Map<String, bool>.unmodifiable(levers),
      categoryAvailability: Map<PerfControlCategory, bool>.unmodifiable(
        _summarizeCategories(availability, levers),
      ),
      nodeCounts: Map<PerfControlCategory, int>.unmodifiable(
        _countByCategory(availability),
      ),
      timeoutAvailable: timeoutAvailable,
      probedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _cached = capabilities;
    return capabilities;
  }

  // ==================== 候选节点推导（仅来自 perf.tunables） ====================

  /// 从 `perf.tunables` 推导候选控制节点（去重升序）。
  List<String> _candidateNodes(TunablesReport tunables) {
    final nodes = <String>{};

    for (final cluster in tunables.cpuClusters) {
      if (cluster.policy.isEmpty) continue;
      final base = '/sys/devices/system/cpu/cpufreq/${cluster.policy}';
      nodes
        ..add('$base/scaling_governor')
        ..add('$base/scaling_min_freq')
        ..add('$base/scaling_max_freq');
    }

    for (final cpuset in tunables.cpusets) {
      if (cpuset.name.isEmpty) continue;
      nodes
        ..add('/dev/cpuset/${cpuset.name}/cpus')
        ..add('/dev/cpuset/${cpuset.name}/mems');
    }

    for (final zone in tunables.thermalZones) {
      if (zone.zone.isEmpty) continue;
      nodes.add('/sys/class/thermal/${zone.zone}/mode');
    }

    nodes.addAll(_gpuNodes(tunables.gpu));

    final ordered = nodes.toList()..sort();
    return ordered;
  }

  /// GPU 候选节点：由 tunables 暴露的**来源路径**推出其同级控制叶子。
  Set<String> _gpuNodes(PerfGpuTunables gpu) {
    final out = <String>{};
    void addDir(String? source) {
      final dir = _parentDir(source);
      if (dir == null) return;
      for (final leaf in _gpuLeaves(dir)) {
        out.add('$dir/$leaf');
      }
    }

    addDir(gpu.governorSource);
    addDir(gpu.freqSource);
    addDir(gpu.powerSource);
    return out;
  }

  static String? _parentDir(String? path) {
    if (path == null || path.isEmpty) return null;
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return null;
    return path.substring(0, idx);
  }

  static List<String> _gpuLeaves(String dir) {
    if (dir.endsWith('/devfreq')) {
      return const <String>['governor', 'min_freq', 'max_freq'];
    }
    if (dir.contains('kgsl-3d0')) {
      return const <String>[
        'governor',
        'min_gpuclk',
        'max_gpuclk',
        'min_pwrlevel',
        'max_pwrlevel',
      ];
    }
    return const <String>['governor', 'min_freq', 'max_freq'];
  }

  // ==================== 探测原语（全部 fail-closed） ====================

  /// `test -w <node>`：退出 0（哨兵 `ok=1`）才判可写；其余一律不可用。
  Future<bool> _probeNode(String path) async {
    // 白名单外 → 不拼命令，直接判不可用（绝不把任意路径交给 shell）。
    if (_validator.sysfsPathReason(path) != null) return false;
    final result = await _shell.run(_shell.buildCommand('test -w $path'));
    return result.ok;
  }

  /// Binder 杠杆：只读 / help 调用；有标记则必须命中标记，否则退出 0 即正向。
  Future<bool> _probeLever(_LeverSpec spec) async {
    final result = await _shell.run(_shell.buildCommand(spec.body));
    if (!result.ok) return false;
    final marker = spec.marker;
    if (marker == null) return true;
    return result.output.contains(marker);
  }

  /// `command -v timeout`：退出 0 表示自我限时工具存在。
  Future<bool> _probeTimeoutTool() async {
    final result = await _shell.run(_shell.buildCommand('command -v timeout'));
    return result.ok;
  }

  // ==================== 类别汇总 ====================

  /// 每类别：存在**至少一个**可用节点（或有可用杠杆）→ 可用。
  Map<PerfControlCategory, bool> _summarizeCategories(
    Map<String, bool> nodes,
    Map<String, bool> levers,
  ) {
    final summary = <PerfControlCategory, bool>{
      for (final category in PerfControlCategory.values) category: false,
    };
    for (final entry in nodes.entries) {
      if (!entry.value) continue;
      final category = _categoryForPath(entry.key);
      if (category != null) summary[category] = true;
    }
    summary[PerfControlCategory.binderLevers] = levers.values.any((v) => v);
    return summary;
  }

  /// 每类别可用节点计数。
  Map<PerfControlCategory, int> _countByCategory(Map<String, bool> nodes) {
    final counts = <PerfControlCategory, int>{
      for (final category in PerfControlCategory.values) category: 0,
    };
    for (final entry in nodes.entries) {
      if (!entry.value) continue;
      final category = _categoryForPath(entry.key);
      if (category != null) counts[category] = counts[category]! + 1;
    }
    return counts;
  }

  /// 路径 → 类别（未知前缀返回 `null`，不参与汇总）。
  static PerfControlCategory? _categoryForPath(String path) {
    if (path.startsWith('/dev/cpuset/')) return PerfControlCategory.cpuset;
    if (path.startsWith('/sys/class/thermal/')) {
      return PerfControlCategory.thermal;
    }
    if (path.startsWith('/sys/devices/system/cpu')) {
      return PerfControlCategory.cpu;
    }
    if (path.startsWith('/sys/class/kgsl') ||
        path.startsWith('/sys/class/devfreq') ||
        path.startsWith('/sys/kernel/gpu') ||
        path.startsWith('/sys/class/mali')) {
      return PerfControlCategory.gpu;
    }
    return null;
  }
}

// ==================== Riverpod 接线（镜像 lib/page/perf/logic.dart） ====================

/// 加载 `perf.tunables` 的函数（生产经模块门面；测试可覆盖）。
typedef PerfTunablesLoader = Future<TunablesReport> Function();

/// `perf.tunables` 加载器（生产为模块门面；测试覆盖为罐头报告）。
final perfTunablesLoaderProvider = Provider<PerfTunablesLoader>(
  (ref) => () => PerfModule.instance.tunables(),
);

/// 能力探测器（生产为单例；测试覆盖为注入假 shell 的实例）。
final perfCapabilityProbeProvider = Provider<PerfCapabilityProbe>(
  (ref) => PerfCapabilityProbe(shell: PrivilegedShell()),
);

/// 最近一次能力探测结果（`null` = 尚未探测）；Wave 4 据此 gating。
final perfControlCapabilitiesProvider =
    NotifierProvider<PerfControlCapabilitiesNotifier, PerfControlCapabilities?>(
  PerfControlCapabilitiesNotifier.new,
);

/// 驱动探测并暴露结果的 Notifier（会话内缓存；`probe(refresh: true)` 强制重探）。
class PerfControlCapabilitiesNotifier
    extends Notifier<PerfControlCapabilities?> {
  bool _disposed = false;

  @override
  PerfControlCapabilities? build() {
    ref.onDispose(() => _disposed = true);
    return ref.read(perfCapabilityProbeProvider).cached;
  }

  /// 拉取 `perf.tunables` 后探测能力；任何失败都降级为 `null`（绝不抛出）。
  Future<PerfControlCapabilities?> probe({bool refresh = false}) async {
    if (_disposed) return null;
    try {
      final tunables = await ref.read(perfTunablesLoaderProvider)();
      final capabilities = await ref
          .read(perfCapabilityProbeProvider)
          .probe(tunables, refresh: refresh);
      if (_disposed) return capabilities;
      state = capabilities;
      return capabilities;
    } catch (error) {
      debugPrint('[PerfCapabilityProbe] 能力探测失败（fail-closed）: $error');
      return null;
    }
  }
}
