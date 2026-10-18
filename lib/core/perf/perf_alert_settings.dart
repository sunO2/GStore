/// 性能告警阈值 / 开关设置 + 持久化（`shared_preferences`）。
///
/// 抽象 [PerfAlertSettingsStore] 让 UI 可注入假实现，widget test 无需平台通道；
/// 生产实现 [SharedPrefsPerfAlertSettingsStore] 以 JSON 字符串保存，跨启动恢复。
///
/// 失败一律静默降级（`null` / 不抛），符合性能页整体容错语义；模型本身为纯
/// Dart（无 Flutter 依赖），可被纯评估逻辑 [evaluate] 直接消费。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// 性能告警设置。
///
/// 阈值含义：CPU / 温度 / Jank 为「**超过**即告警」（严格大于），FPS 为
/// 「**低于**即告警」（严格小于）。默认 [enabled] 为 `false`（绝不主动打扰）。
class PerfAlertSettings {
  const PerfAlertSettings({
    this.enabled = false,
    this.cpuPercent = 80,
    this.temperatureC = 45,
    this.jankPercent = 5,
    this.minFps = 50,
    this.notify = true,
    this.banner = true,
  });

  /// 默认设置（告警关闭）。
  static const PerfAlertSettings defaults = PerfAlertSettings();

  /// 总开关（默认 OFF）。
  final bool enabled;

  /// CPU 总占用告警阈值（%）。
  final double cpuPercent;

  /// 温度告警阈值（°C）。
  final double temperatureC;

  /// Jank 帧占比告警阈值（%）。
  final double jankPercent;

  /// 最低 FPS 告警阈值（低于即告警）。
  final double minFps;

  /// 是否推送系统通知。
  final bool notify;

  /// 是否显示应用内横幅（Snackbar）。
  final bool banner;

  PerfAlertSettings copyWith({
    bool? enabled,
    double? cpuPercent,
    double? temperatureC,
    double? jankPercent,
    double? minFps,
    bool? notify,
    bool? banner,
  }) {
    return PerfAlertSettings(
      enabled: enabled ?? this.enabled,
      cpuPercent: cpuPercent ?? this.cpuPercent,
      temperatureC: temperatureC ?? this.temperatureC,
      jankPercent: jankPercent ?? this.jankPercent,
      minFps: minFps ?? this.minFps,
      notify: notify ?? this.notify,
      banner: banner ?? this.banner,
    );
  }

  /// 序列化为 JSON 友好映射。
  Map<String, dynamic> toMap() => <String, dynamic>{
        'enabled': enabled,
        'cpu_percent': cpuPercent,
        'temperature_c': temperatureC,
        'jank_percent': jankPercent,
        'min_fps': minFps,
        'notify': notify,
        'banner': banner,
      };

  /// 宽容解码：缺失 / 非法字段回退默认值，绝不抛异常。
  factory PerfAlertSettings.fromMap(Map<String, dynamic> map) =>
      PerfAlertSettings(
        enabled: map['enabled'] == true,
        cpuPercent: _asDouble(map['cpu_percent'], defaults.cpuPercent),
        temperatureC:
            _asDouble(map['temperature_c'], defaults.temperatureC),
        jankPercent: _asDouble(map['jank_percent'], defaults.jankPercent),
        minFps: _asDouble(map['min_fps'], defaults.minFps),
        notify: map['notify'] is bool ? map['notify'] as bool : defaults.notify,
        banner: map['banner'] is bool ? map['banner'] as bool : defaults.banner,
      );

  static double _asDouble(Object? value, double fallback) {
    if (value is num && value.isFinite) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed != null && parsed.isFinite) return parsed;
    }
    return fallback;
  }

  @override
  bool operator ==(Object other) =>
      other is PerfAlertSettings &&
      other.enabled == enabled &&
      other.cpuPercent == cpuPercent &&
      other.temperatureC == temperatureC &&
      other.jankPercent == jankPercent &&
      other.minFps == minFps &&
      other.notify == notify &&
      other.banner == banner;

  @override
  int get hashCode => Object.hash(
        enabled,
        cpuPercent,
        temperatureC,
        jankPercent,
        minFps,
        notify,
        banner,
      );

  @override
  String toString() => 'PerfAlertSettings(enabled=$enabled, cpu=$cpuPercent, '
      'temp=$temperatureC, jank=$jankPercent, minFps=$minFps, '
      'notify=$notify, banner=$banner)';
}

/// 告警设置持久化接口。
abstract class PerfAlertSettingsStore {
  /// 读取已保存设置；无记录 / 读取失败返回 `null`。
  Future<PerfAlertSettings?> load();

  /// 保存设置；失败静默（仅日志，不抛）。
  Future<void> save(PerfAlertSettings settings);
}

/// 生产实现：`shared_preferences`（JSON 字符串，单键存储）。
class SharedPrefsPerfAlertSettingsStore implements PerfAlertSettingsStore {
  const SharedPrefsPerfAlertSettingsStore();

  /// 存储键。
  static const String storageKey = 'perf_alert_settings';

  @override
  Future<PerfAlertSettings?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return PerfAlertSettings.fromMap(decoded);
    } catch (error) {
      debugPrint('[PerfAlertSettings] 读取告警设置失败: $error');
      return null;
    }
  }

  @override
  Future<void> save(PerfAlertSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(settings.toMap()));
    } catch (error) {
      debugPrint('[PerfAlertSettings] 保存告警设置失败: $error');
    }
  }
}

/// 内存实现（测试 / 无持久化环境回退）。
class InMemoryPerfAlertSettingsStore implements PerfAlertSettingsStore {
  InMemoryPerfAlertSettingsStore([this._settings]);

  PerfAlertSettings? _settings;

  @override
  Future<PerfAlertSettings?> load() async => _settings;

  @override
  Future<void> save(PerfAlertSettings settings) async => _settings = settings;
}
