/// 统一数据库管理器（简化版）
/// 先用内存存储，后续迁移到 sqflite
library;

import 'package:flutter/foundation.dart';
import 'package:gstore/core/model/AppInfoEntity.dart';
import 'package:gstore/core/model/IAppInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// 统一数据库管理器（临时内存实现）
class UnifiedDatabase {
  static final UnifiedDatabase _instance = UnifiedDatabase._internal();
  factory UnifiedDatabase() => _instance;

  UnifiedDatabase._internal();

  final Map<String, AppInfoEntity> _apps = {};

  /// 获取应用
  Future<AppInfoEntity?> findByPackage(String packageName) async {
    return _apps[packageName];
  }

  /// 获取所有应用
  Future<List<AppInfoEntity>> getAllApps() async {
    return _apps.values.toList()
      ..sort((a, b) => b.addTime.compareTo(a.addTime));
  }

  /// 根据渠道获取应用
  Future<List<AppInfoEntity>> getAppsByChannel(String channelId) async {
    return _apps.values
        .where((app) => app.channelId == channelId)
        .toList()
      ..sort((a, b) => b.addTime.compareTo(a.addTime));
  }

  /// 搜索应用
  Future<List<AppInfoEntity>> searchApps(String keyword) async {
    final pattern = keyword.toLowerCase();
    return _apps.values
        .where((app) =>
            app.appName.toLowerCase().contains(pattern) ||
            app.packageName.toLowerCase().contains(pattern))
        .toList()
      ..sort((a, b) => b.addTime.compareTo(a.addTime));
  }

  /// 插入或更新应用
  Future<void> insertApp(AppInfoEntity app) async {
    _apps[app.packageName] = app;
  }

  /// 批量插入
  Future<void> insertApps(List<AppInfoEntity> apps) async {
    for (final app in apps) {
      _apps[app.packageName] = app;
    }
  }

  /// 删除应用
  Future<void> deleteByPackage(String packageName) async {
    _apps.remove(packageName);
  }

  /// 清空
  Future<void> deleteAll() async {
    _apps.clear();
  }

  /// 获取总数
  Future<int> getCount() async {
    return _apps.length;
  }

  /// 检查是否存在
  Future<bool> exists(String packageName) async {
    return _apps.containsKey(packageName);
  }

  /// 获取所有包名
  Future<List<String>> getAllPackageNames() async {
    return _apps.keys.toList();
  }
}
