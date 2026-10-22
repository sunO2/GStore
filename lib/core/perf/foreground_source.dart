/// 前台应用事件源（AccessibilityService）的 Dart 模型与容错解析层。
///
/// Kotlin `ForegroundAccessibilityService.readJson` 经 `gstore/platform`
/// 暴露为一次平台通道调用；本文件把它解析为 [ForegroundReading]，并提供可注入的
/// [RustJniForegroundBridge]。单测无需平台通道 / 真机。
///
/// 所有解析入口**绝不抛出**：非法 / 非对象 JSON → `null`，缺失字段 → `null`。
library;

import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:gstore/core/platform/platform_channel.dart';

/// 一次无障碍服务前台缓存快照。
class ForegroundReading {
  const ForegroundReading({
    required this.enabled,
    this.package,
    this.activity,
    this.updatedAtMs,
  });

  /// 无障碍服务是否已在系统设置中启用。
  final bool enabled;

  /// 最近一次窗口事件的包名；`null` = 尚未收到事件。
  final String? package;

  /// 最近一次窗口事件的 Activity 类名；`null` = 未知。
  final String? activity;

  /// 最近一次窗口事件时间（Unix ms；`0` = 尚未收到事件）。
  final int? updatedAtMs;

  /// 是否可作为前台数据源：服务已启用**且**已有包名。
  bool get usable => enabled && (package?.isNotEmpty ?? false);

  @override
  String toString() =>
      'ForegroundReading(enabled: $enabled, package: $package, '
      'activity: $activity, updatedAtMs: $updatedAtMs)';
}

/// 把 `foreground_read_json` 的 JSON 解析为 [ForegroundReading]。
///
/// 非法 JSON / 非对象 → `null`；字段缺失 → 对应字段为 `null`（`enabled`
/// 缺失按 `false`）。**绝不抛出**。
ForegroundReading? foregroundReadingFromJson(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final map = <String, Object?>{
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
    };
    return ForegroundReading(
      enabled: _asBool(map['enabled']) ?? false,
      package: _asString(map['package']),
      activity: _asString(map['activity']),
      updatedAtMs: _asInt(map['updatedAtMs']),
    );
  } catch (error) {
    debugPrint('[ForegroundSource] JSON 解析失败: $error');
    return null;
  }
}

/// 无障碍服务探测 seam（生产：`gstore/platform.readForeground`；测试可注入）。
typedef ForegroundAccessibilityProbe = Future<ForegroundReading?> Function();

/// `gstore/platform.readForeground` 的 Dart 门面。
///
/// 类名与构造参数保持历史形状；生产默认走
/// [PlatformChannelClient.readForeground]。[readJson] 可注入，单测无需平台通道。
/// 所有入口**绝不抛出**（异常 / 未实现 / 非法 JSON → `null`）。
class RustJniForegroundBridge {
  RustJniForegroundBridge({
    Future<String?> Function()? readJson,
    PlatformChannelClient? client,
  }) : _readJson = readJson ?? (() => _readJsonFrom(client));

  final Future<String?> Function() _readJson;

  static final PlatformChannelClient _defaultClient = PlatformChannelClient();

  static Future<String?> _readJsonFrom(PlatformChannelClient? client) async =>
      jsonEncode(await (client ?? _defaultClient).readForeground());

  /// 读取一次并解析；不可用 / 失败 → `null`。
  Future<ForegroundReading?> read() async {
    try {
      final json = await _readJson();
      if (json == null || json.isEmpty) return null;
      return foregroundReadingFromJson(json);
    } catch (error) {
      debugPrint('[RustJniForegroundBridge] read 失败: $error');
      return null;
    }
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) {
    return value.isFinite ? value.round() : null;
  }
  if (value is String) {
    return int.tryParse(value.trim());
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
