import 'dart:convert';

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

  /// 仓库完整名（owner/repo），仅 GitHub 渠道使用
  /// GitHub 渠道 appId 暂用此值，下载安装后替换为真实包名
  final String? apprepo;

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

  /// 扩展字段，JSON 字符串格式存储额外信息
  final String? extra;

  ChannelAddedApp({
    required this.appId,
    required this.name,
    required this.user,
    required this.repositories,
    this.apprepo,
    required this.icon,
    required this.description,
    this.category,
    required this.addTime,
    required this.channelCode,
    this.extra,
  });

  /// 从 ChannelType 创建 channelCode
  factory ChannelAddedApp.withChannel({
    required String appId,
    required String name,
    required String user,
    required String repositories,
    String? apprepo,
    required String icon,
    required String description,
    String? category,
    required int addTime,
    required ChannelType channel,
    String? extra,
  }) {
    return ChannelAddedApp(
      appId: appId,
      name: name,
      user: user,
      repositories: repositories,
      apprepo: apprepo,
      icon: icon,
      description: description,
      category: category,
      addTime: addTime,
      channelCode: channel.code,
      extra: extra,
    );
  }

  /// 从 extra 中获取 JSON 数据
  Map<String, dynamic>? getExtraData() {
    if (extra == null || extra!.isEmpty) return null;
    try {
      return jsonDecode(extra!) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// 从 extra 中获取指定字段的值
  T? getExtra<T>(String key) {
    final data = getExtraData();
    if (data == null) return null;
    final value = data[key];
    if (value is T) return value;
    return null;
  }
}
