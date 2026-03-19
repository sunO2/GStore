import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';
import 'package:gstore/core/download/strategy/BaseDownloadStrategy.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// LocalDbChannel 下载策略
/// 处理本地数据库渠道的下载逻辑
/// - 支持使用 extra['proxy'] 中的代理配置加速 GitHub 下载
/// - 如果 URL 不是完整的 GitHub URL，使用代理拼接
class LocalDbDownloadStrategy extends BaseDownloadStrategy {
  @override
  ChannelType get supportedChannel => ChannelType.localDb;

  @override
  Future<DownloadContext> createContext(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  ) async {
    log('创建下载上下文: url=${downloadInfo.url}, name=${downloadInfo.name}');

    // 构建基础上下文
    final context = buildBaseContext(downloadInfo, detailData);

    // 提取代理配置
    final proxy = extractProxy(detailData);
    if (proxy != null && proxy.isNotEmpty) {
      log('提取到代理配置: $proxy');

      // 尝试应用代理转换URL
      final transformedUrl = applyProxy(downloadInfo.url, proxy);
      if (transformedUrl != null) {
        context.finalUrl = transformedUrl;
        context.proxy = proxy;
        log('使用代理URL: $transformedUrl');
      } else {
        // 如果是完整URL，仍然记录代理信息（可能需要用于其他用途）
        if (isFullGitHubUrl(downloadInfo.url)) {
          log('检测到完整GitHub URL，不使用代理转换');
        } else {
          // 对于非GitHub URL，仍然尝试使用代理
          context.proxy = proxy;
          log('非GitHub URL，保留代理配置');
        }
      }
    } else {
      log('未找到代理配置，使用原始URL');
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
