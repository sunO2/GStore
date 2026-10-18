/// Wave 4 · Todo 19 —— **危险、需显式确认**的热控开关动作（`setThermalEnabled`）。
///
/// 本层是把 [PerfControlCapabilities]（todo 15 的 fail-closed 门禁）与
/// [PrivilegedShell]（todo 10 的受限特权 shell 传输层）组合起来的**唯一一个**
/// 会写 `thermal_zone*/mode` 的入口。它自身不拼命令、不碰 `/sys`，只编排
/// **validate → probe(=capabilities) → read-original → write → read-back →
/// rollback** 的协议。
///
/// ## 危险方向与确认门禁（不可协商）
/// * `enabled == true`  → 写入 `enabled`（**保持/恢复热控降温**，安全方向）；
/// * `enabled == false` → 写入 `disabled`（**关闭热控降温**，`msm_thermal` 等
///   「thermal-disable」语义的等价开关；**会有过热风险**）。
///
/// 无论哪个方向，调用方**必须**显式传入 `confirmed: true`。UI 层的确认由
/// `AppDialogs.showConfirmSheet(isDangerous: true)`（含过热警告）在 todo 28 接线；
/// 本动作层**只认这个布尔门禁** —— 未确认时**在任何命令发出之前**直接返回
/// `confirm_required` 并**零写入**（默认绝不自行开启 thermal-disable）。
///
/// ## 候选节点来自 `perf.tunables`（绝不猜测 vendor 节点）
/// 目标节点仅由 `tunables.thermalZones[].zone` 推导为
/// `/sys/class/thermal/<zone>/mode`，且必须同时满足 todo 15 的能力图
/// `capabilities.isNodeAvailable(path) == true`。若 `perf.tunables` 未枚举到任何
/// 可写 thermal 节点 → 返回 `unavailable` 且**零写入**（fail-closed）。像
/// `/sys/module/msm_thermal/parameters/enabled` 这类未被枚举/不在白名单内的
/// 模块参数**绝不**被猜测写入。
///
/// ## 会话还原（todo 20 消费）
/// 每个节点在写入**之前**先读原值并记录进 [ThermalOverrideRecord]；成功结果
/// [ThermalToggleResult.applied] 即「节点 → 原值」清单，供 todo 20 的
/// `PerfControlSession.revertAll()` 精确还原。任何失败都会尽力把已写节点回滚到
/// 原值，并把尝试回滚的节点记入 [ThermalToggleResult.rolledBack]。
///
/// ## 超时 / 读回对账（继承 todo 10 的事实）
/// 每条命令都由 [PrivilegedShell] 以 `timeout <n> sh -c '…'` 自我限时；Dart 侧
/// 超时**不代表写入被中止**，因此写后**必须**回读节点值比对；不一致即视为失败并
/// 回滚。本层**绝不抛出**，一律返回结构化结果。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

// ==================== 常量 ====================

/// `setThermalEnabled` 的结构化错误码（[ThermalToggleResult.error]）。
abstract final class ThermalToggleError {
  /// 缺少显式确认（`confirmed=false`）→ 零命令、零写入。
  static const String confirmRequired = 'confirm_required';

  /// `perf.tunables` 未枚举到任何可写 thermal 节点 → 零写入。
  static const String unavailable = 'unavailable';

  /// 无法读取目标节点的**原值**（fail-closed：没有原值就无法回滚，故不写）。
  static const String readFailed = 'read_failed';

  /// 写入被拒 / 命令失败（只读节点、SELinux 拒绝等）。
  static const String writeFailed = 'write_failed';

  /// 写后回读值与期望不一致（超时 / 未生效 / 被内核改写）。
  static const String readBackMismatch = 'read_back_mismatch';
}

/// 写入 `thermal_zone*/mode` 的字面值（内核通用约定）。
abstract final class ThermalModeTokens {
  /// 热控降温生效（安全方向）。
  static const String enabled = 'enabled';

  /// 热控降温被关闭（**危险方向**）。
  static const String disabled = 'disabled';
}

// ==================== 结果模型 ====================

/// 一个「节点 → 原值」，供 todo 20 的会话还原精确复原。
class ThermalOverrideRecord {
  const ThermalOverrideRecord({
    required this.path,
    required this.originalValue,
    required this.appliedValue,
  });

  /// sysfs 节点路径（如 `/sys/class/thermal/thermal_zone0/mode`）。
  final String path;

  /// 写入**之前**读到的原值（trim 后；用于还原）。
  final String originalValue;

  /// 本次实际写入的值（[ThermalModeTokens.enabled] / [ThermalModeTokens.disabled]）。
  final String appliedValue;

  @override
  String toString() => 'ThermalOverrideRecord($path: '
      '$originalValue -> $appliedValue)';
}

/// 一次 `setThermalEnabled` 的结构化结果（**绝不抛出**）。
class ThermalToggleResult {
  const ThermalToggleResult({
    required this.ok,
    required this.requestedEnabled,
    this.error,
    this.detail = '',
    this.attempted = const <String>[],
    this.applied = const <ThermalOverrideRecord>[],
    this.rolledBack = const <ThermalOverrideRecord>[],
  });

  /// 是否全部目标节点均已生效。
  final bool ok;

  /// 调用方请求的期望态（`true` = 保持/恢复热控；`false` = 关闭热控）。
  final bool requestedEnabled;

  /// 结构化错误码（见 [ThermalToggleError] / [PrivilegedError]）；成功为 `null`。
  final String? error;

  /// 人类可读说明（证据 / 日志）。
  final String detail;

  /// 本次尝试的目标节点（去重升序）。
  final List<String> attempted;

  /// 成功应用的「节点 → 原值」清单（供 todo 20 还原）。
  final List<ThermalOverrideRecord> applied;

  /// 失败时**已尝试**回滚到原值的节点清单（best-effort 记录）。
  final List<ThermalOverrideRecord> rolledBack;

  /// 可序列化摘要（日志 / 证据）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'requested_enabled': requestedEnabled,
        'error': error,
        'detail': detail,
        'attempted': attempted,
        'applied': <Map<String, String>>[
          for (final r in applied)
            <String, String>{
              'path': r.path,
              'original': r.originalValue,
              'applied': r.appliedValue,
            },
        ],
        'rolled_back': rolledBack.map((r) => r.path).toList(growable: false),
      };

  @override
  String toString() => 'ThermalToggleResult(ok: $ok, '
      'requestedEnabled: $requestedEnabled, error: $error, '
      'applied: ${applied.length}, rolledBack: ${rolledBack.length})';
}

// ==================== 动作 ====================

/// 危险、需确认的热控开关动作。
///
/// 生产：`ThermalToggleController(shell: PrivilegedShell())`。
/// 测试：注入带假 [CommandRunner] 的 [PrivilegedShell] +
/// 直接构造的 [PerfControlCapabilities] / [TunablesReport]，**无需 Shizuku / 真机**。
class ThermalToggleController {
  ThermalToggleController({
    required PrivilegedShell shell,
    PrivilegedInputValidator? validator,
  }) : _shell = shell {
    _validator = validator ?? shell.validator;
  }

  final PrivilegedShell _shell;
  late final PrivilegedInputValidator _validator;

  /// 危险动作主入口。**未显式确认 → 零写入**。
  ///
  /// [enabled] `true` = 写 `enabled`（安全方向）；`false` = 写 `disabled`（危险）。
  /// [confirmed] 必须为 `true`（UI 确认弹层的布尔结果；见 todo 28）。
  /// [tunables] `perf.tunables` 报告（候选节点来源）。
  /// [capabilities] todo 15 的能力图（可写性门禁）。
  Future<ThermalToggleResult> setThermalEnabled(
    bool enabled, {
    required bool confirmed,
    required TunablesReport tunables,
    required PerfControlCapabilities capabilities,
  }) async {
    final value =
        enabled ? ThermalModeTokens.enabled : ThermalModeTokens.disabled;

    // 1) 确认门禁：在任何命令之前拒绝（默认绝不开启 thermal-disable）。
    if (!confirmed) {
      debugPrint('[ThermalToggle] 缺少显式确认 → 拒绝写入（confirm_required）');
      return ThermalToggleResult(
        ok: false,
        requestedEnabled: enabled,
        error: ThermalToggleError.confirmRequired,
        detail: '缺少显式确认（confirmed=false）→ 拒绝任何写入；'
            '热控开关必须经危险确认弹层授权',
      );
    }

    // 2) 写入值防御性校验（token 白名单；正常情况下恒过）。
    final invalidValue = _shell.validateValue(value);
    if (invalidValue != null) {
      return ThermalToggleResult(
        ok: false,
        requestedEnabled: enabled,
        error: invalidValue.error,
        detail: '写入值非法：$value（${invalidValue.output}）→ 零写入',
      );
    }

    // 3) 候选节点仅来自 perf.tunables ∩ 能力图（fail-closed）。
    final targets = _targetNodes(tunables, capabilities);
    if (targets.isEmpty) {
      debugPrint('[ThermalToggle] 无可用 thermal 节点 → unavailable（零写入）');
      return ThermalToggleResult(
        ok: false,
        requestedEnabled: enabled,
        error: ThermalToggleError.unavailable,
        detail: 'perf.tunables 未枚举到任何可写 thermal 节点（类别不可用）→ 零写入',
      );
    }

    // 4) 逐节点：读原值 → 写 → 回读对账；任一失败即回滚已写并终止。
    final applied = <ThermalOverrideRecord>[];

    for (final path in targets) {
      // 4a) 先读原值；读不到原值则无法还原 → 不写（fail-closed）。
      final originalResult = await _shell.read(path: path);
      final original = originalResult.ok ? _extractValue(originalResult.output) : null;
      if (original == null || original.isEmpty) {
        final rolledBack = await _rollbackAll(applied);
        return ThermalToggleResult(
          ok: false,
          requestedEnabled: enabled,
          error: ThermalToggleError.readFailed,
          detail: '无法读取原值：$path（${originalResult.error ?? 'empty'}）→ '
              'fail-closed 不写入，并回滚已写节点',
          attempted: targets,
          applied: applied,
          rolledBack: rolledBack,
        );
      }

      // 4b) 写入目标值。
      final writeResult = await _shell.write(path: path, value: value);
      final record = ThermalOverrideRecord(
        path: path,
        originalValue: original,
        appliedValue: value,
      );
      if (!writeResult.ok) {
        // 写入被拒：尽力把该节点恢复原值 + 回滚已写节点。
        final rolledBack = <ThermalOverrideRecord>[
          if (await _restore(record)) record,
          ...await _rollbackAll(applied),
        ];
        return ThermalToggleResult(
          ok: false,
          requestedEnabled: enabled,
          error: ThermalToggleError.writeFailed,
          detail: '写入被拒：$path（${writeResult.error}）→ 回滚',
          attempted: targets,
          applied: applied,
          rolledBack: rolledBack,
        );
      }

      // 4c) 回读对账（超时 != 写入被中止，必须回读确认）。
      final readBackResult = await _shell.read(path: path);
      final readBack =
          readBackResult.ok ? _extractValue(readBackResult.output) : null;
      if (readBack != value) {
        final rolledBack = <ThermalOverrideRecord>[
          if (await _restore(record)) record,
          ...await _rollbackAll(applied),
        ];
        return ThermalToggleResult(
          ok: false,
          requestedEnabled: enabled,
          error: ThermalToggleError.readBackMismatch,
          detail: '回读不一致：$path 期望 "$value" 实得 "$readBack" → 回滚',
          attempted: targets,
          applied: applied,
          rolledBack: rolledBack,
        );
      }

      applied.add(record);
    }

    debugPrint('[ThermalToggle] 已应用 ${applied.length} 个节点 '
        '(requestedEnabled=$enabled)');
    return ThermalToggleResult(
      ok: true,
      requestedEnabled: enabled,
      detail: '已应用 ${applied.length} 个 thermal 节点；原值已记录供还原',
      attempted: targets,
      applied: applied,
    );
  }

  /// 宽松入口（供 Agent / JSON 调用；todo 21 复用）。
  ///
  /// 只接受真正的 `bool`（JSON `true`/`false`）；字符串、`null`、数字等
  /// **一律 `invalid_arg` 且零写入**（覆盖「malformed bool」对抗类）。
  Future<ThermalToggleResult> setThermalEnabledLoose(
    Object? value, {
    required bool confirmed,
    required TunablesReport tunables,
    required PerfControlCapabilities capabilities,
  }) {
    if (value is! bool) {
      debugPrint('[ThermalToggle] 非法 bool 载荷：$value → invalid_arg（零写入）');
      return Future<ThermalToggleResult>.value(
        ThermalToggleResult(
          ok: false,
          requestedEnabled: false,
          error: PrivilegedError.invalidArg,
          detail: '期望 bool（JSON true/false），收到 '
              '${value.runtimeType} → 零写入',
        ),
      );
    }
    return setThermalEnabled(
      value,
      confirmed: confirmed,
      tunables: tunables,
      capabilities: capabilities,
    );
  }

  // ==================== 内部：候选节点 / 原值 / 回滚 ====================

  /// 目标节点：`perf.tunables.thermalZones[].zone` → `.../<zone>/mode`，
  /// 再与能力图求交集（只有显式 `true` 才算可写）。去重升序。
  List<String> _targetNodes(
    TunablesReport tunables,
    PerfControlCapabilities capabilities,
  ) {
    final nodes = <String>{};
    for (final zone in tunables.thermalZones) {
      if (zone.zone.isEmpty) continue;
      final path = '/sys/class/thermal/${zone.zone}/mode';
      if (_validator.sysfsPathReason(path) != null) continue;
      if (!capabilities.isNodeAvailable(path)) continue;
      nodes.add(path);
    }
    final ordered = nodes.toList()..sort();
    return ordered;
  }

  /// 把节点恢复为原值；成功返回 `true`（失败也代表**已尝试**回滚）。
  Future<bool> _restore(ThermalOverrideRecord record) async {
    final result = await _shell.write(
      path: record.path,
      value: record.originalValue,
    );
    if (!result.ok) {
      debugPrint('[ThermalToggle] 回滚失败：${record.path} '
          '→ ${record.originalValue}（${result.error}）');
    }
    return true;
  }

  /// 逆序回滚全部已应用节点；返回**已尝试**回滚的记录（逆序）。
  Future<List<ThermalOverrideRecord>> _rollbackAll(
    List<ThermalOverrideRecord> applied,
  ) async {
    final rolled = <ThermalOverrideRecord>[];
    for (final record in applied.reversed) {
      if (await _restore(record)) rolled.add(record);
    }
    return rolled;
  }

  /// 从「`<内容>` + 哨兵行」的合并输出中提取文件内容（trim 后；空 → `null`）。
  static String? _extractValue(String output) {
    final idx = output.lastIndexOf(kGstoreSentinel);
    final body = idx >= 0 ? output.substring(0, idx) : output;
    final trimmed = body.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

// ==================== Riverpod 接线（镜像 existing perf providers） ====================

/// 热控开关动作（生产为单例；测试覆盖为注入假 shell 的实例）。
final thermalToggleControllerProvider = Provider<ThermalToggleController>(
  (ref) => ThermalToggleController(shell: PrivilegedShell()),
);
