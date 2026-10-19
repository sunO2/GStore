/// 屏幕刷新率控制动作：`settings get/put system min_refresh_rate` /
/// `peak_refresh_rate`（**经 Shizuku shell，无 root**）。
///
/// WS-B（`scene8-port-fps-refresh` 计划）新增。复刻 Scene 8 的「刷新率档位」
/// 能力（`RefreshRateManager` / `RefreshOptions`），但落在 GStore 已有的
/// [PrivilegedShell] 传输层上，采用**标准 Android 机制**：
///
/// * 读当前：`settings get system min_refresh_rate` / `peak_refresh_rate`；
/// * 可选档位：解析 `dumpsys display` 的 `refreshRate=` / `fps=` 值，
///   解析失败退化 [fallbackLevels]（60/90/120）；
/// * 设置：`settings put system min_refresh_rate <n>` +
///   `settings put system peak_refresh_rate <n>`（经 [PrivilegedShell]，自限时 +
///   `&&`/`||` 哨兵），写后 `settings get` **回读校验**。
///
/// ## 不可协商
/// * **不写 root sysfs**：仅经 shell(uid 2000) 的 `settings` / `dumpsys`。
/// * **写而不回读不算成功**：回读值不匹配 → [RefreshRateStatus.readbackMismatch]。
/// * **绝不注入**：数值由 Dart 侧 int → 字符串拼装，并再过
///   [PrivilegedInputValidator.numericReason]（防御纵深）。
/// * **绝不抛出**：读取 / 写入失败一律返回结构化结果。
///
/// ## 可测试性
/// 经 [PrivilegedShell] 的可注入 [CommandRunner]：测试注入罐头输出，
/// **无需 Shizuku / 真机 / 原生插件**。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:gstore/core/perf/privileged_shell.dart';

/// [RefreshRateResult.status] 的稳定取值（供日志 / 报告 / 测试断言）。
abstract final class RefreshRateStatus {
  /// 已写入且回读确认。
  static const String ok = 'ok';

  /// 入参非法（超出范围 / min>peak / 非整数）—— **零写入**。
  static const String invalidArg = 'invalid_arg';

  /// Shizuku 不可用 / 读取被拒 —— **零写入**（fail-closed）。
  static const String unavailable = 'unavailable';

  /// 写入被拒（哨兵 `err=` / 无哨兵 / 超时 / 无输出）。
  static const String writeDenied = 'write_denied';

  /// 写入「成功」但回读值不匹配 —— **不算成功**。
  static const String readbackMismatch = 'readback_mismatch';
}

/// 当前刷新率状态快照（读取结果）。
class RefreshRateState {
  const RefreshRateState({
    required this.available,
    this.min,
    this.peak,
    this.levels = const <int>[],
    this.reason,
  });

  /// 是否成功读取（`settings get` 可执行）。为 `false` 时其余字段无意义。
  final bool available;

  /// 当前 `min_refresh_rate`（Hz）；键未设置为 `null`（系统默认）。
  final int? min;

  /// 当前 `peak_refresh_rate`（Hz）；键未设置为 `null`（系统默认）。
  final int? peak;

  /// 可用档位（Hz，升序去重）。
  final List<int> levels;

  /// 不可用原因（[available] 为 `false` 时给出）。
  final String? reason;

  /// fail-closed 的不可用快照。
  factory RefreshRateState.unavailable(String reason) =>
      RefreshRateState(available: false, reason: reason);

  @override
  String toString() => 'RefreshRateState(available: $available, min: $min, '
      'peak: $peak, levels: $levels, reason: $reason)';
}

/// 一次 [RefreshRateController.apply] 的结构化结果（**绝不抛出**）。
class RefreshRateResult {
  const RefreshRateResult({
    required this.ok,
    required this.status,
    this.min,
    this.peak,
    this.message,
  });

  /// 是否成功（写入 + 回读确认）。
  final bool ok;

  /// 稳定状态码（见 [RefreshRateStatus]）。
  final String status;

  /// 生效的 min（Hz）；失败时为 `null`。
  final int? min;

  /// 生效的 peak（Hz）；失败时为 `null`。
  final int? peak;

  /// 人类可读说明。
  final String? message;

  @override
  String toString() => 'RefreshRateResult(ok: $ok, status: $status, '
      'min: $min, peak: $peak, message: $message)';
}

/// 屏幕刷新率控制器（读取 + 应用）。
///
/// 生产：`RefreshRateController(shell: PrivilegedShell())`。
/// 测试：注入带假 [CommandRunner] 的 [PrivilegedShell]，**无需 Shizuku / 真机**。
class RefreshRateController {
  RefreshRateController({
    required PrivilegedShell shell,
    Future<List<int>> Function()? levelsProvider,
  })  : _shell = shell,
        _levelsProvider = levelsProvider;

  final PrivilegedShell _shell;

  /// 可选档位来源（生产：Rust JNI `DeviceStateChannel` 的支持显示模式）；
  /// 返回空 / 抛异常时回退 `dumpsys display` 解析。
  final Future<List<int>> Function()? _levelsProvider;

  /// `min_refresh_rate` settings 键。
  static const String minKey = 'min_refresh_rate';

  /// `peak_refresh_rate` settings 键。
  static const String peakKey = 'peak_refresh_rate';

  /// 档位解析失败时的退化档位。
  static const List<int> fallbackLevels = <int>[60, 90, 120];

  /// 合法刷新率下界（Hz）。
  static const int minHz = 30;

  /// 合法刷新率上界（Hz）。
  static const int maxHz = 240;

  /// 读取当前 min/peak 与可用档位。
  ///
  /// 任一 `settings get` 失败（Shizuku 未授权 / 被拒 / 无输出）→
  /// [RefreshRateState.unavailable]，调用方据此禁用控件。
  Future<RefreshRateState> read() async {
    final minResult = await _shell
        .run(_shell.buildCommand('settings get system $minKey'));
    final peakResult = await _shell
        .run(_shell.buildCommand('settings get system $peakKey'));
    if (!minResult.ok || !peakResult.ok) {
      return RefreshRateState.unavailable(
        '读取失败（Shizuku 不可用或 settings 被拒）',
      );
    }
    final min = parseHz(firstValue(minResult.output));
    final peak = parseHz(firstValue(peakResult.output));
    final levels = await _readLevels();
    final merged = <int>{
      ...levels,
      if (min != null) min,
      if (peak != null) peak,
    }.toList()
      ..sort();
    return RefreshRateState(
      available: true,
      min: min,
      peak: peak,
      levels: merged.isEmpty ? fallbackLevels : merged,
    );
  }

  /// 解析可用档位：优先注入的 [levelsProvider]（Rust JNI 显示模式）；为空 /
  /// 失败时回退 `dumpsys display`（best-effort），仍失败退化 [fallbackLevels]。
  Future<List<int>> _readLevels() async {
    final provider = _levelsProvider;
    if (provider != null) {
      try {
        final levels = (await provider())
            .where((hz) => hz >= minHz && hz <= maxHz)
            .toSet()
            .toList()
          ..sort();
        if (levels.isNotEmpty) return levels;
      } catch (error) {
        debugPrint('[RefreshRateController] levelsProvider 失败（回退 dumpsys）: $error');
      }
    }
    final result = await _shell.run(_shell.buildCommand('dumpsys display'));
    if (!result.ok) return fallbackLevels;
    final parsed = parseRefreshLevels(result.output);
    return parsed.isEmpty ? fallbackLevels : parsed;
  }

  /// 写入 min/peak 并回读校验。
  ///
  /// [min] / [peak] 为目标刷新率（Hz）。校验在任何命令之前完成；写入后立即
  /// `settings get` 回读，值不匹配即返回 [RefreshRateStatus.readbackMismatch]
  /// （**不假成功**）。**绝不抛出**。
  Future<RefreshRateResult> apply({required int min, required int peak}) async {
    if (min < minHz || min > maxHz || peak < minHz || peak > maxHz) {
      return const RefreshRateResult(
        ok: false,
        status: RefreshRateStatus.invalidArg,
        message: '刷新率需在 $minHz–$maxHz Hz 之间',
      );
    }
    if (min > peak) {
      return const RefreshRateResult(
        ok: false,
        status: RefreshRateStatus.invalidArg,
        message: 'min 不能大于 peak',
      );
    }
    // 防御纵深：数值再过一次共享校验器（绝不把任意 token 交给 shell）。
    if (_shell.validateValue('$min', numeric: true) != null ||
        _shell.validateValue('$peak', numeric: true) != null) {
      return const RefreshRateResult(
        ok: false,
        status: RefreshRateStatus.invalidArg,
        message: '非法数值',
      );
    }

    final writeMin = await _shell
        .run(_shell.buildCommand('settings put system $minKey $min'));
    if (!writeMin.ok) {
      return RefreshRateResult(
        ok: false,
        status: RefreshRateStatus.writeDenied,
        message: '写入 $minKey 被拒（${writeMin.error}）',
      );
    }
    final writePeak = await _shell
        .run(_shell.buildCommand('settings put system $peakKey $peak'));
    if (!writePeak.ok) {
      return RefreshRateResult(
        ok: false,
        status: RefreshRateStatus.writeDenied,
        message: '写入 $peakKey 被拒（${writePeak.error}）',
      );
    }

    // 回读校验：写而不回读不算成功。
    final readMin = await _readInt(minKey);
    final readPeak = await _readInt(peakKey);
    if (readMin != min || readPeak != peak) {
      return RefreshRateResult(
        ok: false,
        status: RefreshRateStatus.readbackMismatch,
        message: '回读不匹配：期望 min=$min peak=$peak，'
            '实得 min=$readMin peak=$readPeak',
      );
    }
    return RefreshRateResult(
      ok: true,
      status: RefreshRateStatus.ok,
      min: min,
      peak: peak,
      message: '已写入并回读确认 min=$min peak=$peak',
    );
  }

  /// 读取单个键的整数值；不可执行时返回 `null`。
  Future<int?> _readInt(String key) async {
    final result = await _shell.run(_shell.buildCommand('settings get system $key'));
    if (!result.ok) return null;
    return parseHz(firstValue(result.output));
  }

  /// 从合并输出中取**首个非哨兵非空行**（`settings get` 的值行）。
  static String? firstValue(String output) {
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.contains(kGstoreSentinel)) continue;
      return trimmed;
    }
    return null;
  }

  /// 把 `settings get` 的值行解析为 Hz；`null` / 非数值 / 空 → `null`。
  static int? parseHz(String? raw) {
    if (raw == null) return null;
    final value = raw.trim();
    if (value.isEmpty || value == 'null') return null;
    final asDouble = double.tryParse(value);
    if (asDouble != null) return asDouble.round();
    return int.tryParse(value);
  }

  /// 从 `dumpsys display` 输出解析刷新率档位（升序去重）。
  ///
  /// 识别 `refreshRate=<n>`、`fps=<n>`、`<n> fps`、`<n>Hz`；仅保留
  /// [[minHz], [maxHz]] 范围内的整数值。无匹配 → 空列表（调用方退化）。
  static List<int> parseRefreshLevels(String output) {
    final levels = <int>{};
    final patterns = <RegExp>[
      RegExp(r'refreshRate\s*=\s*([0-9]+(?:\.[0-9]+)?)'),
      RegExp(r'fps\s*=\s*([0-9]+(?:\.[0-9]+)?)'),
      RegExp(r'([0-9]+(?:\.[0-9]+)?)\s*fps'),
      RegExp(r'([0-9]+(?:\.[0-9]+)?)\s*Hz'),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(output)) {
        final parsed = double.tryParse(match.group(1) ?? '');
        if (parsed == null) continue;
        final hz = parsed.round();
        if (hz >= minHz && hz <= maxHz) levels.add(hz);
      }
    }
    return levels.toList()..sort();
  }
}
