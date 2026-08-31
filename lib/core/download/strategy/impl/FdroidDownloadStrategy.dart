import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/strategy/BaseDownloadStrategy.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// F-Droid 渠道下载策略
/// 处理 F-Droid 应用市场的下载逻辑
/// - 直接使用原始 URL（F-Droid 提供直链）
/// - 无需特殊 headers
class FdroidDownloadStrategy extends BaseDownloadStrategy {
  @override
  ChannelType get supportedChannel => ChannelType.fdroid;

  @override
  String get strategyName => 'fdroid_download';

  @override
  Future<DownloadRequest?> createRequest(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  ) async {
    log('创建下载请求: url=${downloadInfo.url}, name=${downloadInfo.name}');

    // F-Droid 提供直链下载，无需转换 URL
    log('使用 F-Droid 直链: ${downloadInfo.url}');

    return buildBaseRequest(url: downloadInfo.url);
  }
}
