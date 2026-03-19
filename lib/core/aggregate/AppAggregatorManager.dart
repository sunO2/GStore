import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/db/apps/AppInfo.dart';

/// 应用聚合管理器
/// 负责管理所有渠道已添加的应用
class AppAggregatorManager {
  static AppAggregatorManager? _instance;
  static AppAggregatorManager get instance {
    _instance ??= AppAggregatorManager._internal();
    return _instance!;
  }

  AppAggregatorManager._internal();

  late AppAddedDatabase _database;
  late ChannelManager _channelManager;

  /// 流控制器 - 已添加应用变化通知
  final _appsChangedController = StreamController<List<AddedAppInfo>>.broadcast();

  /// 已添加应用变化流
  Stream<List<AddedAppInfo>> get appsChangedStream => _appsChangedController.stream;

  /// 是否已初始化
  bool _isInitialized = false;

  /// 初始化
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _channelManager = ChannelManager.instance;

      // 初始化数据库
      final database = await AppAddedDatabase.create();

      _database = database;
      _isInitialized = true;

      // 监听数据库变化事件
      try {
        final eventBus = DatabaseEventBus.instance;
        ever(eventBus.eventStream, (event) {
          if (event != null) {
            debugPrint('AppAggregatorManager: ✅ 收到数据库事件 - ${event.type}');
            debugPrint('AppAggregatorManager: 开始刷新应用列表...');
            // 任何数据库变化都触发应用列表刷新
            _notifyAppsChanged();
          }
        });
        debugPrint('AppAggregatorManager: 数据库事件监听已注册');
      } catch (e) {
        debugPrint('AppAggregatorManager: 注册数据库事件监听失败 - $e');
      }

      debugPrint('AppAggregatorManager: 初始化成功');
    } catch (e) {
      debugPrint('AppAggregatorManager: 初始化失败 - $e');
      rethrow;
    }
  }

  // ==================== 添加/移除应用 ====================

  /// 添加应用
  Future<void> addApp({
    required ChannelType channel,
    required AppInfo appInfo,
    int? sortOrder,
  }) async {
    final addedApp = AddedAppInfo(
      channelId: channel.code,
      appId: appInfo.appId,
      appName: appInfo.name,
      iconUrl: appInfo.icon,
      description: appInfo.des,
      category: appInfo.category?.join(','),
      addTime: DateTime.now().millisecondsSinceEpoch,
      sortOrder: sortOrder ?? 0,
    );

    await _database.addedAppDao.insertApp(addedApp);

    // 通知变化
    _notifyAppsChanged();

    debugPrint('AppAggregatorManager: 添加应用 - ${appInfo.name} (${channel.code})');
  }

  /// 批量添加应用
  Future<void> addApps({
    required ChannelType channel,
    required List<AppInfo> appInfos,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final addedApps = appInfos.map((app) => AddedAppInfo(
      channelId: channel.code,
      appId: app.appId,
      appName: app.name,
      iconUrl: app.icon,
      description: app.des,
      category: app.category?.join(','),
      addTime: now,
    )).toList();

    await _database.addedAppDao.insertApps(addedApps);

    _notifyAppsChanged();

    debugPrint('AppAggregatorManager: 批量添加 ${appInfos.length} 个应用 (${channel.code})');
  }

  /// 移除应用
  Future<void> removeApp({
    required ChannelType channel,
    required String appId,
  }) async {
    await _database.addedAppDao.removeApp(channel.code, appId);

    _notifyAppsChanged();

    debugPrint('AppAggregatorManager: 移除应用 - $appId (${channel.code})');
  }

  /// 切换应用添加状态
  Future<bool> toggleApp({
    required ChannelType channel,
    required AppInfo appInfo,
  }) async {
    final isAdded = await isAppAdded(channel: channel, appId: appInfo.appId);

    if (isAdded) {
      await removeApp(channel: channel, appId: appInfo.appId);
      return false;
    } else {
      await addApp(channel: channel, appInfo: appInfo);
      return true;
    }
  }

  /// 清空指定渠道的所有应用
  Future<void> clearChannel(ChannelType channel) async {
    await _database.addedAppDao.clearChannel(channel.code);

    _notifyAppsChanged();

    debugPrint('AppAggregatorManager: 清空渠道 - ${channel.code}');
  }

  /// 清空所有应用
  Future<void> clearAll() async {
    await _database.addedAppDao.clearAll();

    _notifyAppsChanged();

    debugPrint('AppAggregatorManager: 清空所有应用');
  }

  // ==================== 查询方法 ====================

  /// 获取所有已添加的应用（按添加时间倒序）
  Future<List<AddedAppInfo>> getAllAddedApps() async {
    return await _database.addedAppDao.getAllAddedApps();
  }

  /// 获取指定渠道的已添加应用
  Future<List<AddedAppInfo>> getAppsByChannel(ChannelType channel) async {
    return await _database.addedAppDao.getAppsByChannel(channel.code);
  }

  /// 检查应用是否已添加
  Future<bool> isAppAdded({
    required ChannelType channel,
    required String appId,
  }) async {
    final app = await _database.addedAppDao.getApp(channel.code, appId);
    return app != null;
  }

  /// 获取应用总数
  Future<int> getTotalCount() async {
    return await _database.addedAppDao.getTotalCount() ?? 0;
  }

  /// 获取指定渠道的应用数量
  Future<int> getCountByChannel(ChannelType channel) async {
    return await _database.addedAppDao.getCountByChannel(channel.code) ?? 0;
  }

  /// 获取已添加应用的索引
  /// 返回 Map<ChannelCode, Set<AppId>>
  Future<Map<String, Set<String>>> getAddedAppsIndex() async {
    final allApps = await getAllAddedApps();

    final index = <String, Set<String>>{};

    for (var app in allApps) {
      index.putIfAbsent(app.channelId, () => {});
      index[app.channelId]!.add(app.appId);
    }

    return index;
  }

  /// 从渠道获取已添加应用的详细信息
  /// 聚合所有渠道的已添加应用
  Future<List<AggregatedAppInfo>> getAggregatedApps() async {
    final addedApps = await getAllAddedApps();
    debugPrint('AppAggregatorManager: 从聚合数据库获取到 ${addedApps.length} 个应用');

    final aggregatedApps = <AggregatedAppInfo>[];
    int successCount = 0;
    int failedCount = 0;
    int cacheCount = 0;

    for (var addedApp in addedApps) {
      try {
        final channelType = ChannelType.fromCode(addedApp.channelId);
        if (channelType == null) {
          debugPrint('AppAggregatorManager: 跳过未知渠道 - ${addedApp.channelId}');
          continue;
        }

        // 从渠道获取应用详情
        final channel = _channelManager.getChannel(channelType);
        if (channel == null) {
          debugPrint('AppAggregatorManager: 渠道实例为空 - ${channelType.name}');
          failedCount++;
          continue;
        }

        debugPrint('AppAggregatorManager: 正在获取应用详情 - ${addedApp.appId} (${channelType.name})');
        final result = await channel.getAppInfo(addedApp.appId);

        if (result.success && result.data != null) {
          aggregatedApps.add(AggregatedAppInfo(
            addedAppInfo: addedApp,
            appInfo: result.data!,
            channel: channelType,
          ));
          successCount++;
        } else {
          // 渠道获取失败，使用本地缓存的数据
          debugPrint('AppAggregatorManager: 渠道获取失败，使用缓存 - ${addedApp.appId}, error: ${result.error}');
          aggregatedApps.add(AggregatedAppInfo(
            addedAppInfo: addedApp,
            appInfo: _createAppInfoFromAdded(addedApp),
            channel: channelType,
            isFromCache: true,
          ));
          cacheCount++;
        }
      } catch (e) {
        debugPrint('AppAggregatorManager: 获取应用详情异常 - ${addedApp.appId}, $e');
        // 使用本地缓存的数据
        aggregatedApps.add(AggregatedAppInfo(
          addedAppInfo: addedApp,
          appInfo: _createAppInfoFromAdded(addedApp),
          channel: ChannelType.localDb,
          isFromCache: true,
          error: e.toString(),
        ));
        failedCount++;
      }
    }

    debugPrint('AppAggregatorManager: 聚合完成 - 成功: $successCount, 缓存: $cacheCount, 失败: $failedCount');
    return aggregatedApps;
  }

  // ==================== 私有方法 ====================

  /// 从 AddedAppInfo 创建 AppInfo
  AppInfo _createAppInfoFromAdded(AddedAppInfo addedApp) {
    return AppInfo(
      addedApp.appId,
      addedApp.appName,
      '', // user
      '', // repositories
      addedApp.iconUrl ?? '',
      addedApp.description ?? '',
      addedApp.category?.split(',') ?? [],
    );
  }

  /// 通知应用列表变化
  void _notifyAppsChanged() {
    debugPrint('AppAggregatorManager: _notifyAppsChanged() 被调用');
    getAllAddedApps().then((apps) {
      debugPrint('AppAggregatorManager: 获取到 ${apps.length} 个已添加应用，准备发送通知');
      _appsChangedController.add(apps);
      debugPrint('AppAggregatorManager: 已发送 appsChangedStream 事件');
    }).catchError((error) {
      debugPrint('AppAggregatorManager: 获取应用列表失败 - $error');
    });
  }

  /// 释放资源
  Future<void> dispose() async {
    await _appsChangedController.close();
    // 注意：不关闭数据库，可能被其他地方使用
  }
}

/// 聚合应用信息
class AggregatedAppInfo {
  /// 已添加应用信息
  final AddedAppInfo addedAppInfo;

  /// 应用详细信息
  final AppInfo appInfo;

  /// 来源渠道
  final ChannelType channel;

  /// 是否来自缓存
  final bool isFromCache;

  /// 错误信息
  final String? error;

  AggregatedAppInfo({
    required this.addedAppInfo,
    required this.appInfo,
    required this.channel,
    this.isFromCache = false,
    this.error,
  });
}
