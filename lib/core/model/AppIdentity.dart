import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';

/// 应用身份（渠道 + 渠道内 ID + 真实包名）
/// 值对象：同渠道同 ID 即同一应用；packageName 在渠道可知时携带
class AppIdentity {
  /// 来源渠道
  final ChannelType channel;

  /// 渠道内 ID（owner/repo、vivoId、包名等，语义由渠道决定）
  final String channelAppId;

  /// 真实包名（渠道可知时；未知为 null）
  final String? packageName;

  const AppIdentity({
    required this.channel,
    required this.channelAppId,
    this.packageName,
  });

  /// 规范化身份键（与 discovery 多选键 `'${channel.code}:${appId}'` 同构）
  String get canonicalKey => '${channel.code}:$channelAppId';

  /// 从聚合信息派生：渠道内 ID 取已添加记录，包名取应用摘要
  factory AppIdentity.fromSummary(AggregatedAppInfo agg) {
    return AppIdentity(
      channel: agg.channel,
      channelAppId: agg.addedAppInfo.appId,
      packageName: agg.appInfo.packageName,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AppIdentity) return false;
    return other.channel == channel &&
        other.channelAppId == channelAppId &&
        other.packageName == packageName;
  }

  @override
  int get hashCode => Object.hash(channel, channelAppId, packageName);
}
