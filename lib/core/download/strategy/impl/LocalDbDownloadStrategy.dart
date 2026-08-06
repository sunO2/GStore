import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';
import 'package:gstore/core/download/strategy/BaseDownloadStrategy.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/core.dart';

/// LocalDbChannel 下载策略
/// 处理本地数据库渠道的下载逻辑
/// - 使用全局代理配置（getProxy）加速 GitHub 下载
/// - 设置了代理则直接使用"代理前缀 + 完整URL"
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

    // 使用全局代理配置
    final proxy = getProxy();
    if (proxy.isNotEmpty) {
      log('使用全局代理配置: $proxy');

      // 设置了代理则直接拼接：代理前缀 + 完整URL
      final finalUrl = '${proxy.endsWith('/') ? proxy : '$proxy/'}${downloadInfo.url}';
      context.finalUrl = finalUrl;
      context.proxy = proxy;
      log('使用代理URL: $finalUrl');
    } else {
      log('未配置代理，使用原始URL');
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
