import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart' as ia;
import 'package:gstore/core/core.dart';

/// 应用图标服务
/// 获取已安装应用的图标作为后备
class AppIconService {
  static AppIconService? _instance;
  static AppIconService get instance {
    _instance ??= AppIconService._internal();
    return _instance!;
  }

  AppIconService._internal();

  /// 图标缓存 (packageName -> icon path)
  final Map<String, String> _iconCache = {};

  /// 获取已安装应用的图标
  /// 返回图标文件路径，如果应用未安装或获取失败则返回 null
  Future<String?> getInstalledAppIcon(String packageName) async {
    // 检查缓存
    if (_iconCache.containsKey(packageName)) {
      final cachedPath = _iconCache[packageName];
      if (cachedPath != null && await File(cachedPath).exists()) {
        debugPrint('AppIconService: 使用缓存的图标 - $packageName');
        return cachedPath;
      } else {
        _iconCache.remove(packageName);
      }
    }

    try {
      debugPrint('AppIconService: 获取已安装应用图标 - $packageName');

      // 检查应用是否已安装
      final isInstalled = await InstalledApps.isAppInstalled(packageName);
      if (isInstalled != true) {
        debugPrint('AppIconService: 应用未安装 - $packageName');
        return null;
      }

      // 获取应用图标路径
      final iconPath = await _getAppIconPath(packageName);
      if (iconPath != null) {
        _iconCache[packageName] = iconPath;
        appLog.info('AppIconService: 成功获取图标 - $packageName -> $iconPath');
        return iconPath;
      }

      appLog.error('AppIconService: 无法获取图标 - $packageName');
      return null;
    } catch (e) {
      appLog.error('AppIconService: 获取图标失败 - $packageName, $e');
      return null;
    }
  }

  /// 获取应用图标路径（平台特定实现）
  Future<String?> _getAppIconPath(String packageName) async {
    if (!Platform.isAndroid) {
      debugPrint('AppIconService: 仅支持 Android 平台');
      return null;
    }

    try {
      // 使用 InstalledApps 插件获取所有应用（包含图标）
      // 注意：这会获取所有应用，可能较慢
      final apps = await InstalledApps.getInstalledApps(
        true,  // excludeSystemApps
        true,  // withIcon
        packageName,  // packageNamePrefix
      );

      // 查找目标应用
      final targetApp = apps.cast<ia.AppInfo?>().firstWhere(
        (app) => app?.packageName == packageName,
        orElse: () => null,
      );
      if (targetApp == null) {
        debugPrint('AppIconService: 未找到应用 - $packageName');
        return null;
      }

      // 获取图标数据
      final iconBytes = targetApp.icon;
      if (iconBytes == null || iconBytes.isEmpty) {
        debugPrint('AppIconService: 图标数据为空 - $packageName');
        return null;
      }

      // 保存到缓存目录
      return await _saveIconToCache(packageName, iconBytes);
    } catch (e) {
      appLog.error('AppIconService: 获取图标失败 - $packageName, $e');
      return null;
    }
  }

  /// 将图标保存到缓存目录
  Future<String?> _saveIconToCache(String packageName, Uint8List iconBytes) async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final iconDir = Directory(path.join(cacheDir.path, 'app_icons'));
      if (!await iconDir.exists()) {
        await iconDir.create(recursive: true);
      }

      final iconFile = File(path.join(iconDir.path, '$packageName.png'));
      await iconFile.writeAsBytes(iconBytes);

      debugPrint('AppIconService: 图标已保存到缓存 - ${iconFile.path}');
      return iconFile.path;
    } catch (e) {
      appLog.error('AppIconService: 保存图标失败 - $e');
      return null;
    }
  }

  /// 检查图标 URL 是否有效
  /// 如果图标 URL 为空或是相对路径，返回 false
  static bool isValidIconUrl(String? iconUrl) {
    if (iconUrl == null || iconUrl.isEmpty) {
      return false;
    }

    // 检查是否是完整的 HTTP(S) URL
    if (iconUrl.startsWith('http://') || iconUrl.startsWith('https://')) {
      return true;
    }

    // 检查是否是本地文件路径
    if (iconUrl.startsWith('/') || iconUrl.startsWith('file://')) {
      return File(iconUrl.replaceFirst('file://', '')).existsSync();
    }

    // 相对路径被视为无效（需要拼接基础 URL）
    return false;
  }

  /// 获取应用图标（带后备逻辑）
  /// 优先使用传入的 iconUrl，如果无效则尝试获取已安装应用的图标
  Future<String?> getAppIconWithFallback(String packageName, String? iconUrl) async {
    // 1. 检查原始图标是否有效
    if (isValidIconUrl(iconUrl)) {
      return iconUrl;
    }

    // 2. 尝试获取已安装应用的图标
    debugPrint('AppIconService: 原始图标无效，尝试获取已安装应用图标 - $packageName');
    return await getInstalledAppIcon(packageName);
  }

  /// 清除图标缓存
  Future<void> clearCache() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final iconDir = Directory(path.join(cacheDir.path, 'app_icons'));
      if (await iconDir.exists()) {
        await iconDir.delete(recursive: true);
        debugPrint('AppIconService: 已清除图标缓存');
      }
      _iconCache.clear();
    } catch (e) {
      appLog.error('AppIconService: 清除缓存失败 - $e');
    }
  }

  /// 预加载图标（用于批量获取）
  Future<void> preloadIcons(List<String> packageNames) async {
    appLog.info('AppIconService: 开始预加载 ${packageNames.length} 个应用图标');
    int successCount = 0;

    for (var packageName in packageNames) {
      final iconPath = await getInstalledAppIcon(packageName);
      if (iconPath != null) {
        successCount++;
      }
    }

    appLog.info('AppIconService: 预加载完成 - 成功: $successCount/${packageNames.length}');
  }
}
