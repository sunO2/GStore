import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/core/download_request.dart';
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
  Future<DownloadRequest?> createRequest(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  ) async {
    log('创建下载请求: url=${downloadInfo.url}, name=${downloadInfo.name}');

    // HTTP 渠道直接使用原始 URL，无特殊处理
    log('使用原始 URL: ${downloadInfo.url}');

    return buildBaseRequest(url: downloadInfo.url);
  }
}
