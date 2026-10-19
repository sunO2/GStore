/// Shizuku 特权 shell **传输层**（transport only —— 本文件**不写任何 sysfs 节点**）。
///
/// 职责只有三件事：把一条特权命令**安全地拼装**出来、经可注入的 [CommandRunner]
/// 执行、再把结果**结构化**地解析回调用方。真正的写节点 / 读节点动作由后续层
/// （调优 Todo）用本层提供的 builder 发起；本层自身不触碰 `/sys`。
///
/// ## 为什么需要这一层（先读，否则会误用）
/// * 默认执行器 [rustShizukuRunner] 底层是 Rust 统一门面（JNI → Kotlin
///   `ShizukuExecBridge.exec` → `Shizuku.newProcess(["sh","-c",cmd])`，复刻
///   `ShizukuShell.kt` 语义）：**stdout 与 stderr 被合并**成一个字符串，
///   **没有任何退出码返回**（只 `waitFor()` 后返回文本）。
///   因此本库**无法**得知命令的真实退出码；[PrivilegedResult.exitHint] 只是
///   shell 内部 `$?` 的**提示值**，不是进程退出码 —— 不要把它当成硬性退出码。
/// * 底层是**阻塞式** `waitFor()`，Dart 侧 `.timeout()` **无法取消**已启动的原生进程。
///   所以「Dart 侧超时」**不等于**「写入被中止」：命令可能仍在原生侧继续跑，
///   或已经写入但输出未回传。**超时后必须重新读取节点状态来对账（reconcile），
///   不能据此判定写入失败或成功。**
/// * 底层是**阻塞式** `waitFor()`：一条卡死的命令会**阻塞后续命令**。因此**每一条**
///   特权命令都必须在 **shell 内部自我限时**：前缀 `timeout <n> sh -c '…'`
///   （toybox `timeout`），保证原生进程一定会退出。Dart 侧超时只用于「不再等待」，
///   绝不能依靠它来终止已启动的原生进程。
///
/// ## 成功判定（哨兵）
/// 命令体 **必须**以 `&&`/`||` 链上哨兵，使哨兵**只在成功时**打印 `ok=1`：
/// ```sh
/// <body> && echo GSTORE_RESULT ok=1 || echo GSTORE_RESULT err=$?
/// ```
/// **绝不**使用 `; echo … ok=1` —— 那种写法在写入被拒（只读节点 / SELinux 拒绝）
/// 时仍会无条件打印 `ok=1`，造成**假成功**。解析时取**最后一行**哨兵
/// （先例：`android/.../CaInstaller.kt:151,175,381`）。
///
/// ## 可测试性
/// [CommandRunner] 可注入（默认经 [rustShizukuRunner]）；测试注入罐头输出即可，
/// **不需要** Shizuku / 真机 / Rust。全部执行入口**绝不抛出**，一律返回
/// 结构化失败。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/shell/rust_shizuku_runner.dart';

/// 执行一条 shell 命令，返回 stdout+stderr 合并文本；未执行 / 失败返回 `null`。
///
/// 生产实现经 [rustShizukuRunner]（Rust 门面 → `sh -c`）；测试注入罐头输出即可脱离设备。
typedef CommandRunner = Future<String?> Function(String command);

/// 哨兵标记：每条特权命令尾部必须回显一次，供 [PrivilegedResult] 判定成败。
const String kGstoreSentinel = 'GSTORE_RESULT';

/// 结构化错误码（[PrivilegedResult.error] 的取值）。
abstract final class PrivilegedError {
  /// 入参非法（路径不在白名单 / 包名不匹配 / 数值非整数 / 含危险 token）。
  static const String invalidArg = 'invalid_arg';

  /// Dart 侧等待超时（**不代表写入被中止**，需回读对账）。
  static const String timeout = 'timeout';

  /// runner 返回 `null`（命令未执行 / 无输出）。
  static const String noOutput = 'no_output';

  /// 输出里找不到哨兵行。
  static const String sentinelMissing = 'sentinel_missing';

  /// 哨兵行形状无法识别。
  static const String sentinelMalformed = 'sentinel_malformed';

  /// 哨兵报告命令失败（`err=` 分支）。
  static const String commandFailed = 'command_failed';

  /// runner 抛异常。
  static const String executionError = 'execution_error';
}

/// 一次特权命令的结构化结果。
///
/// 字段固定为 `{ok, output, error, exitHint}`。**没有真实退出码** ——
/// [exitHint] 是 shell 内 `$?` 的提示值（仅当哨兵走 `||` 分支时存在），
/// 不是进程退出码。
class PrivilegedResult {
  const PrivilegedResult({
    required this.ok,
    required this.output,
    this.error,
    this.exitHint,
  });

  /// 是否成功（哨兵 `ok=1` 且为最后一条哨兵行）。
  final bool ok;

  /// 原始输出（stdout+stderr 合并，未经裁剪）。
  final String output;

  /// 结构化错误码（见 [PrivilegedError]）；成功时为 `null`。
  final String? error;

  /// shell `$?` 提示值（**不是**进程退出码）；无则为 `null`。
  final int? exitHint;

  /// 入参非法（不执行任何命令）。[detail] 仅作可读提示，不影响判定。
  factory PrivilegedResult.invalidArg(String detail) => PrivilegedResult(
        ok: false,
        output: detail,
        error: PrivilegedError.invalidArg,
        exitHint: null,
      );

  /// 从合并输出解析：取**最后一条**哨兵行判定成败。
  ///
  /// * `GSTORE_RESULT ok=1` → `ok:true`；
  /// * `GSTORE_RESULT err=<n>` → `ok:false`，[exitHint] = n；
  /// * 无哨兵 → `sentinel_missing`；形状异常 → `sentinel_malformed`。
  factory PrivilegedResult.fromOutput(String raw) {
    final lines = raw.split('\n');
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i].trim();
      final idx = line.indexOf(kGstoreSentinel);
      if (idx < 0) continue;
      final tail = line.substring(idx + kGstoreSentinel.length).trim();
      if (tail.startsWith('ok=1')) {
        return PrivilegedResult(ok: true, output: raw, exitHint: null);
      }
      if (tail.startsWith('err=')) {
        final value = tail.substring('err='.length).trim().split(RegExp(r'\s+'));
        final hint = value.isEmpty ? null : int.tryParse(value.first);
        return PrivilegedResult(
          ok: false,
          output: raw,
          error: PrivilegedError.commandFailed,
          exitHint: hint,
        );
      }
      return PrivilegedResult(
        ok: false,
        output: raw,
        error: PrivilegedError.sentinelMalformed,
      );
    }
    return PrivilegedResult(
      ok: false,
      output: raw,
      error: PrivilegedError.sentinelMissing,
    );
  }

  @override
  String toString() =>
      'PrivilegedResult(ok: $ok, error: $error, exitHint: $exitHint)';
}

/// 默认 sysfs 白名单（`perf.tunables` 风格）。
///
/// 采用**精确路径 + `*` 单段通配**（`*` 不跨 `/`）。Todo 11 产出
/// `perf.tunables` 枚举后应把此表收敛为该枚举的精确集合；本层允许调用方
/// 通过 [PrivilegedShell.validator] / 构造函数传入自定义白名单，后续 Todo
/// （16-19、37）可复用并收紧。
const List<String> kDefaultSysfsAllowlist = <String>[
  '/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor',
  '/sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq',
  '/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq',
  '/sys/devices/system/cpu/cpufreq/policy*/scaling_governor',
  '/sys/devices/system/cpu/cpufreq/policy*/scaling_min_freq',
  '/sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq',
  '/sys/devices/system/cpu/*/cpufreq/scaling_governor',
  '/sys/devices/system/cpu/*/cpufreq/scaling_min_freq',
  '/sys/devices/system/cpu/*/cpufreq/scaling_max_freq',
  '/sys/class/thermal/thermal_zone*/mode',
  '/sys/class/thermal/thermal_zone*/policy',
  '/sys/class/thermal/thermal_zone*/temp',
  '/sys/class/kgsl/kgsl-3d0/min_gpuclk',
  '/sys/class/kgsl/kgsl-3d0/max_gpuclk',
  '/sys/class/kgsl/kgsl-3d0/devfreq/min_freq',
  '/sys/class/kgsl/kgsl-3d0/devfreq/max_freq',
  '/sys/class/devfreq/*/governor',
  '/sys/class/devfreq/*/min_freq',
  '/sys/class/devfreq/*/max_freq',
  '/dev/cpuset/*/cpus',
  '/dev/cpuset/*/mems',
];

/// 共享入参校验器：**每个调用方都必须先过这里**。
///
/// * sysfs 路径 → 必须先过危险 token 检查，再**精确匹配**白名单（`*` 单段通配）；
/// * 包名 → `^[a-zA-Z][a-zA-Z0-9_.]+$`；
/// * 数值 → 必须能解析为整数；
/// * 任何 token 含 `; | & $ \`（反引号）或换行/回车，以及空白、引号、重定向
///   等危险字符 → 一律拒绝（返回 [PrivilegedError.invalidArg]）。
class PrivilegedInputValidator {
  PrivilegedInputValidator({List<String>? sysfsPatterns})
      : patterns = List<String>.unmodifiable(
          sysfsPatterns ?? kDefaultSysfsAllowlist,
        ),
        _matchers = (sysfsPatterns ?? kDefaultSysfsAllowlist)
            .map(_globToRegExp)
            .toList(growable: false);

  /// 生效的白名单模式（不可变）。
  final List<String> patterns;
  final List<RegExp> _matchers;

  /// 包名允许字符集（与计划一致）。
  static final RegExp packagePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9_.]+$');

  /// 明确禁止的危险字符（计划强制项）：`;` `|` `&` `$` `` ` `` 换行 回车。
  static const Set<String> dangerousChars = <String>{
    ';',
    '|',
    '&',
    r'$',
    '`',
    '\n',
    '\r',
  };

  /// 额外禁止（防御性）：空白、引号、反斜杠、重定向、子 shell 符。
  static const Set<String> unsafeChars = <String>{
    ' ',
    '\t',
    "'",
    '"',
    r'\',
    '<',
    '>',
    '(',
    ')',
    '{',
    '}',
  };

  /// 是否命中任意危险 / 不安全字符。
  static bool hasUnsafeChar(String token) {
    for (final ch in token.split('')) {
      if (dangerousChars.contains(ch) || unsafeChars.contains(ch)) return true;
    }
    return false;
  }

  /// 路径是否命中白名单。
  bool isSysfsPathAllowed(String path) =>
      _matchers.any((m) => m.hasMatch(path));

  /// sysfs 路径校验：通过返回 `null`，否则返回错误原因（`invalid_arg`）。
  String? sysfsPathReason(String path) {
    if (path.isEmpty) return 'path_empty';
    if (hasUnsafeChar(path)) return 'path_unsafe_char';
    if (!path.startsWith('/sys/') && !path.startsWith('/dev/cpuset/')) {
      return 'path_not_sysfs';
    }
    if (!isSysfsPathAllowed(path)) return 'path_not_allowlisted';
    return null;
  }

  /// 包名校验：通过返回 `null`，否则返回错误原因（`invalid_arg`）。
  String? packageReason(String package) {
    if (package.isEmpty) return 'package_empty';
    if (hasUnsafeChar(package)) return 'package_unsafe_char';
    if (!packagePattern.hasMatch(package)) return 'package_bad_shape';
    return null;
  }

  /// 数值校验：通过返回 `null`，否则返回错误原因（`invalid_arg`）。
  String? numericReason(String value) {
    if (value.isEmpty) return 'value_empty';
    if (hasUnsafeChar(value)) return 'value_unsafe_char';
    if (int.tryParse(value) == null) return 'value_not_int';
    return null;
  }

  /// 通用 token 校验（如 governor 名）：只做危险字符检查，通过返回 `null`。
  String? tokenReason(String value) {
    if (value.isEmpty) return 'value_empty';
    if (hasUnsafeChar(value)) return 'value_unsafe_char';
    return null;
  }

  /// `*` → 单段通配 `[^/]*`，其余字符按正则字面量转义。
  static RegExp _globToRegExp(String pattern) {
    final buffer = StringBuffer('^');
    for (final rune in pattern.runes) {
      final ch = String.fromCharCode(rune);
      buffer.write(ch == '*' ? '[^/]*' : RegExp.escape(ch));
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }
}

/// Shizuku 特权 shell 传输层。
///
/// 生产：`PrivilegedShell()`（默认经 [rustShizukuRunner]）。
/// 测试：注入 [CommandRunner]，无需 Shizuku / 真机 / 原生插件。
class PrivilegedShell {
  PrivilegedShell({
    CommandRunner? runner,
    Duration timeout = const Duration(seconds: 6),
    int inShellTimeoutSeconds = 5,
    PrivilegedInputValidator? validator,
  })  : _runner = runner ?? rustShizukuRunner,
        _timeout = timeout,
        _inShellTimeoutSeconds = inShellTimeoutSeconds,
        validator = validator ?? PrivilegedInputValidator();

  final CommandRunner _runner;
  final Duration _timeout;
  final int _inShellTimeoutSeconds;

  /// 共享入参校验器（调用方可传入自定义白名单的实例以实现复用 / 收紧）。
  final PrivilegedInputValidator validator;

  // ==================== 命令拼装（纯函数，可单测） ====================

  /// 把命令体链上哨兵：`<body> && echo GSTORE_RESULT ok=1 || echo GSTORE_RESULT err=$?`。
  ///
  /// 使用 `&&`/`||` 而非 `;`：写入失败时 `ok=1` **不会**打印，只有 `err=` 会打印，
  /// 从而杜绝「假成功」。
  static String chainSentinel(String body) =>
      '$body && echo $kGstoreSentinel ok=1 || echo $kGstoreSentinel err=\$?';

  /// 拼装一条**自限时**的特权命令：`timeout <n> sh -c '<chained>'`。
  ///
  /// 每条特权命令都必须经此方法，以保证原生进程一定退出、单线程 executor 释放。
  /// [body] 必须**已通过**校验（不含危险 / 不安全字符）。
  String buildCommand(String body) {
    final chained = chainSentinel(body);
    return "timeout $_inShellTimeoutSeconds sh -c '${_escapeSingleQuotes(chained)}'";
  }

  /// 拼装「写 sysfs 节点」命令（**只拼字符串，不执行**）。
  ///
  /// [path] / [value] 必须先过 [validator]（[write] 会自动校验）。
  String buildWriteCommand({required String path, required String value}) =>
      buildCommand('printf %s $value > $path');

  /// 拼装「读 sysfs 节点」命令（**只拼字符串，不执行**）。
  String buildReadCommand({required String path}) => buildCommand('cat $path');

  // ==================== 入参校验（返回结构化 invalid_arg 或 null） ====================

  /// 校验 sysfs 路径：通过返回 `null`，否则返回 `invalid_arg` 结果。
  PrivilegedResult? validateSysfsPath(String path) =>
      _invalidOrNull(validator.sysfsPathReason(path));

  /// 校验包名：通过返回 `null`，否则返回 `invalid_arg` 结果。
  PrivilegedResult? validatePackage(String package) =>
      _invalidOrNull(validator.packageReason(package));

  /// 校验写入值：`numeric` 为真时必须是整数，否则只做危险字符检查。
  PrivilegedResult? validateValue(String value, {bool numeric = false}) =>
      _invalidOrNull(
        numeric ? validator.numericReason(value) : validator.tokenReason(value),
      );

  PrivilegedResult? _invalidOrNull(String? reason) =>
      reason == null ? null : PrivilegedResult.invalidArg(reason);

  // ==================== 执行入口（绝不抛出） ====================

  /// 执行一条**已拼装好**的命令并解析结果；任何失败都返回结构化结果。
  Future<PrivilegedResult> run(String command) async {
    final String? raw;
    try {
      raw = await _runner(command).timeout(_timeout);
    } on TimeoutException {
      debugPrint('[PrivilegedShell] 超时（$command）；注意：超时 != 写入被中止，'
          '需回读节点对账');
      return const PrivilegedResult(
        ok: false,
        output: '',
        error: PrivilegedError.timeout,
      );
    } catch (error) {
      debugPrint('[PrivilegedShell] 执行异常（$command）: $error');
      return const PrivilegedResult(
        ok: false,
        output: '',
        error: PrivilegedError.executionError,
      );
    }
    if (raw == null) {
      return const PrivilegedResult(
        ok: false,
        output: '',
        error: PrivilegedError.noOutput,
      );
    }
    return PrivilegedResult.fromOutput(raw);
  }

  /// 校验并写入一个 sysfs 节点（**传输层提供入口，本 Todo 不实际写**）。
  ///
  /// 入参非法 → 直接返回 `invalid_arg` 且**零命令执行**；
  /// 否则拼装自限时命令并执行。
  Future<PrivilegedResult> write({
    required String path,
    required String value,
    bool numeric = false,
  }) {
    final invalid = validateSysfsPath(path) ?? validateValue(value, numeric: numeric);
    if (invalid != null) return Future<PrivilegedResult>.value(invalid);
    return run(buildWriteCommand(path: path, value: value));
  }

  /// 校验并读取一个 sysfs 节点（只读）。
  Future<PrivilegedResult> read({required String path}) {
    final invalid = validateSysfsPath(path);
    if (invalid != null) return Future<PrivilegedResult>.value(invalid);
    return run(buildReadCommand(path: path));
  }

  /// 把内嵌单引号转义为 `'\''`（防御性；校验已禁止引号）。
  static String _escapeSingleQuotes(String value) =>
      value.replaceAll("'", r"'\''");
}
