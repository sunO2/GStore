import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/strategy/BaseDownloadStrategy.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// VivoChannel 下载策略
/// 处理 vivo 应用市场渠道的下载逻辑
/// - 添加特定的 headers（User-Agent, Accept-Language）
/// - 直接使用原始 URL
class VivoDownloadStrategy extends BaseDownloadStrategy {
  /// 默认 User-Agent
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 默认 Accept-Language
  static const String _defaultAcceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';

  @override
  ChannelType get supportedChannel => ChannelType.vivo;

  @override
  String get strategyName => 'vivo_download';

  @override
  Future<DownloadRequest?> createRequest(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  ) async {
    log('创建下载请求: url=${downloadInfo.url}, name=${downloadInfo.name}');

    // 添加 vivo 特定的 headers
    final headers = <String, String>{
      'User-Agent': _defaultUserAgent,
      'Accept-Language': _defaultAcceptLanguage,
      'Accept': '*/*',
      'Connection': 'keep-alive',
    };

    log('添加 vivo 特定 headers: $headers');

    // Vivo 渠道直接使用原始 URL
    log('使用原始 URL: ${downloadInfo.url}');

    return buildBaseRequest(url: downloadInfo.url, headers: headers);
  }
}
