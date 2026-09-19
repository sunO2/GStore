import 'package:flutter/foundation.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/download/rust/lazy_download_service.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// 下载内核**实现**的选择开关。
///
/// 与 `module.download.enabled`（模块是否启用）是两件事：
/// - `module.download.enabled=false` → 整个下载模块下线；
/// - 本开关 → 下载模块绑定哪个 [IDownloadService] 实现。
///
/// 取值优先级：
/// 1. 运行时配置 `download.core`（`dart` / `rust`）
/// 2. 构建期参数 `--dart-define=DOWNLOAD_CORE_RUST=true`
/// 3. 默认 `dart` —— **保持既有行为，切换只需去掉/改回一个参数即可回退**
///
/// 选了 rust 但内核不可用时（未内置、未下载、ABI 不匹配、加载失败）
/// **回落 Dart 并告警**，而不是让下载功能整体不可用。
///
/// 日志：本文件**每条分支都会打印**，并且用 `debugPrint`（项目约定，
/// `main.dart` 已重定向到日志查看器）。所以：
/// **若日志里连一条 `DownloadCoreConfig:` 都没有，说明这段代码没执行**
/// （例如装的是未带 `DOWNLOAD_CORE_RUST` 的旧包），而不是"静默回落"。
class DownloadCoreConfig {
  DownloadCoreConfig._();

  /// 运行时配置键（若上层未注册该键，[ConfigService.get] 返回 null，走构建期参数）
  static const String configKey = 'download.core';

  /// 构建期开关：`flutter build apk --dart-define=DOWNLOAD_CORE_RUST=true`
  static const bool buildTimeRust =
      bool.fromEnvironment('DOWNLOAD_CORE_RUST', defaultValue: false);

  /// 解析要绑定的下载服务实现。
  ///
  /// [dartImpl] 是既有实现，作为默认与回落目标。
  ///
  /// 启动期**不做任何模块探测/下载**：
  /// - 运行时配置显式 `dart` → 直接返回 [dartImpl]（硬回退，可对比/排障）；
  /// - 其余情况 → 返回 [LazyDownloadService]，把 Rust 内核的可用性判断推迟到
  ///   首次**变更类**调用（见 `lazy_download_service.dart`），不可用/异常则静默
  ///   回落 Dart。
  ///
  /// 构期开关 [buildTimeRust] 仅作日志参考，**不再**在启动期强制探测 Rust；
  /// 因此本方法**永不抛错**（即使 Rust 路径不可用），冷启动也不再被内核拖慢。
  ///
  /// [rustProbe] / [rustServiceFactory] 仅用于测试注入，生产调用方省略。
  static Future<IDownloadService> resolve(
    IDownloadService dartImpl, {
    Future<bool> Function()? rustProbe,
    IDownloadService Function()? rustServiceFactory,
  }) async {
    final runtimeValue = await _readRuntimeValue();

    // 1) 显式配置优先：可强制回退 Dart（对比/排障用）。
    if (runtimeValue != null && runtimeValue.toLowerCase() == 'dart') {
      debugPrint('DownloadCoreConfig: 配置强制 Dart，使用 Dart 下载内核');
      return dartImpl;
    }

    // 2) 默认返回惰性路由：启动期零探测、零下载。
    debugPrint(
      'DownloadCoreConfig: 返回惰性下载路由（启动期不探测内核）—— '
      '$configKey=$runtimeValue, 构建期 DOWNLOAD_CORE_RUST=$buildTimeRust',
    );
    return LazyDownloadService(
      dartImpl,
      rustProbe: rustProbe,
      rustServiceFactory: rustServiceFactory,
    );
  }

  /// 读运行时配置；未注册/读取失败返回 null（不阻塞，交给构建期参数）。
  static Future<String?> _readRuntimeValue() async {
    try {
      final v = await ConfigService.instance.get(configKey);
      return v is String && v.isNotEmpty ? v : null;
    } catch (e) {
      debugPrint('DownloadCoreConfig: 读取 $configKey 失败，改用构建期参数 - $e');
      return null;
    }
  }
}
