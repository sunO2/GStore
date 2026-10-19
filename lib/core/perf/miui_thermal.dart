/// MIUI 温控专配（**安全版：只读诊断 + 白名单配置备份 / 恢复**）。
///
/// 本文件把三件事收敛成一个可注入、可单测的服务：
/// 1. **检测**：`getprop ro.miui.ui.version.name` 非空即判定为 MIUI（经注入的
///    [CommandRunner]，默认经 Rust 门面 [rustShizukuRunner]）。
/// 2. **诊断（只读）**：`getprop | grep`、`ls /sys/class/thermal`、以及已知温控
///    配置路径的存在性 / 大小（`stat -c %s_%n <glob>`）。只读，绝不写任意节点。
/// 3. **备份 / 恢复**：把白名单内的温控配置文件 `cp` 到**受控备份目录**；恢复
///    仅允许「本应用备份目录下的文件」→ 校验目标仍在白名单 → 二次确认 → `cp`
///    回目标 → **回读比对（size）**，失败显式报错。全部经注入 runner，绝不 panic。
///
/// ## 备份目录方案（务必知晓）
/// 默认 [kMiuiThermalBackupDir] = `/data/local/tmp/gstore_miui_thermal_backup`。
///
/// **为什么不用应用私有目录（`getApplicationSupportDirectory`）？** 因为本服务
/// 的写操作是经 **Shizuku** 以 shell（非 root 时 uid=2000）执行的，而应用私有
/// 数据目录 `/data/user/0/<pkg>/...` 属于应用 uid、shell 无权穿越写入；把 `cp`
/// 目标指向应用私有目录在多数非 root 设备上会直接 `Permission denied`，造成
/// 「假备份」。`/data/local/tmp` 是 Android 上标准的、shell 可写的受控暂存位置，
/// 且本服务用独立子目录 `gstore_miui_thermal_backup` 做命名空间隔离；备份文件的
/// 归属由 [MiuiThermalService._isOwnBackupFile] 前缀 + 文件名编码强校验。
///
/// ## 危险 / 白名单（不可协商）
/// * 备份来源与恢复目标**必须**命中 [kMiuiThermalAllowlist]（`*` 单段通配）；
/// * 恢复来源**必须**是本服务备份目录下、且文件名可解码的名字；
/// * 恢复**必须** `confirmed: true`（UI 层危险确认弹层的布尔结果）；否则在**任何
///   命令之前**返回 `confirm_required` 且**零写入**；
/// * 找不到配置就显示不可用，**绝不猜测写入**任意路径 / 任意 sysfs。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/shell/rust_shizuku_runner.dart';

/// 已知 MIUI 温控配置路径白名单（`*` 为**单段**通配，不跨 `/`）。
///
/// 采用枚举式精确集合；任何不在此列的路径一律拒绝备份 / 恢复。
const List<String> kMiuiThermalAllowlist = <String>[
  '/data/vendor/thermal/config/*.conf',
  '/system/etc/thermal*.conf',
  '/vendor/etc/thermal*.conf',
];

/// 受控备份目录（Shizuku shell uid 可写；见文件头「备份目录方案」）。
const String kMiuiThermalBackupDir =
    '/data/local/tmp/gstore_miui_thermal_backup';

/// 结构化错误码。
abstract final class MiuiThermalError {
  /// 非 MIUI（检测降级，不提供备份 / 恢复）。
  static const String notMiui = 'not_miui';

  /// 路径不在白名单（备份来源 / 恢复目标）。
  static const String pathNotAllowed = 'path_not_allowed';

  /// 恢复来源不是本应用备份目录下的文件。
  static const String backupNotOwned = 'backup_not_owned';

  /// 缺少二次确认 → 零写入。
  static const String confirmRequired = 'confirm_required';

  /// 命令失败（cp / mkdir 被拒等）。
  static const String commandFailed = 'command_failed';

  /// 备份文件不存在。
  static const String backupNotFound = 'backup_not_found';

  /// 回读比对失败（size 不一致 / 读不到）。
  static const String readBackMismatch = 'read_back_mismatch';
}

// ==================== 模型 ====================

/// MIUI 检测结果。
class MiuiDetection {
  const MiuiDetection({
    required this.isMiui,
    required this.reachable,
    this.versionName,
    this.versionCode,
  });

  /// `ro.miui.ui.version.name` 非空即视为 MIUI。
  final bool isMiui;

  /// runner 是否可达（Rust / Shizuku 是否给出任何输出）。
  final bool reachable;

  final String? versionName;
  final String? versionCode;

  /// 展示串（UI 直接使用）。
  String get display => isMiui
      ? (versionName == null || versionName!.isEmpty
          ? 'MIUI'
          : 'MIUI $versionName')
      : '非 MIUI';

  @override
  String toString() =>
      'MiuiDetection(isMiui: $isMiui, reachable: $reachable, '
      'versionName: $versionName)';
}

/// 一个温控配置文件条目。
class ThermalConfigEntry {
  const ThermalConfigEntry({required this.path, this.sizeBytes});

  final String path;
  final int? sizeBytes;

  @override
  String toString() => 'ThermalConfigEntry($path, $sizeBytes)';
}

/// 只读诊断结果。
class ThermalDiagnostic {
  const ThermalDiagnostic({
    this.properties = '',
    this.zones = '',
    this.coolingDevices = '',
    this.configs = const <ThermalConfigEntry>[],
    this.reachable = true,
  });

  /// `getprop | grep -i -e thermal -e miui` 原始输出（trim）。
  final String properties;

  /// `ls /sys/class/thermal` 原始输出（trim）。
  final String zones;

  /// `ls /sys/class/thermal | grep cooling_device` 原始输出（trim）。
  final String coolingDevices;

  /// 已知配置路径的存在性 / 大小（白名单内）。
  final List<ThermalConfigEntry> configs;

  /// runner 是否可达。
  final bool reachable;

  @override
  String toString() =>
      'ThermalDiagnostic(configs: ${configs.length}, reachable: $reachable)';
}

/// 一条本应用生成的备份记录。
class MiuiThermalBackup {
  const MiuiThermalBackup({
    required this.fileName,
    required this.sourcePath,
    required this.backupPath,
    required this.sizeBytes,
    required this.createdAtMs,
  });

  /// 备份文件名（备份目录内）。
  final String fileName;

  /// 原始配置文件路径（恢复目标）。
  final String sourcePath;

  /// 备份文件完整路径。
  final String backupPath;

  /// 备份文件大小（字节）。
  final int sizeBytes;

  /// 备份时间（epoch ms）。
  final int createdAtMs;

  @override
  String toString() =>
      'MiuiThermalBackup($fileName → $sourcePath, ${sizeBytes}B)';
}

/// 备份 / 恢复的结构化结果（**绝不抛出**）。
class MiuiThermalActionResult {
  const MiuiThermalActionResult({
    required this.ok,
    this.error,
    this.detail = '',
    this.backup,
  });

  final bool ok;
  final String? error;
  final String detail;

  /// 备份成功时的记录。
  final MiuiThermalBackup? backup;

  factory MiuiThermalActionResult.failure(String error, String detail) =>
      MiuiThermalActionResult(ok: false, error: error, detail: detail);

  factory MiuiThermalActionResult.success(
    String detail, {
    MiuiThermalBackup? backup,
  }) =>
      MiuiThermalActionResult(ok: true, detail: detail, backup: backup);

  @override
  String toString() =>
      'MiuiThermalActionResult(ok: $ok, error: $error, detail: $detail)';
}

// ==================== 服务 ====================

/// MIUI 温控检测 / 诊断 / 备份 / 恢复服务。
///
/// 生产：`MiuiThermalService()`（默认经 [rustShizukuRunner]）。
/// 测试：注入假 [CommandRunner]（以及可选的 [backupDir] / [clock]），
/// 无需 Shizuku / 真机 / 原生插件。
class MiuiThermalService {
  MiuiThermalService({
    CommandRunner? runner,
    PrivilegedShell? shell,
    String backupDir = kMiuiThermalBackupDir,
    List<String> allowlist = kMiuiThermalAllowlist,
    int Function()? clock,
    Duration timeout = const Duration(seconds: 8),
    int inShellTimeoutSeconds = 8,
  })  : _shell = shell ??
            PrivilegedShell(
              runner: runner ?? rustShizukuRunner,
              timeout: timeout,
              inShellTimeoutSeconds: inShellTimeoutSeconds,
            ),
        _backupDir = backupDir,
        _allowlist = List<String>.unmodifiable(allowlist),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _matchers = allowlist.map(_globToRegExp).toList(growable: false);

  final PrivilegedShell _shell;
  final String _backupDir;
  final List<String> _allowlist;
  final int Function() _clock;
  final List<RegExp> _matchers;

  /// 生效的备份目录。
  String get backupDir => _backupDir;

  /// 生效的白名单模式。
  List<String> get allowlist => _allowlist;

  // ==================== 检测 ====================

  /// 检测是否 MIUI（`ro.miui.ui.version.name` 非空）。
  Future<MiuiDetection> detect() async {
    final nameRes = await _run('getprop ro.miui.ui.version.name');
    final reachable = _reachable(nameRes);
    final versionName = _body(nameRes);
    String? versionCode;
    if (versionName.isNotEmpty) {
      final codeRes = await _run('getprop ro.miui.ui.version.code');
      final code = _body(codeRes);
      versionCode = code.isEmpty ? null : code;
    }
    return MiuiDetection(
      isMiui: versionName.isNotEmpty,
      reachable: reachable,
      versionName: versionName.isEmpty ? null : versionName,
      versionCode: versionCode,
    );
  }

  // ==================== 诊断（只读） ====================

  /// 只读诊断：`getprop` / thermal zones / cooling 设备 / 已知配置路径。
  Future<ThermalDiagnostic> diagnose() async {
    final propsRes = await _run('getprop | grep -i -e thermal -e miui');
    final zonesRes = await _run('ls /sys/class/thermal');
    final coolingRes = await _run('ls /sys/class/thermal | grep cooling_device');
    final configs = await _listConfigs();
    return ThermalDiagnostic(
      properties: _body(propsRes),
      zones: _body(zonesRes),
      coolingDevices: _body(coolingRes),
      configs: configs,
      reachable: _reachable(propsRes),
    );
  }

  /// 列出白名单内的已知温控配置文件（存在性 + 大小）。
  Future<List<ThermalConfigEntry>> _listConfigs() async {
    final entries = <ThermalConfigEntry>[];
    final seen = <String>{};
    for (final glob in _allowlist) {
      final res = await _run('stat -c %s_%n $glob');
      if (!res.ok) continue; // 无匹配 / 不可读 → 该模式跳过（降级）。
      for (final line in _body(res).split('\n')) {
        final match = RegExp(r'^(\d+)_(\S+)$').firstMatch(line.trim());
        if (match == null) continue;
        final path = match.group(2)!;
        if (!_pathAllowed(path)) continue;
        if (!seen.add(path)) continue;
        entries.add(
          ThermalConfigEntry(
            path: path,
            sizeBytes: int.tryParse(match.group(1)!),
          ),
        );
      }
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    return entries;
  }

  // ==================== 备份 ====================

  /// 备份白名单内的一个配置文件到受控备份目录。
  ///
  /// 非法路径 → `path_not_allowed` 且**零命令**。
  Future<MiuiThermalActionResult> backup(String path) async {
    if (!_pathAllowed(path)) {
      debugPrint('[MiuiThermal] 备份路径不在白名单：$path → 零写入');
      return MiuiThermalActionResult.failure(
        MiuiThermalError.pathNotAllowed,
        '路径不在温控白名单内：$path → 拒绝备份',
      );
    }
    final createdAtMs = _clock();
    final fileName = _encodeBackupName(path, createdAtMs);
    final dst = '$_backupDir/$fileName';
    final res = await _run('mkdir -p $_backupDir && cp -f $path $dst');
    if (!res.ok) {
      return MiuiThermalActionResult.failure(
        MiuiThermalError.commandFailed,
        '备份命令失败：$path（${res.error}）',
      );
    }
    final size = await _sizeOf(dst);
    if (size == null) {
      return MiuiThermalActionResult.failure(
        MiuiThermalError.readBackMismatch,
        '备份回读失败（无法读取 $dst）',
      );
    }
    final record = MiuiThermalBackup(
      fileName: fileName,
      sourcePath: path,
      backupPath: dst,
      sizeBytes: size,
      createdAtMs: createdAtMs,
    );
    debugPrint('[MiuiThermal] 已备份 $path → $dst（${size}B）');
    return MiuiThermalActionResult.success(
      '已备份 $path（${size}B）到 $dst',
      backup: record,
    );
  }

  // ==================== 恢复 ====================

  /// 从「本应用备份」恢复一个配置文件到白名单目标。
  ///
  /// 门禁顺序：确认 → 备份归属 → 目标白名单 → 备份存在 → `cp` → 回读比对。
  Future<MiuiThermalActionResult> restore(
    MiuiThermalBackup backup, {
    bool confirmed = false,
  }) async {
    if (!confirmed) {
      debugPrint('[MiuiThermal] 恢复缺少二次确认 → 零写入');
      return MiuiThermalActionResult.failure(
        MiuiThermalError.confirmRequired,
        '缺少二次确认（confirmed=false）→ 拒绝恢复',
      );
    }
    if (!_isOwnBackupFile(backup.backupPath)) {
      debugPrint('[MiuiThermal] 恢复来源非本应用备份：${backup.backupPath}');
      return MiuiThermalActionResult.failure(
        MiuiThermalError.backupNotOwned,
        '仅允许恢复本应用备份目录内的文件：${backup.backupPath}',
      );
    }
    if (!_pathAllowed(backup.sourcePath)) {
      debugPrint('[MiuiThermal] 恢复目标不在白名单：${backup.sourcePath}');
      return MiuiThermalActionResult.failure(
        MiuiThermalError.pathNotAllowed,
        '恢复目标不在温控白名单内：${backup.sourcePath}',
      );
    }
    final srcSize = await _sizeOf(backup.backupPath);
    if (srcSize == null) {
      return MiuiThermalActionResult.failure(
        MiuiThermalError.backupNotFound,
        '备份文件不存在或不可读：${backup.backupPath}',
      );
    }
    final res = await _run('cp -f ${backup.backupPath} ${backup.sourcePath}');
    if (!res.ok) {
      return MiuiThermalActionResult.failure(
        MiuiThermalError.commandFailed,
        '恢复命令失败：${backup.sourcePath}（${res.error}）',
      );
    }
    final readBack = await _sizeOf(backup.sourcePath);
    if (readBack == null || readBack != srcSize) {
      return MiuiThermalActionResult.failure(
        MiuiThermalError.readBackMismatch,
        '恢复回读校验失败：期望 $srcSize 字节，实得 ${readBack ?? '读取失败'}',
      );
    }
    debugPrint('[MiuiThermal] 已恢复 ${backup.sourcePath}（$readBack 字节，已回读校验）');
    return MiuiThermalActionResult.success(
      '已恢复到 ${backup.sourcePath}（$readBack 字节，已回读校验）',
    );
  }

  // ==================== 备份列表 ====================

  /// 列出受控备份目录内的本应用备份（按时间倒序）。
  Future<List<MiuiThermalBackup>> listBackups() async {
    final res = await _run('stat -c %s_%n $_backupDir/*');
    if (!res.ok) return const <MiuiThermalBackup>[];
    final out = <MiuiThermalBackup>[];
    for (final line in _body(res).split('\n')) {
      final match = RegExp(r'^(\d+)_(\S+)$').firstMatch(line.trim());
      if (match == null) continue;
      final full = match.group(2)!;
      if (!_isOwnBackupFile(full)) continue;
      final name = full.substring(full.lastIndexOf('/') + 1);
      final decoded = _decodeBackupName(name);
      if (decoded == null) continue;
      if (!_pathAllowed(decoded.sourcePath)) continue;
      out.add(
        MiuiThermalBackup(
          fileName: name,
          sourcePath: decoded.sourcePath,
          backupPath: full,
          sizeBytes: int.tryParse(match.group(1)!) ?? 0,
          createdAtMs: decoded.createdAtMs,
        ),
      );
    }
    out.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return out;
  }

  // ==================== 内部 ====================

  /// 执行命令体（自动链哨兵 + 自限时，经 [PrivilegedShell]）。
  Future<PrivilegedResult> _run(String body) =>
      _shell.run(_shell.buildCommand(body));

  /// runner 是否可达（未执行 / 异常 → 不可达）。
  static bool _reachable(PrivilegedResult result) =>
      result.error != PrivilegedError.noOutput &&
      result.error != PrivilegedError.executionError;

  /// 去掉尾部哨兵行、trim 后的命令体内容。
  static String _body(PrivilegedResult result) {
    final raw = result.output;
    final idx = raw.lastIndexOf(kGstoreSentinel);
    final sliced = idx >= 0 ? raw.substring(0, idx) : raw;
    return sliced.trim();
  }

  /// `stat -c %s <path>` → 字节数；失败 → `null`。
  Future<int?> _sizeOf(String path) async {
    final res = await _run('stat -c %s $path');
    if (!res.ok) return null;
    return int.tryParse(_body(res));
  }

  /// 路径是否命中白名单（并拒绝危险字符 / 文件名编码保留字符 `%`）。
  bool _pathAllowed(String path) {
    if (path.isEmpty) return false;
    if (path.contains('%')) return false;
    if (PrivilegedInputValidator.hasUnsafeChar(path)) return false;
    return _matchers.any((m) => m.hasMatch(path));
  }

  /// 是否为本应用备份目录下的**直接**文件（禁止子路径 / 危险字符）。
  bool _isOwnBackupFile(String path) {
    final prefix = '$_backupDir/';
    if (!path.startsWith(prefix)) return false;
    final rest = path.substring(prefix.length);
    if (rest.isEmpty || rest.contains('/')) return false;
    return !PrivilegedInputValidator.hasUnsafeChar(rest);
  }

  /// 备份文件名编码：`<tsMs>__<sourcePath with '/' → '%'>.bak`。
  static String _encodeBackupName(String sourcePath, int tsMs) =>
      '${tsMs}__${sourcePath.replaceAll('/', '%')}.bak';

  /// 备份文件名解码（形状不符 → `null`）。
  static ({String sourcePath, int createdAtMs})? _decodeBackupName(
    String fileName,
  ) {
    if (!fileName.endsWith('.bak')) return null;
    final core = fileName.substring(0, fileName.length - 4);
    final sep = core.indexOf('__');
    if (sep <= 0) return null;
    final tsMs = int.tryParse(core.substring(0, sep));
    if (tsMs == null) return null;
    final source = core.substring(sep + 2).replaceAll('%', '/');
    if (source.isEmpty) return null;
    return (sourcePath: source, createdAtMs: tsMs);
  }

  /// `*` → 单段通配 `[^/]*`，其余字符正则字面量转义。
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

// ==================== Riverpod 接线 ====================

/// MIUI 温控服务（生产为单例；测试覆盖为注入假 runner / 假服务的实例）。
final miuiThermalServiceProvider = Provider<MiuiThermalService>(
  (ref) => MiuiThermalService(),
);
