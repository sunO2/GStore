import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';

/// 详情页数据接口
/// 不同渠道实现此接口提供详情数据
abstract class IDetailData {
  /// 应用ID
  String get appId;

  /// 应用名称
  String get name;

  /// 应用图标URL
  String get icon;

  /// 简短描述
  String get description;

  /// 版本号
  String? get version;

  /// 开发者/作者
  String? get developer;

  /// 应用包名
  String? get packageName;

  /// 项目主页URL
  String? get projectUrl;

  /// 渠道类型
  ChannelType get channelType;

  /// 下载信息列表
  List<DownloadInfo> get downloads;

  /// 可展示的区块列表
  List<DetailSection> get sections;

  /// 渠道特有扩展数据
  Map<String, dynamic> get extra;

  /// 获取README/详情文本
  String? get readme;

  /// 获取截图列表
  List<ScreenshotInfo>? get screenshots;

  /// 获取更新日志
  String? get changelog;

  /// 获取权限列表
  List<String>? get permissions;

  /// 获取统计数据（从 extra 中解析）
  StatisticsInfo? get statistics {
    if (extra['statistics'] is StatisticsInfo) {
      return extra['statistics'] as StatisticsInfo;
    }
    // 兼容旧格式，从extra中构建StatisticsInfo
    if (extra['stars'] != null ||
        extra['forks'] != null ||
        extra['watchers'] != null ||
        extra['downloadCount'] != null ||
        extra['rating'] != null) {
      return StatisticsInfo(
        stars: extra['stars'],
        forks: extra['forks'],
        watchers: extra['watchers'],
        downloads: extra['downloadCount'], // 下载量（int）
        rating: extra['rating']?.toDouble(),
        ratingCount: extra['ratingCount'],
        favorites: extra['favorites'],
      );
    }
    return null;
  }

  /// 构建统计标签列表
  List<StatTag> buildStatTags();

  /// 是否为有效数据
  bool get isValid => appId.isNotEmpty && name.isNotEmpty;
}
