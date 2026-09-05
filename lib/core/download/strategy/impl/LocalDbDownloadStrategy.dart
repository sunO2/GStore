import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/core/download_request.dart';
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

      // 复用 applyProxy（含已带代理跳过，避免二次拼）
      final transformed = applyProxy(downloadInfo.url, globalProxy);
      if (transformed != null) {
        finalUrl = transformed;
        log('使用代理URL: $finalUrl');
      }
    } else {
      log('未配置代理，使用原始URL');
    }

    return buildBaseRequest(url: finalUrl);
  }
}
