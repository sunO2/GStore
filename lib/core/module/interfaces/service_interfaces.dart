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
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/webdav/webdav_client.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/webdav/webdav_config.dart';

/// 下载服务接口
abstract class IDownloadService {
  /// 下载应用 APK
  Future<DownloadTask> download(
    String appid,
    String appName,
    String version,
    String url,
    String fileName, {
    int? downloadSize,
    bool breakPoint = true,
    String? saveFileName,
    bool forceDownload = false,
    bool installAfterDownload = true,
  });

  /// 使用下载上下文下载（策略模式：自定义请求头/代理/URL 转换/超时）
  Future<DownloadTask> downloadWithContext(
    DownloadRequest request,
    String appid,
    String appName,
    String version,
    String fileName, {
    bool breakPoint = true,
    String? saveFileName,
    bool installAfterDownload = true,
  });

  /// 暂停下载任务
  Future<void> pause(int id);

  /// 恢复下载任务
  Future<void> resume(int id);

  /// 取消下载任务
  Future<void> cancel(int id);

  /// 删除任务记录。**必须由实现方删除自己的持久化数据**
  /// （Rust 内核在模块库里，只删 Dart 的 Floor 会导致记录"复活"）
  Future<void> remove(int id);

  /// 重试下载任务
  Future<void> retry(int id);

  /// 重新下载：**清空已下分段与进度，从 0 开始**。
  ///
  /// 与 [resume] / [retry]（保留分段续传）语义不同，用于文件损坏、源变更等需要重来的场景。
  Future<void> restart(int id);

  /// 获取下载任务
  Future<DownloadTask?> getTask(int id);

  /// 列出全部下载任务。
  ///
  /// **这是面板任务列表的数据源**——换实现即换真源：
  /// Dart 实现读 Floor，Rust 实现向内核查询。
  /// 调用方不应再直接读 `DownloadRepository`，否则切内核后面板会看不到任务。
  Future<List<DownloadTask>> listTasks();

  /// 监听下载任务状态
  Stream<DownloadTask> watch(int id);

  /// 全局任务流（所有任务）。供通知栏 / 自动安装统一消费。
  /// Dart 内核返回空流：它已自行驱动通知，避免重复弹。
  Stream<DownloadTask> watchAll();
}

/// 备份服务接口
abstract class IBackupService {
  /// 导出备份数据
  Future<BackupData> exportData({BackupOptions? options});

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
  Future<Map<String, dynamic>?> getAppByPackageName(String packageName, {String? sourceId});

  /// 获取全部应用
  Future<List<Map<String, dynamic>>> getAllApps();

  /// 应用数量
  Future<int> getAppCount();

  /// 统计信息（**按源**：每个源自己库里的应用数，未同步过为 0）
  Future<List<FdroidSourceStat>> getStatistics();

  /// 切换源
  Future<void> switchSource(String sourceId);

  /// 当前配置的源列表（含启用状态与镜像配置）
  List<FdroidSource> get sources;

  /// 当前选中源（**仅用于显示/默认**，不得用于数据定位）
  FdroidSource? get currentSource;

  /// 仓库身份键（指纹优先，其次归一化地址）——渠道把源标识写入自有记录时使用
  String identityKeyFor(FdroidSource source);

  /// 某源**实际生效**的资源基址（模块 `resolved_url`：镜像回退后真正下载成功的地址）。
  ///
  /// 这是资源地址的**唯一产出方**：宿主不得再用"第一个启用镜像"另算一套，
  /// 否则镜像挂掉时搜索走可用地址、列表图标仍指向坏镜像（真机图标 404）。
  /// 未缓存时返回 null（调用方用 [ensureBaseFor] 补读）。
  String? cachedBaseFor(FdroidSource source);

  /// 冷启动/缓存未命中时补读该源的 `resolved_url`（只读该源自己的本地库，不触网）
  Future<void> ensureBaseFor(FdroidSource source);

  /// 启用/禁用某个源（**多源可同时启用**）
  Future<void> setSourceEnabled(String sourceId, bool enabled);

  /// 逐个加载**全部已启用**的源（每个源独立库；单个失败不影响其它源）
  Future<int> loadAllEnabled();

  /// 添加源
  Future<void> addSource(FdroidSource source);

  /// 更新源配置（镜像启用/增删、是否启用镜像回退等）并持久化
  Future<void> updateSource(FdroidSource source);

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
  /// 已添加应用变化事件流
  Stream<List<AddedAppInfo>> get appsChangedStream;

  /// 移除应用
  Future<void> removeApp({
    required String channelCode,
    required String appId,
  });

  /// 是否已添加
  Future<bool> isAppAdded({
    required String channelCode,
    required String appId,
  });

  /// 全部已添加应用
  Future<List<AddedAppInfo>> getAllAddedApps();

  /// 按渠道获取
  Future<List<AddedAppInfo>> getAppsByChannel(String channelCode);

  /// 总数
  Future<int> getTotalCount();

  /// 批量添加应用
  Future<void> addApps({
    required String channelCode,
    required List<AppSummary> appInfos,
  });

  /// 切换应用添加状态
  Future<bool> toggleApp({
    required String channelCode,
    required AppSummary appInfo,
  });

  /// 获取应用的用户标签（无标签返回空列表）
  Future<List<String>> getTags({
    required String channelCode,
    required String appId,
  });

  /// 设置应用的用户标签（整体替换：先清空再写入）
  Future<void> setTags({
    required String channelCode,
    required String appId,
    required List<String> tags,
  });

  /// 清空指定渠道的所有应用
  Future<void> clearChannel(String channelCode);

  /// 获取已添加应用的索引（ChannelCode → Set<AppId>）
  Future<Map<String, Set<String>>> getAddedAppsIndex();

  /// 从渠道获取已添加应用的详细信息（聚合所有渠道）
  Future<List<AggregatedAppInfo>> getAggregatedApps();

  /// 分页获取聚合应用详情（首页列表用，避免一次性全量加载耗时）
  /// 返回 (本页聚合应用, 已添加应用总数)
  Future<(List<AggregatedAppInfo> apps, int total)> getAggregatedAppsPage({
    required int offset,
    required int limit,
  });
}

/// 已安装应用服务接口
abstract class IInstalledAppsService {
  /// 已安装应用列表
  Future<List<dynamic>> getInstalledApps();

  /// 是否已安装
  Future<bool?> isAppInstalled(String packageName);
}
