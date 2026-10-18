/// 每应用性能档案的**自动应用引擎**（todo 24）。
///
/// 消费 todo 23 的 [ForegroundWatcher] 事件（这里只接收「前台包名」字符串，
/// 保持解耦）、todo 22 的 [PerfProfile] / [PerfProfileStore]、todo 20 的
/// [PerfControlSession]，以及 todos 16-19 的四个控制动作，实现：
///
/// ```text
/// 前台进入包 P
///   → 全局开关开？能力已探测（非 unknown）？
///   → 从 store 取 P 的档案且 enabled？非空？
///   → 逐个动作应用（CPU 各簇 → GPU → cpuset → thermal），
///     每个成功的动作结果经会话登记（记录原值）
///   → 任一动作失败 → 会话 revertAll（回滚已应用的部分，绝不半应用）
///
/// 前台离开包 P（package == null）/ 全局关闭 / 档案被禁用或删除
///   → 会话 revertAll（精确写回原值）
/// ```
///
/// ## 不可协商的约束
/// * **FAIL-CLOSED**：能力为 `unknown`（探测结果为 `null`）时**绝不**应用新档案；
///   全局开关关闭时同样**绝不**应用。
/// * **绝不半应用**：跨动作的部分失败会把本次已登记的成功覆盖项**全部回滚**
///   （经会话 `revertAll`），并返回 `ok:false`。
/// * **幂等**：同一档案重复「进入」为 no-op（不重复写、不重复登记）；重复
///   「离开」为 no-op（会话无待还原项时 `revertAll` 零命令）。
/// * **去抖（debounce）**：快速 A→B→A 切换在去抖窗口内**合并**为最后一次
///   （最终态 = A 的档案），避免中间态抖动。
/// * **串行**：所有 reconcile 经内部串行队列执行；切换期间到来的新事件会
///   在本次完成后立刻按**最新**目标重新收敛（cancel/resume 不丢事件）。
///
/// ## 归属与单会话假设（风险）
/// 还原经 [PerfControlSession.revertAll]，它**只**遍历会话自己的登记表。本引擎
/// 假定该会话为「自动应用」这一消费者独占（与 todo 20 的「全 App 单会话」假设
/// 一致）；若手动控制（todo 28）与自动应用共用同一会话，`revertAll` 会一并还原。
/// 该接线风险由 todo 30 在装配时保证。
///
/// ## thermal 的确认语义
/// 档案里的 `thermalEnabled` 是用户在档案编辑器（todo 25）中**显式配置**、
/// 并经全局开关（todo 26）授权的意图；自动应用不弹交互确认，因此动作层按
/// 「已授权」传入 `confirmed: true`。`enabled=true` 为安全方向（保持/恢复降温），
/// `enabled=false` 才是危险方向。编辑器需在写入 `thermalEnabled` 时向用户明示。
///
/// ## 可测试性
/// store / 会话 / 四个控制动作 / `perf.tunables` / 能力提供者 / 全局开关 /
/// 去抖时长**全部可注入**；测试注入假 [CommandRunner] 构造的 [PrivilegedShell]、
/// [InMemoryPerfProfileStore]、[InMemoryPerfControlSessionStore]，**无需
/// Shizuku / 真机 / 原生模块 / SharedPreferences 平台通道**。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/perf/control_cpu.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/control_thermal.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/perf_control_session.dart';
import 'package:gstore/core/perf/perf_profile.dart';
import 'package:gstore/core/perf/perf_profile_store.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

// ==================== 结果模型 ====================

/// 一次 reconcile 的**结果类别**。
abstract final class PerfAutoApplyOutcome {
  /// 成功应用了某个档案（可能包含 0 个节点）。
  static const String applied = 'applied';

  /// 成功还原了当前档案。
  static const String reverted = 'reverted';

  /// 无需变更（幂等 / 无前台 / 档案缺失或禁用 / 全局关闭）。
  static const String noop = 'noop';

  /// 因门禁（能力未知）主动跳过，**零写入**。
  static const String skipped = 'skipped';

  /// 应用失败（部分失败已回滚 / 还原失败）。
  static const String failed = 'failed';

  /// 被更新的事件取代（去抖窗口内），未执行。
  static const String superseded = 'superseded';
}

/// 结果**原因码**（稳定、可断言）。
abstract final class PerfAutoApplyReason {
  /// 成功应用。
  static const String applied = 'applied';

  /// 全局开关关闭。
  static const String globalDisabled = 'global_disabled';

  /// 当前无前台包（离开前台 / 无法判定）。
  static const String noForeground = 'no_foreground';

  /// 目标包无档案。
  static const String profileMissing = 'profile_missing';

  /// 目标包档案未启用（fail-closed）。
  static const String profileDisabled = 'profile_disabled';

  /// 同一档案已应用且未变更（幂等）。
  static const String unchanged = 'unchanged';

  /// 能力未知（探测未运行）→ 拒绝应用（fail-closed）。
  static const String capabilityUnknown = 'capability_unknown';

  /// 跨动作部分失败（已回滚）。
  static const String partialFailure = 'partial_failure';

  /// 还原失败（会话保留待重试）。
  static const String revertFailed = 'revert_failed';

  /// 被更新的事件取代。
  static const String superseded = 'superseded';

  /// 引擎已释放。
  static const String disposed = 'disposed';

  /// 未预期异常（已降级）。
  static const String exception = 'exception';
}

/// 会话还原的原因码（写入 [PerfRevertReport.reason]）。
abstract final class PerfAutoApplyRevertReason {
  /// 前台离开。
  static const String leave = 'profile_leave';

  /// 全局开关关闭。
  static const String globalDisabled = 'profile_global_disabled';

  /// 档案被禁用 / 删除。
  static const String profileDisabled = 'profile_disabled';

  /// 切换到另一个档案前的还原。
  static const String switchProfile = 'profile_switch';

  /// 部分失败后的回滚。
  static const String partialFailure = 'profile_partial_failure';
}

/// 一次 reconcile 的结构化报告（**绝不抛出**）。
class PerfAutoApplyReport {
  const PerfAutoApplyReport({
    required this.outcome,
    required this.reason,
    this.package,
    this.appliedOverrides = 0,
    this.revertedOverrides = 0,
    this.revertRemaining = 0,
    this.failedStage,
    this.error,
  });

  /// 结果类别（见 [PerfAutoApplyOutcome]）。
  final String outcome;

  /// 原因码（见 [PerfAutoApplyReason]）。
  final String reason;

  /// 本次涉及的包（进入 / 离开的包；缺失档案时为请求的包）。
  final String? package;

  /// 本次成功登记的覆盖项数（`applied` 时有意义）。
  final int appliedOverrides;

  /// 本次成功还原的覆盖项数。
  final int revertedOverrides;

  /// 还原后仍保留（失败待重试）的覆盖项数。
  final int revertRemaining;

  /// 部分失败时失败的动作（`cpu` / `gpu` / `cpuset` / `thermal`）。
  final String? failedStage;

  /// 结构化错误（失败时）。
  final String? error;

  /// 是否成功（应用 / 还原 / no-op 均视为正常收敛）。
  bool get ok =>
      outcome == PerfAutoApplyOutcome.applied ||
      outcome == PerfAutoApplyOutcome.reverted ||
      outcome == PerfAutoApplyOutcome.noop;

  /// 是否实际改变了设备状态。
  bool get changed =>
      outcome == PerfAutoApplyOutcome.applied ||
      outcome == PerfAutoApplyOutcome.reverted;

  /// 可序列化摘要（证据 / 日志）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'outcome': outcome,
        'reason': reason,
        if (package != null) 'package': package,
        'applied_overrides': appliedOverrides,
        'reverted_overrides': revertedOverrides,
        'revert_remaining': revertRemaining,
        if (failedStage != null) 'failed_stage': failedStage,
        if (error != null) 'error': error,
      };

  /// 人类可读单行摘要（证据 / 日志）。
  String describe() {
    final buffer = StringBuffer('auto-apply $outcome reason=$reason'
        '${package == null ? '' : ' package=$package'}');
    if (appliedOverrides > 0) buffer.write(' applied=$appliedOverrides');
    if (revertedOverrides > 0) buffer.write(' reverted=$revertedOverrides');
    if (revertRemaining > 0) buffer.write(' remaining=$revertRemaining');
    if (failedStage != null) buffer.write(' stage=$failedStage');
    if (error != null) buffer.write(' error=$error');
    return buffer.toString();
  }

  @override
  String toString() => 'PerfAutoApplyReport(${describe()})';
}

// ==================== 内部辅助 ====================

/// [_applyProfile] 的中间结果。
class _ApplyOutcome {
  const _ApplyOutcome._({required this.ok, required this.count, this.report});

  factory _ApplyOutcome.ok(int count) =>
      _ApplyOutcome._(ok: true, count: count);

  factory _ApplyOutcome.failure(PerfAutoApplyReport report) =>
      _ApplyOutcome._(ok: false, count: 0, report: report);

  final bool ok;
  final int count;
  final PerfAutoApplyReport? report;
}

// ==================== 引擎 ====================

/// 每应用性能档案的自动应用 / 还原引擎（无状态持久化；状态在内存）。
///
/// 生产装配见 todo 30：订阅 `ForegroundWatcher.events` 后把 `event.package`
/// 交给 [onForegroundPackage]；全局开关（todo 26 的配置键）经 [isGloballyEnabled]
/// 注入；能力经 [capabilities] 注入。
class PerfProfileAutoEngine {
  PerfProfileAutoEngine({
    required PerfProfileStore store,
    required PerfControlSession session,
    required CpuControl cpuControl,
    required GpuControlAction gpuControl,
    required CpusetController cpusetControl,
    required ThermalToggleController thermalControl,
    required TunablesReport tunables,
    required PerfControlCapabilities? Function() capabilities,
    required bool Function() isGloballyEnabled,
    Duration debounce = defaultDebounce,
  })  : _store = store,
        _session = session,
        _cpuControl = cpuControl,
        _gpuControl = gpuControl,
        _cpusetControl = cpusetControl,
        _thermalControl = thermalControl,
        _tunables = tunables,
        _capabilities = capabilities,
        _isGloballyEnabled = isGloballyEnabled,
        _debounce = debounce;

  /// 默认去抖窗口（前台快速切换时合并处理）。
  static const Duration defaultDebounce = Duration(milliseconds: 400);

  final PerfProfileStore _store;
  final PerfControlSession _session;
  final CpuControl _cpuControl;
  final GpuControlAction _gpuControl;
  final CpusetController _cpusetControl;
  final ThermalToggleController _thermalControl;
  final TunablesReport _tunables;
  final PerfControlCapabilities? Function() _capabilities;
  final bool Function() _isGloballyEnabled;
  final Duration _debounce;

  /// 当前期望的前台包（最近一次事件）。
  String? _desiredPackage;
  bool _hasDesired = false;

  /// 当前已完整应用的档案（`null` = 未应用任何档案）。
  PerfProfile? _appliedProfile;

  /// 串行队列尾（保证 reconcile 串行、事件不丢）。
  Future<void> _tail = Future<void>.value();

  Timer? _debounceTimer;
  Completer<PerfAutoApplyReport>? _pendingCompleter;
  bool _isApplying = false;
  bool _disposed = false;

  // ==================== 可观测状态 ====================

  /// 当前已应用的档案；未应用为 `null`。
  PerfProfile? get appliedProfile => _appliedProfile;

  /// 当前已应用的档案所属包；未应用为 `null`。
  String? get appliedPackage => _appliedProfile?.package;

  /// 最近一次事件期望的前台包。
  String? get desiredPackage => _desiredPackage;

  /// 是否正在执行一次 reconcile（应用 / 还原）。
  bool get isApplying => _isApplying;

  /// 是否有待处理的去抖事件。
  bool get hasPendingForeground => _pendingCompleter != null;

  /// 会话中待还原的覆盖项数。
  int get pendingRevertCount => _session.pendingCount;

  /// 是否已释放。
  bool get isDisposed => _disposed;

  // ==================== 事件入口 ====================

  /// 喂入一条前台包名事件（[package] 为 `null` = 离开前台 / 无法判定）。
  ///
  /// [debounce] > 0 时按窗口合并快速切换；返回**处理最终期望态**的那次
  /// reconcile 报告（被取代的事件报告 `superseded`）。
  Future<PerfAutoApplyReport> onForegroundPackage(String? package) {
    if (_disposed) {
      return Future<PerfAutoApplyReport>.value(
        const PerfAutoApplyReport(
          outcome: PerfAutoApplyOutcome.superseded,
          reason: PerfAutoApplyReason.disposed,
        ),
      );
    }
    _desiredPackage = package;
    _hasDesired = true;

    if (_debounce <= Duration.zero) {
      return reconcile();
    }

    _debounceTimer?.cancel();
    final previous = _pendingCompleter;
    if (previous != null && !previous.isCompleted) {
      previous.complete(
        const PerfAutoApplyReport(
          outcome: PerfAutoApplyOutcome.superseded,
          reason: PerfAutoApplyReason.superseded,
        ),
      );
    }
    final completer = Completer<PerfAutoApplyReport>();
    _pendingCompleter = completer;
    _debounceTimer = Timer(_debounce, () {
      _pendingCompleter = null;
      reconcile().then(
        (report) {
          if (!completer.isCompleted) completer.complete(report);
        },
        onError: (Object error, StackTrace stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
        },
      );
    });
    return completer.future;
  }

  /// 重新按**最新**期望态收敛（用于 store 变更 / 全局开关变更后的刷新）。
  ///
  /// 会重新读取 store：若当前应用的档案被删除 / 禁用或全局关闭，则还原。
  Future<PerfAutoApplyReport> refresh() => reconcile();

  /// 立即按当前期望态执行一次收敛（绕过去抖；测试 / 手动触发用）。
  ///
  /// 所有 reconcile 串行执行；排队期间到达的新事件会更新期望态，使**最后**
  /// 一次 reconcile 收敛到最新目标。
  Future<PerfAutoApplyReport> reconcile() {
    final completer = Completer<PerfAutoApplyReport>();
    _tail = _tail.then((_) async {
      PerfAutoApplyReport report;
      try {
        report = await _doReconcile();
      } catch (error, stack) {
        report = PerfAutoApplyReport(
          outcome: PerfAutoApplyOutcome.failed,
          reason: PerfAutoApplyReason.exception,
          error: '$error',
        );
        debugPrint('[PerfProfileAutoEngine] reconcile 异常（已降级）: $error\n$stack');
      }
      if (!completer.isCompleted) completer.complete(report);
    });
    return completer.future;
  }

  /// 释放：取消去抖定时器并完成挂起的 Future。**不**自动还原（还原由
  /// 显式事件 / 会话生命周期钩子触发）。幂等。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    final pending = _pendingCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.complete(
        const PerfAutoApplyReport(
          outcome: PerfAutoApplyOutcome.superseded,
          reason: PerfAutoApplyReason.disposed,
        ),
      );
    }
    _pendingCompleter = null;
  }

  // ==================== 收敛核心 ====================

  Future<PerfAutoApplyReport> _doReconcile() async {
    if (_disposed) {
      return const PerfAutoApplyReport(
        outcome: PerfAutoApplyOutcome.superseded,
        reason: PerfAutoApplyReason.disposed,
      );
    }
    _isApplying = true;
    try {
      return await _reconcileOnce();
    } finally {
      _isApplying = false;
    }
  }

  Future<PerfAutoApplyReport> _reconcileOnce() async {
    final package = _hasDesired ? _desiredPackage : null;
    final globalEnabled = _isGloballyEnabled();

    // ---- 1. 解析目标档案（每次重新读 store：处理「档案被删/禁用」的陈旧态） ----
    PerfProfile? target;
    var skipReason = PerfAutoApplyReason.noForeground;
    if (!globalEnabled) {
      skipReason = PerfAutoApplyReason.globalDisabled;
    } else if (package == null) {
      skipReason = PerfAutoApplyReason.noForeground;
    } else {
      final profiles = await _store.loadAll();
      final profile = profiles[package];
      if (profile == null) {
        skipReason = PerfAutoApplyReason.profileMissing;
      } else if (!profile.enabled) {
        skipReason = PerfAutoApplyReason.profileDisabled;
      } else {
        // 以 map 键为准归一档案身份（宽容解码可能缺 package）。
        target = profile.package == package
            ? profile
            : profile.copyWith(package: package);
      }
    }

    final current = _appliedProfile;

    // ---- 2. 无目标 → 确保已还原（幂等：无残留时零命令） ----
    if (target == null) {
      if (current == null) {
        return PerfAutoApplyReport(
          outcome: PerfAutoApplyOutcome.noop,
          reason: skipReason,
          package: package,
        );
      }
      return _revertCurrent(stopReason: skipReason, package: current.package);
    }

    // ---- 3. 已应用且未变更 → 幂等 no-op（零写入） ----
    if (current != null && current == target) {
      return PerfAutoApplyReport(
        outcome: PerfAutoApplyOutcome.noop,
        reason: PerfAutoApplyReason.unchanged,
        package: target.package,
      );
    }

    // ---- 4. FAIL-CLOSED：能力未知 → 绝不应用（保持现状） ----
    final capabilities = _capabilities();
    if (capabilities == null) {
      debugPrint('[PerfProfileAutoEngine] 能力未知 → 拒绝应用 '
          '${target.package}（fail-closed，保持现状）');
      return PerfAutoApplyReport(
        outcome: PerfAutoApplyOutcome.skipped,
        reason: PerfAutoApplyReason.capabilityUnknown,
        package: target.package,
      );
    }

    // ---- 5. 切换前先还原当前档案（绝不在旧覆盖之上叠加新覆盖） ----
    if (current != null) {
      final revert = await _session.revertAll(
        reason: PerfAutoApplyRevertReason.switchProfile,
      );
      _appliedProfile = null;
      if (!revert.ok) {
        debugPrint('[PerfProfileAutoEngine] 切换前还原失败 '
            '(${revert.failedCount} 项保留)，放弃应用 ${target.package}');
        return PerfAutoApplyReport(
          outcome: PerfAutoApplyOutcome.failed,
          reason: PerfAutoApplyReason.revertFailed,
          package: current.package,
          revertedOverrides: revert.revertedCount,
          revertRemaining: revert.remaining.length,
          error: 'revert of ${revert.failedCount} node(s) failed before switch',
        );
      }
    }

    // ---- 6. 应用目标档案（部分失败内部回滚） ----
    final applied = await _applyProfile(target, capabilities);
    if (!applied.ok) {
      return applied.report!;
    }
    _appliedProfile = target;
    debugPrint('[PerfProfileAutoEngine] 已应用档案 ${target.package} '
        '（${applied.count} 个覆盖项）');
    return PerfAutoApplyReport(
      outcome: PerfAutoApplyOutcome.applied,
      reason: PerfAutoApplyReason.applied,
      package: target.package,
      appliedOverrides: applied.count,
    );
  }

  /// 还原当前档案（经会话 `revertAll`）。
  Future<PerfAutoApplyReport> _revertCurrent({
    required String stopReason,
    required String package,
  }) async {
    final reason = switch (stopReason) {
      PerfAutoApplyReason.globalDisabled =>
        PerfAutoApplyRevertReason.globalDisabled,
      PerfAutoApplyReason.profileDisabled ||
      PerfAutoApplyReason.profileMissing =>
        PerfAutoApplyRevertReason.profileDisabled,
      _ => PerfAutoApplyRevertReason.leave,
    };
    final revert = await _session.revertAll(reason: reason);
    _appliedProfile = null;
    final ok = revert.ok;
    debugPrint('[PerfProfileAutoEngine] 还原档案 $package '
        '（reason=$reason ok=$ok reverted=${revert.revertedCount} '
        'failed=${revert.failedCount}）');
    return PerfAutoApplyReport(
      outcome: ok ? PerfAutoApplyOutcome.reverted : PerfAutoApplyOutcome.failed,
      reason: ok ? stopReason : PerfAutoApplyReason.revertFailed,
      package: package,
      revertedOverrides: revert.revertedCount,
      revertRemaining: revert.remaining.length,
      error: ok ? null : 'revert failed for ${revert.failedCount} node(s)',
    );
  }

  /// 把档案映射到 todos 16-19 的动作并依次应用；每个成功结果经会话登记。
  ///
  /// 任一动作失败 → 会话 `revertAll` 回滚本次已登记的全部覆盖项（绝不半应用）。
  Future<_ApplyOutcome> _applyProfile(
    PerfProfile profile,
    PerfControlCapabilities capabilities,
  ) async {
    var count = 0;

    // ---- CPU：每个策略簇一次 applyCpuPolicy ----
    for (final entry in profile.cpuClusters.entries) {
      final cluster = entry.value;
      if (cluster.isEmpty) continue;
      final result = await _cpuControl.applyCpuPolicy(
        cluster: entry.key,
        governor: cluster.governor,
        minFreqMhz: cluster.minFreqMhz,
        maxFreqMhz: cluster.maxFreqMhz,
      );
      if (!result.ok) {
        return _rollbackPartial(
          stage: 'cpu',
          error: '${result.status}'
              '${result.message == null ? '' : ': ${result.message}'}',
          package: profile.package,
        );
      }
      await _session.recordCpu(result);
      count += result.applied.length;
    }

    // ---- GPU：`gpuLevel` → kgsl `max_pwrlevel`（功率档位上限） ----
    if (profile.gpuLevel != null) {
      final result = await _gpuControl.applyGpuPolicy(
        GpuPolicy(maxPwrlevel: profile.gpuLevel),
        tunables: _tunables,
      );
      if (!result.applied) {
        return _rollbackPartial(
          stage: 'gpu',
          error: '${result.error ?? result.status.name}'
              '${result.reason == null ? '' : ': ${result.reason}'}',
          package: profile.package,
        );
      }
      await _session.recordGpu(result);
      count += result.writes.length;
    }

    // ---- cpuset：把目标包归属到指定 cpuset ----
    if (profile.cpuset != null) {
      final result = await _cpusetControl.applyCpuset(
        pkgOrPid: profile.package,
        cpuset: profile.cpuset!,
      );
      if (!result.ok) {
        return _rollbackPartial(
          stage: 'cpuset',
          error: '${result.status}: ${result.message}',
          package: profile.package,
        );
      }
      await _session.recordCpuset(result);
      count += result.appliedPids.length;
    }

    // ---- thermal：档案显式配置 + 全局授权 = 视为已确认（见文件头说明） ----
    if (profile.thermalEnabled != null) {
      final result = await _thermalControl.setThermalEnabled(
        profile.thermalEnabled!,
        confirmed: true,
        tunables: _tunables,
        capabilities: capabilities,
      );
      if (!result.ok) {
        return _rollbackPartial(
          stage: 'thermal',
          error: '${result.error ?? 'failed'}: ${result.detail}',
          package: profile.package,
        );
      }
      await _session.recordThermal(result);
      count += result.applied.length;
    }

    return _ApplyOutcome.ok(count);
  }

  /// 部分失败：回滚本次已登记的全部覆盖项（经会话），返回 `ok:false` 报告。
  Future<_ApplyOutcome> _rollbackPartial({
    required String stage,
    required String error,
    required String package,
  }) async {
    final revert = await _session.revertAll(
      reason: PerfAutoApplyRevertReason.partialFailure,
    );
    _appliedProfile = null;
    debugPrint('[PerfProfileAutoEngine] 档案 $package 在 $stage 失败（$error）→ '
        '回滚 ${revert.revertedCount} 项（ok=${revert.ok}, '
        'remaining=${revert.remaining.length}）');
    return _ApplyOutcome.failure(
      PerfAutoApplyReport(
        outcome: PerfAutoApplyOutcome.failed,
        reason: PerfAutoApplyReason.partialFailure,
        package: package,
        revertedOverrides: revert.revertedCount,
        revertRemaining: revert.remaining.length,
        failedStage: stage,
        error: error,
      ),
    );
  }
}
