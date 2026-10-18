/// 性能可调面 Agent 工具（**只读**）。
///
/// 一个工具模块（[kPerfTunablesSpec] → `perfTunables`）把 Wave 4 的
/// `perf.tunables` 可控面枚举（todos 11/14）与 fail-closed 能力图（todo 15）
/// 暴露给 in-app Agent，供其**先看清本机到底能调什么、哪些类别真的可写**，
/// 再决定是否请求用户危险确认后调用 `perfControl`（todo 21）。
///
/// ## 设计要点（对齐 [PerfToolModule] / `perf_tools.dart`）
/// * 元数据单一来源（[AgentToolSpec]），[PerfTunablesToolModule] 自包含执行
///   （**不**委托 AgentService 分发），由 [PerfTunablesTools] 注入依赖，供
///   todo 31/32 注册。
/// * **绝不抛出**：模块缺失 / 能力探测失败 / 超时 / 任意异常一律降级为结构化
///   JSON；调用加**有界超时**（[kPerfTunablesToolTimeout]）。
/// * **只读**：不写任何 sysfs 节点、不执行任何动作；能力图仅来自 `test -w` /
///   只读 Binder 探测（fail-closed）。
/// * **无 UI / 无新依赖**；日志统一 `debugPrint`。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 单次 `perfTunables` 调用的有界超时（含能力探测）。
const Duration kPerfTunablesToolTimeout = Duration(seconds: 6);

/// 加载能力图的函数（生产经 [PerfCapabilityProbe]；测试可覆盖为罐头结果）。
typedef PerfTunablesCapabilitiesLoader = Future<PerfControlCapabilities?> Function(
  TunablesReport tunables,
);

// ==================== 工具协议声明（元数据单一来源） ====================

/// 性能可调面 + 控制能力图（无参数，只读）。
const AgentToolSpec kPerfTunablesSpec = AgentToolSpec(
  name: 'perfTunables',
  group: AgentToolGroup.discover,
  label: '性能可调面',
  brief: '读取本机可调性能参数（CPU 簇/governor/频率、GPU、cpuset、热区/散热）'
      '与控制能力图（哪些类别经 Shizuku 真的可写；无参数，只读）。',
  params: <AgentToolParam>[],
  protocol: '''
1. 用户问"这台机器能调什么、能不能改 CPU 频率/governor/GPU/热控、哪些能写"时调用。
2. 无参数；返回一段 JSON：available / tunables{cpu_clusters[], cpusets[],
   thermal_zones[], cooling_devices[], gpu{}} / capabilities_available /
   capabilities{probed_at_ms, timeout_available, nodes{}, binder_levers{},
   categories{}}。
3. **只读**：不执行任何调优、不写任何节点、无副作用。
4. `capabilities` 为 fail-closed 能力图：只有 `categories.<id>.available=true`
   才代表该类别真的可写。**不要**仅凭 `tunables` 里存在某个节点就断言可写。
5. 需要真正调优时，必须另行取得用户显式危险确认后调用 `perfControl`
   （confirm=true）；本工具**不能**代替确认。
6. 原生性能模块未安装时返回 available=false 与可读 message，不要谎称拿到数据；
   能力探测失败时 capabilities_available=false，但 tunables 仍如实返回。''',
);

// ==================== 工具模块（自包含执行） ====================

/// 由 [AgentToolSpec] 派生元数据、执行体可覆写的 Agent 工具模块。
///
/// 与 [PerfToolModule] 同形：本类**自行执行**（不委托 AgentService 分发），
/// 因为该工具是运行时注册的扩展工具（不在内置协议注册表内）。
class PerfTunablesToolModule extends AgentToolModule {
  PerfTunablesToolModule(this.spec, this._run);

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

/// 性能可调面 Agent 工具套件。
///
/// 生产：`PerfTunablesTools()`（默认 [PerfModule.instance.tunables] +
/// [PerfCapabilityProbe]）。
/// 测试：注入罐头 tunables / 能力图 / 抛异常的加载器，**无需 Shizuku / 原生模块**。
class PerfTunablesTools {
  PerfTunablesTools({
    PerfTunablesLoader? tunablesLoader,
    PerfTunablesCapabilitiesLoader? capabilitiesLoader,
    PrivilegedShell? shell,
    PerfCapabilityProbe? probe,
    Duration timeout = kPerfTunablesToolTimeout,
  })  : _tunablesLoaderOverride = tunablesLoader,
        _capabilitiesLoaderOverride = capabilitiesLoader,
        _shell = shell ?? PrivilegedShell(),
        _probeOverride = probe,
        _timeout = timeout;

  final PerfTunablesLoader? _tunablesLoaderOverride;
  final PerfTunablesCapabilitiesLoader? _capabilitiesLoaderOverride;
  final PrivilegedShell _shell;
  final PerfCapabilityProbe? _probeOverride;
  final Duration _timeout;

  /// 会话内复用的能力探针（生产默认；测试可注入取代）。
  late final PerfCapabilityProbe _probe =
      _probeOverride ?? PerfCapabilityProbe(shell: _shell);

  /// 单个工具模块（构造时不触碰任何原生服务；`toolName` 稳定，便于注册/注销）。
  late final List<AgentToolModule> tools = List<AgentToolModule>.unmodifiable(
    <AgentToolModule>[
      PerfTunablesToolModule(kPerfTunablesSpec, _read),
    ],
  );

  // ==================== 入口（有界超时 + 绝不抛出） ====================

  /// 执行一次 `perfTunables`：加载只读可控面 + 能力图。
  ///
  /// **绝不抛出**：超时 / 未预期异常一律降级为结构化 JSON。
  Future<String> _read(Map<String, dynamic> params) async {
    try {
      return await _dispatch().timeout(_timeout);
    } on TimeoutException {
      debugPrint('[PerfTunables] 调用超时（${_timeout.inSeconds}s）→ 降级');
      return _unavailable('timeout', '性能可调面读取超时（≤${_timeout.inSeconds}s）');
    } catch (error, stack) {
      debugPrint('[PerfTunables] 未预期异常（降级）: $error\n$stack');
      return _unavailable('error', '$error');
    }
  }

  Future<String> _dispatch() async {
    // (1) perf.tunables（只读枚举）—— 模块缺失即不可用。
    final TunablesReport tunables;
    try {
      tunables = await _loadTunables();
    } on PerfModuleUnavailableException catch (e) {
      debugPrint('[PerfTunables] 模块不可用: $e');
      return _unavailable('perf_module_unavailable', e.message);
    } catch (error) {
      debugPrint('[PerfTunables] perf.tunables 加载失败（降级）: $error');
      return _unavailable('perf_module_unavailable', '$error');
    }

    // (2) 能力图（fail-closed；失败只降级能力部分，不影响只读枚举）。
    Map<String, dynamic>? capabilities;
    bool capabilitiesAvailable = false;
    String? capabilitiesMessage;
    try {
      final caps = await _loadCapabilities(tunables);
      if (caps == null) {
        capabilitiesMessage = '控制能力未探测（fail-closed）→ 视为不可写';
      } else {
        capabilities = caps.toJson();
        capabilitiesAvailable = true;
      }
    } catch (error) {
      debugPrint('[PerfTunables] 能力探测失败（降级）: $error');
      capabilitiesMessage = '控制能力探测失败（fail-closed）：$error';
    }

    return _encode(<String, Object?>{
      'available': true,
      'tunables': _tunablesToJson(tunables),
      'capabilities_available': capabilitiesAvailable,
      'capabilities': capabilities,
      if (capabilitiesMessage != null) 'capabilities_message': capabilitiesMessage,
    });
  }

  // ==================== 依赖加载 ====================

  Future<TunablesReport> _loadTunables() =>
      (_tunablesLoaderOverride ?? _defaultTunablesLoader)();

  static Future<TunablesReport> _defaultTunablesLoader() =>
      PerfModule.instance.tunables();

  Future<PerfControlCapabilities?> _loadCapabilities(TunablesReport tunables) {
    final override = _capabilitiesLoaderOverride;
    if (override != null) return override(tunables);
    return _probe.probe(tunables);
  }

  // ==================== 序列化 / 工具函数 ====================

  /// `perf.tunables` → 结构稳定的 JSON（字段与 Rust / 契约镜像一致）。
  static Map<String, dynamic> _tunablesToJson(TunablesReport t) =>
      <String, dynamic>{
        'cpu_clusters': <Map<String, dynamic>>[
          for (final c in t.cpuClusters)
            <String, dynamic>{
              'policy': c.policy,
              'related_cpus': c.relatedCpus,
              'available_governors': c.availableGovernors,
              'governor': c.governor,
              'available_frequencies_mhz': c.availableFrequenciesMhz,
              'min_freq_mhz': c.minFreqMhz,
              'max_freq_mhz': c.maxFreqMhz,
            },
        ],
        'cpusets': <Map<String, dynamic>>[
          for (final c in t.cpusets)
            <String, dynamic>{
              'name': c.name,
              'cpus': c.cpus,
              'mems': c.mems,
            },
        ],
        'thermal_zones': <Map<String, dynamic>>[
          for (final z in t.thermalZones)
            <String, dynamic>{
              'zone': z.zone,
              'type': z.type,
              'mode': z.mode,
            },
        ],
        'cooling_devices': <Map<String, dynamic>>[
          for (final d in t.coolingDevices)
            <String, dynamic>{
              'device': d.device,
              'type': d.type,
              'cur_state': d.curState,
              'max_state': d.maxState,
            },
        ],
        'gpu': <String, dynamic>{
          'available_frequencies_mhz': t.gpu.availableFrequenciesMhz,
          'freq_source': t.gpu.freqSource,
          'governor': t.gpu.governor,
          'governor_source': t.gpu.governorSource,
          'power_levels': t.gpu.powerLevels,
          'power_source': t.gpu.powerSource,
        },
      };

  static String _encode(Map<String, Object?> value) => jsonEncode(value);

  static String _unavailable(String error, String message) =>
      _encode(<String, Object?>{
        'available': false,
        'error': error,
        'message': message,
      });
}
