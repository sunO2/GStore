/// 应用详情请求参数
/// 用于传递到详情页面的轻量级信息
library;

import 'package:gstore/core/channel/model/ChannelType.dart';

class AppDetailRequest {
  /// 应用ID（在对应渠道中的ID）
  final String appId;

  /// 应用名称
  final String name;

  /// 包名
  final String? packageName;

  /// 图标URL
  final String? icon;

  /// 简短描述
  final String? description;

  /// 来源渠道
  final ChannelType channel;

  const AppDetailRequest({
    required this.appId,
    required this.name,
    required this.channel,
    this.packageName,
    this.icon,
    this.description,
  });

  /// 从 AggregatedAppInfo 转换
  factory AppDetailRequest.fromAggregatedAppInfo(
    dynamic aggregatedInfo,
  ) {
    // 处理 AggregatedAppInfo 类型
    if (aggregatedInfo is! Map) {
      // 如果是对象，尝试通过反射访问属性
      try {
        final appInfo = (aggregatedInfo as dynamic).appInfo;
        final channel = (aggregatedInfo as dynamic).channel as ChannelType;

        return AppDetailRequest(
          appId: appInfo?.appId ?? '',
          name: appInfo?.name ?? '',
          packageName: appInfo?.repositories,
          icon: appInfo?.icon,
          description: appInfo?.des,
          channel: channel,
        );
      } catch (e) {
        // 如果转换失败，返回默认值
        return const AppDetailRequest(
          appId: '',
          name: 'Unknown',
          channel: ChannelType.localDb,
        );
      }
    }

    final map = aggregatedInfo as Map;
    return AppDetailRequest(
      appId: map['appId']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Unknown',
      packageName: map['packageName']?.toString(),
      icon: map['icon']?.toString(),
      description: map['description']?.toString(),
      channel: map['channel'] is ChannelType
          ? map['channel'] as ChannelType
          : ChannelType.localDb,
    );
  }

  /// 从 AppInfo 转换
  factory AppDetailRequest.fromAppInfo(
    Map<String, dynamic> appInfoMap,
    ChannelType channel,
  ) {
    return AppDetailRequest(
      appId: appInfoMap['appId']?.toString() ?? '',
      name: appInfoMap['name']?.toString() ?? 'Unknown',
      packageName: appInfoMap['repositories']?.toString(),
      icon: appInfoMap['icon']?.toString(),
      description: appInfoMap['des']?.toString(),
      channel: channel,
    );
  }

  @override
  String toString() {
    return 'AppDetailRequest{appId: $appId, name: $name, channel: $channel}';
  }
}
