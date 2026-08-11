import 'dart:convert';

import 'package:floor/floor.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';

/// 渠道已添加应用实体
/// v4：复合主键 (channelCode, appId)，同 appId 跨渠道可共存（不再互相覆盖）
/// 注意：Floor 按字段声明顺序生成 PRIMARY KEY 列序，channelCode 须在 appId 之前
@Entity(tableName: 'channel_added_app', primaryKeys: ['channelCode', 'appId'])
class ChannelAddedApp {
  /// 渠道类型代码
  final String channelCode;

  /// 渠道内应用 ID（GitHub 为 owner/repo 或真实包名，其他渠道为包名/渠道 ID）
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
