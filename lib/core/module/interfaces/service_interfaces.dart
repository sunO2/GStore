/// 服务接口定义
///
/// 各业务服务的抽象接口，供 ModuleManager 绑定与动态代理使用：
/// - 调用方依赖接口而非具体类（不直接调用模块组件功能）
/// - 模块上线时 bind 实现，下线时 unbind
/// - 可选 DynamicProxy 实现延迟绑定/热插拔
library;

import 'dart:typed_data';

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

  /// 导出备份压缩包（tar.gz bytes）——供 WebDAV 等传输层上传
  Future<Uint8List> exportCompressedBackup({
    BackupOptions? options,
    List<ChannelType>? channels,
    bool includeAppConfig = false,
    BackupLogCallback? onLog,
  });

  /// 从备份压缩包 bytes 恢复（下载层拉取后交给备份模块）
  Future<BackupImportResult> importBackupBytes(
    Uint8List bytes, {
    BackupImportMode mode = BackupImportMode.merge,
    bool restoreAppConfig = true,
    BackupLogCallback? onLog,
  });

  /// 列出备份文件
  Future<List<BackupFile>> getBackupFiles();

  /// 删除备份文件
  Future<void> deleteBackupFile(String filePath);
}

/// WebDAV 任务类型
enum WebDavTaskType {
  /// 上传任务
  upload,

  /// 下载任务
  download,
}

/// WebDAV 任务管理器接口（防重复 + 状态）
abstract class IWebDavTaskManager {
  /// 是否正在上传
  bool get isUploading;

  /// 是否正在下载
  bool get isDownloading;

  /// 是否有任务进行中
  bool get isBusy;

  /// 尝试开始任务（已 busy 时返回 false）
  bool tryStart(WebDavTaskType type);

  /// 结束任务（复位对应状态）
  void finish(WebDavTaskType type);
}

/// WebDAV 服务接口（纯传输层）
abstract class IWebDavService {
  /// 测试连接
  Future<bool> testWebDavConnection(WebDavConfig config);

  /// 列出目录文件
  Future<List<WebDavFile>> listFiles(String dirPath, {String? pattern});

  /// 上传备份到 WebDAV
  Future<String> uploadToWebDav({
    required WebDavConfig config,
    bool compressed = true,
    BackupOptions? options,
    List<ChannelType>? channels,
    bool includeAppConfig = false,
    BackupLogCallback? onLog,
  });

  /// 从 WebDAV 下载并导入
  Future<BackupImportResult> downloadFromWebDav({
    required WebDavConfig config,
    required String remotePath,
    BackupImportMode mode = BackupImportMode.merge,
    bool restoreAppConfig = true,
    BackupLogCallback? onLog,
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
