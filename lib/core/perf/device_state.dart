/// 批量设备状态（Rust JNI → Kotlin `DeviceStateChannel.readJson`）的 Dart 模型
/// 与容错解析层。
///
/// Kotlin 一次 JNI 静态调用返回电池扩展 / 电源 / 显示模式 / 内存 / 流量 /
/// 热状态；本文件把它解析为强类型快照，并提供可注入的
/// [RustJniDeviceStateBridge]，单测无需 FFI / 真机。
///
/// 所有解析入口**绝不抛出**：非法 / 非对象 JSON → `null`，缺失字段 → `null`。
library;

import 'dart:convert' show jsonDecode;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:gstore/core/rust/generated/frb_generated.dart' show RustLib;

/// 一个显示模式（`Display.Mode`）。
class DisplayModeHz {
  const DisplayModeHz({
    required this.refreshRate,
    this.mode,
    this.width,
    this.height,
  });

  /// 系统模式 ID（`Display.Mode.getModeId()`）。
  final int? mode;

  /// 物理宽（px）。
  final int? width;

  /// 物理高（px）。
  final int? height;

  /// 刷新率（Hz）。
  final double refreshRate;

  @override
  String toString() =>
      'DisplayModeHz(mode: $mode, ${width}x$height @ $refreshRate Hz)';
}

/// 电池扩展状态（原生单位原样透传）。
class DeviceBatteryState {
  const DeviceBatteryState({
    this.present = false,
    this.level,
    this.scale,
    this.voltageMv,
    this.temperatureTenthsC,
    this.status,
    this.health,
    this.technology,
    this.currentUa,
    this.chargeCounterUah,
    this.energyCounterNwh,
    this.chargeTimeRemainingMs,
    this.powerSave,
    this.deviceIdle,
    this.interactive,
  });

  final bool present;
  final int? level;
  final int? scale;
  final int? voltageMv;
  final int? temperatureTenthsC;
  final int? status;
  final int? health;
  final String? technology;
  final int? currentUa;
  final int? chargeCounterUah;
  final int? energyCounterNwh;
  final int? chargeTimeRemainingMs;
  final bool? powerSave;
  final bool? deviceIdle;
  final bool? interactive;

  /// 电压（V）。
  double? get voltageV => voltageMv == null ? null : voltageMv! / 1000.0;

  /// 电流（mA；可为负）。
  double? get currentMa => currentUa == null ? null : currentUa! / 1000.0;

  /// 温度（℃）。
  double? get temperatureC =>
      temperatureTenthsC == null ? null : temperatureTenthsC! / 10.0;

  @override
  String toString() => 'DeviceBatteryState(present: $present, '
      'level: $level/$scale, voltageMv: $voltageMv, currentUa: $currentUa, '
      'temperatureTenthsC: $temperatureTenthsC)';
}

/// 内存状态（字节）。
class DeviceMemoryState {
  const DeviceMemoryState({
    this.totalMem,
    this.availMem,
    this.threshold,
    this.lowMemory,
  });

  final int? totalMem;
  final int? availMem;
  final int? threshold;
  final bool? lowMemory;

  @override
  String toString() => 'DeviceMemoryState(total: $totalMem, '
      'avail: $availMem, threshold: $threshold, low: $lowMemory)';
}

/// 流量计数（字节）。
class DeviceTrafficState {
  const DeviceTrafficState({
    this.totalRx,
    this.totalTx,
    this.mobileRx,
    this.mobileTx,
    this.uidRx,
    this.uidTx,
  });

  final int? totalRx;
  final int? totalTx;
  final int? mobileRx;
  final int? mobileTx;
  final int? uidRx;
  final int? uidTx;

  @override
  String toString() => 'DeviceTrafficState(totalRx: $totalRx, '
      'totalTx: $totalTx, uidRx: $uidRx, uidTx: $uidTx)';
}

/// 一次批量设备状态快照。
class DeviceStateReading {
  const DeviceStateReading({
    this.battery,
    this.displayRefreshRate,
    this.supportedDisplayModes = const <DisplayModeHz>[],
    this.memory,
    this.traffic,
    this.thermalStatus,
    this.thermalHeadroom,
    this.sources = const <String>{},
  });

  final DeviceBatteryState? battery;

  /// 当前显示模式刷新率（Hz）。
  final double? displayRefreshRate;

  /// 设备支持的显示模式（可能为空）。
  final List<DisplayModeHz> supportedDisplayModes;

  final DeviceMemoryState? memory;
  final DeviceTrafficState? traffic;

  /// `PowerManager.getCurrentThermalStatus()` 的 `THERMAL_STATUS_*` 整型。
  final int? thermalStatus;

  /// `PowerManager.getThermalHeadroom(0)`（0..1+，NaN 已被 Kotlin 过滤）。
  final double? thermalHeadroom;

  /// 数据来源标记（本解析器恒为 `{'rust_jni'}`）。
  final Set<String> sources;

  /// 是否来自 Rust JNI 数据源。
  bool get fromRustJni => sources.contains('rust_jni');

  /// 支持模式 → 四舍五入、去重、升序的 Hz 档位（未做范围过滤）。
  List<int> get refreshLevels {
    final levels = <int>{
      for (final mode in supportedDisplayModes) mode.refreshRate.round(),
    }.toList()
      ..sort();
    return levels;
  }

  @override
  String toString() => 'DeviceStateReading(refreshRate: $displayRefreshRate, '
      'modes: ${supportedDisplayModes.length}, '
      'thermalStatus: $thermalStatus, sources: $sources)';
}

/// 把 Rust JNI `device_state_read_json` 的 JSON 解析为 [DeviceStateReading]。
///
/// 非法 JSON / 非对象 → `null`；字段缺失 / 类型不符 → 对应字段为 `null`。
/// **绝不抛出**。
DeviceStateReading? deviceStateFromRustJniJson(String json) {
  try {
    final decoded = jsonDecode(json);
    final root = _asMap(decoded);
    if (root == null) return null;
    final display = _asMap(root['display']);
    final thermal = _asMap(root['thermal']);
    return DeviceStateReading(
      battery: _battery(_asMap(root['battery'])),
      displayRefreshRate: _asDouble(display?['refreshRate']),
      supportedDisplayModes: _displayModes(display?['supportedModes']),
      memory: _memory(_asMap(root['memory'])),
      traffic: _traffic(_asMap(root['traffic'])),
      thermalStatus: _asInt(thermal?['status']),
      thermalHeadroom: _asDouble(thermal?['headroom']),
      sources: const <String>{'rust_jni'},
    );
  } catch (error) {
    debugPrint('[DeviceState] rust_jni JSON 解析失败: $error');
    return null;
  }
}

DeviceBatteryState? _battery(Map<String, Object?>? map) {
  if (map == null) return null;
  return DeviceBatteryState(
    present: _asBool(map['present']) ?? false,
    level: _asInt(map['level']),
    scale: _asInt(map['scale']),
    voltageMv: _asInt(map['voltageMv']),
    temperatureTenthsC: _asInt(map['temperatureTenthsC']),
    status: _asInt(map['status']),
    health: _asInt(map['health']),
    technology: _asString(map['technology']),
    currentUa: _asInt(map['currentUa']),
    chargeCounterUah: _asInt(map['chargeCounterUah']),
    energyCounterNwh: _asInt(map['energyCounterNwh']),
    chargeTimeRemainingMs: _asInt(map['chargeTimeRemainingMs']),
    powerSave: _asBool(map['powerSave']),
    deviceIdle: _asBool(map['deviceIdle']),
    interactive: _asBool(map['interactive']),
  );
}

DeviceMemoryState? _memory(Map<String, Object?>? map) {
  if (map == null) return null;
  return DeviceMemoryState(
    totalMem: _asInt(map['totalMem']),
    availMem: _asInt(map['availMem']),
    threshold: _asInt(map['threshold']),
    lowMemory: _asBool(map['lowMemory']),
  );
}

DeviceTrafficState? _traffic(Map<String, Object?>? map) {
  if (map == null) return null;
  return DeviceTrafficState(
    totalRx: _asInt(map['totalRx']),
    totalTx: _asInt(map['totalTx']),
    mobileRx: _asInt(map['mobileRx']),
    mobileTx: _asInt(map['mobileTx']),
    uidRx: _asInt(map['uidRx']),
    uidTx: _asInt(map['uidTx']),
  );
}

List<DisplayModeHz> _displayModes(Object? raw) {
  if (raw is! List) return const <DisplayModeHz>[];
  final modes = <DisplayModeHz>[];
  for (final entry in raw) {
    final map = _asMap(entry);
    if (map == null) continue;
    final refreshRate = _asDouble(map['refreshRate']);
    if (refreshRate == null || !refreshRate.isFinite || refreshRate <= 0) {
      continue;
    }
    modes.add(
      DisplayModeHz(
        mode: _asInt(map['mode']),
        width: _asInt(map['width']),
        height: _asInt(map['height']),
        refreshRate: refreshRate,
      ),
    );
  }
  return modes;
}

Map<String, Object?>? _asMap(Object? value) {
  if (value is! Map) return null;
  return <String, Object?>{
    for (final entry in value.entries) entry.key.toString(): entry.value,
  };
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) {
    if (!value.isFinite) return null;
    return value.round();
  }
  if (value is String) {
    final parsed = double.tryParse(value.trim());
    if (parsed == null || !parsed.isFinite) return null;
    return parsed.round();
  }
  return null;
}

double? _asDouble(Object? value) {
  if (value is double) return value.isFinite ? value : null;
  if (value is num) {
    final asDouble = value.toDouble();
    return asDouble.isFinite ? asDouble : null;
  }
  if (value is String) {
    final parsed = double.tryParse(value.trim());
    return parsed != null && parsed.isFinite ? parsed : null;
  }
  return null;
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

String? _asString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Rust JNI 设备状态读取 seam（生产：FRB `device_state_read_json`）。
typedef RustDeviceStateJsonReader = Future<String?> Function();

/// Rust JNI → Kotlin `DeviceStateChannel` 的 Dart 门面。
///
/// 生产默认走生成的 FRB 函数；[readJson] 可注入，单测无需 FFI。
/// 所有入口**绝不抛出**（异常 / 未初始化 / 非法 JSON → `null`）。
class RustJniDeviceStateBridge {
  RustJniDeviceStateBridge({RustDeviceStateJsonReader? readJson})
      : _readJson = readJson ?? _defaultReadJson;

  final RustDeviceStateJsonReader _readJson;

  static Future<String?> _defaultReadJson() =>
      RustLib.instance.api.crateBridgeDeviceStateReadJson();

  /// 读取一次并解析为 [DeviceStateReading]；不可用 / 失败 → `null`。
  Future<DeviceStateReading?> read() async {
    try {
      final json = await _readJson();
      if (json == null || json.isEmpty) return null;
      return deviceStateFromRustJniJson(json);
    } catch (error) {
      debugPrint('[RustJniDeviceStateBridge] read 失败: $error');
      return null;
    }
  }
}
