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

  /// 完整详情（用于下载策略上下文；缓存恢复时为 null，更新时降级普通下载）
  final IDetailInfo? detail;

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
    this.detail,
    DateTime? checkedAt,
  }) : checkedAt = checkedAt ?? DateTime.now();

  /// 渠道显示名称
  String get channelName =>
      ChannelType.fromCode(channelId)?.description ?? channelId;

  /// 序列化为缓存 JSON（detail 不持久化：接口类型无法可靠序列化，恢复后置空走降级）
  Map<String, dynamic> toCacheJson() {
    return {
      'channelId': channelId,
      'appId': appId,
      'appName': appName,
      'iconUrl': iconUrl,
      'packageName': packageName,
      'installedVersion': installedVersion,
      'latestVersion': latestVersion,
      'checkedAt': checkedAt.millisecondsSinceEpoch,
      'download': {
        'url': latestDownload.url,
        'name': latestDownload.name,
        'size': latestDownload.size,
        'downloadCount': latestDownload.downloadCount,
        'version': latestDownload.version,
        'versionCode': latestDownload.versionCode,
        'publishedAt': latestDownload.publishedAt?.millisecondsSinceEpoch,
        'platform': latestDownload.platform,
        'hash': latestDownload.hash,
        'hashType': latestDownload.hashType,
      },
    };
  }

  /// 从缓存 JSON 恢复（detail 为 null，更新时降级普通下载）
  factory AppUpdateInfo.fromCacheJson(Map<String, dynamic> json) {
    final d = (json['download'] as Map?) ?? const <String, dynamic>{};
    return AppUpdateInfo(
      channelId: json['channelId']?.toString() ?? '',
      appId: json['appId']?.toString() ?? '',
      appName: json['appName']?.toString() ?? '',
      iconUrl: json['iconUrl']?.toString(),
      packageName: json['packageName']?.toString() ?? '',
      installedVersion: json['installedVersion']?.toString() ?? '',
      latestVersion: json['latestVersion']?.toString() ?? '',
      latestDownload: DownloadInfo(
        url: d['url']?.toString() ?? '',
        name: d['name']?.toString() ?? '',
        size: d['size'] as int?,
        downloadCount: d['downloadCount'] as int?,
        version: d['version']?.toString(),
        versionCode: d['versionCode'] as int?,
        publishedAt: d['publishedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(d['publishedAt'] as int)
            : null,
        platform: d['platform']?.toString(),
        hash: d['hash']?.toString(),
        hashType: d['hashType']?.toString(),
      ),
      detail: null,
      checkedAt: json['checkedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['checkedAt'] as int)
          : null,
    );
  }
}
