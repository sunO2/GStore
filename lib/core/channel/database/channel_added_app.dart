import 'package:floor/floor.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';

/// 渠道已添加应用实体
@Entity(tableName: 'channel_added_app')
class ChannelAddedApp {
  @PrimaryKey()
  final String appId;

  /// 应用名称
  final String name;

  /// 开发者
  final String user;

  /// 仓库/包名
  final String repositories;

  /// 图标 URL
  final String icon;

  /// 描述
  final String description;

  /// 分类（逗号分隔）
  final String? category;

  /// 添加时间（毫秒时间戳）
  final int addTime;

  /// 渠道类型代码
  final String channelCode;

  ChannelAddedApp({
    required this.appId,
    required this.name,
    required this.user,
    required this.repositories,
    required this.icon,
    required this.description,
    this.category,
    required this.addTime,
    required this.channelCode,
  });

  /// 从 ChannelType 创建 channelCode
  factory ChannelAddedApp.withChannel({
    required String appId,
    required String name,
    required String user,
    required String repositories,
    required String icon,
    required String description,
    String? category,
    required int addTime,
    required ChannelType channel,
  }) {
    return ChannelAddedApp(
      appId: appId,
      name: name,
      user: user,
      repositories: repositories,
      icon: icon,
      description: description,
      category: category,
      addTime: addTime,
      channelCode: channel.code,
    );
  }
}
