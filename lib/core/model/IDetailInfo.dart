/// 应用详情信息抽象接口
/// 继承基础信息接口，扩展详情相关字段
library;

import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';

/// 应用详情信息接口
/// 扩展自基础信息接口，提供完整的应用详情数据
/// 替代旧的 IDetailData 接口
abstract class IDetailInfo {
  /// 应用包名（唯一标识）
  ///
  /// 用于：
  /// - 数据库主键
  /// - 应用安装状态检测
  /// - 应用去重和合并
  String get packageName;

  /// 应用名称
  String get appName;

  /// 应用图标URL
  String get icon;

  /// 应用简短描述
  String get description;

  /// 应用ID（渠道中的原始ID，如 owner/repo 或数字ID）
  /// 用于向后兼容 IDetailData
  String get appId;

  /// 来源渠道ID
  /// 用于标识数据来自哪个渠道（github, vivo, fdroid, localdb等）
  String get channelId;

  /// 应用名称的别名
  /// 向后兼容：提供 name getter 返回 appName
  String get name => appName;

  /// 来源渠道类型枚举
  ChannelType get channelType;

  /// 版本号
  String? get version;

  /// 开发者/作者
  String? get developer;

  /// 项目主页URL
  String? get projectUrl;

  /// 下载信息列表
  List<DownloadInfo> get downloads;

  /// 可展示的区块列表
  /// 控制详情页显示哪些内容区块
  List<DetailSection> get sections;

  /// 渠道特有扩展数据
  /// 存储渠道特有的额外信息
  Map<String, dynamic> get extra;

  /// 获取README/详情文本
  String? get readme;

  /// 获取应用截图列表
  List<ScreenshotInfo>? get screenshots;

  /// 获取更新日志
  String? get changelog;

  /// 获取权限说明列表
  List<String>? get permissions;

  /// 获取统计数据
  /// 包含：stars, forks, downloads, rating 等
  StatisticsInfo? get statistics;

  /// 构建统计标签列表
  /// 用于UI展示
  List<StatTag> buildStatTags();

  /// 是否为有效数据
  /// 检查必要字段是否非空
  bool get isValid => packageName.isNotEmpty && appName.isNotEmpty;
}
