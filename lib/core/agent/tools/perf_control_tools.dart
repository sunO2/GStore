/// 性能控制 Agent 工具（**危险、需显式确认**）。
///
/// 一个工具模块（[kPerfControlSpec] → `perfControl`）把 Wave 4 的控制动作
/// （todos 16-19）暴露给 in-app Agent，但调用方必须**先过两道硬门禁**：
///
/// 1. **显式确认（out-of-band）**：`confirm` 必须**恰为** JSON 布尔 `true`。
///    任何其它值（缺省 / `"true"` 字符串 / `1` / `null`）→ 在任何命令之前返回
///    结构化 `confirm_required` 且**零写入**（默认绝不自行调优）。
/// 2. **能力探测门禁（todo 15，fail-closed）**：`perf.tunables` + 能力探针必须
///    在能力图中把目标**类别**显式标记为可用；未知 / 未探测 / 类别不可用 →
///    结构化 `unavailable` 且**零写入**。
///
/// 通过门禁后按 `action` 分发到对应动作层：
/// * `cpu`    → [CpuControl.applyCpuPolicy]（governor / 每簇 min·max）；
/// * `gpu`    → [GpuControlAction.applyGpuPolicy]（governor / 频率 / 功耗档位）；
/// * `cpuset` → [CpusetController.applyCpuset]（把包名/pid 归属到 cgroup）；
/// * `thermal`→ [ThermalToggleController.setThermalEnabledLoose]（热控开关）。
///
/// ## 设计要点（对齐 [PerfToolModule] / `perf_tools.dart:98-129`）
/// * 元数据单一来源（[AgentToolSpec]），[PerfControlToolModule] 自包含执行
///   （**不**委托 AgentService 分发），由 [PerfControlTools] 注入依赖，供
///   todo 31/32 注册；本文件**不**改 `AgentToolsModule.tools`。
/// * **绝不抛出**：任何失败（含超时 / 未预期异常）都降级为结构化 JSON
///   `{available, ok, error, message, action}`；调用加**有界超时**
///   （[kPerfControlToolTimeout]）。
/// * **对抗输入**：agent 提供的 `action` / 参数**不能**绕过确认门禁或动作层
///   入参校验器（白名单 / 危险字符）；非法载荷 → 结构化错误，**零命令**。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/core/perf/control_cpu.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/control_thermal.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 单次 `perfControl` 调用的有界超时（避免 Agent 运行时被长时间阻塞）。
const Duration kPerfControlToolTimeout = Duration(seconds: 6);

// ==================== action / 错误码常量 ====================

/// `perfControl` 支持的 `action` 取值（与 Wave 4 动作层一一对应）。
abstract final class PerfControlActions {
  /// CPU governor / 每簇 min·max 频率。
  static const String cpu = 'cpu';

  /// GPU governor / 频率 / 功耗档位。
  static const String gpu = 'gpu';

  /// cpuset / affinity 归属。
  static const String cpuset = 'cpuset';

  /// 热控开关（危险方向 = 关闭热控）。
  static const String thermal = 'thermal';

  /// 全部 action（顺序稳定）。
  static const List<String> all = <String>[cpu, gpu, cpuset, thermal];
}

/// [PerfControlTools] 的结构化错误码（JSON `error` 字段）。
abstract final class PerfControlError {
  /// 缺少显式确认（`confirm != true`）→ 零命令、零写入。
  static const String confirmRequired = 'confirm_required';

  /// 未知 / 缺失 `action` → 零命令、零写入。
  static const String invalidAction = 'invalid_action';

  /// 动作入参非法（缺失 / 危险字符 / 越界）→ 零命令、零写入。
  static const String invalidArg = 'invalid_arg';

  /// 能力未知 / 类别不可用（fail-closed）→ 零写入。
  static const String unavailable = 'unavailable';

  /// 调用超过有界超时。
  static const String timeout = 'timeout';

  /// 未预期异常（降级为结构化结果）。
  static const String error = 'error';
}

// ==================== 工具协议声明（元数据单一来源） ====================

/// 性能控制（危险操作；`confirm` 必填且能力门控）。
const AgentToolSpec kPerfControlSpec = AgentToolSpec(
  name: 'perfControl',
  group: AgentToolGroup.manage,
  label: '性能控制（危险）',
  brief: '危险：调整 CPU/GPU/cpuset/热控；必须有用户显式确认（confirm=true）且'
      '设备能力探测通过，否则一律拒绝。',
  params: <AgentToolParam>[
    AgentToolParam(
      name: 'action',
      description: 'cpu / gpu / cpuset / thermal',
      required: true,
    ),
    AgentToolParam(
      name: 'confirm',
      description: '必须为 true：由用户危险确认弹层授权（out-of-band）。'
          '缺省 / 非布尔 true 一律拒绝（零写入）。',
      required: true,
      type: 'bool',
    ),
    AgentToolParam(
      name: 'cluster',
      description: 'CPU 策略簇名（action=cpu，如 policy0）',
    ),
    AgentToolParam(name: 'governor', description: 'CPU/GPU governor 名（token）'),
    AgentToolParam(
      name: 'min_freq_mhz',
      description: 'CPU/GPU 最小频率（MHz）',
      type: 'number',
    ),
    AgentToolParam(
      name: 'max_freq_mhz',
      description: 'CPU/GPU 最大频率（MHz）',
      type: 'number',
    ),
    AgentToolParam(
      name: 'min_pwrlevel',
      description: 'GPU 最小功耗档位（action=gpu）',
      type: 'int',
    ),
    AgentToolParam(
      name: 'max_pwrlevel',
      description: 'GPU 最大功耗档位（action=gpu）',
      type: 'int',
    ),
    AgentToolParam(
      name: 'package',
      description: '目标应用包名（action=cpuset，如 com.x.y）',
    ),
    AgentToolParam(
      name: 'cpuset',
      description: '目标 cpuset 名（action=cpuset，如 top-app / background）',
    ),
    AgentToolParam(
      name: 'enabled',
      description: '热控开关（action=thermal）：true=开启热控；'
          'false=关闭热控（危险，过热风险）。',
      type: 'bool',
    ),
  ],
  alwaysSensitive: true,
  protocol: '''
1. 这是**危险**工具：会经 Shizuku 特权 shell 写 CPU/GPU/cpuset/热控节点。
   只有用户在界面上明确同意后才可调用；**必须**传 confirm=true。
2. 缺 confirm（或非布尔 true）→ 直接返回 {ok:false, error:"confirm_required"}，
   **不执行任何命令**。不要用文字/其它工具绕过确认。
3. action 与参数：
   - cpu：cluster（如 policy0）+ governor / min_freq_mhz / max_freq_mhz（至少一个）；
   - gpu：governor / min_freq_mhz / max_freq_mhz / min_pwrlevel / max_pwrlevel（至少一个）；
   - cpuset：package + cpuset（如 top-app）；
   - thermal：enabled（true=开热控；false=关热控，危险）。
4. 设备能力（是否可写）由 fail-closed 探针门控：类别不可用 → 返回
   {ok:false, error:"unavailable"} 且**零写入**，不要谎称已生效。
5. 返回 JSON：available / ok / error / message / action（+ 动作相关字段）。
   失败原因可能是 invalid_arg / unavailable / write_failed / readback_mismatch 等；
   如实转述，不要伪造成功。
6. 每次只做一个 action；改完如用户要还原，需另行确认后反向调整。''',
);

// ==================== 工具模块（自包含执行） ====================

/// 由 [AgentToolSpec] 派生元数据、执行体可覆写的 Agent 工具模块。
///
/// 与 [PerfToolModule] 同形：本类**自行执行**（不委托 AgentService 分发），
/// 因为控制工具是运行时注册的扩展工具（不在内置协议注册表内）。
class PerfControlToolModule extends AgentToolModule {
  PerfControlToolModule(this.spec, this._run);

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

/// 加载 `perf.tunables` 的函数（生产经模块门面；测试可覆盖）。
typedef PerfCapabilitiesLoader = Future<PerfControlCapabilities?> Function(
  TunablesReport tunables,
);

/// 性能控制 Agent 工具套件。
///
/// 生产：`PerfControlTools()`（默认 [PrivilegedShell] / [PerfModule.instance] /
/// [PerfCapabilityProbe]）。
/// 测试：注入假 [PrivilegedShell]（假 [CommandRunner]）+ 罐头 tunables / 能力图 /
/// 假 [PidResolver] / 假 [PerfSysfsReader]，**无需 Shizuku / 真机 / 原生模块**。
class PerfControlTools {
  PerfControlTools({
    PrivilegedShell? shell,
    PerfTunablesLoader? tunablesLoader,
    PerfCapabilitiesLoader? capabilitiesLoader,
    PerfCapabilityProbe? probe,
    PerfSysfsReader? cpuSysfsReader,
    PidResolver? pidResolver,
    Duration timeout = kPerfControlToolTimeout,
  })  : _shell = shell ?? PrivilegedShell(),
        _tunablesLoaderOverride = tunablesLoader,
        _capabilitiesLoaderOverride = capabilitiesLoader,
        _probeOverride = probe,
        _cpuSysfsReader = cpuSysfsReader,
        _pidResolver = pidResolver,
        _timeout = timeout;

  final PrivilegedShell _shell;
  final PerfTunablesLoader? _tunablesLoaderOverride;
  final PerfCapabilitiesLoader? _capabilitiesLoaderOverride;
  final PerfCapabilityProbe? _probeOverride;
  final PerfSysfsReader? _cpuSysfsReader;
  final PidResolver? _pidResolver;
  final Duration _timeout;

  /// 会话内复用的能力探针（生产默认；测试可注入取代）。
  late final PerfCapabilityProbe _probe =
      _probeOverride ?? PerfCapabilityProbe(shell: _shell);

  /// 单个工具模块（构造时不触碰任何原生服务；`toolName` 稳定，便于注册/注销）。
  late final List<AgentToolModule> tools = List<AgentToolModule>.unmodifiable(
    <AgentToolModule>[
      PerfControlToolModule(kPerfControlSpec, _control),
    ],
  );

  // ==================== 入口（有界超时 + 绝不抛出） ====================

  /// 执行一次 `perfControl`：确认门禁 → 能力门禁 → 分发动作。
  ///
  /// **绝不抛出**：超时 / 未预期异常一律降级为结构化 JSON。
  Future<String> _control(Map<String, dynamic> params) async {
    try {
      return await _dispatch(params).timeout(_timeout);
    } on TimeoutException {
      debugPrint('[PerfControl] 调用超时（${_timeout.inSeconds}s）→ 降级');
      return _encode(<String, Object?>{
        'available': false,
        'ok': false,
        'error': PerfControlError.timeout,
        'message': '性能控制调用超时（≤${_timeout.inSeconds}s）',
      });
    } catch (error, stack) {
      debugPrint('[PerfControl] 未预期异常（降级）: $error\n$stack');
      return _encode(<String, Object?>{
        'available': false,
        'ok': false,
        'error': PerfControlError.error,
        'message': '$error',
      });
    }
  }

  Future<String> _dispatch(Map<String, dynamic> params) async {
    // (1) 确认门禁最先执行 —— action 载荷绝不可能绕过它。
    if (params['confirm'] != true) {
      debugPrint('[PerfControl] 缺少显式确认（confirm != true）→ 拒绝（零写入）');
      return _refuse(
        PerfControlError.confirmRequired,
        '缺少显式确认：confirm 必须为布尔 true（用户危险确认授权）→ '
            '拒绝执行，零写入',
      );
    }

    // (2) action 解析（校验先于任何命令）。
    final action = params['action']?.toString().trim() ?? '';
    if (!PerfControlActions.all.contains(action)) {
      return _refuse(
        PerfControlError.invalidAction,
        '未知 action "$action"（允许：${PerfControlActions.all.join("/")}）→ 零写入',
      );
    }

    // (3) perf.tunables + 能力探针（fail-closed）。
    final TunablesReport tunables;
    try {
      tunables = await _loadTunables();
    } catch (error) {
      debugPrint('[PerfControl] perf.tunables 加载失败（降级）: $error');
      return _unavailable(action, 'perf.tunables 不可用：$error');
    }

    PerfControlCapabilities? capabilities;
    try {
      capabilities = await _loadCapabilities(tunables);
    } catch (error) {
      debugPrint('[PerfControl] 能力探测失败（fail-closed）: $error');
      capabilities = null;
    }
    if (capabilities == null) {
      return _unavailable(action, '控制能力未探测（fail-closed）→ 拒绝写入');
    }

    // (4) 类别门禁：只有显式可用才继续。
    final category = _categoryFor(action);
    if (!capabilities.isCategoryAvailable(category)) {
      return _unavailable(
        action,
        '类别 ${category.id} 在本机 / 本 shell 不可用（探针 fail-closed）→ 零写入',
      );
    }

    // (5) 分发到 Wave 4 动作层（各自再做写前校验 + 写后回读）。
    return switch (action) {
      PerfControlActions.cpu => _applyCpu(params, tunables, capabilities),
      PerfControlActions.gpu => _applyGpu(params, tunables),
      PerfControlActions.cpuset => _applyCpuset(params),
      PerfControlActions.thermal => _applyThermal(params, tunables, capabilities),
      _ => _refuse(PerfControlError.invalidAction, '未知 action "$action"'),
    };
  }

  // ==================== 动作分发 ====================

  Future<String> _applyCpu(
    Map<String, dynamic> params,
    TunablesReport tunables,
    PerfControlCapabilities capabilities,
  ) async {
    const action = PerfControlActions.cpu;
    final cluster = params['cluster']?.toString().trim() ?? '';
    final governor = _nonEmptyString(params['governor']);
    final minFreq = _asDouble(params['min_freq_mhz']);
    final maxFreq = _asDouble(params['max_freq_mhz']);
    if (cluster.isEmpty) {
      return _invalid(action, 'cpu 需要参数 cluster（策略簇名，如 policy0）');
    }
    if (governor == null && minFreq == null && maxFreq == null) {
      return _invalid(
        action,
        'cpu 至少需要 governor / min_freq_mhz / max_freq_mhz 之一',
      );
    }

    final controller = CpuControl(
      shell: _shell,
      tunables: tunables,
      capabilities: capabilities,
      sysfsReader: _cpuSysfsReader,
    );
    final result = await controller.applyCpuPolicy(
      cluster: cluster,
      governor: governor,
      minFreqMhz: minFreq,
      maxFreqMhz: maxFreq,
    );
    return _encode(<String, Object?>{
      'available': result.status != CpuPolicyStatus.unavailable,
      'ok': result.ok,
      'error': result.ok ? null : result.status,
      'message': result.message ?? result.status,
      'action': action,
      'cluster': result.cluster,
      'applied': result.applied.map((c) => c.toJson()).toList(growable: false),
    });
  }

  Future<String> _applyGpu(
    Map<String, dynamic> params,
    TunablesReport tunables,
  ) async {
    const action = PerfControlActions.gpu;
    final policy = GpuPolicy(
      governor: _nonEmptyString(params['governor']),
      minFreqMhz: _asDouble(params['min_freq_mhz']),
      maxFreqMhz: _asDouble(params['max_freq_mhz']),
      minPwrlevel: _asInt(params['min_pwrlevel']),
      maxPwrlevel: _asInt(params['max_pwrlevel']),
    );
    if (policy.isEmpty) {
      return _invalid(
        action,
        'gpu 至少需要一个旋钮（governor / min_freq_mhz / max_freq_mhz / '
            'min_pwrlevel / max_pwrlevel）',
      );
    }

    final controller = GpuControlAction(shell: _shell);
    final result = await controller.applyGpuPolicy(policy, tunables: tunables);
    return _encode(<String, Object?>{
      'available': result.status != GpuPolicyStatus.unavailable,
      'ok': result.applied,
      'error': result.error,
      'message': result.reason ?? result.status.name,
      'action': action,
      'status': result.status.name,
      'writes': result.writeCount,
    });
  }

  Future<String> _applyCpuset(Map<String, dynamic> params) async {
    const action = PerfControlActions.cpuset;
    final pkgOrPid = params['package']?.toString().trim() ?? '';
    final cpuset = params['cpuset']?.toString().trim() ?? '';
    if (pkgOrPid.isEmpty || cpuset.isEmpty) {
      return _invalid(action, 'cpuset 需要参数 package 与 cpuset');
    }

    final controller = CpusetController(shell: _shell, pidResolver: _pidResolver);
    final result = await controller.applyCpuset(
      pkgOrPid: pkgOrPid,
      cpuset: cpuset,
    );
    return _encode(<String, Object?>{
      'available': result.status != CpusetError.unavailable,
      'ok': result.ok,
      'error': result.ok ? null : result.status,
      'message': result.message,
      'action': action,
      'cpuset': result.cpuset,
      'applied_pids': result.appliedPids,
    });
  }

  Future<String> _applyThermal(
    Map<String, dynamic> params,
    TunablesReport tunables,
    PerfControlCapabilities capabilities,
  ) async {
    const action = PerfControlActions.thermal;
    // 已过上面的 confirm 门禁（confirm == true），故这里 confirmed: true。
    // enabled 传入原始值：非 bool → 动作层 invalid_arg（覆盖 malformed bool）。
    final controller = ThermalToggleController(shell: _shell);
    final result = await controller.setThermalEnabledLoose(
      params['enabled'],
      confirmed: true,
      tunables: tunables,
      capabilities: capabilities,
    );
    return _encode(<String, Object?>{
      'available': result.error != ThermalToggleError.unavailable,
      'ok': result.ok,
      'error': result.error,
      'message': result.detail,
      'action': action,
      'requested_enabled': result.requestedEnabled,
      'applied': result.applied.map((r) => r.path).toList(growable: false),
    });
  }

  // ==================== 依赖加载 ====================

  Future<TunablesReport> _loadTunables() =>
      (_tunablesLoaderOverride ?? _defaultTunablesLoader)();

  static Future<TunablesReport> _defaultTunablesLoader() =>
      PerfModule.instance.tunables();

  Future<PerfControlCapabilities?> _loadCapabilities(
    TunablesReport tunables,
  ) {
    final override = _capabilitiesLoaderOverride;
    if (override != null) return override(tunables);
    return _probe.probe(tunables);
  }

  // ==================== 工具函数 ====================

  static PerfControlCategory _categoryFor(String action) => switch (action) {
        PerfControlActions.cpu => PerfControlCategory.cpu,
        PerfControlActions.gpu => PerfControlCategory.gpu,
        PerfControlActions.cpuset => PerfControlCategory.cpuset,
        PerfControlActions.thermal => PerfControlCategory.thermal,
        _ => PerfControlCategory.cpu,
      };

  static String? _nonEmptyString(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// 宽容取数：`num` / 数值字符串；非有限值 → `null`（视为未提供）。
  static double? _asDouble(Object? value) {
    if (value is num) {
      final parsed = value.toDouble();
      return parsed.isFinite ? parsed : null;
    }
    if (value is String) {
      final parsed = double.tryParse(value.trim());
      return (parsed == null || !parsed.isFinite) ? null : parsed;
    }
    return null;
  }

  /// 宽容取整：`int` / 整数值 `num` / 数值字符串；否则 `null`。
  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) {
      final parsed = value.toDouble();
      if (!parsed.isFinite || parsed != parsed.roundToDouble()) return null;
      return parsed.toInt();
    }
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String _encode(Map<String, Object?> value) => jsonEncode(value);

  static String _refuse(String error, String message, [String? action]) =>
      _encode(<String, Object?>{
        'available': true,
        'ok': false,
        'error': error,
        'message': message,
        if (action != null) 'action': action,
      });

  static String _invalid(String action, String message) =>
      _refuse(PerfControlError.invalidArg, message, action);

  static String _unavailable(String action, String message) =>
      _encode(<String, Object?>{
        'available': false,
        'ok': false,
        'error': PerfControlError.unavailable,
        'message': message,
        'action': action,
      });
}
