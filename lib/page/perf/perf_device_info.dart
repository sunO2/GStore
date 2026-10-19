/// 性能监控页「概览」的设备信息（机型 / 平台 / 系统）——展示层本地 provider。
///
/// Scene 的帧率统计页（`fps-chart/index.html`）顶部有一行设备信息
/// （`Platform` / `Model` / `OS`）。GStore 性能页在「渲染 / FPS」区顶部镜像该头部：
/// * **首选来源**：原生 `perf.device`（[DeviceReport]）——含 `model`（机型）、
///   `hardware`（SoC / 平台）、`androidRelease`（系统），与 Scene 的
///   `device.soc` / `device.model` / `device.sdk` 语义对齐；
/// * **兜底来源**：`device_info_plus` 的 `androidInfo`（原生模块未就绪时仍可显示）；
/// * **降级**：任一来源失败 / 无值 → `null`（UI 显示「—」），**绝不抛出**。
///
/// **不新建状态存储**：本 provider 只读既有 [perfModuleProvider]，不改
/// [PerfPageState] / `logic.dart` 的采集主链路（避免拖累既有刷新批次）。
library;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/rust/perf/PerfModule.dart';

import 'logic.dart';

/// 概览「渲染 / FPS」区顶部展示的设备信息（各字段可空；`null` / 空 → UI 显「—」）。
class PerfDeviceInfo {
  const PerfDeviceInfo({this.model, this.platform, this.os});

  /// 机型（如 `Pixel 5`）。
  final String? model;

  /// 平台 / SoC（如 `qcom` / `mt6889`）。
  final String? platform;

  /// 系统版本（如 `Android 14`）。
  final String? os;
}

/// 设备信息（best-effort；任何失败 / 无数据 → `null`，UI 降级为「—」）。
final perfDeviceInfoProvider = FutureProvider<PerfDeviceInfo?>((ref) async {
  // 1) 原生 `perf.device`：字段最全（SoC + 系统版本），模块未就绪时失败 → 走兜底。
  final fromModule = await _fromModule(ref.read(perfModuleProvider));
  if (fromModule != null) return fromModule;
  // 2) `device_info_plus` 兜底（仅 Android；测试 / 缺失平台通道 → null）。
  return _fromPlatform();
});

/// 经原生 `perf.device` 读取设备信息；不可用 / 全空 → `null`（绝不抛）。
Future<PerfDeviceInfo?> _fromModule(PerfModule module) async {
  try {
    final report = await module.device();
    final info = PerfDeviceInfo(
      model: _clean(report.model),
      platform: _clean(report.hardware) ??
          _clean(report.cpuName) ??
          _clean(report.boardPlatform),
      os: _clean(report.androidRelease) ?? _clean(report.osRelease),
    );
    return _isEmpty(info) ? null : info;
  } catch (error) {
    debugPrint('[PerfDeviceInfo] perf.device 不可用（降级）: $error');
    return null;
  }
}

/// 经 `device_info_plus` 兜底读取设备信息；非 Android / 失败 / 全空 → `null`。
Future<PerfDeviceInfo?> _fromPlatform() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final android = await DeviceInfoPlugin().androidInfo;
    final release = android.version.release;
    final info = PerfDeviceInfo(
      model: _clean(android.model) ?? _clean(android.device),
      platform: _clean(android.hardware) ?? _clean(android.board),
      os: release.trim().isEmpty ? null : 'Android ${release.trim()}',
    );
    return _isEmpty(info) ? null : info;
  } catch (error) {
    debugPrint('[PerfDeviceInfo] device_info_plus 不可用（降级）: $error');
    return null;
  }
}

/// 去空白；空串 → `null`。
String? _clean(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// 三字段是否全空。
bool _isEmpty(PerfDeviceInfo info) =>
    info.model == null && info.platform == null && info.os == null;
