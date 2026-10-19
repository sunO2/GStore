/// Root 可选能力门（**Shizuku 为主，Root 严格可选**）。
///
/// 计划锁定决策 3：默认走 **Shizuku（shell uid 2000）**；Root **只**用于
/// 「仅 Root 可用」的动作，且**必须**显式门禁 + 显式标签。本仓库目前唯一
/// 的 root-only 动作是 **MIUI 温控直写**（`thermal_disguise` 风格，需 uid 0，
/// 见 `miui_thermal.dart`）。
///
/// ## 为什么单独成层
/// Root 的有无是**运行时**事实，且会决定 UI 上「某些动作是否可见 / 可点」。
/// 把它收敛成一个可注入、可单测的探测器 + 一个纯能力门（[RootCapabilityGate]），
/// 使 UI / 服务层都能以**同一真相**做 gating，而**绝不**把 root 直写设为默认。
///
/// ## FAIL-CLOSED（不可协商）
/// **只有正向信号**（`su -c 'id -u'` 经哨兵判定成功，且输出 uid 为 `0`）才判
/// Root 可用。超时 / 无输出 / 未执行 / 哨兵缺失 / 命令失败 / 抛异常 / uid 非 0
/// → 一律 `rooted: false`。**绝不**因为「`su` 文件存在」就假定可用 —— 那只是
/// 必要非充分信号。
///
/// ## 可测试性
/// [RootDetector] 的 [CommandRunner] 可注入（默认经 [rustShizukuRunner]），
/// 测试注入罐头输出即可，**不需要** Shizuku / 真机 / 真实 Root / 原生插件。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/shell/rust_shizuku_runner.dart';

/// Root 探测命令体：经 Shizuku shell 以 `su` 取当前 uid（`0` 即 Root）。
///
/// 使用单引号包裹 `id -u`，保证 `su -c` 只执行 `id -u`；[PrivilegedShell.buildCommand]
/// 会把内嵌单引号安全转义，且命令体已链哨兵 + 自限时。
const String kRootProbeBody = "su -c 'id -u'";

/// Root 检测结果（**不可变快照**）。
class RootStatus {
  const RootStatus({
    required this.rooted,
    required this.reachable,
    this.uid,
    this.detail = '',
  });

  /// 是否检测到可用 Root（**唯一**决定 root-only 能力开关）。
  final bool rooted;

  /// 探测命令是否可达（runner 是否给出任何输出 / 是否未抛异常）。
  final bool reachable;

  /// `id -u` 原始输出（uid 串；不可达时可能为 `null`）。
  final String? uid;

  /// 人类可读细节（日志 / 证据）。
  final String detail;

  /// 展示串（UI 直接使用；**显式**说明 Shizuku 为主）。
  String get display =>
      rooted ? 'Root 可用（可选）' : 'Root 不可用（Shizuku 为主）';

  /// 未检出 / 不可达的保守默认值。
  static const RootStatus none = RootStatus(rooted: false, reachable: false);

  @override
  String toString() =>
      'RootStatus(rooted: $rooted, reachable: $reachable, uid: $uid)';
}

/// root-only 能力 id 常量（供服务 / UI 统一引用，避免魔法串）。
abstract final class RootOnlyCapability {
  /// MIUI 温控直写（`thermal_disguise` 风格，需 uid 0）。
  static const String miuiThermalDirectWrite = 'miui_thermal_direct_write';

  /// 全部 root-only 能力 id（顺序稳定）。
  static const List<String> all = <String>[miuiThermalDirectWrite];
}

/// Root 检测器（[CommandRunner] 可注入；经 [PrivilegedShell] 传输）。
///
/// 生产：`RootDetector()`（默认经 [rustShizukuRunner]）。
/// 测试：`RootDetector(runner: fake)`，无需真机 / 真实 Root。
class RootDetector {
  RootDetector({
    CommandRunner? runner,
    Duration timeout = const Duration(seconds: 4),
    int inShellTimeoutSeconds = 4,
  }) : _shell = PrivilegedShell(
          runner: runner ?? rustShizukuRunner,
          timeout: timeout,
          inShellTimeoutSeconds: inShellTimeoutSeconds,
        );

  final PrivilegedShell _shell;

  RootStatus? _cached;

  /// 会话缓存（未探测时为 `null`）。
  RootStatus? get cached => _cached;

  /// 探测 Root；[refresh] 为假（默认）时复用会话缓存。
  ///
  /// **绝不抛出**：任何失败一律降级为 `rooted: false`。
  Future<RootStatus> detect({bool refresh = false}) async {
    final cached = _cached;
    if (!refresh && cached != null) return cached;
    final result = await _shell.run(_shell.buildCommand(kRootProbeBody));
    final status = _interpret(result);
    _cached = status;
    return status;
  }

  /// 解释一次探测结果（fail-closed）。
  static RootStatus _interpret(PrivilegedResult result) {
    final reachable = result.error != PrivilegedError.noOutput &&
        result.error != PrivilegedError.executionError;
    final body = _body(result);
    final rooted = result.ok && _isRootUid(body);
    if (!rooted) {
      debugPrint('[RootStatus] 未检测到 Root（reachable=$reachable）→ 走 Shizuku');
    }
    return RootStatus(
      rooted: rooted,
      reachable: reachable,
      uid: body.isEmpty ? null : body,
      detail: rooted
          ? 'su 可用且 uid=0（Root 可选能力已开启）'
          : '未检测到 Root；默认走 Shizuku（uid 2000）',
    );
  }

  /// 输出首行是否为 Root uid（`0` 或 `uid=0…`）。
  static bool _isRootUid(String body) {
    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      return trimmed == '0' || trimmed.startsWith('uid=0');
    }
    return false;
  }

  /// 去掉尾部哨兵行、trim 后的命令体内容。
  static String _body(PrivilegedResult result) {
    final raw = result.output;
    final idx = raw.lastIndexOf(kGstoreSentinel);
    final sliced = idx >= 0 ? raw.substring(0, idx) : raw;
    return sliced.trim();
  }
}

/// Root-only 能力门（**纯函数**，给定 [RootStatus] 决定可用性）。
///
/// * Shizuku 主路径动作**恒可用**（[shizukuPrimaryAvailable]），不受 Root 影响；
/// * root-only 动作**仅**在 [RootStatus.rooted] 为真时可用，否则必须**隐藏 /
///   禁用**并给出**显式原因**（绝不静默 no-op）。
class RootCapabilityGate {
  const RootCapabilityGate(this.status);

  /// 当前 Root 状态。
  final RootStatus status;

  /// Shizuku 主路径是否可用（**恒为真**；Root 有无不影响）。
  bool get shizukuPrimaryAvailable => true;

  /// 指定 root-only 能力是否可用。
  bool isAvailable(String capabilityId) =>
      RootOnlyCapability.all.contains(capabilityId) && status.rooted;

  /// 不可用原因（可用时为 `null`）；用于 UI 显式标签 / tooltip。
  String? unavailableReason(String capabilityId) => isAvailable(capabilityId)
      ? null
      : '需要 Root（当前未检测到）；请使用 Shizuku 主路径';

  @override
  String toString() =>
      'RootCapabilityGate(rooted: ${status.rooted}, '
      'shizukuPrimary: $shizukuPrimaryAvailable)';
}

// ==================== Riverpod 接线 ====================

/// Root 检测器（生产为单例；测试覆盖为注入假 runner 的实例）。
final rootDetectorProvider = Provider<RootDetector>((ref) => RootDetector());

/// 最近一次 Root 状态（`null` = 尚未探测）；UI 据此 gating root-only 动作。
final rootStatusProvider = FutureProvider<RootStatus>(
  (ref) => ref.read(rootDetectorProvider).detect(),
);
