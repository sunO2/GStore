/// Wave 4 控制动作 #18：把某个 app / pid **归属**到某个 cpuset（cgroup）。
///
/// 本文件是**单用途**的 cpuset 控制动作：把目标进程的 pid 写入
/// `/dev/cpuset/<cpuset>/tasks`（Android cpuset cgroup 的成员写入口），
/// 从而约束其 CPU / 内存亲和。它**不做**通用 sysfs 写、不做 CPU/GPU/thermal 调优
/// （那些是 todos 16/17/19），也**不建**会话级 revert 注册表（todo 20 负责）。
///
/// ## 协议（与 todo 10/15 一脉相承，fail-closed）
/// 1. **校验**：包名用与 [PrivilegedShell] 相同的 `^[a-zA-Z][a-zA-Z0-9_.]+$`
///    （含危险字符拒绝）；cpuset 名用 `^[a-zA-Z][a-zA-Z0-9_-]*$`（只允许单段、
///    无 `/`、无穿越）。pid 字面量必须是 `> 1` 的整数。
/// 2. **解析 pid**：包名经 `pidof <pkg>`（Shizuku uid 2000）解析，取不到再回退
///    `PerfModule.processes()` 过滤 `name == pkg` / `name` 以 `pkg:` 开头。
///    **解析不到 pid → 结构化 `not_found`，零写入。**
/// 3. **能力门禁**：对目标 `tasks` 节点跑 `test -w`（自限时哨兵）；只有哨兵 `ok=1`
///    才判可写。超时 / 无输出 / 哨兵缺失 / 拒绝 → `unavailable`，**零写入**。
/// 4. **探测 → 写 → 回读**：逐 pid 写 `tasks` 后**回读**该节点确认 pid 已出现；
///    任一步失败 → 回滚已应用项并返回结构化失败。
/// 5. **绝不**触碰系统关键守护进程的 cpuset（见 [kCriticalSystemPackages] / pid≤1）。
///
/// ## 为什么用 `tasks` 而不是自己拼 cpus
/// 归属一个 app 到 cpuset 的语义是「把它的 pid 放进该 cgroup 的成员表」——即写
/// `/dev/cpuset/<name>/tasks`。`cpus` / `mems` 是该 cgroup 的**共享资源掩码**，
/// 本动作不含掩码入参，故只读取（作为回滚原始值记录）不写入。
///
/// ## 超时 ≠ 写入被中止
/// 底层 [PrivilegedShell] 已给**每条**命令加 `timeout <n> sh -c '…'` 自我限时；
/// 但 Dart 侧 `.timeout()` 无法取消原生阻塞进程。超时后本动作按 `unavailable`
/// fail-closed 处理并**不写入**（探测阶段），写入后的回读负责对账。
///
/// ## 可测试性
/// [PrivilegedShell] / [PidResolver] / [PerfModule] 均可注入；测试注入假
/// [CommandRunner] + 假 [PidResolver] 即可完全脱离 Shizuku / 真机 / 原生模块。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

// ==================== 常量 ====================

/// 本动作使用的 sysfs / cpuset 白名单：默认写白名单 + cpuset `tasks` 成员表。
///
/// 默认白名单只有 `/dev/cpuset/*/{cpus,mems}`；归属动作需要写 `tasks`，故在此
/// **显式追加**（`*` 为单段通配，不跨 `/`，因此 `../` 穿越会被拒）。
const List<String> kCpusetControlAllowlist = <String>[
  ...kDefaultSysfsAllowlist,
  '/dev/cpuset/*/tasks',
];

/// 已知 / 常见的 cpuset 名（用于回滚时反查 pid 的原始归属；枚举候选用）。
///
/// Android 常见集合：`root` / `top-app` / `foreground` / `background` /
/// `system-background` / `system` / `restricted`。仅作**只读**扫描候选，
/// 不因为在此列表就假定其存在或可写。
const List<String> kDefaultCpusetNames = <String>[
  'top-app',
  'foreground',
  'background',
  'system-background',
  'restricted',
  'system',
  'root',
];

/// 系统关键守护进程包名——**绝不**改动其 cpuset 归属。
const Set<String> kCriticalSystemPackages = <String>{
  'android',
  'com.android.systemui',
  'com.android.phone',
  'com.android.server.telecom',
  'com.android.bluetooth',
  'com.android.nfc',
  'com.android.providers.telephony',
};

/// 结构化错误码（[CpusetResult.error] 的取值）。
abstract final class CpusetError {
  /// 入参非法（包名 / cpuset 名形状错误，或含危险字符）——零命令执行。
  static const String invalidArg = 'invalid_arg';

  /// 目标是系统关键守护进程 / pid≤1 —— 拒绝且零写入。
  static const String refusedCritical = 'refused_critical';

  /// 无法解析到任何 pid —— 零写入。
  static const String notFound = 'not_found';

  /// 目标 cpuset 的 `tasks` 节点当前不可写（能力未知或拒绝）—— 零写入。
  static const String unavailable = 'unavailable';

  /// 写命令返回失败哨兵（`err=` / 无哨兵 / 超时）。
  static const String writeFailed = 'write_failed';

  /// 写入后回读未确认 pid 出现（已尝试回滚）。
  static const String readbackMismatch = 'readback_mismatch';
}

/// 成功状态码。
const String kCpusetStatusApplied = 'applied';

/// 一次 cpuset 归属动作的结构化结果（**绝不抛出**）。
class CpusetResult {
  const CpusetResult({
    required this.ok,
    required this.status,
    required this.message,
    this.cpuset,
    this.pids = const <int>[],
    this.appliedPids = const <int>[],
    this.nodesTouched = const <String>[],
    this.originals = const <String, String?>{},
    this.originalCpusets = const <int, String?>{},
    this.rolledBack = false,
  });

  /// 是否成功应用。
  final bool ok;

  /// 状态码：成功为 [kCpusetStatusApplied]，否则为 [CpusetError] 之一。
  final String status;

  /// 人类可读说明。
  final String message;

  /// 目标 cpuset 名（解析失败入参时为 `null`）。
  final String? cpuset;

  /// 解析到的目标 pid（解析失败为空）。
  final List<int> pids;

  /// 实际写入并被回读确认的 pid。
  final List<int> appliedPids;

  /// 被本动作**写**过的节点路径（回滚用的归属节点也计入）。
  final List<String> nodesTouched;

  /// 写前各节点的原始内容（`节点 -> 原始文本`），供 todo 20 的 revert 消费。
  final Map<String, String?> originals;

  /// 每个 pid 的原始 cpuset 名（反查失败为 `null`），供 todo 20 的 revert 消费。
  final Map<int, String?> originalCpusets;

  /// 是否发生了回滚。
  final bool rolledBack;

  /// 失败结果工厂（零写入路径复用）。
  factory CpusetResult.failure(
    String status,
    String message, {
    String? cpuset,
    List<int> pids = const <int>[],
    List<String> nodesTouched = const <String>[],
    Map<String, String?> originals = const <String, String?>{},
    Map<int, String?> originalCpusets = const <int, String?>{},
    bool rolledBack = false,
  }) =>
      CpusetResult(
        ok: false,
        status: status,
        message: message,
        cpuset: cpuset,
        pids: pids,
        nodesTouched: nodesTouched,
        originals: originals,
        originalCpusets: originalCpusets,
        rolledBack: rolledBack,
      );

  /// 可序列化摘要（日志 / 证据 / 报告）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'status': status,
        'message': message,
        'cpuset': cpuset,
        'pids': pids,
        'applied_pids': appliedPids,
        'nodes_touched': nodesTouched,
        'originals': originals,
        'original_cpusets': <String, dynamic>{
          for (final entry in originalCpusets.entries)
            '${entry.key}': entry.value,
        },
        'rolled_back': rolledBack,
      };

  @override
  String toString() =>
      'CpusetResult(ok: $ok, status: $status, cpuset: $cpuset, '
      'pids: $pids, applied: $appliedPids, rolledBack: $rolledBack)';
}

/// 解析目标 pid 的函数：入参为**已校验**的包名（或数字 pid 字面量），返回 pid 列表。
typedef PidResolver = Future<List<int>> Function(String pkgOrPid);

// ==================== 控制器 ====================

/// capability-gated 的 cpuset / affinity 控制动作。
///
/// 生产：`CpusetController()`（默认经 [PrivilegedShell] + [PerfModule.instance]）。
/// 测试：注入假 [PrivilegedShell]（假 [CommandRunner]）+ 假 [PidResolver]，
/// **无需 Shizuku / 真机 / 原生模块**。
class CpusetController {
  CpusetController({
    PrivilegedShell? shell,
    PerfModule? perfModule,
    PidResolver? pidResolver,
    PrivilegedInputValidator? validator,
    List<String> cpusetNames = kDefaultCpusetNames,
  })  : _shell = shell ?? PrivilegedShell(),
        _perfModule = perfModule ?? PerfModule.instance,
        _pidResolverOverride = pidResolver,
        _validator = validator ??
            PrivilegedInputValidator(sysfsPatterns: kCpusetControlAllowlist),
        _cpusetNames = List<String>.unmodifiable(cpusetNames);

  final PrivilegedShell _shell;
  final PerfModule _perfModule;
  final PidResolver? _pidResolverOverride;
  final PrivilegedInputValidator _validator;

  /// 回滚反查 pid 原始归属时的候选 cpuset 名（只读扫描）。
  final List<String> _cpusetNames;

  /// cpuset 名允许形状：单段、字母开头、允许 `-` / `_` / 数字，**禁止** `/` 与危险字符。
  static final RegExp cpusetNamePattern =
      RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$');

  /// 纯数字 = pid 字面量。
  static final RegExp _pidLiteralPattern = RegExp(r'^[0-9]+$');

  // ==================== 公共入口 ====================

  /// 把 [pkgOrPid] 归属到名为 [cpuset] 的 cgroup（写其 `tasks` 成员表）。
  ///
  /// [pkgOrPid]：合法包名（如 `com.example.app`）或纯数字 pid 字面量。
  /// [cpuset]：cpuset 名（如 `top-app` / `foreground` / `background`）。
  ///
  /// **绝不抛出**：所有失败都返回结构化 [CpusetResult]。
  /// 成功 = 解析到 pid + `tasks` 可写 + 每个 pid 写入且**回读确认**。
  Future<CpusetResult> applyCpuset({
    required String pkgOrPid,
    required String cpuset,
  }) async {
    // ---- 1. 校验 cpuset 名 + 目标节点白名单 ----
    final cpusetReason = _cpusetNameReason(cpuset);
    if (cpusetReason != null) {
      return CpusetResult.failure(
        CpusetError.invalidArg,
        '非法 cpuset 名（$cpusetReason）',
      );
    }
    final tasksNode = '/dev/cpuset/$cpuset/tasks';
    final cpusNode = '/dev/cpuset/$cpuset/cpus';
    if (_validator.sysfsPathReason(tasksNode) != null) {
      return CpusetResult.failure(
        CpusetError.invalidArg,
        'cpuset 节点不在白名单: $tasksNode',
        cpuset: cpuset,
      );
    }

    // ---- 2. 解析目标 pid（零写入的安全边界） ----
    final _TargetResolution target;
    try {
      target = await _resolveTarget(pkgOrPid, cpuset);
    } catch (error) {
      debugPrint('[CpusetController] 解析 pid 失败: $error');
      return CpusetResult.failure(
        CpusetError.notFound,
        '解析 pid 失败：$error',
        cpuset: cpuset,
      );
    }
    switch (target) {
      case _InvalidTarget(:final reason):
        return CpusetResult.failure(CpusetError.invalidArg, reason);
      case _RefusedTarget(:final reason):
        return CpusetResult.failure(
          CpusetError.refusedCritical,
          reason,
          cpuset: cpuset,
        );
      case _ResolvedTarget():
        break;
    }
    // 上面的 switch 已排除非法 / 拒绝分支（均 return），此处 target 已窄化为
    // _ResolvedTarget（Dart 模式 switch 对 final 局部变量的流分析提升）。
    final resolved = target;
    if (resolved.pids.isEmpty) {
      return CpusetResult.failure(
        CpusetError.notFound,
        '未找到匹配 pid：$pkgOrPid',
        cpuset: cpuset,
      );
    }

    // ---- 3. 能力门禁：tasks 节点必须可写（fail-closed） ----
    if (!await _isWritable(tasksNode)) {
      return CpusetResult.failure(
        CpusetError.unavailable,
        'cpuset 不可写或能力未知：$tasksNode',
        cpuset: cpuset,
        pids: resolved.pids,
      );
    }

    // ---- 4. 记录原始值（供 todo 20 revert；本层不建注册表） ----
    final originals = <String, String?>{
      cpusNode: _stripSentinel(await _readNode(cpusNode) ?? ''),
      tasksNode: _stripSentinel(await _readNode(tasksNode) ?? ''),
    };

    // ---- 5. 逐 pid 探测（反查原归属）→ 写 → 回读 ----
    final nodesTouched = <String>[];
    final originalCpusets = <int, String?>{};
    final applied = <int>[];
    for (final pid in resolved.pids) {
      originalCpusets[pid] = await _findOriginalCpuset(pid, cpuset);

      final write = await _shell.run(
        _shell.buildWriteCommand(path: tasksNode, value: '$pid'),
      );
      if (!write.ok) {
        nodesTouched.add(tasksNode);
        final rolledBack = await _rollback(
          applied,
          originalCpusets,
          cpuset,
          nodesTouched,
        );
        return CpusetResult.failure(
          CpusetError.writeFailed,
          '写入 tasks 失败（${write.error ?? 'unknown'}）：$tasksNode',
          cpuset: cpuset,
          pids: resolved.pids,
          nodesTouched: nodesTouched,
          originals: originals,
          originalCpusets: originalCpusets,
          rolledBack: rolledBack,
        );
      }
      if (!nodesTouched.contains(tasksNode)) nodesTouched.add(tasksNode);

      final back = await _readNode(tasksNode);
      final present = back != null && _parsePids(back).contains(pid);
      if (!present) {
        // 回读未确认：把「本次已写入的 pid」连同此前已应用项一起回滚。
        final rolledBack = await _rollback(
          <int>[...applied, pid],
          originalCpusets,
          cpuset,
          nodesTouched,
        );
        return CpusetResult.failure(
          CpusetError.readbackMismatch,
          '写入后回读未确认 pid $pid（已回滚）',
          cpuset: cpuset,
          pids: resolved.pids,
          nodesTouched: nodesTouched,
          originals: originals,
          originalCpusets: originalCpusets,
          rolledBack: rolledBack,
        );
      }
      applied.add(pid);
    }

    return CpusetResult(
      ok: true,
      status: kCpusetStatusApplied,
      message: '已归属 ${applied.length} 个 pid 到 cpuset $cpuset',
      cpuset: cpuset,
      pids: resolved.pids,
      appliedPids: List<int>.unmodifiable(applied),
      nodesTouched: List<String>.unmodifiable(nodesTouched),
      originals: Map<String, String?>.unmodifiable(originals),
      originalCpusets: Map<int, String?>.unmodifiable(originalCpusets),
    );
  }

  // ==================== 入参 / 目标解析 ====================

  /// cpuset 名校验：通过返回 `null`，否则返回原因。
  String? _cpusetNameReason(String name) {
    if (name.isEmpty) return 'empty';
    if (PrivilegedInputValidator.hasUnsafeChar(name)) return 'unsafe_char';
    if (name.contains('/') || name.contains('..')) return 'path_segment';
    if (!cpusetNamePattern.hasMatch(name)) return 'bad_shape';
    return null;
  }

  /// 解析目标 pid；区分「非法 / 拒绝(关键) / 已解析」。
  Future<_TargetResolution> _resolveTarget(
    String pkgOrPid,
    String cpuset,
  ) async {
    // 数字字面量 → pid。
    if (_pidLiteralPattern.hasMatch(pkgOrPid)) {
      final numericReason = _validator.numericReason(pkgOrPid);
      if (numericReason != null) {
        return _InvalidTarget('非法 pid（$numericReason）');
      }
      final pid = int.parse(pkgOrPid);
      if (pid <= 1) {
        return const _RefusedTarget('拒绝：pid ≤ 1 属于内核 / init');
      }
      return _ResolvedTarget(<int>[pid]);
    }

    // 包名。
    final packageReason = _validator.packageReason(pkgOrPid);
    if (packageReason != null) {
      return _InvalidTarget('非法包名（$packageReason）');
    }
    if (kCriticalSystemPackages.contains(pkgOrPid)) {
      return _RefusedTarget('拒绝：系统关键守护进程 $pkgOrPid 不可改 cpuset');
    }

    final pids = await _resolvePids(pkgOrPid);
    if (pids.any((pid) => pid <= 1)) {
      return const _RefusedTarget('拒绝：解析到 pid ≤ 1（内核 / init）');
    }
    return _ResolvedTarget(pids);
  }

  /// 解析包名对应的 pid：`pidof` 优先，取不到回退 `PerfModule.processes()`。
  ///
  /// [pkg] 必须**已通过** [PrivilegedInputValidator.packageReason]；
  /// 因此将其直接拼进 `pidof` 命令体是安全的（无危险字符 / 无插值逃逸）。
  Future<List<int>> _resolvePids(String pkg) async {
    final override = _pidResolverOverride;
    if (override != null) return _dedupeSorted(await override(pkg));

    final pids = <int>{};
    final pidof = await _shell.run(_shell.buildCommand('pidof $pkg'));
    if (pidof.ok) pids.addAll(_parsePids(pidof.output));

    if (pids.isEmpty) {
      try {
        final report = await _perfModule.processes(limit: 100);
        for (final proc in report.processes) {
          if (proc.pid > 1 &&
              (proc.name == pkg || proc.name.startsWith('$pkg:'))) {
            pids.add(proc.pid);
          }
        }
      } catch (error) {
        debugPrint('[CpusetController] PerfModule.processes 回退失败: $error');
      }
    }
    return _dedupeSorted(pids);
  }

  static List<int> _dedupeSorted(Iterable<int> pids) {
    final set = <int>{};
    for (final pid in pids) {
      if (pid > 1) set.add(pid);
    }
    return set.toList()..sort();
  }

  /// 从命令输出解析 pid（忽略哨兵行与非数字 token）。
  static Set<int> _parsePids(String raw) {
    final pids = <int>{};
    for (final line in raw.split('\n')) {
      for (final token in line.trim().split(RegExp(r'\s+'))) {
        final value = int.tryParse(token);
        if (value != null && value > 1) pids.add(value);
      }
    }
    return pids;
  }

  // ==================== 节点原语（全部经自限时哨兵命令） ====================

  /// `test -w <path>`：哨兵 `ok=1` 才判可写；其余（含超时 / 无输出）一律不可写。
  Future<bool> _isWritable(String path) async {
    if (_validator.sysfsPathReason(path) != null) return false;
    final result = await _shell.run(_shell.buildCommand('test -w $path'));
    return result.ok;
  }

  /// 读取节点：成功返回原始文本（含哨兵），否则 `null`。路径先过白名单。
  Future<String?> _readNode(String path) async {
    if (_validator.sysfsPathReason(path) != null) return null;
    final result = await _shell.run(_shell.buildCommand('cat $path'));
    return result.ok ? result.output : null;
  }

  /// 反查 pid 当前所属 cpuset（只读扫描候选名；找不到返回 `null`）。
  Future<String?> _findOriginalCpuset(int pid, String targetCpuset) async {
    for (final name in _cpusetNames) {
      if (name == targetCpuset) continue;
      final path = '/dev/cpuset/$name/tasks';
      if (_validator.sysfsPathReason(path) != null) continue;
      final content = await _readNode(path);
      if (content == null) continue;
      if (_parsePids(content).contains(pid)) return name;
    }
    return null;
  }

  /// 回滚已应用的 pid：把它们写回各自记录的原始 cpuset（未知则跳过）。
  ///
  /// 返回是否**至少**发生了一次成功的回写。
  Future<bool> _rollback(
    List<int> applied,
    Map<int, String?> originalCpusets,
    String targetCpuset,
    List<String> nodesTouched,
  ) async {
    var rolled = false;
    for (final pid in applied.reversed) {
      final original = originalCpusets[pid];
      if (original == null || original == targetCpuset) continue;
      final path = '/dev/cpuset/$original/tasks';
      if (_validator.sysfsPathReason(path) != null) continue;
      final result = await _shell.run(
        _shell.buildWriteCommand(path: path, value: '$pid'),
      );
      if (!nodesTouched.contains(path)) nodesTouched.add(path);
      rolled = rolled || result.ok;
    }
    return rolled;
  }

  /// 去掉哨兵行并裁剪首尾空白（把命令输出还原为「节点内容」）。
  static String _stripSentinel(String raw) {
    final buffer = StringBuffer();
    for (final line in raw.split('\n')) {
      if (line.contains(kGstoreSentinel)) continue;
      buffer.writeln(line);
    }
    return buffer.toString().trim();
  }
}

// ==================== 私有解析结果 ====================

/// [_resolveTarget] 的三态结果。
sealed class _TargetResolution {
  const _TargetResolution();
}

/// 入参非法。
class _InvalidTarget extends _TargetResolution {
  const _InvalidTarget(this.reason);
  final String reason;
}

/// 目标为关键守护进程 / pid≤1，拒绝。
class _RefusedTarget extends _TargetResolution {
  const _RefusedTarget(this.reason);
  final String reason;
}

/// 已解析到 pids（可能为空 → not_found）。
class _ResolvedTarget extends _TargetResolution {
  const _ResolvedTarget(this.pids);
  final List<int> pids;
}
