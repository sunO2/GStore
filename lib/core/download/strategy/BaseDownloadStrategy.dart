import 'package:flutter/foundation.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';
import 'package:gstore/core/download/strategy/IDownloadStrategy.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// 下载策略抽象基类
/// 提供默认实现和辅助方法，子类只需实现特定逻辑
abstract class BaseDownloadStrategy implements IDownloadStrategy {
  @override
  String get strategyName => supportedChannel.code;

  @override
  Future<bool> validateContext(DownloadContext context) {
    return Future.value(context.downloadUrl.isNotEmpty);
  }

  @override
  Future<void>? postProcess(String savedPath, DownloadContext context) {
    return null;
  }

  /// 辅助方法：从详情数据中提取代理配置
  String? extractProxy(IDetailInfo detailData) {
    final proxy = detailData.extra['proxy'];
    if (proxy is String) {
      return proxy.isNotEmpty ? proxy : null;
    }
    return null;
  }

  /// 辅助方法：从详情数据中提取API数据
  Map<String, dynamic>? extractApiData(IDetailInfo detailData) {
    final apiData = detailData.extra['apiData'];
    if (apiData is Map) {
      return Map<String, dynamic>.from(apiData);
    }
    return null;
  }

  /// 辅助方法：构建基础下载上下文
  DownloadContext buildBaseContext(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  ) {
    return DownloadContext(
      originalUrl: downloadInfo.url,
      channelType: detailData.channelType,
      fileName: downloadInfo.name,
      fileSize: downloadInfo.size,
      version: downloadInfo.version,
      supportBreakpoint: true,
      metadata: {
        'appId': detailData.appId,
        'appName': detailData.name,
        'developer': detailData.developer,
      },
    );
  }

  /// 辅助方法：判断URL是否是完整的GitHub URL
  bool isFullGitHubUrl(String url) {
    return url.startsWith('https://github.com/') ||
        url.startsWith('https://api.github.com/') ||
        url.startsWith('https://raw.githubusercontent.com/');
  }

  /// 辅助方法：判断URL是否是GitHub releases下载URL
  bool isGitHubReleasesUrl(String url) {
    return url.contains('github.com') &&
        (url.contains('/releases/download/') ||
            url.contains('/archive/refs/tags/') ||
            url.contains('/archive/'));
  }

  /// 辅助方法：使用代理转换URL
  String? applyProxy(String originalUrl, String proxy) {
    if (proxy.isEmpty) return null;

    // 确保代理URL以 / 结尾
    final normalizedProxy = proxy.endsWith('/') ? proxy : '$proxy/';

    // 如果已经是完整URL，不转换
    if (isFullGitHubUrl(originalUrl)) {
      return null;
    }

    // 对于GitHub releases URL，使用代理转换
    if (isGitHubReleasesUrl(originalUrl)) {
      // 提取 GitHub 路径部分
      // 例如: https://github.com/user/repo/releases/download/v1.0/file.apk
      // 转换为: {proxy}/user/repo/releases/download/v1.0/file.apk
      final uri = Uri.tryParse(originalUrl);
      if (uri != null && uri.path.isNotEmpty) {
        return '$normalizedProxy${uri.path.substring(1)}'; // 移除开头的 /
      }
    }

    return null;
  }

  /// 辅助方法：日志输出
  void log(String message) {
    debugPrint('[$strategyName] $message');
  }
}
