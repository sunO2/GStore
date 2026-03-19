import 'package:flutter/foundation.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';
import 'package:gstore/core/download/strategy/IDownloadStrategy.dart';
import 'package:gstore/core/download/exception/DownloadException.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// 下载策略管理器
/// 单例模式，管理所有渠道的下载策略
class DownloadStrategyManager {
  static DownloadStrategyManager? _instance;

  final Map<ChannelType, IDownloadStrategy> _strategies = {};

  /// 私有构造函数
  DownloadStrategyManager._();

  /// 单例获取
  static DownloadStrategyManager get instance {
    _instance ??= DownloadStrategyManager._();
    return _instance!;
  }

  /// 重置单例（主要用于测试）
  static void reset() {
    _instance?.clear();
    _instance = null;
  }

  /// 注册策略
  /// 如果同一渠道类型已注册，会覆盖旧策略
  void register(IDownloadStrategy strategy) {
    _strategies[strategy.supportedChannel] = strategy;
    debugPrint('DownloadStrategyManager: 注册策略 ${strategy.strategyName} '
        'for ${strategy.supportedChannel.code}');
  }

  /// 批量注册策略
  void registerAll(List<IDownloadStrategy> strategies) {
    for (final strategy in strategies) {
      register(strategy);
    }
  }

  /// 获取指定渠道的策略
  /// 返回null表示未找到对应策略
  IDownloadStrategy? getStrategy(ChannelType channel) {
    return _strategies[channel];
  }

  /// 检查是否有指定渠道的策略
  bool hasStrategy(ChannelType channel) {
    return _strategies.containsKey(channel);
  }

  /// 创建下载上下文（自动选择策略）
  /// [downloadInfo] 下载信息
  /// [detailData] 详情数据
  /// 返回配置好的下载上下文，失败返回null
  Future<DownloadContext?> createContext(
    DownloadInfo downloadInfo,
    IDetailInfo detailData,
  ) async {
    final channel = detailData.channelType;
    final strategy = getStrategy(channel);

    if (strategy == null) {
      debugPrint('DownloadStrategyManager: 未找到渠道 $channel 的下载策略');
      return null;
    }

    try {
      final context = await strategy.createContext(downloadInfo, detailData);
      final isValid = await strategy.validateContext(context);

      if (!isValid) {
        debugPrint('DownloadStrategyManager: 下载上下文验证失败 - $context');
        return null;
      }

      debugPrint('DownloadStrategyManager: 创建下载上下文成功 - ${context.downloadUrl}');
      return context;
    } catch (e) {
      debugPrint('DownloadStrategyManager: 创建下载上下文异常 - $e');
      return null;
    }
  }

  /// 清除所有策略
  void clear() {
    _strategies.clear();
  }

  /// 获取所有已注册的渠道类型
  List<ChannelType> get registeredChannels => _strategies.keys.toList();

  /// 获取已注册策略数量
  int get strategyCount => _strategies.length;
}
