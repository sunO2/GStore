import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';
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
  Future<DownloadContext> createContext(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  ) async {
    log('创建下载上下文: url=${downloadInfo.url}, name=${downloadInfo.name}');

    // 构建基础上下文
    final context = buildBaseContext(downloadInfo, detailData);

    // F-Droid 提供直链下载，无需转换 URL
    log('使用 F-Droid 直链: ${downloadInfo.url}');

    return context;
  }

  @override
  Future<bool> validateContext(DownloadContext context) async {
    final isValid = await super.validateContext(context);
    if (!isValid) {
      log('下载上下文验证失败: URL为空');
      return false;
    }

    // 验证是否为 F-Droid 仓库 URL
    final uri = Uri.tryParse(context.downloadUrl);
    if (uri == null || !uri.hasScheme) {
      log('下载上下文验证失败: URL格式无效 ${context.downloadUrl}');
      return false;
    }

    // 检查是否来自 F-Droid 仓库
    if (!uri.host.contains('f-droid.org')) {
      log('警告: 非 F-Droid 仓库 URL: ${context.downloadUrl}');
    }

    log('下载上下文验证通过: ${context.downloadUrl}');
    return true;
  }
}
