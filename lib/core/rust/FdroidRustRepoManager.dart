import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show FdroidRepoManager;
import 'package:gstore/core/rust/generated/components.dart' show ApkComponents;
import 'package:gstore/core/rust/generated/elf.dart' show ApkElfScanResult;
import 'package:gstore/core/rust/generated/frb_generated.dart' show RustLib;
import 'package:gstore/core/rust/generated/models.dart'
    show AppInfo, ApkInfo, DownloadResult;

/// Rust F-Droid 仓库管理器
///
/// 使用 Rust 实现，提供更快的网络下载和 JSON 解析性能
class FdroidRustRepoManager {
  FdroidRustRepoManager._();

  static bool _initialized = false;
  static FdroidRepoManager? _manager;

  /// 初始化管理器和 bridge
  static Future<void> initialize({String? dbPath}) async {
    if (!_initialized) {
      // 初始化 flutter_rust_bridge
      await RustLib.init();
      _initialized = true;
      appLog.info('FdroidRustRepoManager: Bridge initialized');
    }

    if (_manager == null) {
      final db = dbPath ??
          path.join(
            (await _getApplicationDocumentsDirectory()).path,
            'fdroid_rust.db',
          );

      try {
        // 创建新实例
        _manager = await FdroidRepoManager.newInstance();
        await _manager!.initialize(dbPath: db);
        appLog.info('FdroidRustRepoManager: 初始化成功 - $db');
      } catch (e) {
        appLog.error('FdroidRustRepoManager: 初始化失败 - $e');
        rethrow;
      }
    }
  }

  /// 下载并解析仓库
  ///
  /// 使用 Rust 在后台线程下载和解析 JSON，避免阻塞 UI
  /// 返回下载的应用数量
  static Future<int> downloadRepository({
    required String repoUrl,
  }) async {
    if (_manager == null) {
      await initialize();
    }

    try {
      appLog.info('FdroidRustRepoManager: 开始下载 $repoUrl');

      final result = await _manager!.downloadRepo(repoUrl: repoUrl);

      appLog.info('FdroidRustRepoManager: 下载完成 - ${result.totalApps} 个应用, '
          '耗时 ${result.downloadTimeMs}ms');

      return result.totalApps;
    } catch (e) {
      appLog.error('FdroidRustRepoManager: 下载失败 - $e');
      rethrow;
    }
  }

  /// 获取应用数量
  static Future<int> getAppCount() async {
    if (_manager == null) {
      await initialize();
    }

    try {
      return await _manager!.getAppCount();
    } catch (e) {
      appLog.error('FdroidRustRepoManager: 获取应用数量失败 - $e');
      return 0;
    }
  }

  /// 搜索应用
  static Future<List<AppInfo>> searchApps(String keyword,
      {int limit = 50}) async {
    if (_manager == null) {
      await initialize();
    }

    try {
      final results =
          await _manager!.searchApps(keyword: keyword, limit: limit);
      return results;
    } catch (e) {
      appLog.error('FdroidRustRepoManager: 搜索失败 - $e');
      return [];
    }
  }

  /// 清空所有应用数据
  static Future<int> clearApps() async {
    if (_manager == null) {
      await initialize();
    }

    try {
      final count = await _manager!.clearApps();
      appLog.info('FdroidRustRepoManager: 已清空 $count 个应用');
      return count;
    } catch (e) {
      appLog.error('FdroidRustRepoManager: 清空应用失败 - $e');
      return 0;
    }
  }

  /// 获取一个应用（用于调试）
  static Future<AppInfo?> getOneApp() async {
    if (_manager == null) {
      await initialize();
    }

    try {
      final app = await _manager!.getOneApp();
      if (app != null) {
        debugPrint(
            'FdroidRustRepoManager: 调试信息 - packageName=${app.packageName}, name=${app.name}, icon=${app.icon}');
      } else {
        debugPrint('FdroidRustRepoManager: 数据库中没有应用');
      }
      return app;
    } catch (e) {
      appLog.error('FdroidRustRepoManager: 获取应用失败 - $e');
      return null;
    }
  }

  /// 获取应用文档目录
  static Future<Directory> _getApplicationDocumentsDirectory() async {
    // 使用 path_provider 的简化版本
    final home = Platform.environment['HOME'];
    if (home != null) {
      return Directory(path.join(home, '.gstore'));
    }
    return Directory.current;
  }

  /// 转换 Rust 模型到 Dart 模型（Map）
  static Map<String, dynamic> appInfoToMap(AppInfo rustApp) {
    return {
      'packageName': rustApp.packageName,
      'name': rustApp.name,
      'summary': rustApp.summary,
      'icon': rustApp.icon,
      'license': rustApp.license,
      'authorName': rustApp.authorName,
      'sourceCode': rustApp.sourceCode,
      'webSite': rustApp.webSite,
      'categories': rustApp.categories,
      'added': rustApp.added,
      'lastUpdated': rustApp.lastUpdated,
      'metadata': rustApp.metadata,
      'versions': rustApp.versions,
    };
  }

  /// 解析 APK 文件，提取真实包名/版本/应用名等信息
  /// 在安装前调用（Rust 实现，从 APK 的 AndroidManifest.xml 解析）
  static Future<ApkInfo> parseApkInfo(String apkPath) async {
    if (_manager == null) {
      await initialize();
    }
    return await _manager!.parseApkInfo(apkPath: apkPath);
  }

  /// 扫描 APK 内所有 classes*.dex 的类名并与 patterns 匹配（方案 B DEX 检测）
  ///
  /// Rust 实现（fdroid_repo::dex_scan）：patterns 为 LibChecker matchesClassPattern
  /// 语义，`*` 结尾=前缀匹配，否则精确。返回命中的点分类名（如 androidx.lifecycle.LiveData）。
  /// 调用方负责容错（Rust 不可用/失败时降级为空）。
  static Future<List<String>> scanDexClasses(
    String apkPath,
    List<String> patterns,
  ) async {
    if (_manager == null) {
      await initialize();
    }
    return await _manager!.scanDexClasses(apkPath: apkPath, patterns: patterns);
  }

  /// 解析 APK 的 AndroidManifest.xml，枚举四类组件名与 minSdk/targetSdk
  /// （方案 C 组件库检测）。Rust 实现（fdroid_repo::components）。
  /// 调用方负责容错（Rust 不可用/失败时降级为空）。
  static Future<ApkComponents> parseComponents(String apkPath) async {
    if (_manager == null) {
      await initialize();
    }
    return await _manager!.parseComponents(apkPath: apkPath);
  }

  /// 扫描 APK 内所有 `lib/<abi>/*.so` 的 PT_LOAD 段页对齐（16KB 兼容检测）。
  /// Rust 实现（fdroid_repo::elf_scan）：返回每个 .so 的 ABI/文件名/
  /// 最小 p_align 与是否 16KB 对齐。
  /// 调用方负责容错（Rust 不可用/失败时降级为空）。
  static Future<ApkElfScanResult> scanElfPageSizes(String apkPath) async {
    if (_manager == null) {
      await initialize();
    }
    return await _manager!.scanElfPageSizes(apkPath: apkPath);
  }
}
