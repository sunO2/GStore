import 'package:flutter/foundation.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/download/manager/download_manager.dart';
import 'package:gstore/core/download/rust/rust_download_service.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';

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
  static Future<IDownloadService> resolve(DownloadManager dartImpl) async {
    final runtimeValue = await _readRuntimeValue();

    // 只读探测：走 RustModuleLoader.isAvailable → Kotlin hasModule
    // （**APK 内含 或 已解压**），且不解压、不 dlopen。
    //
    // 注意：不能用 probe()——它只查"已解压产物"，首次安装必然为 false。
    var present = false;
    try {
      present = await RustModuleLoader.instance
          .isAvailable(RustDownloadService.moduleName);
    } catch (e) {
      debugPrint('DownloadCoreConfig: 探测 Rust 内核失败 - $e');
    }

    debugPrint(
      'DownloadCoreConfig: 选择开始 —— $configKey=$runtimeValue, '
      '构建期 DOWNLOAD_CORE_RUST=$buildTimeRust, Rust 模块存在=$present',
    );

    // 1) 显式配置优先：可强制回退 Dart（对比/排障用）
    if (runtimeValue != null && runtimeValue.toLowerCase() == 'dart') {
      debugPrint('DownloadCoreConfig: 配置强制 Dart，使用 Dart 下载内核');
      return dartImpl;
    }

    // 2) 默认按「模块是否存在」决定。
    //
    // 与项目约定一致：**模块不在，能力就不在**——所以不需要任何构建参数，
    // 把 jniLibs 里的 .so 移除即自动回落 Dart。
    if (present) {
      debugPrint('DownloadCoreConfig: 使用 Rust 下载内核（模块存在）');
      return RustDownloadService.instance;
    }

    debugPrint('DownloadCoreConfig: Rust 模块不存在，使用 Dart 下载内核');
    return dartImpl;
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
