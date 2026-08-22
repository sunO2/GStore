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

  /// 渠道唯一标识（枚举渠道 = type.code；脚本渠道 = channelKey，如 'js_pingan'）
  /// 用于详情页精确查找渠道（getChannelByCode），区分同属 custom 的不同 JS 渠道。
  /// 为 null 时回退到 channel.code（兼容旧调用方）。
  final String? channelCode;

  const AppDetailRequest({
    required this.appId,
    required this.name,
    required this.channel,
    this.channelCode,
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

        // 优先使用真实包名（B1 后 packageName 为 AppSummary 一级字段），否则回退 repositories 占位
        String? packageName;
        // appInfo 为 dynamic；对 AggregatedAppInfo 调用 ?.packageName 不会抛（AppSummary.packageName 为
        // 真实 getter，null 时返回 null）——无需 try/catch 死防御，异常统一由外层兜底
        final pkg = appInfo?.packageName;
        if (pkg != null && pkg.isNotEmpty) {
          packageName = pkg;
        }
        packageName ??= appInfo?.repositories;

        // 注意：appId 原样传递（渠道查询键），不做格式转换——由渠道内部处理
        // AggregatedAppInfo 现在有 channelCode 属性
        final channelCode = (aggregatedInfo as dynamic).channelCode as String?;
        return AppDetailRequest(
          appId: appInfo?.appId ?? '',
          name: appInfo?.name ?? '',
          packageName: packageName,
          icon: appInfo?.icon,
          description: appInfo?.des,
          channel: channel,
          channelCode: channelCode,
        );
      } catch (e) {
        // 如果转换失败，返回默认值
        return const AppDetailRequest(
          appId: '',
          name: 'Unknown',
          channel: ChannelType.localDb,
          channelCode: null,
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
      channelCode: null,
    );
  }

  /// 从 AppInfo 转换
  factory AppDetailRequest.fromAppInfo(
    Map<String, dynamic> appInfoMap,
    ChannelType channel, {
    String? channelCode,
  }) {
    return AppDetailRequest(
      appId: appInfoMap['appId']?.toString() ?? '',
      name: appInfoMap['name']?.toString() ?? 'Unknown',
      packageName: appInfoMap['repositories']?.toString(),
      icon: appInfoMap['icon']?.toString(),
      description: appInfoMap['des']?.toString(),
      channel: channel,
      channelCode: channelCode,
    );
  }

  @override
  String toString() {
    return 'AppDetailRequest{appId: $appId, name: $name, channel: $channel, channelCode: $channelCode}';
  }
}
