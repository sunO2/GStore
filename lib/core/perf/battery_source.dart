/// 免权限电池数据源 + 多源合并层。
///
/// 背景：部分设备 SELinux 拒绝读取
/// `/sys/class/power_supply/battery/{current_now,voltage_now}`，导致 Rust
/// `perf.battery`（开销最小的主源）电流 / 电压恒为 null。本文件在其上叠加两个
/// **免权限**兜底源并逐字段合并：
/// 1. [PerfModule.battery]（sysfs；`source='sysfs'`）；
/// 2. Android `BatteryManager` 原生通道（`gstore/battery`；
///    `source='battery_manager'`，见 Kotlin `BatteryChannel`）；
/// 3. `dumpsys battery`（经既有 [PrivilegedShell] / Shizuku；
///    `source='dumpsys'`，仅当 1+2 仍缺电流或电压时才执行）。
///
/// 合并规则：逐字段取**第一个非 null** 值，优先级 `sysfs > battery_manager >
/// dumpsys`；`present` = 任一源 present；状态优先采用**有整型码**的值；
/// `sources` 取并集。
///
/// 全部入口**绝不抛出**：异常一律降级为 null / 跳过该源。所有解析与合并函数为
/// **纯函数**，且 [readBatteryReading] 的读取 seam 可注入，故单测无需真机 /
/// Shizuku / FFI。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart' show BatteryReport;
import 'package:gstore/core/rust/perf/PerfModule.dart' show PerfModule;

/// Android `BATTERY_STATUS_*` 整型 → 展示标签（未知码 → `Unknown`）。
String? statusLabelFromCode(int? code) {
  switch (code) {
    case 1:
      return 'Unknown';
    case 2:
      return 'Charging';
    case 3:
      return 'Discharging';
    case 4:
      return 'Not charging';
    case 5:
      return 'Full';
    default:
      return code == null ? null : 'Unknown';
  }
}

/// sysfs `status` 标签字符串 → Android `BATTERY_STATUS_*`（大小写不敏感）。
///
/// `null` → `null`；可识别标签映射为对应码；其余（含空串）→ 1（Unknown）。
int? statusCodeFromLabel(String? label) {
  if (label == null) return null;
  switch (label.trim().toLowerCase()) {
    case 'charging':
      return 2;
    case 'discharging':
      return 3;
    case 'not charging':
      return 4;
    case 'full':
      return 5;
    case 'unknown':
      return 1;
    default:
      return 1;
  }
}

/// Android `BATTERY_HEALTH_*` 整型 → 展示标签（未知码 → `Unknown`）。
String? healthLabelFromCode(int? code) {
  switch (code) {
    case 1:
      return 'Unknown';
    case 2:
      return 'Good';
    case 3:
      return 'Overheat';
    case 4:
      return 'Dead';
    case 5:
      return 'Over voltage';
    case 6:
      return 'Unspecified failure';
    case 7:
      return 'Cold';
    default:
      return code == null ? null : 'Unknown';
  }
}

/// 一次电池读数（多源合并的统一模型；字段缺失为 null）。
class BatteryReading {
  const BatteryReading({
    this.present = false,
    this.capacityPercent,
    this.voltageV,
    this.currentMa,
    this.temperatureC,
    this.statusCode,
    this.statusLabel,
    this.health,
    this.technology,
    this.basePath,
    this.interactive,
    this.sources = const <String>{},
  });

  /// 是否检测到电池。
  final bool present;

  /// 电量百分比（0..100）。
  final double? capacityPercent;

  /// 电压（V）。
  final double? voltageV;

  /// 电流（mA，有符号；放电为负）。
  final double? currentMa;

  /// 温度（℃）。
  final double? temperatureC;

  /// Android `BATTERY_STATUS_*` 整型码。
  final int? statusCode;

  /// 状态展示标签（由 [statusCode] 或 sysfs 字符串归一）。
  final String? statusLabel;

  /// 健康度标签（`Good` / `Overheat` …）。
  final String? health;

  /// 材质（`Li-ion` …）。
  final String? technology;

  /// sysfs 基路径（仅 sysfs 源提供）。
  final String? basePath;

  /// 屏幕是否点亮（仅 BatteryManager 源提供；`null` = 未知）。
  final bool? interactive;

  /// 贡献过本读数的源（`sysfs` / `battery_manager` / `dumpsys`）。
  final Set<String> sources;

  /// 逐字段覆盖；[sources] 非空时替换、否则沿用原值。
  BatteryReading copyWith({
    bool? present,
    double? capacityPercent,
    double? voltageV,
    double? currentMa,
    double? temperatureC,
    int? statusCode,
    String? statusLabel,
    String? health,
    String? technology,
    String? basePath,
    bool? interactive,
    Set<String>? sources,
  }) =>
      BatteryReading(
        present: present ?? this.present,
        capacityPercent: capacityPercent ?? this.capacityPercent,
        voltageV: voltageV ?? this.voltageV,
        currentMa: currentMa ?? this.currentMa,
        temperatureC: temperatureC ?? this.temperatureC,
        statusCode: statusCode ?? this.statusCode,
        statusLabel: statusLabel ?? this.statusLabel,
        health: health ?? this.health,
        technology: technology ?? this.technology,
        basePath: basePath ?? this.basePath,
        interactive: interactive ?? this.interactive,
        sources: sources ?? this.sources,
      );

  @override
  String toString() => 'BatteryReading(present: $present, '
      'capacityPercent: $capacityPercent, voltageV: $voltageV, '
      'currentMa: $currentMa, temperatureC: $temperatureC, '
      'statusCode: $statusCode, statusLabel: $statusLabel, '
      'health: $health, technology: $technology, basePath: $basePath, '
      'interactive: $interactive, sources: $sources)';
}

/// 从 Rust [BatteryReport]（sysfs）构造读数（`source='sysfs'`）。
BatteryReading batteryReadingFromSysfs(BatteryReport report) => BatteryReading(
      present: report.present,
      capacityPercent: report.capacityPercent,
      voltageV: report.voltageV,
      currentMa: report.currentMa,
      temperatureC: report.temperatureC,
      statusCode: statusCodeFromLabel(report.status),
      statusLabel: report.status,
      health: report.health,
      technology: report.technology,
      basePath: report.basePath,
      sources: const <String>{'sysfs'},
    );

/// 把 Kotlin `BatteryChannel.read` 的原始 Map 归一为 [BatteryReading]。
///
/// 单位：`voltageMv / 1000`、`currentUa / 1000`（BatteryManager CURRENT_NOW 为
/// µA，可为负）、`temperatureTenthsC / 10`；`health` 整型码转标签。
BatteryReading batteryReadingFromBatteryManagerMap(Map<Object?, Object?> map) {
  final voltageMv = _asInt(map['voltageMv']);
  final currentUa = _asInt(map['currentUa']);
  final temperatureTenthsC = _asInt(map['temperatureTenthsC']);
  final statusCode = _asInt(map['status']);
  final healthCode = _asInt(map['health']);
  final technology = _asString(map['technology']);
  final capacityPercent = _asInt(map['capacityPercent']);
  final present = map['present'] == true;
  final interactive = _asBool(map['interactive']);

  return BatteryReading(
    present: present,
    capacityPercent: capacityPercent?.toDouble(),
    voltageV: voltageMv == null ? null : voltageMv / 1000.0,
    currentMa: currentUa == null ? null : currentUa / 1000.0,
    temperatureC:
        temperatureTenthsC == null ? null : temperatureTenthsC / 10.0,
    statusCode: statusCode,
    statusLabel: statusLabelFromCode(statusCode),
    health: healthLabelFromCode(healthCode),
    technology: technology,
    interactive: interactive,
    sources: const <String>{'battery_manager'},
  );
}

/// `gstore/battery` 通道包装；[read] 捕获 `MissingPluginException` /
/// `PlatformException` → `null`（绝不抛出）。
class BatteryManagerChannel {
  BatteryManagerChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('gstore/battery');

  final MethodChannel _channel;

  /// 读取一次；不可用 / 异常 → `null`。
  Future<BatteryReading?> read() async {
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('read');
      if (map == null) return null;
      return batteryReadingFromBatteryManagerMap(map);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('[BatteryManagerChannel] read 异常: ${error.message}');
      return null;
    } catch (error) {
      debugPrint('[BatteryManagerChannel] read 失败: $error');
      return null;
    }
  }
}

/// 解析 `dumpsys battery` 输出（纯函数，宽容）。
///
/// 识别 `level` / `scale` / `voltage`(mV→V) / `temperature`(十分之一℃→℃) /
/// `status`(int) / `health`(int) / `present` / `technology` / `current now`(µA→mA)。
/// 无法识别的行（含 [PrivilegedShell] 哨兵行）原样忽略；无任何字段时返回
/// `present=false` 的空读数（非 null）。
BatteryReading parseDumpsysBattery(String output) {
  final values = <String, String>{};
  for (final line in output.split('\n')) {
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    final key = line.substring(0, idx).trim().toLowerCase();
    final value = line.substring(idx + 1).trim();
    if (key.isEmpty || value.isEmpty) continue;
    values.putIfAbsent(key, () => value);
  }

  final level = int.tryParse(values['level'] ?? '');
  final scale = int.tryParse(values['scale'] ?? '');
  final voltageMv = int.tryParse(values['voltage'] ?? '');
  final temperatureTenthsC = int.tryParse(values['temperature'] ?? '');
  final statusCode = int.tryParse(values['status'] ?? '');
  final healthCode = int.tryParse(values['health'] ?? '');
  final currentUa = int.tryParse(values['current now'] ?? '');
  final presentRaw = values['present']?.toLowerCase();
  final technology = values['technology'];

  double? capacityPercent;
  if (level != null && scale != null && scale > 0) {
    capacityPercent = level * 100.0 / scale;
  }

  final present = presentRaw != null
      ? presentRaw == 'true'
      : (level != null || voltageMv != null || capacityPercent != null);

  return BatteryReading(
    present: present,
    capacityPercent: capacityPercent,
    voltageV: voltageMv == null ? null : voltageMv / 1000.0,
    currentMa: currentUa == null ? null : currentUa / 1000.0,
    temperatureC:
        temperatureTenthsC == null ? null : temperatureTenthsC / 10.0,
    statusCode: statusCode,
    statusLabel: statusLabelFromCode(statusCode),
    health: healthLabelFromCode(healthCode),
    technology: technology,
    sources: const <String>{'dumpsys'},
  );
}

/// 逐字段合并（优先级 `sysfs > batteryManager > dumpsys`）。
///
/// `present` = 任一源 present；`status` 优先采用有整型码的值；`sources` 取并集。
BatteryReading mergeBatteryReadings({
  BatteryReading? sysfs,
  BatteryReading? batteryManager,
  BatteryReading? dumpsys,
}) {
  final ordered = <BatteryReading?>[sysfs, batteryManager, dumpsys];

  final statusCode = _first<int>(ordered.map((r) => r?.statusCode));
  final statusLabel = statusCode != null
      ? statusLabelFromCode(statusCode)
      : _first<String>(ordered.map((r) => r?.statusLabel));

  return BatteryReading(
    present: ordered.any((r) => r?.present == true),
    capacityPercent:
        _first<double>(ordered.map((r) => r?.capacityPercent)),
    voltageV: _first<double>(ordered.map((r) => r?.voltageV)),
    currentMa: _first<double>(ordered.map((r) => r?.currentMa)),
    temperatureC: _first<double>(ordered.map((r) => r?.temperatureC)),
    statusCode: statusCode,
    statusLabel: statusLabel,
    health: _first<String>(ordered.map((r) => r?.health)),
    technology: _first<String>(ordered.map((r) => r?.technology)),
    basePath: _first<String>(ordered.map((r) => r?.basePath)),
    interactive: _first<bool>(ordered.map((r) => r?.interactive)),
    sources: {
      for (final r in ordered)
        if (r != null) ...r.sources,
    },
  );
}

/// sysfs 读取 seam（生产：[PerfModule.battery]）。
typedef BatterySysfsReader = Future<BatteryReading?> Function();

/// 特权 shell 执行 seam（生产：[PrivilegedShell.run] 的 `dumpsys battery`）。
typedef BatteryShellRunner = Future<String?> Function(String command);

/// `dumpsys battery` 命令体（经 [PrivilegedShell.buildCommand] 自限时 + 哨兵）。
const String kBatteryDumpsysCommand = 'dumpsys battery';

/// 默认 sysfs 读取：经 [PerfModule]；异常 → `null`（**绝不抛出**）。
Future<BatteryReading?> defaultBatterySysfsReader() async {
  try {
    return batteryReadingFromSysfs(await PerfModule.instance.battery());
  } catch (error) {
    debugPrint('[BatterySource] sysfs 电池读取失败: $error');
    return null;
  }
}

/// 默认 `dumpsys battery` 执行：经 [PrivilegedShell]；失败 → `null`。
Future<String?> defaultBatteryShellRunner(String command) async {
  try {
    final shell = PrivilegedShell(
      timeout: const Duration(seconds: 5),
      inShellTimeoutSeconds: 3,
    );
    final result = await shell.run(shell.buildCommand(command));
    return result.ok ? result.output : null;
  } catch (error) {
    debugPrint('[BatterySource] dumpsys battery 失败: $error');
    return null;
  }
}

/// 廉价缓存 TTL（不含 `dumpsys`）。
const Duration kBatteryReadingCheapTtl = Duration(seconds: 2);

/// 完整缓存 TTL（含 `dumpsys`）。
const Duration kBatteryReadingFullTtl = Duration(seconds: 60);

class _BatteryReadingCacheEntry {
  const _BatteryReadingCacheEntry(this.reading, this.at);

  final BatteryReading? reading;
  final DateTime at;
}

final Map<bool, _BatteryReadingCacheEntry> _batteryReadingCache =
    <bool, _BatteryReadingCacheEntry>{};
final Map<bool, Future<BatteryReading?>> _batteryReadingInFlight =
    <bool, Future<BatteryReading?>>{};

/// 清空 [readBatteryReading] 的 TTL 缓存（测试用）。
void resetBatteryReadingCache() {
  _batteryReadingCache.clear();
  _batteryReadingInFlight.clear();
}

/// 读取并合并电池读数：sysfs → BatteryManager → （按需）dumpsys。
///
/// 热路径默认 **不** 执行 `dumpsys battery`（[includeDumpsys] 默认 `false`）：
/// 3s 记录器 / 1s 刷新只走 sysfs + BatteryManager（平台通道，无 shell 进程）。
///
/// 结果按 [includeDumpsys] 分键缓存：[kBatteryReadingCheapTtl]（廉价）/
/// [kBatteryReadingFullTtl]（完整）。[forceRefresh] 或 TTL 过期时重新采集；
/// [cacheTtl] 可显式覆盖 TTL。**绝不抛出**。
Future<BatteryReading?> readBatteryReading({
  bool includeDumpsys = false,
  bool forceRefresh = false,
  Duration? cacheTtl,
  BatterySysfsReader? sysfsReader,
  BatteryManagerChannel? channel,
  BatteryShellRunner? shellRunner,
}) {
  final ttl = cacheTtl ??
      (includeDumpsys ? kBatteryReadingFullTtl : kBatteryReadingCheapTtl);
  final cached = _batteryReadingCache[includeDumpsys];
  if (!forceRefresh &&
      cached != null &&
      DateTime.now().difference(cached.at) < ttl) {
    return Future<BatteryReading?>.value(cached.reading);
  }
  final inFlight = _batteryReadingInFlight[includeDumpsys];
  if (!forceRefresh && inFlight != null) return inFlight;

  final future = _readBatteryReadingUncached(
    includeDumpsys: includeDumpsys,
    sysfsReader: sysfsReader,
    channel: channel,
    shellRunner: shellRunner,
  );
  _batteryReadingInFlight[includeDumpsys] = future;
  return future.then((reading) {
    _batteryReadingCache[includeDumpsys] =
        _BatteryReadingCacheEntry(reading, DateTime.now());
    return reading;
  }).whenComplete(() {
    if (identical(_batteryReadingInFlight[includeDumpsys], future)) {
      _batteryReadingInFlight.remove(includeDumpsys);
    }
  });
}

Future<BatteryReading?> _readBatteryReadingUncached({
  required bool includeDumpsys,
  BatterySysfsReader? sysfsReader,
  BatteryManagerChannel? channel,
  BatteryShellRunner? shellRunner,
}) async {
  BatteryReading? sysfs;
  try {
    sysfs = await (sysfsReader ?? defaultBatterySysfsReader)();
  } catch (error) {
    debugPrint('[BatterySource] sysfsReader 异常: $error');
    sysfs = null;
  }

  final batteryManager = await (channel ?? BatteryManagerChannel()).read();

  var merged = mergeBatteryReadings(
    sysfs: sysfs,
    batteryManager: batteryManager,
  );

  if (includeDumpsys &&
      (merged.currentMa == null || merged.voltageV == null)) {
    String? output;
    try {
      output = await (shellRunner ?? defaultBatteryShellRunner)(
        kBatteryDumpsysCommand,
      );
    } catch (error) {
      debugPrint('[BatterySource] shellRunner 异常: $error');
      output = null;
    }
    if (output != null && output.isNotEmpty) {
      final dumpsys = parseDumpsysBattery(output);
      merged = mergeBatteryReadings(
        sysfs: sysfs,
        batteryManager: batteryManager,
        dumpsys: dumpsys,
      );
    }
  }

  return merged.present ? merged : null;
}

/// 单个数据源的诊断结果（[BatterySourceDiagnostic]）。
///
/// * [source]：`sysfs` / `battery_manager` / `dumpsys`；
/// * [reading]：该源归一后的读数（解析失败 / 不可用为 `null`）；
/// * [error]：该源抛出的错误字符串（无错误为 `null`）；
/// * [raw]：原始输出（`dumpsys battery`；无输出时回退为错误字符串）。
class BatterySourceDiagnostic {
  const BatterySourceDiagnostic({
    required this.source,
    this.reading,
    this.error,
    this.raw,
  });

  final String source;
  final BatteryReading? reading;
  final String? error;
  final String? raw;

  @override
  String toString() => 'BatterySourceDiagnostic(source: $source, '
      'reading: $reading, error: $error, raw: $raw)';
}

/// 逐源诊断（供 UI 展示「哪一路数据源失败/缺什么」）。
///
/// 与 [readBatteryReading] 不同，本函数**强制**分别执行三个源（含 `dumpsys
/// battery`）并原样捕获输出 / 错误，**绝不抛出**，也不写缓存。
Future<List<BatterySourceDiagnostic>> readBatterySourceDiagnostics({
  BatterySysfsReader? sysfsReader,
  BatteryManagerChannel? channel,
  BatteryShellRunner? shellRunner,
}) async {
  final out = <BatterySourceDiagnostic>[];

  // sysfs
  BatteryReading? sysfsReading;
  String? sysfsError;
  try {
    sysfsReading = await (sysfsReader ?? defaultBatterySysfsReader)();
  } catch (error) {
    sysfsError = '$error';
  }
  out.add(BatterySourceDiagnostic(
    source: 'sysfs',
    reading: sysfsReading,
    error: sysfsError,
  ));

  // battery_manager
  BatteryReading? bmReading;
  String? bmError;
  try {
    bmReading = await (channel ?? BatteryManagerChannel()).read();
  } catch (error) {
    bmError = '$error';
  }
  out.add(BatterySourceDiagnostic(
    source: 'battery_manager',
    reading: bmReading,
    error: bmError,
  ));

  // dumpsys
  String? output;
  String? dumpsysError;
  try {
    output = await (shellRunner ?? defaultBatteryShellRunner)(
      kBatteryDumpsysCommand,
    );
  } catch (error) {
    dumpsysError = '$error';
  }
  final raw = (output != null && output.isNotEmpty) ? output : dumpsysError;
  out.add(BatterySourceDiagnostic(
    source: 'dumpsys',
    reading: (output != null && output.isNotEmpty)
        ? parseDumpsysBattery(output)
        : null,
    error: dumpsysError,
    raw: raw,
  ));

  return out;
}

T? _first<T>(Iterable<T?> values) {
  for (final value in values) {
    if (value != null) return value;
  }
  return null;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value == null) return null;
  return int.tryParse(value.toString());
}

String? _asString(Object? value) {
  if (value is String) return value.isEmpty ? null : value;
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

bool? _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
        return true;
      case 'false':
      case '0':
        return false;
    }
  }
  return null;
}
