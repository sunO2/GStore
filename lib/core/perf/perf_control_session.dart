/// Wave 4 · Todo 20 —— **控制会话**：记录每个已应用的覆盖项（节点 → 原值），
/// 并提供**有保证的还原**（`revertAll`）+ 崩溃/重启后的「待还原」持久化。
///
/// 本层是 todos 16-19（CPU / GPU / cpuset / thermal 四个控制动作）之上的
/// **唯一**会话管理器。四个动作都把「写前原值」作为结构化结果回传
/// （见各自的 `applied` / `writes` / `originals` / `applied` 字段），但**没有**
/// 任何动作会跨会话保留状态 —— 于是本层负责：
///
/// ```text
/// recordAll(动作结果适配出的 PerfOverride[])
///   → 记入本次会话的覆盖登记表（path → 原值；首次写入者胜出）
///   → 持久化「待还原」清单（崩溃/重启后下次启动还原）
///   → 首次登记即启动会话超时（可选）
///
/// revertAll(reason)
///   → 逆登记顺序把每个节点写回**记录的原值**（精确还原）
///   → 成功的移出登记表；失败的保留待重试（不静默丢弃）
///   → 登记表清空后清除持久化的「待还原」状态
///
/// restorePendingOnInit()
///   → 读取上次未完成的「待还原」清单 → 立即 revertAll（崩溃恢复）
/// ```
///
/// ## 不可协商的约束（照抄 todo 20 的 Must NOT do）
/// * **绝不**在写节点前不记录原值；没有记录到原值的节点**绝不**触碰
///   （适配器与 [PerfControlSession.recordAll] 双重过滤掉无原值的项）。
/// * **绝不**触碰不属于本会话登记的节点（`revertAll` 只遍历自己的登记表，
///   不扫描、不猜测任何节点）。
/// * 还原写必须**精确**（写回记录的原文，不做任何归一化 / 数值换算）。
///
/// ## 部分失败（partial writes）
/// * 控制动作**中途写失败**会自行回滚，其结果的 `applied` 为空 —— 本层据此
///   登记 **0 个覆盖项**（无残留「假覆盖」）。
/// * 还原**中途写失败**：成功者移出登记表，失败者**保留**在登记表与持久化状态中
///   （`ok:false` + `remaining`），可重试；持久化状态**不会**被提前清除。
///
/// ## 归属与并发假设（风险）
/// 本层假定**全 App 单会话**：登记表按节点路径去重并保留**最早**的原值，从而
/// 多次写入同一节点也能还原到会话开始前的值。跨实例并发（两个不同会话同时写
/// 同一节点）无法在本地协调，需由上层保证单例（[perfControlSessionProvider]）
/// —— 见 todo 24/27/30 的接线。
///
/// ## 超时（继承 todo 10 的事实，对本层不适用）
/// 还原写全部经 [PrivilegedShell.buildWriteCommand] 自带 `timeout <n> sh -c '…'`
/// 自我限时；本层不做自己的 Dart 超时（`revertAll` 会等待每条命令的结果）。
///
/// ## 可测试性
/// [PrivilegedShell] / [PerfControlSessionStore] / 时钟与超时时长均可注入；
/// 测试注入假 [CommandRunner] + [InMemoryPerfControlSessionStore]，
/// **无需 Shizuku / 真机 / 原生模块 / SharedPreferences 平台通道**。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/control_cpu.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/control_thermal.dart';
import 'package:gstore/core/perf/privileged_shell.dart';

// ==================== 白名单 ====================

/// 会话还原的**写**白名单：所有控制动作写节点的并集。
///
/// 由默认写白名单 + GPU 扩展（kgsl `governor` / `pwrlevel`，todo 17）+
/// cpuset `tasks` 成员表（todo 18）合并而来；`*` 为单段通配（不跨 `/`）。
/// 会话对每个还原写先用自己的校验器判定，再经 [PrivilegedShell.buildWriteCommand]
/// 发出（绕过注入 shell 可能更窄的默认校验器），保证生产一致。
const List<String> kPerfControlSessionAllowlist = <String>[
  ...kDefaultSysfsAllowlist,
  ...kGpuControlAllowlist,
  ...kCpusetControlAllowlist,
];

// ==================== 还原原因 ====================

/// `revertAll` 的触发原因（可读 + 可断言）。
abstract final class PerfRevertReason {
  /// 手动 / 通用登记后还原。
  static const String manual = 'manual';

  /// 显式停止控制会话。
  static const String explicitStop = 'explicit_stop';

  /// `PerfMonitorModule` 被禁用 / 注销。
  static const String moduleDisabled = 'module_disabled';

  /// App 退出（`detached`）。
  static const String appExit = 'app_exit';

  /// 后台超时（长时间不在前台）。
  static const String backgroundTimeout = 'background_timeout';

  /// 会话超时（达到最大会话时长）。
  static const String sessionTimeout = 'session_timeout';

  /// 崩溃 / 重启后在初始化时恢复。
  static const String restartRecovery = 'restart_recovery';
}

// ==================== 覆盖项模型 ====================

/// 一个已应用的覆盖项：把 [path] 写回 [originalValue] 即**精确撤销**该次变更。
///
/// * **简单控制节点**（CPU / GPU governor·频率·功耗档位、thermal `mode`）：
///   [path] = 被写的节点，[originalValue] = 写入**之前**读到的原值。
/// * **cpuset 归属**（todo 18）：撤销 = 把 pid **移回原 cpuset**，故
///   [path] = `/dev/cpuset/<原 cpuset>/tasks`，[originalValue] = `<pid>`，
///   [numeric] = `true`。这是「补偿写」，语义仍是「把记录的原文写到记录的节点」。
class PerfOverride {
  const PerfOverride({
    required this.path,
    required this.originalValue,
    this.numeric = false,
    this.source = 'manual',
  });

  /// 需要被写回以撤销变更的节点路径。
  final String path;

  /// 写入 [path] 的**原值**（撤销目标）。
  final String originalValue;

  /// 写值是否为纯整数（[PrivilegedShell.write] 的 `numeric` 提示）。
  final bool numeric;

  /// 贡献该覆盖项的动作（`cpu` / `gpu` / `cpuset` / `thermal` / `manual`）。
  final String source;

  /// 序列化（供「待还原」持久化）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'original': originalValue,
        'numeric': numeric,
        'source': source,
      };

  /// 宽容反序列化（缺字段用默认值；非法路径/原值由会话在登记时再过滤）。
  factory PerfOverride.fromJson(Map<String, dynamic> json) => PerfOverride(
        path: json['path']?.toString() ?? '',
        originalValue:
            (json['original'] ?? json['originalValue'])?.toString() ?? '',
        numeric: json['numeric'] == true,
        source: json['source']?.toString() ?? 'unknown',
      );

  @override
  String toString() =>
      'PerfOverride($source:$path: $originalValue${numeric ? ' [num]' : ''})';
}

// ==================== 动作结果 → 覆盖项 适配器 ====================

/// 把 todos 16-19 的结构化结果适配为 [PerfOverride] 列表。
///
/// **只**为「确实已应用且记录了原值」的节点产出覆盖项：
/// * 动作失败（`ok:false` / `failed`）→ 不产出（其 `applied` 已为空 / 已回滚）；
/// * 原值缺失（null / 空串）→ **跳过**（没有原值就绝不还原该节点）。
abstract final class PerfOverrideAdapters {
  /// todo 16 CPU 结果 → 覆盖项（`applied[].before` 为原值）。
  static List<PerfOverride> fromCpu(CpuPolicyResult result) {
    if (!result.ok) return const <PerfOverride>[];
    final out = <PerfOverride>[];
    for (final change in result.applied) {
      final before = change.before;
      if (before == null || before.isEmpty) continue;
      out.add(PerfOverride(
        path: change.path,
        originalValue: before,
        numeric: !change.path.endsWith('/scaling_governor'),
        source: 'cpu',
      ));
    }
    return out;
  }

  /// todo 17 GPU 结果 → 覆盖项（`writes[].previousValue` 为原值）。
  static List<PerfOverride> fromGpu(GpuPolicyResult result) {
    if (!result.applied) return const <PerfOverride>[];
    final out = <PerfOverride>[];
    for (final write in result.writes) {
      if (write.previousValue.isEmpty) continue;
      out.add(PerfOverride(
        path: write.path,
        originalValue: write.previousValue,
        numeric: !write.path.endsWith('/governor'),
        source: 'gpu',
      ));
    }
    return out;
  }

  /// todo 19 thermal 结果 → 覆盖项（`applied[].originalValue` 为原值）。
  static List<PerfOverride> fromThermal(ThermalToggleResult result) {
    if (!result.ok) return const <PerfOverride>[];
    final out = <PerfOverride>[];
    for (final record in result.applied) {
      if (record.originalValue.isEmpty) continue;
      out.add(PerfOverride(
        path: record.path,
        originalValue: record.originalValue,
        source: 'thermal',
      ));
    }
    return out;
  }

  /// todo 18 cpuset 结果 → 覆盖项（把每个已应用 pid **移回**原 cpuset）。
  ///
  /// 撤销动作是「把 pid 写回其原 cpuset 的 `tasks`」；原 cpuset 未知（`null` /
  /// 与目标相同）的 pid **不产出覆盖项**（无原归属即不动）。
  static List<PerfOverride> fromCpuset(CpusetResult result) {
    if (!result.ok) return const <PerfOverride>[];
    final out = <PerfOverride>[];
    for (final pid in result.appliedPids) {
      final original = result.originalCpusets[pid];
      if (original == null || original.isEmpty) continue;
      if (original == result.cpuset) continue;
      out.add(PerfOverride(
        path: '/dev/cpuset/$original/tasks',
        originalValue: '$pid',
        numeric: true,
        source: 'cpuset',
      ));
    }
    return out;
  }
}

// ==================== 还原结果模型 ====================

/// 一次还原写的结果（成功或失败）。
class PerfRevertEntry {
  const PerfRevertEntry({
    required this.item,
    required this.ok,
    this.error,
    this.detail,
  });

  /// 成功还原的项。
  factory PerfRevertEntry.ok(PerfOverride item) =>
      PerfRevertEntry(item: item, ok: true);

  /// 失败（保留待重试）的项。
  factory PerfRevertEntry.failure(
    PerfOverride item,
    String? error,
    String? detail,
  ) =>
      PerfRevertEntry(
        item: item,
        ok: false,
        error: error,
        detail: detail,
      );

  /// 对应的覆盖项。
  final PerfOverride item;

  /// 是否成功写回原值。
  final bool ok;

  /// 结构化错误码（见 [PrivilegedError]）；成功为 `null`。
  final String? error;

  /// 可读补充（exitHint / 校验原因）。
  final String? detail;

  /// 便捷：节点路径。
  String get path => item.path;

  /// 便捷：写回的原值。
  String get value => item.originalValue;

  /// 序列化（证据 / 日志）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'original': value,
        'source': item.source,
        'ok': ok,
        if (error != null) 'error': error,
        if (detail != null) 'detail': detail,
      };

  @override
  String toString() =>
      'PerfRevertEntry($path: $value, ok: $ok${error == null ? '' : ', $error'})';
}

/// 一次 `revertAll` 的完整报告（**绝不抛出**）。
class PerfRevertReport {
  const PerfRevertReport({
    required this.ok,
    required this.reason,
    this.reverted = const <PerfRevertEntry>[],
    this.failed = const <PerfRevertEntry>[],
    this.remaining = const <PerfOverride>[],
  });

  /// 是否**全部**待还原项都成功写回（无待还原项时也为 `true`）。
  final bool ok;

  /// 触发原因（见 [PerfRevertReason]）。
  final String reason;

  /// 成功写回原值的项（已移出登记表）。
  final List<PerfRevertEntry> reverted;

  /// 写回失败的项（**保留**在登记表与持久化状态中待重试）。
  final List<PerfRevertEntry> failed;

  /// 还原后仍登记在册的覆盖项（= [failed] 的覆盖项，便于上层展示 / 重试）。
  final List<PerfOverride> remaining;

  /// 成功还原数。
  int get revertedCount => reverted.length;

  /// 失败数。
  int get failedCount => failed.length;

  /// 本次调用是否处理了任何项。
  bool get hadPending => reverted.isNotEmpty || failed.isNotEmpty;

  /// 可序列化摘要（证据 / 日志）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'reason': reason,
        'reverted_count': revertedCount,
        'failed_count': failedCount,
        'reverted': reverted.map((e) => e.toJson()).toList(growable: false),
        'failed': failed.map((e) => e.toJson()).toList(growable: false),
        'remaining': remaining.map((o) => o.toJson()).toList(growable: false),
      };

  /// 人类可读多行摘要（证据用）。
  String describe() {
    final buffer = StringBuffer()
      ..writeln('revert reason=$reason ok=$ok '
          'reverted=$revertedCount failed=$failedCount '
          'remaining=${remaining.length}');
    for (final entry in reverted) {
      buffer.writeln('  reverted ${entry.path}: ${entry.value}');
    }
    for (final entry in failed) {
      buffer.writeln('  FAILED   ${entry.path}: ${entry.value} '
          '(error=${entry.error}${entry.detail == null ? '' : ' ${entry.detail}'})');
    }
    return buffer.toString();
  }

  @override
  String toString() => 'PerfRevertReport(ok: $ok, reason: $reason, '
      'reverted: $revertedCount, failed: $failedCount)';
}

// ==================== 「待还原」持久化 ====================

/// 「待还原」状态的持久化抽象（崩溃 / 重启恢复用）。
///
/// 失败一律静默降级（不抛），与会话「绝不抛出」的整体风格一致。
abstract class PerfControlSessionStore {
  /// 读取上次未完成的「待还原」清单；无 / 失败返回空列表。
  Future<List<PerfOverride>> loadPending();

  /// 覆盖保存「待还原」清单；失败静默。
  Future<void> savePending(List<PerfOverride> overrides);

  /// 清除「待还原」状态（全部成功还原后调用）；失败静默。
  Future<void> clearPending();
}

/// 生产实现：`shared_preferences`（与会话同进程的小 JSON）。
class SharedPrefsPerfControlSessionStore implements PerfControlSessionStore {
  const SharedPrefsPerfControlSessionStore();

  /// 存储键。
  static const String storageKey = 'perf_control_session_pending';

  @override
  Future<List<PerfOverride>> loadPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return const <PerfOverride>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <PerfOverride>[];
      final out = <PerfOverride>[];
      for (final item in decoded) {
        if (item is Map) {
          out.add(PerfOverride.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ));
        }
      }
      return out;
    } catch (error) {
      debugPrint('[PerfControlSession] 读取待还原状态失败: $error');
      return const <PerfOverride>[];
    }
  }

  @override
  Future<void> savePending(List<PerfOverride> overrides) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        storageKey,
        jsonEncode(overrides.map((o) => o.toJson()).toList(growable: false)),
      );
    } catch (error) {
      debugPrint('[PerfControlSession] 保存待还原状态失败: $error');
    }
  }

  @override
  Future<void> clearPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (error) {
      debugPrint('[PerfControlSession] 清除待还原状态失败: $error');
    }
  }
}

/// 内存实现（测试 / 无持久化环境）。
class InMemoryPerfControlSessionStore implements PerfControlSessionStore {
  InMemoryPerfControlSessionStore([List<PerfOverride>? initial])
      : _pending = <PerfOverride>[...?initial];

  List<PerfOverride> _pending;

  /// 当前持久化的项（测试断言「stale state 已清理」用）。
  List<PerfOverride> get pending =>
      List<PerfOverride>.unmodifiable(_pending);

  @override
  Future<List<PerfOverride>> loadPending() async =>
      List<PerfOverride>.of(_pending);

  @override
  Future<void> savePending(List<PerfOverride> overrides) async {
    _pending = List<PerfOverride>.of(overrides);
  }

  @override
  Future<void> clearPending() async {
    _pending = <PerfOverride>[];
  }
}

// ==================== 会话 ====================

/// 控制会话：登记已应用的覆盖项并保证还原。
///
/// 生产：`PerfControlSession(shell: PrivilegedShell(),
/// store: const SharedPrefsPerfControlSessionStore())`。
/// 测试：注入假 [CommandRunner] 的 [PrivilegedShell] +
/// [InMemoryPerfControlSessionStore]，**无需 Shizuku / 真机 / 平台通道**。
class PerfControlSession {
  PerfControlSession({
    required PrivilegedShell shell,
    PerfControlSessionStore? store,
    PrivilegedInputValidator? validator,
    this.sessionTimeout,
    DateTime Function()? clock,
    String sessionId = 'default',
  })  : _shell = shell,
        _store = store,
        _validator = validator ??
            PrivilegedInputValidator(sysfsPatterns: kPerfControlSessionAllowlist),
        _clock = clock ?? DateTime.now,
        _sessionId = sessionId;

  final PrivilegedShell _shell;
  final PerfControlSessionStore? _store;
  final PrivilegedInputValidator _validator;

  /// 会话最大时长；`null` = 不启用超时。首次登记时启动，还原后取消。
  final Duration? sessionTimeout;

  final DateTime Function() _clock;

  /// 会话标识（日志 / 报告）。
  final String _sessionId;

  /// 登记表：`节点路径 -> 覆盖项`（插入序 = 应用序，还原时逆序）。
  final Map<String, PerfOverride> _overrides = <String, PerfOverride>{};

  Timer? _timeoutTimer;
  Future<PerfRevertReport>? _inFlight;

  /// 会话标识。
  String get sessionId => _sessionId;

  /// 是否仍有待还原的覆盖项。
  bool get hasPendingRevert => _overrides.isNotEmpty;

  /// 待还原项数。
  int get pendingCount => _overrides.length;

  /// 当前登记的覆盖项（插入序，只读快照）。
  List<PerfOverride> get pendingOverrides =>
      List<PerfOverride>.unmodifiable(_overrides.values);

  /// 某节点是否由本会话登记（= 本会话拥有）。
  bool owns(String path) => _overrides.containsKey(path);

  // ==================== 登记 ====================

  /// 登记一批覆盖项（只登记带合法路径与原值的项）。
  ///
  /// * 原值缺失（空）→ **跳过**（无原值绝不还原）。
  /// * 同一节点已登记 → **保留最早的原值**（多次写同一节点仍能还原到会话前）。
  /// * 有新增 → 持久化「待还原」状态并启动会话超时。
  ///
  /// **绝不抛出**。
  Future<void> recordAll(
    Iterable<PerfOverride> overrides, {
    String reason = PerfRevertReason.manual,
  }) async {
    var added = false;
    for (final override in overrides) {
      if (override.path.isEmpty || override.originalValue.isEmpty) {
        debugPrint('[PerfControlSession] 跳过无原值的覆盖项 '
            '(${override.path.isEmpty ? '<empty path>' : override.path})');
        continue;
      }
      if (_overrides.containsKey(override.path)) {
        // 已有更早的原值 → 不覆盖（first-write-wins；不夺占已登记节点）。
        continue;
      }
      _overrides[override.path] = override;
      added = true;
    }
    if (!added) return;
    debugPrint('[PerfControlSession] 登记 $added 项（reason=$reason, '
        'pending=${_overrides.length}）');
    await _persistPending();
    _armSessionTimeout();
  }

  /// 便捷：登记 todo 16 CPU 结果的覆盖项。
  Future<void> recordCpu(CpuPolicyResult result) =>
      recordAll(PerfOverrideAdapters.fromCpu(result), reason: 'cpu');

  /// 便捷：登记 todo 17 GPU 结果的覆盖项。
  Future<void> recordGpu(GpuPolicyResult result) =>
      recordAll(PerfOverrideAdapters.fromGpu(result), reason: 'gpu');

  /// 便捷：登记 todo 18 cpuset 结果的覆盖项。
  Future<void> recordCpuset(CpusetResult result) =>
      recordAll(PerfOverrideAdapters.fromCpuset(result), reason: 'cpuset');

  /// 便捷：登记 todo 19 thermal 结果的覆盖项。
  Future<void> recordThermal(ThermalToggleResult result) =>
      recordAll(PerfOverrideAdapters.fromThermal(result), reason: 'thermal');

  // ==================== 还原 ====================

  /// 还原本会话登记的所有覆盖项（逆登记顺序）。
  ///
  /// **幂等**：无待还原项 → 立即返回 `ok:true` 且**零命令**；并发触发会
  /// **合并**为同一次还原（返回同一个 Future）。
  ///
  /// 成功者移出登记表；失败者保留（`ok:false` + [PerfRevertReport.remaining]）。
  /// 登记表清空后清除持久化「待还原」状态。
  ///
  /// **绝不抛出**。
  Future<PerfRevertReport> revertAll({
    String reason = PerfRevertReason.manual,
  }) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _doRevertAll(reason);
    _inFlight = future;
    unawaited(future.whenComplete(() => _inFlight = null));
    return future;
  }

  /// 显式停止会话 → 还原。
  Future<PerfRevertReport> stop() =>
      revertAll(reason: PerfRevertReason.explicitStop);

  /// 模块被禁用 / 注销 → 还原（由 `PerfMonitorModule.onUnregister` 调用）。
  Future<PerfRevertReport> onModuleDisabled() =>
      revertAll(reason: PerfRevertReason.moduleDisabled);

  /// App 退出 → 还原。
  Future<PerfRevertReport> onAppExit() =>
      revertAll(reason: PerfRevertReason.appExit);

  /// 后台超时 → 还原。
  Future<PerfRevertReport> onBackgroundTimeout() =>
      revertAll(reason: PerfRevertReason.backgroundTimeout);

  /// 会话超时 → 还原（[sessionTimeout] 到期时也会自动调用）。
  Future<PerfRevertReport> onSessionTimeout() =>
      revertAll(reason: PerfRevertReason.sessionTimeout);

  /// 崩溃 / 重启恢复：读取上次未完成的「待还原」状态，非空则**立即还原**。
  ///
  /// 返回本次恢复的还原报告；无待还原状态时返回 `null`。
  /// **绝不抛出**。
  Future<PerfRevertReport?> restorePendingOnInit() async {
    final store = _store;
    if (store == null) return null;
    final pending = await store.loadPending();
    if (pending.isEmpty) return null;
    for (final override in pending) {
      if (override.path.isEmpty || override.originalValue.isEmpty) continue;
      _overrides.putIfAbsent(override.path, () => override);
    }
    if (_overrides.isEmpty) {
      await store.clearPending();
      return null;
    }
    debugPrint('[PerfControlSession] 检测到待还原状态 '
        '(${_overrides.length} 项) → 初始化时还原');
    return revertAll(reason: PerfRevertReason.restartRecovery);
  }

  /// 释放：取消会话超时计时器（**不**自动还原 —— 还原由显式生命周期钩子
  /// `onAppExit` / `onModuleDisabled` / `stop` 触发）。
  void dispose() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  // ==================== 内部 ====================

  Future<PerfRevertReport> _doRevertAll(String reason) async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    final snapshot = _overrides.values.toList(growable: false).reversed.toList(
          growable: false,
        );
    final reverted = <PerfRevertEntry>[];
    final failed = <PerfRevertEntry>[];

    for (final override in snapshot) {
      final entry = await _restore(override);
      if (entry.ok) {
        _overrides.remove(override.path);
        reverted.add(entry);
      } else {
        failed.add(entry);
      }
    }

    await _persistPending();
    if (_overrides.isNotEmpty) _armSessionTimeout();

    final report = PerfRevertReport(
      ok: failed.isEmpty,
      reason: reason,
      reverted: List<PerfRevertEntry>.unmodifiable(reverted),
      failed: List<PerfRevertEntry>.unmodifiable(failed),
      remaining: List<PerfOverride>.unmodifiable(_overrides.values),
    );
    debugPrint('[PerfControlSession] revertAll($reason) ok=${report.ok} '
        'reverted=${report.revertedCount} failed=${report.failedCount} '
        'remaining=${report.remaining.length}');
    return report;
  }

  /// 把单个覆盖项写回原值；先过白名单校验再发命令。
  Future<PerfRevertEntry> _restore(PerfOverride override) async {
    final pathReason = _validator.sysfsPathReason(override.path);
    if (pathReason != null) {
      debugPrint('[PerfControlSession] 还原路径不在白名单（$pathReason）：'
          '${override.path} → 保留待重试');
      return PerfRevertEntry.failure(
        override,
        PrivilegedError.invalidArg,
        pathReason,
      );
    }
    final valueReason = override.numeric
        ? _validator.numericReason(override.originalValue)
        : _validator.tokenReason(override.originalValue);
    if (valueReason != null) {
      debugPrint('[PerfControlSession] 还原值非法（$valueReason）：'
          '${override.path} → 保留待重试');
      return PerfRevertEntry.failure(
        override,
        PrivilegedError.invalidArg,
        valueReason,
      );
    }

    final result = await _shell.run(
      _shell.buildWriteCommand(
        path: override.path,
        value: override.originalValue,
      ),
    );
    if (result.ok) return PerfRevertEntry.ok(override);
    return PerfRevertEntry.failure(
      override,
      result.error,
      result.exitHint == null ? null : 'exitHint=${result.exitHint}',
    );
  }

  Future<void> _persistPending() async {
    final store = _store;
    if (store == null) return;
    if (_overrides.isEmpty) {
      await store.clearPending();
    } else {
      await store.savePending(
        _overrides.values.toList(growable: false),
      );
    }
  }

  void _armSessionTimeout() {
    final timeout = sessionTimeout;
    if (timeout == null || _timeoutTimer != null || _overrides.isEmpty) return;
    _timeoutTimer = Timer(timeout, () {
      debugPrint('[PerfControlSession] 会话超时（$timeout）→ 还原');
      unawaited(onSessionTimeout());
    });
  }

  /// 当前时间（保留给日志 / 未来 TTL；注入可在测试中固定）。
  DateTime now() => _clock();
}

// ==================== Riverpod 接线（镜像 existing perf providers） ====================

/// 全 App 共享的单例控制会话（生产 = SharedPreferences 持久化 + 30 分钟超时）。
///
/// **关键：单例语义**。自动应用引擎（todo 24，经 [PerfProfilesCoordinator]）与
/// 性能页的手动控制（todo 28，`DefaultPerfControlActions`）**必须**共用同一实例
/// —— `revertAll` 只遍历会话自己的登记表，两个会话各自登记同一节点会在还原时
/// 互相踩踏。模块生命周期（todo 30）直接取用本 getter，Riverpod 的
/// [perfControlSessionProvider] 也返回**同一对象**。
///
/// **惰性 / 零副作用**：构造 [PrivilegedShell] 与 [SharedPrefsPerfControlSessionStore]
/// 都不会发命令、不触达 FFI / 平台通道；只有真正 [PerfControlSession.revertAll]
/// 时才写节点。
PerfControlSession? _sharedControlSession;

/// 共享控制会话（惰性创建）。
PerfControlSession get sharedPerfControlSession =>
    _sharedControlSession ??= PerfControlSession(
      shell: PrivilegedShell(),
      store: const SharedPrefsPerfControlSessionStore(),
      sessionTimeout: const Duration(minutes: 30),
    );

/// 测试用：替换 / 重置共享单例（避免跨测试污染）。
@visibleForTesting
void setSharedPerfControlSessionForTest(PerfControlSession? session) {
  _sharedControlSession = session;
}

/// 全 App 单例控制会话（Riverpod 入口，返回 [sharedPerfControlSession]）。
///
/// 消费方（todos 24/27/30）应在启动时调用 [PerfControlSession.restorePendingOnInit]，
/// 并在模块注销 / App 退出 / 后台超时时调用对应的还原钩子。
final perfControlSessionProvider = Provider<PerfControlSession>(
  (ref) => sharedPerfControlSession,
);
