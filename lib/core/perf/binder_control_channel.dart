/// Binder 命令控制通道：sysfs 不可写时的**回退调优基质**（shell uid 2000）。
///
/// 本层只驱动**探测（todo 15）已确认可用**的 Binder 命令杠杆，绝不自作主张：
///
/// * [PerfControlLevers.powerFixedPerf] → `cmd power set-fixed-performance-mode-enabled true|false`
/// * [PerfControlLevers.thermal] → `cmd thermal`（状态读取）+ `cmd thermal reset` +
///   `cmd thermal override-status <zone> <status>`（AOSP 文档化子命令）
/// * [PerfControlLevers.settings] → `settings put global <key> <value>`
/// * [PerfControlLevers.deviceConfig] → `device_config put <namespace> <key> <value>`
/// * [PerfControlLevers.amStandbyBucket] → `am set-standby-bucket <pkg> <bucket>`
///
/// ## 硬性纪律（不可协商）
/// 1. **门禁**：每条杠杆执行前先查 [PerfControlCapabilities.isLeverAvailable]；
///    不可用 → 直接返回结构化 `unavailable`，**零命令执行**（绝不对未探测的杠杆拼命令）。
/// 2. **校验**：包名走 `PrivilegedInputValidator.packagePattern`；数值必须是整数；
///    布尔规范化为 `true|false`；其余 token 走危险字符检查。任一项非法 →
///    `invalid_arg`，**零命令执行**。
/// 3. **哨兵**：所有命令经 [PrivilegedShell.buildCommand] 自我限时（`timeout <n> sh -c …`）
///    并链上 `&&/||` 哨兵；**只有** [PrivilegedResult.ok]（哨兵 `ok=1`）才算成功，
///    绝不把「无哨兵 / err= / 超时 / 无输出」当成成功。
/// 4. **记录原值**：有状态杠杆在写入前**尽力**读取原值（`settings get` /
///    `device_config get` / `am get-standby-bucket`），随结果 `original` 返回，
///    供 todo 20 的会话 / 回滚登记表复用；本层**不实现**回滚登记表。
///
/// ## 本层不做的事
/// * 不写 sysfs（由 todos 16-19 负责）；不实现会话 / 回滚登记（todo 20）。
/// * 不使用探测未确认的**厂商专有** Binder 命令。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/privileged_shell.dart';

/// Binder 控制通道的结构化错误码（扩展 [PrivilegedError]）。
abstract final class BinderControlError {
  /// 探测（todo 15）未将该杠杆标记为可用 → 不执行任何命令。
  static const String unavailable = 'unavailable';
}

/// 一次 Binder 杠杆动作的结构化结果。
///
/// 字段固定为 `{ok, lever, command, error, detail, original, raw}`。
/// [command] 仅在**真正下发**时非空；`unavailable` / `invalid_arg` 时必为 `null`，
/// 从而可从结果直接断言「零调用」。
class BinderControlResult {
  const BinderControlResult({
    required this.ok,
    required this.lever,
    this.command,
    this.error,
    this.detail,
    this.original,
    this.raw,
  });

  /// 是否成功（哨兵 `ok=1`）。
  final bool ok;

  /// 杠杆 id（见 [PerfControlLevers]）。
  final String lever;

  /// 实际下发的完整命令（自限时 + 哨兵）；未下发时为 `null`。
  final String? command;

  /// 结构化错误码（[PrivilegedError] / [BinderControlError]）；成功时为 `null`。
  final String? error;

  /// 可读的失败细节（校验原因 / 原值读取说明）。
  final String? detail;

  /// 写入前的原值（有状态杠杆尽力读取；读取失败为 `null`）。
  final String? original;

  /// 底层 [PrivilegedResult]（首次执行时存在）。
  final PrivilegedResult? raw;

  /// 探测未标记可用 → 结构化 `unavailable`（**零命令**）。
  factory BinderControlResult.unavailable(String lever) => BinderControlResult(
        ok: false,
        lever: lever,
        error: BinderControlError.unavailable,
      );

  /// 入参非法 → `invalid_arg`（**零命令**）。
  factory BinderControlResult.invalidArg(String lever, String detail) =>
      BinderControlResult(
        ok: false,
        lever: lever,
        error: PrivilegedError.invalidArg,
        detail: detail,
      );

  /// 由一次真实执行构造（成败完全由哨兵决定）。
  factory BinderControlResult.fromPrivileged({
    required String lever,
    required String command,
    required PrivilegedResult raw,
    String? original,
    String? detail,
  }) =>
      BinderControlResult(
        ok: raw.ok,
        lever: lever,
        command: command,
        error: raw.ok ? null : raw.error,
        detail: raw.ok ? detail : (detail ?? raw.error),
        original: original,
        raw: raw,
      );

  @override
  String toString() => 'BinderControlResult(ok: $ok, lever: $lever, '
      'error: $error, original: $original)';
}

/// Binder 命令控制通道。
///
/// 生产：`BinderControlChannel(shell: PrivilegedShell(), capabilities: caps)`，
/// 其中 `caps` 来自 [PerfCapabilityProbe]（todo 15）。
/// 测试：注入带假 [CommandRunner] 的 [PrivilegedShell] + 手搓
/// [PerfControlCapabilities]，**无需 Shizuku / 真机 / 原生插件**。
class BinderControlChannel {
  BinderControlChannel({
    required PrivilegedShell shell,
    required PerfControlCapabilities capabilities,
  })  : _shell = shell,
        _capabilities = capabilities;

  final PrivilegedShell _shell;
  final PerfControlCapabilities _capabilities;

  /// `cmd thermal override-status` 允许的状态值（AOSP `ThermalManagerService`）。
  static const Set<String> kThermalStatuses = <String>{
    'none',
    'light',
    'moderate',
    'severe',
    'critical',
    'emergency',
    'shutdown',
  };

  /// 热区 token 合法形状（如 `thermal_zone0` / `0`）。
  static final RegExp _zonePattern = RegExp(r'^[A-Za-z0-9_.:-]+$');

  /// device_config namespace / key 合法形状。
  static final RegExp _configTokenPattern = RegExp(r'^[A-Za-z0-9_.:-]+$');

  /// 该杠杆是否被探测标记为可用（门禁）。
  bool isLeverAvailable(String leverId) =>
      _capabilities.isLeverAvailable(leverId);

  // ==================== 杠杆 1：cmd power 固定性能模式 ====================

  /// `cmd power set-fixed-performance-mode-enabled true|false`。
  ///
  /// 无状态读取子命令未经探测确认 → [original] 始终为 `null`（不做回读猜测）。
  Future<BinderControlResult> setFixedPerformanceMode({
    required bool enabled,
  }) async {
    const lever = PerfControlLevers.powerFixedPerf;
    if (!isLeverAvailable(lever)) {
      return BinderControlResult.unavailable(lever);
    }
    final value = enabled ? 'true' : 'false';
    return _apply(
      lever,
      'cmd power set-fixed-performance-mode-enabled $value',
    );
  }

  // ==================== 杠杆 2：cmd thermal ====================

  /// `cmd thermal`（只读状态）。
  Future<BinderControlResult> thermalStatus() async {
    const lever = PerfControlLevers.thermal;
    if (!isLeverAvailable(lever)) {
      return BinderControlResult.unavailable(lever);
    }
    return _apply(lever, 'cmd thermal');
  }

  /// `cmd thermal reset`（清除全部 override，恢复默认）。
  Future<BinderControlResult> thermalReset() async {
    const lever = PerfControlLevers.thermal;
    if (!isLeverAvailable(lever)) {
      return BinderControlResult.unavailable(lever);
    }
    return _apply(lever, 'cmd thermal reset');
  }

  /// `cmd thermal override-status <zone> <status>`（AOSP 文档化子命令）。
  ///
  /// 仅当探测把 `cmd thermal` 标记为可用时才下发。
  Future<BinderControlResult> thermalOverrideZoneStatus({
    required String zone,
    required String status,
  }) async {
    const lever = PerfControlLevers.thermal;
    if (!isLeverAvailable(lever)) {
      return BinderControlResult.unavailable(lever);
    }
    final zoneReason = _shapeReason(zone, _zonePattern, 'zone');
    if (zoneReason != null) {
      return BinderControlResult.invalidArg(lever, zoneReason);
    }
    final normalized = status.toLowerCase();
    if (!kThermalStatuses.contains(normalized)) {
      return BinderControlResult.invalidArg(lever, 'status_not_allowed');
    }
    return _apply(
      lever,
      'cmd thermal override-status $zone $normalized',
    );
  }

  // ==================== 杠杆 3：settings ====================

  /// `settings put global <key> <value>`（有状态：先读 `settings get global <key>`）。
  Future<BinderControlResult> putGlobalSetting({
    required String key,
    required String value,
  }) async {
    const lever = PerfControlLevers.settings;
    if (!isLeverAvailable(lever)) {
      return BinderControlResult.unavailable(lever);
    }
    final invalid = _shell.validateValue(key) ?? _shell.validateValue(value);
    if (invalid != null) {
      return BinderControlResult.invalidArg(lever, invalid.output);
    }
    final original = await _readOriginal(lever, 'settings get global $key');
    return _apply(
      lever,
      'settings put global $key $value',
      original: original,
    );
  }

  // ==================== 杠杆 4：device_config ====================

  /// `device_config put <namespace> <key> <value>`（有状态）。
  Future<BinderControlResult> putDeviceConfig({
    required String namespace,
    required String key,
    required String value,
  }) async {
    const lever = PerfControlLevers.deviceConfig;
    if (!isLeverAvailable(lever)) {
      return BinderControlResult.unavailable(lever);
    }
    final reason = _shapeReason(namespace, _configTokenPattern, 'namespace') ??
        _shapeReason(key, _configTokenPattern, 'key') ??
        _shell.validateValue(value)?.output;
    if (reason != null) {
      return BinderControlResult.invalidArg(lever, reason);
    }
    final original = await _readOriginal(
      lever,
      'device_config get $namespace $key',
    );
    return _apply(
      lever,
      'device_config put $namespace $key $value',
      original: original,
    );
  }

  // ==================== 杠杆 5：am set-standby-bucket ====================

  /// `am set-standby-bucket <pkg> <bucket>`（有状态）。
  Future<BinderControlResult> setStandbyBucket({
    required String package,
    required int bucket,
  }) async {
    const lever = PerfControlLevers.amStandbyBucket;
    if (!isLeverAvailable(lever)) {
      return BinderControlResult.unavailable(lever);
    }
    final invalid =
        _shell.validatePackage(package) ?? _shell.validateValue('$bucket', numeric: true);
    if (invalid != null) {
      return BinderControlResult.invalidArg(lever, invalid.output);
    }
    final original = await _readOriginal(
      lever,
      'am get-standby-bucket $package',
    );
    return _apply(
      lever,
      'am set-standby-bucket $package $bucket',
      original: original,
    );
  }

  // ==================== 内部原语 ====================

  /// 校验 token 形状：空 / 危险字符 / 形状不符 → 返回原因字符串。
  String? _shapeReason(String token, RegExp pattern, String label) {
    if (token.isEmpty) return '${label}_empty';
    if (PrivilegedInputValidator.hasUnsafeChar(token)) {
      return '${label}_unsafe_char';
    }
    if (!pattern.hasMatch(token)) return '${label}_bad_shape';
    return null;
  }

  /// 尽力读取有状态杠杆的原值（供 todo 20 回滚；读取失败返回 `null`）。
  ///
  /// 读取仍**必须**经门禁（本方法只在门禁通过后被调用）与哨兵校验；
  /// 任一步失败都只返回 `null`，绝不影响后续写入的成败判定。
  Future<String?> _readOriginal(String lever, String body) async {
    final result = await _shell.run(_shell.buildCommand(body));
    if (!result.ok) return null;
    return _extractValue(result.output);
  }

  /// 从合并输出中取**最后一条**非哨兵非空行作为值；无则为 `null`。
  static String? _extractValue(String output) {
    final lines = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.contains(kGstoreSentinel))
        .toList(growable: false);
    if (lines.isEmpty) return null;
    return lines.last;
  }

  /// 拼装（自限时 + 哨兵）并执行一条杠杆命令；成败完全由哨兵决定。
  Future<BinderControlResult> _apply(
    String lever,
    String body, {
    String? original,
  }) async {
    final command = _shell.buildCommand(body);
    final raw = await _shell.run(command);
    if (!raw.ok) {
      debugPrint('[BinderControlChannel] $lever 未成功（${raw.error}）: $command');
    }
    return BinderControlResult.fromPrivileged(
      lever: lever,
      command: command,
      raw: raw,
      original: original,
    );
  }
}
