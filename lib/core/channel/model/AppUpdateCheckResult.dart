import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// 渠道应用更新检测结果
/// 由各渠道内部实现，决定如何获取最新版本信息
/// （本地索引 / GitHub releases / 数据库 / 网络 API 等）
class AppUpdateCheckResult {
  /// 应用 ID（渠道内原始 ID）
  final String appId;

  /// 包名
  final String packageName;

  /// 应用名称
  final String name;

  /// 图标 URL
  final String? icon;

  /// 渠道最新版本号
  final String? latestVersion;

  /// 最新版本下载信息（可能为空）
  final DownloadInfo? latestDownload;

  /// 完整详情（供下载策略上下文 / 详情展示）
  final IDetailInfo detail;

  AppUpdateCheckResult({
    required this.appId,
    required this.packageName,
    required this.name,
    this.icon,
    this.latestVersion,
    this.latestDownload,
    required this.detail,
  });
}
