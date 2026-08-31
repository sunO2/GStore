import 'package:gstore/core/core.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/strategy/BaseDownloadStrategy.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// GitHubChannel 下载策略
/// 处理 GitHub API 渠道的下载逻辑
/// - 使用全局 getProxy() 获取代理
/// - 如果有代理且 URL 不是完整 GitHub URL，进行拼接
class GitHubDownloadStrategy extends BaseDownloadStrategy {
  @override
  ChannelType get supportedChannel => ChannelType.github;

  @override
  String get strategyName => 'github_download';

  @override
  Future<DownloadRequest?> createRequest(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  ) async {
    log('创建下载请求: url=${downloadInfo.url}, name=${downloadInfo.name}');

    // 使用全局代理配置
    String finalUrl = downloadInfo.url;
    final globalProxy = getProxy();
    if (globalProxy.isNotEmpty) {
      log('使用全局代理配置: $globalProxy');

      // 尝试应用代理转换URL
      final transformedUrl = applyProxy(downloadInfo.url, globalProxy);
      if (transformedUrl != null) {
        finalUrl = transformedUrl;
        log('使用代理URL: $transformedUrl');
      } else {
        // 如果是完整URL，记录但不强制使用代理
        if (isFullGitHubUrl(downloadInfo.url)) {
          log('检测到完整GitHub URL，不使用代理转换');
        }
      }
    } else {
      log('未配置全局代理，使用原始URL');
    }

    // GitHub 特定的 headers（如果需要）
    Map<String, String>? headers;
    if (downloadInfo.url.contains('api.github.com')) {
      headers = {'Accept': 'application/vnd.github.v3+json'};
      log('添加 GitHub API Accept header');
    }

    return buildBaseRequest(url: finalUrl, headers: headers);
  }
}
