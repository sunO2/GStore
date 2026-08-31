import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// 下载策略接口
/// 定义各渠道下载预处理的契约
abstract interface class IDownloadStrategy {
  /// 策略名称
  String get strategyName;

  /// 支持的渠道类型
  ChannelType get supportedChannel;

  /// 创建下载请求
  /// [downloadInfo] 下载信息（包含url, name, size等）
  /// [detailData] 详情数据（包含extra等扩展信息）
  /// 返回配置好的下载请求，无法创建时返回null
  Future<DownloadRequest?> createRequest(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  );

  /// 验证下载请求是否有效
  /// [request] 待验证的下载请求
  /// 返回true表示请求有效，可以开始下载
  Future<bool> validateRequest(DownloadRequest request);

  /// 下载后处理（可选）
  /// [savedPath] 保存的文件路径
  /// [request] 使用的下载请求
  /// 子类可以覆盖此方法实现下载后的特殊处理
  Future<void>? postProcess(String savedPath, DownloadRequest request);
}
