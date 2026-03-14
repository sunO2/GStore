/// 统一的应用详情数据模型
/// 用于不同渠道的应用详情页面展示
library;

import 'package:flutter/material.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/StatTag.dart';

/// 详情页可展示的区块类型
enum DetailSection {
  /// 版本信息
  version,

  /// 统计数据（GitHub: stars/forks, vivo: 下载量/评分）
  statistics,

  /// 应用截图（vivo等应用商店）
  screenshots,

  /// README/详情文本（GitHub: README.md, vivo: 应用介绍）
  readme,

  /// 下载链接列表
  downloads,

  /// 评分信息（应用商店）
  rating,

  /// 开发者信息
  developer,

  /// 更新日志
  changelog,

  /// 权限说明
  permissions,
}

/// 下载信息
class DownloadInfo {
  /// 下载链接
  final String url;

  /// 文件名
  final String name;

  /// 文件大小（字节）
  final int? size;

  /// 下载次数
  final int? downloadCount;

  /// 版本号/标签
  final String? version;

  /// 发布时间
  final DateTime? publishedAt;

  /// 平台标识（如：android, universal, arm64-v8a）
  final String? platform;

  DownloadInfo({
    required this.url,
    required this.name,
    this.size,
    this.downloadCount,
    this.version,
    this.publishedAt,
    this.platform,
  });

  /// 格式化文件大小
  String get formattedSize {
    if (size == null) return '';
    final bytes = size!;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// 应用截图信息
class ScreenshotInfo {
  /// 图片URL
  final String url;

  /// 描述文字
  final String? description;

  ScreenshotInfo({
    required this.url,
    this.description,
  });
}

/// 统计数据信息
class StatisticsInfo {
  /// GitHub: stars 数量
  final int? stars;

  /// GitHub: forks 数量
  final int? forks;

  /// GitHub: watchers 数量
  final int? watchers;

  /// 应用商店: 下载量
  final int? downloads;

  /// 应用商店: 评分 (0-5)
  final double? rating;

  /// 应用商店: 评分人数
  final int? ratingCount;

  /// 应用商店: 收藏数
  final int? favorites;

  StatisticsInfo({
    this.stars,
    this.forks,
    this.watchers,
    this.downloads,
    this.rating,
    this.ratingCount,
    this.favorites,
  });

  /// 是否为空
  bool get isEmpty =>
      stars == null &&
      forks == null &&
      watchers == null &&
      downloads == null &&
      rating == null &&
      ratingCount == null &&
      favorites == null;

  /// 构建统计标签列表
  /// 根据当前统计数据生成用于UI展示的标签
  List<StatTag> buildStatTags() {
    final tags = <StatTag>[];

    // GitHub 统计数据
    if (stars != null && stars! > 0) {
      tags.add(StatTag.stars(stars!));
    }
    if (watchers != null && watchers! > 0) {
      tags.add(StatTag.watchers(watchers!));
    }
    if (forks != null && forks! > 0) {
      tags.add(StatTag.forks(forks!));
    }

    // 应用商店统计数据
    if (downloads != null && downloads! > 0) {
      tags.add(StatTag.downloads(downloads!));
    }
    if (rating != null && rating! > 0) {
      tags.add(StatTag.rating(rating!, ratingCount));
    }
    if (favorites != null && favorites! > 0) {
      tags.add(StatTag.favorites(favorites!));
    }

    return tags;
  }
}

/// 统一的应用详情信息
class AppDetailInfo {
  /// 应用ID
  final String appId;

  /// 应用名称
  final String name;

  /// 应用图标URL
  final String icon;

  /// 简短描述
  final String description;

  /// 版本号
  final String? version;

  /// 开发者/作者
  final String? developer;

  /// 应用包名
  final String? packageName;

  /// 项目主页URL
  final String? projectUrl;

  /// 来源渠道
  final ChannelType channel;

  /// 可展示的区块列表
  final List<DetailSection> sections;

  /// 下载信息列表
  final List<DownloadInfo> downloads;

  /// 渠道特有扩展信息
  final Map<String, dynamic> extra;

  AppDetailInfo({
    required this.appId,
    required this.name,
    required this.icon,
    required this.description,
    required this.channel,
    required this.sections,
    this.version,
    this.developer,
    this.packageName,
    this.projectUrl,
    List<DownloadInfo>? downloads,
    Map<String, dynamic>? extra,
  })  : downloads = downloads ?? [],
        extra = extra ?? {};

  /// 从extra获取统计数据
  StatisticsInfo? get statistics {
    if (extra['statistics'] is StatisticsInfo) {
      return extra['statistics'] as StatisticsInfo;
    }
    // 兼容旧格式，从extra中构建StatisticsInfo
    if (extra['stars'] != null ||
        extra['forks'] != null ||
        extra['downloads'] != null ||
        extra['rating'] != null) {
      return StatisticsInfo(
        stars: extra['stars'],
        forks: extra['forks'],
        watchers: extra['watchers'],
        downloads: extra['downloads'],
        rating: extra['rating']?.toDouble(),
        ratingCount: extra['ratingCount'],
        favorites: extra['favorites'],
      );
    }
    return null;
  }

  /// 从extra获取截图列表
  List<ScreenshotInfo>? get screenshots {
    if (extra['screenshots'] is List) {
      final list = extra['screenshots'] as List;
      return list.map((e) {
        if (e is ScreenshotInfo) return e;
        if (e is String) return ScreenshotInfo(url: e);
        if (e is Map) {
          return ScreenshotInfo(
            url: e['url']?.toString() ?? '',
            description: e['description']?.toString(),
          );
        }
        return ScreenshotInfo(url: e.toString());
      }).toList();
    }
    return null;
  }

  /// 从extra获取README/详情文本
  String? get readme {
    return extra['readme']?.toString();
  }

  /// 从extra获取更新日志
  String? get changelog {
    return extra['changelog']?.toString();
  }

  /// 从extra获取权限列表
  List<String>? get permissions {
    if (extra['permissions'] is List) {
      return (extra['permissions'] as List).map((e) => e.toString()).toList();
    }
    return null;
  }

  /// 是否为空（用于检查数据是否有效）
  bool get isValid => appId.isNotEmpty && name.isNotEmpty;

  /// 复制并修改部分字段
  AppDetailInfo copyWith({
    String? appId,
    String? name,
    String? icon,
    String? description,
    ChannelType? channel,
    List<DetailSection>? sections,
    String? version,
    String? developer,
    String? packageName,
    String? projectUrl,
    List<DownloadInfo>? downloads,
    Map<String, dynamic>? extra,
  }) {
    return AppDetailInfo(
      appId: appId ?? this.appId,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      description: description ?? this.description,
      channel: channel ?? this.channel,
      sections: sections ?? this.sections,
      version: version ?? this.version,
      developer: developer ?? this.developer,
      packageName: packageName ?? this.packageName,
      projectUrl: projectUrl ?? this.projectUrl,
      downloads: downloads ?? this.downloads,
      extra: extra ?? Map.from(this.extra),
    );
  }

  @override
  String toString() {
    return 'AppDetailInfo{appId: $appId, name: $name, version: $version, channel: $channel, sections: $sections}';
  }
}
