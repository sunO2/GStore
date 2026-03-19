import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// 下载策略接口
/// 定义各渠道下载预处理的契约
abstract interface class IDownloadStrategy {
  /// 策略名称
  String get strategyName;

  /// 支持的渠道类型
  ChannelType get supportedChannel;

  /// 创建下载上下文
  /// [downloadInfo] 下载信息（包含url, name, size等）
  /// [detailData] 详情数据（包含extra等扩展信息）
  /// 返回配置好的下载上下文
  Future<DownloadContext> createContext(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  );

  /// 验证下载上下文是否有效
  /// [context] 待验证的下载上下文
  /// 返回true表示上下文有效，可以开始下载
  Future<bool> validateContext(DownloadContext context);

  /// 下载后处理（可选）
  /// [savedPath] 保存的文件路径
  /// [context] 使用的下载上下文
  /// 子类可以覆盖此方法实现下载后的特殊处理
  Future<void>? postProcess(String savedPath, DownloadContext context);
}
