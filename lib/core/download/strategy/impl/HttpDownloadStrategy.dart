import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';
import 'package:gstore/core/download/strategy/BaseDownloadStrategy.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// HttpChannel 下载策略
/// 处理通用 HTTP API 渠道的下载逻辑
/// - 直接使用原始 URL
/// - 无特殊处理
class HttpDownloadStrategy extends BaseDownloadStrategy {
  @override
  ChannelType get supportedChannel => ChannelType.http;

  @override
  String get strategyName => 'http_download';

  @override
  Future<DownloadContext> createContext(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  ) async {
    log('创建下载上下文: url=${downloadInfo.url}, name=${downloadInfo.name}');

    // 构建基础上下文
    final context = buildBaseContext(downloadInfo, detailData);

    // HTTP 渠道直接使用原始 URL，无特殊处理
    log('使用原始 URL: ${downloadInfo.url}');

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

    // 验证是否为 HTTP 或 HTTPS
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      log('下载上下文验证失败: 不支持的协议 ${uri.scheme}');
      return false;
    }

    log('下载上下文验证通过: ${context.downloadUrl}');
    return true;
  }
}
