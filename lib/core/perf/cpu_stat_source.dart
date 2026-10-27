/// `/proc/stat` **特权读取** + 逐核占用增量（Android 8+ 兜底）。
///
/// ## 为什么需要本文件
/// Android 8.0（API 26）起，SELinux 对 `untrusted_app` 域拒绝
/// `proc_stat:file read`（隐私 / 侧信道缓解），因此 Rust 采集器在普通应用进程内
/// 读取 `/proc/stat` 恒失败：
/// * `per_core` 为空 → `per_core_usage = []`，UI 逐核全部落到 `0%`；
/// * 聚合 `usage_percent = 0`（首行同样不可读）。
///
/// `shell` 域（Shizuku / adb shell，uid 2000）**仍可读取**该文件。本文件经既有
/// [PrivilegedShell]（默认 [rustShizukuRunner]）执行 `cat /proc/stat`，在 Dart
/// 侧维护上次样本并计算增量，作为 Rust 采集的**只读兜底**：
/// * 仅在 Rust 报告的 `perCoreUsage` 为空时由调用方使用；
/// * 无 Shizuku / 未授权 / 命令失败 / 输出非法 → 一律返回 `null`，绝不抛出；
/// * 与 Rust 同算法：`usage% = 100 - Δidle*100/Δtotal`（clamp 0..100）。
///
/// 纯解析函数 [parseProcStatText] 与读取器分离，单测无需真机 / Shizuku。
library;

import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/shell/rust_shizuku_runner.dart';

/// 单次 `/proc/stat` 节拍快照（聚合行或某核）。
class CpuTick {
  const CpuTick({required this.total, required this.idle});

  /// `Σfields[1..]`（user..guest_nice）。
  final int total;

  /// `fields[4]`（user,nice,system,**idle**,…）→ 0 基下标 3。
  final int idle;
}

/// `/proc/stat` 解析结果：聚合行 + 按 CPU 编号索引的各核节拍。
class CpuStatSnapshot {
  const CpuStatSnapshot({required this.aggregate, required this.perCore});

  /// 聚合行（`cpu …`）。
  final CpuTick aggregate;

  /// 各核（`cpuN …`），key = CPU 编号（离线核可能缺失）。
  final Map<int, CpuTick> perCore;
}

/// 一次特权采样计算出的占用（百分比）。
class CpuUsageSample {
  const CpuUsageSample({
    required this.usagePercent,
    required this.perCoreById,
  });

  /// 聚合 CPU 占用（%）。
  final double usagePercent;

  /// 各核占用（%），key = CPU 编号；无法配对增量的核心不出现在表中。
  final Map<int, double> perCoreById;
}

/// 解析 `/proc/stat` 文本（忽略 `intr` / `ctxt` 等非 CPU 行与 [kGstoreSentinel] 行）。
///
/// 无聚合 `cpu` 行时返回 `null`（无法计算总占用）。
CpuStatSnapshot? parseProcStatText(String text) {
  CpuTick? aggregate;
  final Map<int, CpuTick> perCore = <int, CpuTick>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    // 只关心 `cpu` / `cpuN`；`GSTORE_RESULT …` 等行自然跳过。
    if (!line.startsWith('cpu')) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 5) continue;

    final fields = <int>[];
    for (var i = 1; i < parts.length; i++) {
      final value = int.tryParse(parts[i]);
      if (value == null) break;
      fields.add(value);
    }
    if (fields.length < 4) continue;

    var total = 0;
    for (final value in fields) {
      total += value;
    }
    final tick = CpuTick(total: total, idle: fields[3]);

    final label = parts.first;
    if (label == 'cpu') {
      aggregate = tick;
    } else {
      final id = int.tryParse(label.substring(3));
      if (id != null) perCore[id] = tick;
    }
  }

  if (aggregate == null) return null;
  return CpuStatSnapshot(aggregate: aggregate, perCore: perCore);
}

/// 两次节拍的占用率（%）；`Δtotal <= 0`（同一 jiffy / 计数器回退）返回 `null`。
double? cpuUsageDelta(CpuTick prev, CpuTick cur) {
  final dTotal = cur.total - prev.total;
  if (dTotal <= 0) return null;
  final dIdle = cur.idle - prev.idle;
  final value = 100.0 - dIdle * 100.0 / dTotal;
  if (value.isNaN) return null;
  return value.clamp(0.0, 100.0);
}

/// `/proc/stat` 特权读取器（维护上次样本，增量计算逐核占用）。
class CpuStatReader {
  CpuStatReader({
    CommandRunner? runner,
    Duration timeout = const Duration(seconds: 2),
    int inShellTimeoutSeconds = 2,
  }) : _shell = PrivilegedShell(
          runner: runner ?? rustShizukuRunner,
          timeout: timeout,
          inShellTimeoutSeconds: inShellTimeoutSeconds,
        );

  final PrivilegedShell _shell;
  CpuStatSnapshot? _prev;
  DateTime? _prevAt;

  /// 两次采样间隔超过该值视为新基线（页面重开 / 长时间挂起后不复用陈旧增量）。
  static const Duration maxGap = Duration(seconds: 5);

  /// 读取一次并计算自上次调用以来的占用；首次 / 失败 / 间隔过长返回 `null`。
  Future<CpuUsageSample?> sample() async {
    final result = await _shell.run(_shell.buildCommand('cat /proc/stat'));
    if (!result.ok) return null;
    final current = parseProcStatText(result.output);
    if (current == null) return null;

    final now = DateTime.now();
    final previous = _prev;
    final previousAt = _prevAt;
    _prev = current;
    _prevAt = now;

    if (previous == null || previousAt == null) return null;
    if (now.difference(previousAt) > maxGap) return null;

    final usagePercent = cpuUsageDelta(previous.aggregate, current.aggregate);
    if (usagePercent == null) return null;

    final perCoreById = <int, double>{};
    current.perCore.forEach((id, tick) {
      final prevTick = previous.perCore[id];
      if (prevTick == null) return;
      final usage = cpuUsageDelta(prevTick, tick);
      if (usage != null) perCoreById[id] = usage;
    });

    return CpuUsageSample(
      usagePercent: usagePercent,
      perCoreById: perCoreById,
    );
  }
}
