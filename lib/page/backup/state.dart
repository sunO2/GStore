import 'package:gstore/core/core.dart';

/// WebDAV 连接状态
enum WebDavConnectionStatus {
  /// 未配置
  notConfigured,

  /// 连接成功
  connected,

  /// 连接失败
  failed,

  /// 测试中
  testing,
}

/// 恢复模式
enum RestoreMode {
  /// 覆盖模式
  replace,

  /// 合并模式
  merge,

  /// 更新模式
  update,
}

/// 备份页状态（不可变，配合 ChangeNotifier 使用）。
class BackupState {
  /// 是否正在导出
  final bool isExporting;

  /// 是否正在导入
  final bool isImporting;

  /// 统计信息
  final BackupStatistics? statistics;

  /// 错误信息
  final String errorMessage;

  /// 是否已配置 WebDAV
  final bool hasWebDavConfig;

  /// 是否正在上传到 WebDAV
  final bool isUploadingWebDav;

  /// WebDAV 连接状态
  final WebDavConnectionStatus webDavStatus;

  /// 是否包含应用配置（导出时）
  final bool includeAppConfig;

  /// 是否恢复应用配置（导入时）
  final bool restoreAppConfig;

  /// 导出选项：是否包含图标 URL
  final bool includeIconUrls;

  /// 导出选项：是否包含描述
  final bool includeDescription;

  /// 导出选项：是否包含分类
  final bool includeCategory;

  /// 导出选项：是否包含 extra 字段
  final bool includeExtra;

  /// 导出选项：是否仅包含已启用的应用
  final bool enabledOnly;

  /// 恢复模式
  final RestoreMode restoreMode;

  const BackupState({
    this.isExporting = false,
    this.isImporting = false,
    this.statistics,
    this.errorMessage = '',
    this.hasWebDavConfig = false,
    this.isUploadingWebDav = false,
    this.webDavStatus = WebDavConnectionStatus.notConfigured,
    this.includeAppConfig = true,
    this.restoreAppConfig = true,
    this.includeIconUrls = true,
    this.includeDescription = true,
    this.includeCategory = true,
    this.includeExtra = true,
    this.enabledOnly = false,
    this.restoreMode = RestoreMode.merge,
  });

  BackupState copyWith({
    bool? isExporting,
    bool? isImporting,
    BackupStatistics? statistics,
    bool clearStatistics = false,
    String? errorMessage,
    bool? hasWebDavConfig,
    bool? isUploadingWebDav,
    WebDavConnectionStatus? webDavStatus,
    bool? includeAppConfig,
    bool? restoreAppConfig,
    bool? includeIconUrls,
    bool? includeDescription,
    bool? includeCategory,
    bool? includeExtra,
    bool? enabledOnly,
    RestoreMode? restoreMode,
  }) {
    return BackupState(
      isExporting: isExporting ?? this.isExporting,
      isImporting: isImporting ?? this.isImporting,
      statistics:
          clearStatistics ? null : statistics ?? this.statistics,
      errorMessage: errorMessage ?? this.errorMessage,
      hasWebDavConfig: hasWebDavConfig ?? this.hasWebDavConfig,
      isUploadingWebDav: isUploadingWebDav ?? this.isUploadingWebDav,
      webDavStatus: webDavStatus ?? this.webDavStatus,
      includeAppConfig: includeAppConfig ?? this.includeAppConfig,
      restoreAppConfig: restoreAppConfig ?? this.restoreAppConfig,
      includeIconUrls: includeIconUrls ?? this.includeIconUrls,
      includeDescription: includeDescription ?? this.includeDescription,
      includeCategory: includeCategory ?? this.includeCategory,
      includeExtra: includeExtra ?? this.includeExtra,
      enabledOnly: enabledOnly ?? this.enabledOnly,
      restoreMode: restoreMode ?? this.restoreMode,
    );
  }
}
