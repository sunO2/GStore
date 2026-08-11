/// 更新检测结果模型
library;

import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// 可更新的应用信息
class AppUpdateInfo {
  /// 来源渠道
  final String channelId;

  /// 应用 ID（渠道内原始 ID）
  final String appId;

  /// 应用名称
  final String appName;

  /// 图标 URL
  final String? iconUrl;

  /// 包名
  final String packageName;

  /// 已安装版本
  final String installedVersion;

  /// 最新版本
  final String latestVersion;

  /// 最新版本的下载信息
  final DownloadInfo latestDownload;

  /// 完整详情（用于下载策略上下文）
  final IDetailInfo detail;

  /// 检测时间（缓存有效性判断）
  final DateTime checkedAt;

  AppUpdateInfo({
    required this.channelId,
    required this.appId,
    required this.appName,
    this.iconUrl,
    required this.packageName,
    required this.installedVersion,
    required this.latestVersion,
    required this.latestDownload,
    required this.detail,
    DateTime? checkedAt,
  }) : checkedAt = checkedAt ?? DateTime.now();

  /// 渠道显示名称
  String get channelName =>
      ChannelType.fromCode(channelId)?.description ?? channelId;
}
