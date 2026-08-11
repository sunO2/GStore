/// 服务接口定义
///
/// 各业务服务的抽象接口，供 ModuleManager 绑定与动态代理使用：
/// - 调用方依赖接口而非具体类（不直接调用模块组件功能）
/// - 模块上线时 bind 实现，下线时 unbind
/// - 可选 DynamicProxy 实现延迟绑定/热插拔
library;

import 'package:flutter/material.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/webdav/webdav_client.dart';
import 'package:gstore/core/webdav/webdav_config.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

/// 下载服务接口
abstract class IDownloadService {
  /// 下载应用 APK
  Future<DownloadStatus> download(
    String appid,
    String appName,
    String version,
    String url,
    String fileName, {
    int? downloadSize,
    bool breakPoint = true,
    String? saveFileName,
    bool forceDownload = false,
  });
}

/// 备份服务接口
abstract class IBackupService {
  /// 导出备份数据
  Future<BackupData> exportData({BackupOptions? options});

  /// 导出到文件
  Future<String> exportToFile({BackupOptions? options});

  /// 导出压缩文件（tar.gz）
  Future<String> exportToCompressedFile({BackupOptions? options});

  /// 从文件导入
  Future<BackupImportResult> importFromFile(
    String filePath, {
    BackupImportMode mode = BackupImportMode.merge,
  });

  /// 列出备份文件
  Future<List<BackupFile>> getBackupFiles();

  /// 删除备份文件
  Future<void> deleteBackupFile(String filePath);
}

/// WebDAV 服务接口
abstract class IWebDavService {
  /// 测试连接
  Future<bool> testWebDavConnection(WebDavConfig config);

  /// 列出目录文件
  Future<List<WebDavFile>> listFiles(String dirPath, {String? pattern});

  /// 上传备份到 WebDAV
  Future<String> uploadToWebDav({
    required WebDavConfig config,
    bool compressed = true,
    bool includeAppConfig = false,
  });

  /// 从 WebDAV 下载并导入
  Future<BackupImportResult> downloadFromWebDav({
    required WebDavConfig config,
    required String remotePath,
    BackupImportMode mode = BackupImportMode.merge,
    bool restoreAppConfig = true,
  });
}

/// F-Droid 仓库服务接口
abstract class IFdroidRepoService {
  /// 加载仓库索引
  Future<void> loadRepository({bool forceRefresh = false});

  /// 搜索应用
  Future<List<Map<String, dynamic>>> searchApps(String keyword, {int limit = 50});

  /// 获取应用详情
  Future<Map<String, dynamic>?> getAppByPackageName(String packageName);

  /// 获取全部应用
  Future<List<Map<String, dynamic>>> getAllApps();

  /// 应用数量
  Future<int> getAppCount();

  /// 统计信息
  Future<Map<String, int>> getStatistics();

  /// 切换源
  Future<void> switchSource(String sourceId);

  /// 添加源
  Future<void> addSource(FdroidSource source);

  /// 移除源
  Future<void> removeSource(String sourceId);

  /// 清空数据
  Future<void> clearData();
}

/// 主题服务接口
abstract class IThemeService {
  /// 当前主题模式
  AppThemeMode get themeMode;

  /// 当前主题配置
  AppThemeConfig get themeConfig;

  /// 设置主题模式
  Future<void> setThemeMode(AppThemeMode mode);

  /// 切换深浅色
  Future<void> toggleTheme();

  /// 设置自定义颜色主题
  Future<void> setCustomColorTheme({
    required Color primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
  });

  /// 重置默认
  Future<void> resetToDefault();
}

/// 安装服务接口
abstract class IInstallService {
  /// 安装 APK（Shizuku 静默或系统安装器）
  Future<(bool, dynamic)> installApk(String filePath);

  /// 卸载应用
  Future<bool> managePackage(String packageName, String action);

  /// 清理应用数据
  Future<bool> clearAppData(String packageName);

  /// 清理应用缓存
  Future<bool> clearAppCache(String packageName);

  /// 强制停止应用
  Future<bool> forceStopApp(String packageName);
}

/// 聚合（我的应用）服务接口
abstract class IAggregateService {
  /// 移除应用
  Future<void> removeApp({
    required ChannelType channel,
    required String appId,
  });

  /// 是否已添加
  Future<bool> isAppAdded({
    required ChannelType channel,
    required String appId,
  });

  /// 全部已添加应用
  Future<List<AddedAppInfo>> getAllAddedApps();

  /// 按渠道获取
  Future<List<AddedAppInfo>> getAppsByChannel(ChannelType channel);

  /// 总数
  Future<int> getTotalCount();
}

/// 已安装应用服务接口
abstract class IInstalledAppsService {
  /// 已安装应用列表
  Future<List<dynamic>> getInstalledApps();

  /// 是否已安装
  Future<bool?> isAppInstalled(String packageName);
}
