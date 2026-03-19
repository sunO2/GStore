import 'package:flutter/foundation.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';

/// 渠道详情数据代理基类
/// 包装原始数据，实现 IDetailInfo 接口
/// 子类实现特定渠道的数据访问逻辑
abstract class ChannelDetailProxy implements IDetailInfo {
  /// 原始数据（来自 API 或数据库）
  final Map<String, dynamic> _data;

  ChannelDetailProxy(this._data);

  /// 提供给子类访问原始数据的方法
  Map<String, dynamic> get data => _data;

  @override
  Map<String, dynamic> get extra => _data;

  @override
  bool get isValid => packageName.isNotEmpty && appName.isNotEmpty;

  /// 子类需要实现的渠道类型
  @override
  ChannelType get channelType;

  /// 子类需要实现的渠道ID（用于统一数据库）
  @override
  String get channelId => channelType.code;

  /// 子类需要实现 appName
  /// 从旧接口的 name 字段获取，确保兼容性
  @override
  String get appName;

  @override
  String? get readme => extra['readme']?.toString();

  @override
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

  @override
  List<ScreenshotInfo>? get screenshots {
    final screenshotsData = extra['screenshots'];
    if (screenshotsData is List) {
      return screenshotsData.map((e) {
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

  @override
  String? get changelog => extra['changelog']?.toString();

  @override
  List<String>? get permissions {
    final permissionsData = extra['permissions'];
    if (permissionsData is List) {
      return permissionsData.map((e) => e.toString()).toList();
    }
    return null;
  }

  @override
  List<StatTag> buildStatTags() {
    // 默认实现：子类可以覆盖
    return const [];
  }

  /// 辅助方法：从 Map 中安全获取值
  T? getValue<T>(String key) {
    final value = _data[key];
    if (value == null) return null;
    if (value is T) return value;
    return null;
  }

  /// 辅助方法：从嵌套 Map 中获取值
  T? getNestedValue<T>(List<String> keys) {
    dynamic current = _data;
    for (final key in keys) {
      if (current is Map) {
        current = current[key];
      } else {
        return null;
      }
    }
    if (current is T) return current;
    return null;
  }
}
