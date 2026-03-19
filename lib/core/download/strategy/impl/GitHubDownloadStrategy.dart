import 'package:gstore/core/core.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';
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
  Future<DownloadContext> createContext(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  ) async {
    log('创建下载上下文: url=${downloadInfo.url}, name=${downloadInfo.name}');

    // 构建基础上下文
    final context = buildBaseContext(downloadInfo, detailData);

    // 使用全局代理配置
    final globalProxy = getProxy();
    if (globalProxy.isNotEmpty) {
      log('使用全局代理配置: $globalProxy');

      // 尝试应用代理转换URL
      final transformedUrl = applyProxy(downloadInfo.url, globalProxy);
      if (transformedUrl != null) {
        context.finalUrl = transformedUrl;
        context.proxy = globalProxy;
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

    // 添加 GitHub 特定的 headers（如果需要）
    context.headers ??= {};
    // GitHub API 可能需要 Accept header
    if (downloadInfo.url.contains('api.github.com')) {
      context.headers!['Accept'] = 'application/vnd.github.v3+json';
      log('添加 GitHub API Accept header');
    }

    return context;
  }

  @override
  Future<bool> validateContext(DownloadContext context) async {
    final isValid = await super.validateContext(context);
    if (!isValid) {
      log('下载上下文验证失败: URL为空');
      return false;
    }

    // 验证URL格式
    final uri = Uri.tryParse(context.downloadUrl);
    if (uri == null || !uri.hasScheme) {
      log('下载上下文验证失败: URL格式无效 ${context.downloadUrl}');
      return false;
    }

    log('下载上下文验证通过: ${context.downloadUrl}');
    return true;
  }
}
