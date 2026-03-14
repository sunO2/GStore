import 'package:flutter/foundation.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;

/// 渠道管理器
/// 负责管理多个渠道，支持优先级、降级和手动指定
class ChannelManager {
  static ChannelManager? _instance;
  static ChannelManager get instance {
    _instance ??= ChannelManager._internal();
    return _instance!;
  }

  ChannelManager._internal();

  /// 所有已注册的渠道
  final Map<ChannelType, IChannel> _channels = {};

  /// 默认渠道类型（当未指定渠道时使用）
  ChannelType _defaultChannelType = ChannelType.localDb;

  /// 获取默认渠道类型
  ChannelType get defaultChannelType => _defaultChannelType;

  /// 设置默认渠道
  void setDefaultChannel(ChannelType type) {
    if (_channels.containsKey(type)) {
      _defaultChannelType = type;
      debugPrint('ChannelManager: 默认渠道已设置为 ${type.code}');
    } else {
      debugPrint('ChannelManager: 渠道 ${type.code} 未注册，无法设为默认');
    }
  }

  /// 注册渠道
  void registerChannel(IChannel channel) {
    _channels[channel.info.type] = channel;
    debugPrint('ChannelManager: 渠道 ${channel.info.type.code} 已注册');
  }

  /// 批量注册渠道
  void registerChannels(List<IChannel> channels) {
    for (var channel in channels) {
      registerChannel(channel);
    }
  }

  /// 取消注册渠道
  void unregisterChannel(ChannelType type) {
    var channel = _channels.remove(type);
    if (channel != null) {
      channel.dispose();
      debugPrint('ChannelManager: 渠道 ${type.code} 已取消注册');
    }
  }

  /// 获取渠道
  IChannel? getChannel(ChannelType type) {
    return _channels[type];
  }

  /// 获取所有已注册渠道信息（按优先级排序）
  List<ChannelInfo> get allChannelInfo {
    var infos = _channels.values.map((e) => e.info).toList();
    infos.sort((a, b) => a.priority.compareTo(b.priority));
    return infos;
  }

  /// 获取所有启用的渠道（按优先级排序）
  List<IChannel> get enabledChannels {
    var channels = _channels.values.where((e) => e.info.enabled).toList();
    channels.sort((a, b) => a.info.priority.compareTo(b.info.priority));
    return channels;
  }

  /// 检查渠道可用性
  Future<List<ChannelType>> checkAvailableChannels() async {
    List<ChannelType> availableTypes = [];

    for (var entry in _channels.entries) {
      if (entry.value.info.enabled) {
        bool isAvailable = await entry.value.checkAvailable();
        if (isAvailable) {
          availableTypes.add(entry.key);
        }
      }
    }

    return availableTypes;
  }

  // ==================== 查询方法（指定渠道） ====================

  /// 使用指定渠道获取所有应用
  Future<ChannelResult<List<AppInfo>>> getAllApps({
    ChannelType? from,
    bool forceRefresh = false,
  }) async {
    var channel = _selectChannel(from);
    if (channel == null) {
      return ChannelResult.failure(
        from: from ?? _defaultChannelType,
        error: '渠道不可用或未注册',
      );
    }
    return channel.getAllApps(forceRefresh: forceRefresh);
  }

  /// 使用指定渠道获取应用信息
  Future<ChannelResult<AppInfo?>> getAppInfo(
    String appId, {
    ChannelType? from,
    bool forceRefresh = false,
  }) async {
    var channel = _selectChannel(from);
    if (channel == null) {
      return ChannelResult.failure(
        from: from ?? _defaultChannelType,
        error: '渠道不可用或未注册',
      );
    }
    return channel.getAppInfo(appId, forceRefresh: forceRefresh);
  }

  /// 使用指定渠道搜索应用
  Future<ChannelResult<List<AppInfo>>> searchApps(
    String keyword, {
    ChannelType? from,
    bool forceRefresh = false,
  }) async {
    var channel = _selectChannel(from);
    if (channel == null) {
      return ChannelResult.failure(
        from: from ?? _defaultChannelType,
        error: '渠道不可用或未注册',
      );
    }
    return channel.searchApps(keyword, forceRefresh: forceRefresh);
  }

  /// 使用指定渠道按分类搜索
  Future<ChannelResult<List<AppInfo>>> searchByCategory(
    String categoryId, {
    ChannelType? from,
    bool forceRefresh = false,
  }) async {
    var channel = _selectChannel(from);
    if (channel == null) {
      return ChannelResult.failure(
        from: from ?? _defaultChannelType,
        error: '渠道不可用或未注册',
      );
    }
    return channel.searchByCategory(categoryId, forceRefresh: forceRefresh);
  }

  /// 使用指定渠道获取所有分类
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    ChannelType? from,
    bool forceRefresh = false,
  }) async {
    var channel = _selectChannel(from);
    if (channel == null) {
      return ChannelResult.failure(
        from: from ?? _defaultChannelType,
        error: '渠道不可用或未注册',
      );
    }
    return channel.getAllCategories(forceRefresh: forceRefresh);
  }

  // ==================== 查询方法（自动降级） ====================

  /// 获取所有应用（支持自动降级）
  Future<ChannelResult<List<AppInfo>>> getAllAppsWithFallback({
    bool forceRefresh = false,
    List<ChannelType>? preferredOrder,
  }) async {
    var channels = _getChannelsInOrder(preferredOrder);

    for (var channel in channels) {
      try {
        var result = await channel.getAllApps(forceRefresh: forceRefresh);
        if (result.success && result.data != null) {
          return result;
        }
      } catch (e) {
        debugPrint('ChannelManager: 渠道 ${channel.info.type.code} 查询失败: $e');
        continue;
      }
    }

    return ChannelResult.failure(
      from: _defaultChannelType,
      error: '所有渠道均不可用',
    );
  }

  /// 获取应用信息（支持自动降级）
  Future<ChannelResult<AppInfo?>> getAppInfoWithFallback(
    String appId, {
    bool forceRefresh = false,
    List<ChannelType>? preferredOrder,
  }) async {
    var channels = _getChannelsInOrder(preferredOrder);

    for (var channel in channels) {
      try {
        var result = await channel.getAppInfo(appId, forceRefresh: forceRefresh);
        if (result.success) {
          return result;
        }
      } catch (e) {
        debugPrint('ChannelManager: 渠道 ${channel.info.type.code} 查询失败: $e');
        continue;
      }
    }

    return ChannelResult.failure(
      from: _defaultChannelType,
      error: '所有渠道均不可用',
    );
  }

  // ==================== 更新相关 ====================

  /// 检查指定渠道的更新
  Future<ChannelResult<bool>> checkUpdate({ChannelType? from}) async {
    var channel = _selectChannel(from);
    if (channel == null) {
      return ChannelResult.failure(
        from: from ?? _defaultChannelType,
        error: '渠道不可用或未注册',
      );
    }
    return channel.checkUpdate();
  }

  /// 执行指定渠道的更新
  Future<ChannelResult<bool>> doUpdate({
    ChannelType? from,
    Function(int current, int total)? onProgress,
  }) async {
    var channel = _selectChannel(from);
    if (channel == null) {
      return ChannelResult.failure(
        from: from ?? _defaultChannelType,
        error: '渠道不可用或未注册',
      );
    }
    return channel.doUpdate(onProgress: onProgress);
  }

  /// 检查所有启用渠道的更新
  Future<Map<ChannelType, ChannelResult<bool>>> checkAllUpdates() async {
    Map<ChannelType, ChannelResult<bool>> results = {};

    for (var channel in enabledChannels) {
      results[channel.info.type] = await channel.checkUpdate();
    }

    return results;
  }

  // ==================== 缓存管理 ====================

  /// 清除指定渠道的缓存
  Future<void> clearCache({ChannelType? from}) async {
    if (from != null) {
      var channel = _channels[from];
      if (channel != null) {
        await channel.clearCache();
      }
    } else {
      for (var channel in _channels.values) {
        await channel.clearCache();
      }
    }
  }

  /// 获取所有渠道的总缓存大小
  Future<int> getTotalCacheSize() async {
    int total = 0;
    for (var channel in _channels.values) {
      total += await channel.getCacheSize();
    }
    return total;
  }

  // ==================== 初始化与释放 ====================

  /// 初始化所有启用的渠道
  Future<void> initializeAll() async {
    for (var channel in enabledChannels) {
      if (!channel.isInitialized) {
        try {
          await channel.initialize();
          debugPrint('ChannelManager: 渠道 ${channel.info.type.code} 初始化成功');
        } catch (e) {
          debugPrint('ChannelManager: 渠道 ${channel.info.type.code} 初始化失败: $e');
        }
      }
    }
  }

  /// 释放所有渠道资源
  Future<void> disposeAll() async {
    for (var channel in _channels.values) {
      await channel.dispose();
    }
    _channels.clear();
    _instance = null;
  }

  // ==================== 私有方法 ====================

  /// 选择渠道
  IChannel? _selectChannel(ChannelType? type) {
    var selectedType = type ?? _defaultChannelType;
    var channel = _channels[selectedType];

    if (channel == null) {
      debugPrint('ChannelManager: 渠道 ${selectedType.code} 未注册');
      return null;
    }

    if (!channel.info.enabled) {
      debugPrint('ChannelManager: 渠道 ${selectedType.code} 未启用');
      return null;
    }

    return channel;
  }

  /// 获取按优先级排序的渠道列表
  List<IChannel> _getChannelsInOrder(List<ChannelType>? preferredOrder) {
    if (preferredOrder != null && preferredOrder.isNotEmpty) {
      // 使用指定的优先级顺序
      var orderedChannels = <IChannel>[];
      for (var type in preferredOrder) {
        var channel = _channels[type];
        if (channel != null && channel.info.enabled) {
          orderedChannels.add(channel);
        }
      }
      // 添加剩余的启用渠道
      for (var channel in enabledChannels) {
        if (!orderedChannels.contains(channel)) {
          orderedChannels.add(channel);
        }
      }
      return orderedChannels;
    }

    return enabledChannels;
  }
}
