/// Wave 4 CPU 控制动作：governor + 每策略簇 min/max 频率（**经 Shizuku shell，无 root**）。
///
/// 本层是 todo 10（[PrivilegedShell] 传输层）之上的**第一个真正写节点的动作层**，
/// 严格遵守计划（`.omo/plans/scene-perf-reverse-gstore.md` todo 16）的协议：
///
/// ```text
/// 校验（perf.tunables，写前，绝不写非法值）
///   → 能力门禁（todo 15 fail-closed 探测器；未知/不可写 → 零写入）
///   → 记录写前值（回滚 / todo 20 revert 用）
///   → 写（echo/printf 经 PrivilegedShell，自限时 + `&&`/`||` 哨兵）
///   → 回读确认（PerfModule.readSysfs；非 world-readable 经特权 shell 对账）
///   → 不匹配 / 被拒 → 结构化失败 + 回滚到写前值（不留部分状态）
/// ```
///
/// ## 不可协商的约束（照抄 todo 16 的 Must NOT do）
/// * **绝不**在能力未知 / 类别不可用时写入（fail-closed）。
/// * **绝不**写非法值（governor 不在 `scaling_available_governors`、
///   频率不在 available 列表、min > max）—— 校验在任何命令之前完成。
/// * **绝不**留下部分状态：任一写入被拒 / 回读不匹配，立即把**已写入**的节点
///   回滚到记录的写前值。
/// * 写而不回读**不算成功**（哨兵 `ok=1` 只是命令链成功，不是节点值生效）。
///
/// ## 回读上下文注意（todo 12 文档）
/// `perf.sysfs.read` 以 **App 进程 uid** 读取；Shizuku（uid 2000）写入的
/// 非 world-readable 节点，App uid 可能读不到。因此 [CpuControl] 的回读优先走
/// [PerfSysfsReader]，不可用时（`exists:false`）**回落到特权 shell 的 `cat`**，
/// 保证「写侧 uid = 读侧 uid」。
///
/// ## 供 todo 20 / 24 / 28 消费的公开 API
/// * [CpuControl.applyCpuPolicy]：执行一次 CPU 策略应用，返回 [CpuPolicyResult]。
/// * [CpuPolicyResult.applied]：成功时保留的覆盖项（`path` / `before` / `after`），
///   **todo 20 的会话 revert 注册表据此还原**。
/// * [CpuPolicyResult.rollback]：失败时实际执行的回滚写（证据）。
/// * [CpuPolicyStatus]：稳定状态码（`ok` / `invalid_arg` / `unavailable` /
///   `write_denied` / `readback_mismatch` / `pre_read_failed` / `not_found`）。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// `perf.sysfs.read` 读取函数（生产为模块门面；测试注入罐头结果）。
typedef PerfSysfsReader = Future<SysfsReadResult> Function(String path);

/// [CpuPolicyResult.status] 的稳定取值（供日志 / 报告 / 测试断言）。
abstract final class CpuPolicyStatus {
  /// 全部请求的写入均已生效且回读确认。
  static const String ok = 'ok';

  /// 输入非法（未知簇之外的非法 governor / 频率 / min>max / 无任何变更）——
  /// **零写入**。
  static const String invalidArg = 'invalid_arg';

  /// 能力未知（未探测）或 CPU 类别 / 目标节点不可用 —— **零写入**（fail-closed）。
  static const String unavailable = 'unavailable';

  /// 目标策略簇不在 `perf.tunables` 中 —— **零写入**。
  static const String notFound = 'not_found';

  /// 写前值无法确定（既读不到也拿不到 tunables 基线）—— **零写入**（无法安全回滚）。
  static const String preReadFailed = 'pre_read_failed';

  /// 写入被拒（哨兵 `err=` / 无哨兵 / 超时 / 无输出）—— 已回滚。
  static const String writeDenied = 'write_denied';

  /// 写入「成功」但回读值不匹配 —— 已回滚（**写而不回读不算成功**）。
  static const String readbackMismatch = 'readback_mismatch';
}

/// 一次节点变更记录（覆盖项 / 回滚项共用）。
///
/// * 覆盖项（[CpuPolicyResult.applied]）：[before] = 写前值，[after] = 写入值；
/// * 回滚项（[CpuPolicyResult.rollback]）：[before] = 已写入值，
///   [after] = 恢复到的写前值；[ok] = 回滚写是否成功。
class CpuPolicyChange {
  const CpuPolicyChange({
    required this.path,
    required this.before,
    required this.after,
    this.ok = true,
  });

  /// 节点绝对路径。
  final String path;

  /// 变更前 / 回滚前（该次操作开始时）的值。
  final String? before;

  /// 变更后 / 回滚目标值。
  final String after;

  /// 该次写入是否成功（仅回滚项有意义；覆盖项恒 `true`）。
  final bool ok;

  /// 序列化（证据 / 报告）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'before': before,
        'after': after,
        'ok': ok,
      };

  @override
  String toString() => 'CpuPolicyChange($path: $before -> $after'
      '${ok ? '' : ' [FAILED]'})';
}

/// 一次 [CpuControl.applyCpuPolicy] 的结构化结果（**绝不抛出**）。
class CpuPolicyResult {
  const CpuPolicyResult({
    required this.ok,
    required this.status,
    this.message,
    this.cluster,
    this.applied = const <CpuPolicyChange>[],
    this.rollback = const <CpuPolicyChange>[],
    this.rolledBack = false,
  });

  /// 是否成功（全部请求已生效且回读确认）。
  final bool ok;

  /// 稳定状态码（见 [CpuPolicyStatus]）。
  final String status;

  /// 人类可读说明（失败原因 / 摘要）。
  final String? message;

  /// 作用的策略簇（`policy0` …）；未解析到时为 `null`。
  final String? cluster;

  /// 成功时保留的覆盖项（含写前值）—— **todo 20 revert 输入**。
  final List<CpuPolicyChange> applied;

  /// 失败时实际执行的回滚写（证据；成功时为空）。
  final List<CpuPolicyChange> rollback;

  /// 是否所有回滚写均成功（回滚为空时为 `false`）。
  final bool rolledBack;

  /// 序列化（证据 / 报告）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'status': status,
        if (message != null) 'message': message,
        if (cluster != null) 'cluster': cluster,
        'applied': applied.map((c) => c.toJson()).toList(growable: false),
        'rollback': rollback.map((c) => c.toJson()).toList(growable: false),
        'rolled_back': rolledBack,
      };

  /// 人类可读多行摘要（证据用）。
  String describe() {
    final buffer = StringBuffer()
      ..writeln('ok=$ok status=$status'
          '${cluster == null ? '' : ' cluster=$cluster'}')
      ..writeln('message=${message ?? '-'}');
    buffer.writeln('applied=${applied.length}:');
    for (final change in applied) {
      buffer.writeln('  ${change.path}: ${change.before} -> ${change.after}');
    }
    buffer.writeln('rollback=${rollback.length} rolled_back=$rolledBack:');
    for (final change in rollback) {
      buffer.writeln(
          '  ${change.path}: ${change.before} -> ${change.after}'
          '${change.ok ? '' : ' [FAILED]'}');
    }
    return buffer.toString();
  }

  @override
  String toString() => 'CpuPolicyResult(ok: $ok, status: $status, '
      'applied: ${applied.length}, rollback: ${rollback.length})';
}

/// 计划中的一次写入。
class _PlannedWrite {
  const _PlannedWrite({
    required this.path,
    required this.value,
    required this.numeric,
  });

  final String path;
  final String value;
  final bool numeric;
}

/// CPU 策略控制器（govnernor / 每簇 min/max 频率）。
///
/// 生产：`CpuControl(shell: PrivilegedShell(), tunables: <perf.tunables>,
/// capabilities: <todo 15 probe result>)`。
/// 测试：注入假的 [PrivilegedShell] [CommandRunner]、罐头 [TunablesReport] /
/// [PerfControlCapabilities] / [PerfSysfsReader]，**无需 Shizuku / 真机 / 原生模块**。
class CpuControl {
  CpuControl({
    required PrivilegedShell shell,
    required TunablesReport tunables,
    PerfControlCapabilities? capabilities,
    PerfSysfsReader? sysfsReader,
  })  : _shell = shell,
        _tunables = tunables,
        _capabilities = capabilities,
        _sysfsReader = sysfsReader ?? _defaultSysfsReader;

  static Future<SysfsReadResult> _defaultSysfsReader(String path) =>
      PerfModule.instance.readSysfs(path);

  final PrivilegedShell _shell;
  final TunablesReport _tunables;

  /// todo 15 的能力快照；`null`（未探测）→ 一律 `unavailable`（fail-closed）。
  final PerfControlCapabilities? _capabilities;

  final PerfSysfsReader _sysfsReader;

  /// cpufreq 策略簇基目录。
  static const String _cpufreqBase = '/sys/devices/system/cpu/cpufreq';

  /// 应用一次 CPU 策略。
  ///
  /// [cluster] 是策略目录名（如 `policy0`），必须在 [CpuControl] 构造时的
  /// `perf.tunables` 中存在。[governor] / [minFreqMhz] / [maxFreqMhz] 三者至少
  /// 提供一个；频率单位 MHz（内部转 kHz 写入 `scaling_{min,max}_freq`）。
  ///
  /// 校验在任何命令之前完成；任一非法 / 不可用 / 无变更 → 零写入的结构化结果。
  /// **绝不抛出**。
  Future<CpuPolicyResult> applyCpuPolicy({
    required String cluster,
    String? governor,
    double? minFreqMhz,
    double? maxFreqMhz,
  }) async {
    if (governor == null && minFreqMhz == null && maxFreqMhz == null) {
      return _fail(
        CpuPolicyStatus.invalidArg,
        'no changes requested (governor/minFreq/maxFreq all null)',
      );
    }

    final target = _findCluster(cluster);
    if (target == null) {
      return _fail(
        CpuPolicyStatus.notFound,
        'cluster not found in perf.tunables: $cluster',
        cluster: cluster,
      );
    }
    final policy = target.policy;
    final base = '$_cpufreqBase/$policy';

    // ---- 1. 写前校验（零命令） ----
    final planned = <_PlannedWrite>[];

    if (governor != null) {
      if (!target.availableGovernors.contains(governor)) {
        return _fail(
          CpuPolicyStatus.invalidArg,
          'governor "$governor" not in scaling_available_governors '
              '${target.availableGovernors}',
          cluster: policy,
        );
      }
      planned.add(_PlannedWrite(
        path: '$base/scaling_governor',
        value: governor,
        numeric: false,
      ));
    }

    final effectiveMin = minFreqMhz ?? target.minFreqMhz;
    final effectiveMax = maxFreqMhz ?? target.maxFreqMhz;
    if (effectiveMin != null &&
        effectiveMax != null &&
        effectiveMin > effectiveMax + 1e-9) {
      return _fail(
        CpuPolicyStatus.invalidArg,
        'minFreq ($effectiveMin MHz) > maxFreq ($effectiveMax MHz)',
        cluster: policy,
      );
    }

    if (minFreqMhz != null) {
      if (!_isAvailableFrequency(target, minFreqMhz)) {
        return _fail(
          CpuPolicyStatus.invalidArg,
          'minFreq $minFreqMhz MHz not in available_frequencies_mhz '
              '${target.availableFrequenciesMhz}',
          cluster: policy,
        );
      }
      planned.add(_PlannedWrite(
        path: '$base/scaling_min_freq',
        value: _mhzToKhzString(minFreqMhz),
        numeric: true,
      ));
    }

    if (maxFreqMhz != null) {
      if (!_isAvailableFrequency(target, maxFreqMhz)) {
        return _fail(
          CpuPolicyStatus.invalidArg,
          'maxFreq $maxFreqMhz MHz not in available_frequencies_mhz '
              '${target.availableFrequenciesMhz}',
          cluster: policy,
        );
      }
      planned.add(_PlannedWrite(
        path: '$base/scaling_max_freq',
        value: _mhzToKhzString(maxFreqMhz),
        numeric: true,
      ));
    }

    // ---- 2. 能力门禁（fail-closed；零命令） ----
    final capabilities = _capabilities;
    if (capabilities == null) {
      return _fail(
        CpuPolicyStatus.unavailable,
        'control capabilities unknown (probe not run) — refusing to write',
        cluster: policy,
      );
    }
    if (!capabilities.isCategoryAvailable(PerfControlCategory.cpu)) {
      return _fail(
        CpuPolicyStatus.unavailable,
        'cpu category unavailable on this device/shell (probe)',
        cluster: policy,
      );
    }
    for (final write in planned) {
      if (!capabilities.isNodeAvailable(write.path)) {
        return _fail(
          CpuPolicyStatus.unavailable,
          'node not writable per probe: ${write.path}',
          cluster: policy,
        );
      }
    }

    // ---- 3. 记录写前值 → 写 → 回读确认 → 失败回滚 ----
    final applied = <CpuPolicyChange>[];
    for (final write in planned) {
      final before = await _readNode(write.path) ??
          _tunablesPreValue(target, write.path);
      if (before == null) {
        final rollback = await _rollback(applied);
        return _fail(
          CpuPolicyStatus.preReadFailed,
          'cannot determine pre-write value of ${write.path}; '
              'no write attempted',
          cluster: policy,
          rollback: rollback,
        );
      }

      final writeResult = await _shell.write(
        path: write.path,
        value: write.value,
        numeric: write.numeric,
      );
      final change = CpuPolicyChange(
        path: write.path,
        before: before,
        after: write.value,
      );
      if (!writeResult.ok) {
        // 被拒（err= / 无哨兵 / 超时 / 无输出）→ **本次未生效**，只回滚已生效的写入。
        final rollback = await _rollback(applied);
        return _fail(
          CpuPolicyStatus.writeDenied,
          'write denied for ${write.path} '
              '(error=${writeResult.error}, exitHint=${writeResult.exitHint})',
          cluster: policy,
          rollback: rollback,
        );
      }

      final readBack = await _readNode(write.path);
      if (!_matches(write, readBack)) {
        // 「写成功」但值未生效 → 回读不匹配 → 连同本次一起回滚。
        final rollback = await _rollback(<CpuPolicyChange>[...applied, change]);
        return _fail(
          CpuPolicyStatus.readbackMismatch,
          'read-back mismatch for ${write.path}: '
              'expected "${write.value}", got "${readBack ?? '<null>'}"',
          cluster: policy,
          rollback: rollback,
        );
      }
      applied.add(change);
    }

    return CpuPolicyResult(
      ok: true,
      status: CpuPolicyStatus.ok,
      cluster: policy,
      message: 'applied ${applied.length} change(s) with read-back confirmation',
      applied: List<CpuPolicyChange>.unmodifiable(applied),
    );
  }

  // ==================== 校验辅助 ====================

  PerfCpuCluster? _findCluster(String cluster) {
    for (final candidate in _tunables.cpuClusters) {
      if (candidate.policy == cluster) return candidate;
    }
    return null;
  }

  static bool _isAvailableFrequency(PerfCpuCluster cluster, double mhz) =>
      cluster.availableFrequenciesMhz.any((f) => (f - mhz).abs() < 1e-6);

  /// MHz → kHz 整数字符串（sysfs `scaling_{min,max}_freq` 单位为 kHz）。
  static String _mhzToKhzString(double mhz) => (mhz * 1000).round().toString();

  /// tunables 提供的写前基线（sysfs 读不到时的回退）。
  static String? _tunablesPreValue(PerfCpuCluster cluster, String path) {
    if (path.endsWith('/scaling_governor')) return cluster.governor;
    if (path.endsWith('/scaling_min_freq')) {
      final value = cluster.minFreqMhz;
      return value == null ? null : _mhzToKhzString(value);
    }
    if (path.endsWith('/scaling_max_freq')) {
      final value = cluster.maxFreqMhz;
      return value == null ? null : _mhzToKhzString(value);
    }
    return null;
  }

  static bool _matches(_PlannedWrite write, String? readBack) {
    if (readBack == null) return false;
    final actual = readBack.trim();
    if (!write.numeric) return actual == write.value;
    final a = int.tryParse(actual);
    final b = int.tryParse(write.value);
    return a != null && b != null && a == b;
  }

  // ==================== 读 / 写原语 ====================

  /// 读取节点当前值：优先 App uid 的 `perf.sysfs.read`，不可用则经特权 shell
  /// `cat`（保证「写侧 uid = 读侧 uid」对账）。任一失败返回 `null`（未知）。
  Future<String?> _readNode(String path) async {
    try {
      final result = await _sysfsReader(path);
      final value = result.value?.trim();
      if (result.exists && value != null && value.isNotEmpty) return value;
    } catch (error) {
      debugPrint('[CpuControl] perf.sysfs.read 失败（回落特权 shell）：$path - $error');
    }
    final fallback = await _shell.read(path: path);
    if (!fallback.ok) return null;
    return _extractReadValue(fallback.output);
  }

  /// 从 `cat <node>` 的合并输出中取节点值：丢弃哨兵行，取首个非空行。
  static String? _extractReadValue(String output) {
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.contains(kGstoreSentinel)) continue;
      return trimmed;
    }
    return null;
  }

  /// 回滚一组变更（逆序写回 [CpuPolicyChange.before]），返回实际回滚写记录。
  Future<List<CpuPolicyChange>> _rollback(
    List<CpuPolicyChange> changes,
  ) async {
    final performed = <CpuPolicyChange>[];
    for (final change in changes.reversed) {
      final restore = change.before;
      if (restore == null) continue;
      final numeric = !change.path.endsWith('/scaling_governor');
      final result = await _shell.write(
        path: change.path,
        value: restore,
        numeric: numeric,
      );
      performed.add(CpuPolicyChange(
        path: change.path,
        before: change.after,
        after: restore,
        ok: result.ok,
      ));
    }
    return List<CpuPolicyChange>.unmodifiable(performed);
  }

  CpuPolicyResult _fail(
    String status,
    String message, {
    String? cluster,
    List<CpuPolicyChange> applied = const <CpuPolicyChange>[],
    List<CpuPolicyChange> rollback = const <CpuPolicyChange>[],
  }) {
    final rolledBack =
        rollback.isNotEmpty && rollback.every((change) => change.ok);
    return CpuPolicyResult(
      ok: false,
      status: status,
      message: message,
      cluster: cluster,
      applied: List<CpuPolicyChange>.unmodifiable(applied),
      rollback: List<CpuPolicyChange>.unmodifiable(rollback),
      rolledBack: rolledBack,
    );
  }
}
