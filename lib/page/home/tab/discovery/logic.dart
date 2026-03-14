import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/db/apps/AppInfo.dart';

import 'state.dart';

class DiscoveryLogic extends GetxController {
  final DiscoveryState state = DiscoveryState();

  late AppAggregatorManager _aggregator;
  late ChannelManager _channelManager;

  @override
  void onReady() async {
    super.onReady();
    _aggregator = Get.find(tag: 'aggregatorManager');
    _channelManager = Get.find(tag: 'channelManager');

    // 监听已添加应用变化
    _aggregator.appsChangedStream.listen((apps) {
      _updateAddedAppsIndex();
    });

    await loadData();
  }

  /// 加载数据
  Future<void> loadData() async {
    state.isLoading.value = true;
    state.errorMessage.value = '';

    try {
      // 并发加载所有渠道的应用和已添加索引
      await Future.wait([
        _loadAllChannelApps(),
        _updateAddedAppsIndex(),
      ]);
    } catch (e) {
      state.errorMessage.value = '加载数据失败: $e';
      debugPrint('DiscoveryLogic: 加载失败 - $e');
    } finally {
      state.isLoading.value = false;
    }
  }

  /// 加载所有渠道的应用
  Future<void> _loadAllChannelApps() async {
    final channels = _channelManager.enabledChannels;

    for (var channel in channels) {
      try {
        final result = await channel.getAllApps();

        if (result.success && result.data != null) {
          state.channelApps[channel.info.type] = result.data!;
        }
      } catch (e) {
        debugPrint('DiscoveryLogic: 加载 ${channel.info.type.code} 失败 - $e');
        // 即使失败也添加空列表
        state.channelApps[channel.info.type] = [];
      }
    }
  }

  /// 更新已添加应用索引
  Future<void> _updateAddedAppsIndex() async {
    final index = await _aggregator.getAddedAppsIndex();
    state.addedAppsIndex.clear();
    state.addedAppsIndex.addAll(index);
  }

  /// 切换渠道筛选
  void selectChannel(ChannelType? type) {
    state.selectedChannel.value = type;
  }

  /// 切换显示模式
  void setDisplayMode(DisplayMode mode) {
    state.displayMode.value = mode;
  }

  /// 搜索
  void setSearchKeyword(String keyword) {
    state.searchKeyword.value = keyword;
  }

  /// 检查应用是否已添加
  bool isAppAdded(ChannelType channel, String appId) {
    return state.addedAppsIndex[channel.code]?.contains(appId) ?? false;
  }

  /// 添加/移除应用（添加到聚合管理器，用于首页显示）
  Future<void> toggleApp(ChannelType channel, AppInfo appInfo) async {
    try {
      // 使用聚合管理器切换应用状态
      final added = await _aggregator.toggleApp(
        channel: channel,
        appInfo: appInfo,
      );

      // 重新加载该渠道的应用列表
      final channelInstance = _channelManager.getChannel(channel);
      if (channelInstance != null) {
        final result = await channelInstance.getAllApps(forceRefresh: true);
        if (result.success && result.data != null) {
          state.channelApps[channel] = result.data!;
        }
      }

      Get.snackbar(
        added ? '已添加到首页' : '已从首页移除',
        appInfo.name,
        icon: Icon(
          added ? Icons.check_circle : Icons.remove_circle,
          color: added ? Colors.green : Colors.orange,
        ),
        duration: const Duration(seconds: 1),
      );
    } catch (e) {
      Get.snackbar(
        '操作失败',
        e.toString(),
        icon: const Icon(Icons.error, color: Colors.red),
      );
    }
  }

  /// 批量添加（添加渠道的所有应用）
  Future<void> addAllFromChannel(ChannelType channel) async {
    final apps = state.channelApps[channel] ?? [];
    if (apps.isEmpty) return;

    try {
      await _aggregator.addApps(
        channel: channel,
        appInfos: apps,
      );

      Get.snackbar(
        '批量添加',
        '已添加 ${apps.length} 个应用',
        icon: const Icon(Icons.check_circle, color: Colors.green),
      );
    } catch (e) {
      Get.snackbar(
        '操作失败',
        e.toString(),
        icon: const Icon(Icons.error, color: Colors.red),
      );
    }
  }

  /// 清空渠道的所有已添加应用
  Future<void> clearChannel(ChannelType channel) async {
    try {
      await _aggregator.clearChannel(channel);

      Get.snackbar(
        '已清空',
        '已清空 ${channel.code} 渠道的所有应用',
        icon: const Icon(Icons.delete_sweep, color: Colors.orange),
      );
    } catch (e) {
      Get.snackbar(
        '操作失败',
        e.toString(),
        icon: const Icon(Icons.error, color: Colors.red),
      );
    }
  }

  /// 获取筛选后的应用列表
  Map<ChannelType, List<AppInfo>> getFilteredApps() {
    final result = <ChannelType, List<AppInfo>>{};

    state.channelApps.forEach((channel, apps) {
      // 渠道筛选
      if (state.selectedChannel.value != null &&
          state.selectedChannel.value != channel) {
        return;
      }

      // 搜索和显示模式筛选
      var filteredApps = apps.where((app) {
        // 搜索筛选
        if (state.searchKeyword.value.isNotEmpty) {
          final keyword = state.searchKeyword.value.toLowerCase();
          if (!app.name.toLowerCase().contains(keyword) &&
              !app.des.toLowerCase().contains(keyword)) {
            return false;
          }
        }

        // 显示模式筛选
        final isAdded = isAppAdded(channel, app.appId);
        switch (state.displayMode.value) {
          case DisplayMode.added:
            return isAdded;
          case DisplayMode.notAdded:
            return !isAdded;
          case DisplayMode.all:
          default:
            return true;
        }
      }).toList();

      if (filteredApps.isNotEmpty) {
        result[channel] = filteredApps;
      }
    });

    return result;
  }

  /// 获取渠道图标
  IconData getChannelIcon(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return Icons.storage;
      case ChannelType.github:
        return Icons.code;
      case ChannelType.http:
        return Icons.cloud;
      case ChannelType.vivo:
        return Icons.phone_android;
      default:
        return Icons.apps;
    }
  }

  /// 获取应用总数
  int getTotalAppCount() {
    return state.channelApps.values.fold(0, (sum, apps) => sum + apps.length);
  }

  /// 获取已添加应用总数
  int getAddedAppCount() {
    return state.addedAppsIndex.values.fold(0, (sum, ids) => sum + ids.length);
  }

  /// 显示添加应用的 Bottom Sheet
  void showAddAppSheet(BuildContext context) {
    final channels = _channelManager.enabledChannels;

    // 过滤出支持添加应用的渠道
    final addableChannels = channels.where((channel) {
      final widget = channel.getAddAppWidget(context, (app) {});
      return widget != null;
    }).toList();

    if (addableChannels.isEmpty) {
      Get.snackbar(
        '提示',
        '当前没有支持通过 UI 添加应用的渠道',
        icon: const Icon(Icons.info, color: Colors.blue),
      );
      return;
    }

    // 如果只有一个支持添加的渠道，直接显示它的添加界面
    if (addableChannels.length == 1) {
      final channel = addableChannels.first;
      final addWidget = channel.getAddAppWidget(
        context,
        (app) async {
          // 注意：这里的回调现在不再使用
          // 搜索 widget 会直接保存到渠道数据库
          // 这个回调保留是为了兼容性，但不会被调用
        },
        onAppSaved: () async {
          // 保存后重新加载该渠道的应用列表
          final result = await channel.getAllApps(forceRefresh: true);
          if (result.success && result.data != null) {
            state.channelApps[channel.info.type] = result.data!;
          }
        },
      );

      if (addWidget != null) {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (context) => DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            expand: false,
            builder: (context, scrollController) => Container(
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  // 拖动指示器
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 12),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // 标题
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Icon(
                          getChannelIcon(channel.info.type),
                          size: 20,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '搜索并保存 ${channel.info.name} 应用',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Get.back(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  // 添加界面
                  Expanded(child: addWidget),
                ],
              ),
            ),
          ),
        );
      }
      return;
    }

    // 多个渠道时，先显示渠道选择列表
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖动指示器
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.add_circle, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '选择渠道',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 渠道列表
            ListView.builder(
              shrinkWrap: true,
              itemCount: addableChannels.length,
              itemBuilder: (context, index) {
                final channel = addableChannels[index];
                return ListTile(
                  leading: Icon(getChannelIcon(channel.info.type)),
                  title: Text(channel.info.name),
                  subtitle: Text(channel.info.description),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Get.back();
                    // 显示该渠道的添加界面
                    final addWidget = channel.getAddAppWidget(
                      context,
                      (app) async {
                        // 注意：这里的回调现在不再使用
                        // 搜索 widget 会直接保存到渠道数据库
                      },
                      onAppSaved: () async {
                        // 保存后重新加载该渠道的应用列表
                        final result = await channel.getAllApps(forceRefresh: true);
                        if (result.success && result.data != null) {
                          state.channelApps[channel.info.type] = result.data!;
                        }
                      },
                    );

                    if (addWidget != null) {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        builder: (context) => DraggableScrollableSheet(
                          initialChildSize: 0.7,
                          minChildSize: 0.5,
                          maxChildSize: 0.95,
                          expand: false,
                          builder: (context, scrollController) => Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(20),
                                topRight: Radius.circular(20),
                              ),
                            ),
                            child: Column(
                              children: [
                                // 拖动指示器
                                Container(
                                  margin: const EdgeInsets.symmetric(vertical: 12),
                                  width: 40,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: Colors.grey[300],
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                // 标题
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  child: Row(
                                    children: [
                                      Icon(
                                        getChannelIcon(channel.info.type),
                                        size: 20,
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '搜索并保存 ${channel.info.name} 应用',
                                        style: Theme.of(context).textTheme.titleMedium,
                                      ),
                                      const Spacer(),
                                      IconButton(
                                        icon: const Icon(Icons.close),
                                        onPressed: () => Get.back(),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1),
                                // 添加界面
                                Expanded(child: addWidget),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void onClose() {
    super.onClose();
  }
}
