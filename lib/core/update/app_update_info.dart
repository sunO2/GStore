/// 更新检测结果模型
library;

import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// 稳定偏好/选择键：与 Rust 侧 `{channel}:{app}` 保持一致。
String updateSelectionKey(AppUpdateInfo info) =>
    '${info.channelId}:${info.appId}';

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

  /// 候选下载列表（core 检测结果提供；detail 缺失时仍可展开选择）
  final List<DownloadInfo> downloadCandidates;

  /// 本次下载的匹配来源：`preference` / `abi` / `abi_fallback`。
  final String? selectionSource;

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
    this.downloadCandidates = const [],
    this.selectionSource,
    this.detail,
    DateTime? checkedAt,
  }) : checkedAt = checkedAt ?? DateTime.now();

  /// 渠道显示名称
  String get channelName =>
      ChannelType.fromCode(channelId)?.description ?? channelId;

  /// 候选下载：优先 core 提供的候选，回退完整详情（兼容旧路径）。
  List<DownloadInfo> get downloads => downloadCandidates.isNotEmpty
      ? downloadCandidates
      : (detail?.downloads ?? const <DownloadInfo>[]);

  /// 仅替换当前选中的下载项，保留候选/详情/检测时间。
  ///
  /// 用户换选 APK 后，本地共享状态需要立即与新偏好一致；否则离开更新页再
  /// 回来会暂时显示旧的 `latestDownload`（直到下一次 core 检测重投影）。
  AppUpdateInfo withLatestDownload(DownloadInfo download) => AppUpdateInfo(
        channelId: channelId,
        appId: appId,
        appName: appName,
        iconUrl: iconUrl,
        packageName: packageName,
        installedVersion: installedVersion,
        latestVersion: latestVersion,
        latestDownload: download,
        downloadCandidates: downloadCandidates,
        selectionSource: 'preference',
        detail: detail,
        checkedAt: checkedAt,
      );

  /// 序列化为缓存 JSON（detail 不持久化：接口类型无法可靠序列化，恢复后置空走降级）
  Map<String, dynamic> toCacheJson() {
    // 始终持久化候选：core 结果的 downloadCandidates 优先；旧路径没有候选
    // 时至少保留本次选中的下载项，保证与 Rust 缓存形状（downloads 数组）一致。
    final candidates = downloads;
    final cachedDownloads =
        candidates.isEmpty ? <DownloadInfo>[latestDownload] : candidates;
    return {
      'channelId': channelId,
      'appId': appId,
      'appName': appName,
      'iconUrl': iconUrl,
      'packageName': packageName,
      'installedVersion': installedVersion,
      'latestVersion': latestVersion,
      'checkedAt': checkedAt.millisecondsSinceEpoch,
      'download': _downloadToJson(latestDownload),
      'downloads': [for (final d in cachedDownloads) _downloadToJson(d)],
      if (selectionSource != null) 'selectionSource': selectionSource,
    };
  }

  /// 从缓存 JSON 恢复（detail 为 null，更新时降级普通下载）
  factory AppUpdateInfo.fromCacheJson(Map<String, dynamic> json) {
    final d = (json['download'] as Map?) ?? const <String, dynamic>{};
    final rawDownloads = json['downloads'];
    final candidates = rawDownloads is List
        ? [
            for (final item in rawDownloads)
              if (item is Map)
                _downloadFromJson(Map<String, dynamic>.from(item)),
          ]
        : const <DownloadInfo>[];
    return AppUpdateInfo(
      channelId: json['channelId']?.toString() ?? '',
      appId: json['appId']?.toString() ?? '',
      appName: json['appName']?.toString() ?? '',
      iconUrl: json['iconUrl']?.toString(),
      packageName: json['packageName']?.toString() ?? '',
      installedVersion: json['installedVersion']?.toString() ?? '',
      latestVersion: json['latestVersion']?.toString() ?? '',
      latestDownload: _downloadFromJson(Map<String, dynamic>.from(d)),
      downloadCandidates: candidates,
      selectionSource: json['selectionSource']?.toString(),
      detail: null,
      checkedAt: json['checkedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['checkedAt'] as int)
          : null,
    );
  }
}

/// 反序列化单个下载项（camelCase，与 Rust core 输出一致）。
DownloadInfo _downloadFromJson(Map<String, dynamic> json) {
  return DownloadInfo(
    url: json['url']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    size: json['size'] as int?,
    downloadCount: json['downloadCount'] as int?,
    version: json['version']?.toString(),
    versionCode: json['versionCode'] as int?,
    publishedAt: json['publishedAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['publishedAt'] as int)
        : null,
    platform: json['platform']?.toString(),
    hash: json['hash']?.toString(),
    hashType: json['hashType']?.toString(),
    downloadable: json['downloadable'] as bool? ?? true,
    note: json['note']?.toString(),
  );
}

/// 序列化单个下载项（camelCase）。可选字段仅在有意义时输出。
Map<String, dynamic> _downloadToJson(DownloadInfo d) {
  return {
    'url': d.url,
    'name': d.name,
    'size': d.size,
    'downloadCount': d.downloadCount,
    'version': d.version,
    'versionCode': d.versionCode,
    'publishedAt': d.publishedAt?.millisecondsSinceEpoch,
    'platform': d.platform,
    'hash': d.hash,
    'hashType': d.hashType,
    if (!d.downloadable) 'downloadable': false,
    if (d.note != null) 'note': d.note,
  };
}
