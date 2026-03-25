import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'dart:async';

import 'state.dart';

class DiscoveryLogic extends GetxController {
  final DiscoveryState state = DiscoveryState();

  late AppAggregatorManager _aggregator;
  late ChannelManager _channelManager;

  // 搜索控制器
  final searchController = TextEditingController();

  // 防抖定时器
  Timer? _debounceTimer;

  // 选中的搜索渠道
  ChannelType? _selectedSearchChannel;

  /// 获取渠道列表（用于UI显示）
  List<ChannelInfo> get channelList => _channelManager.allChannelInfo;

  /// 获取已排序的渠道类型列表（用于筛选标签）
  List<ChannelType> get sortedChannelTypes {
    final channels = state.channelApps.keys.toList();
    // 按渠道名称排序，确保顺序稳定
    channels.sort((a, b) => a.code.compareTo(b.code));
    return channels;
  }

  /// 获取当前显示的应用列表（扁平化，用于 Grid）
  /// 返回 (AppInfo, ChannelType) 对，确保每个应用都有正确的渠道信息
  List<(AppInfo, ChannelType)> getDisplayApps() {
    List<(AppInfo, ChannelType)> result = [];

    final channels = state.selectedChannel.value == null
        ? sortedChannelTypes
        : [state.selectedChannel.value!];

    for (var channel in channels) {
      final apps = state.channelApps[channel] ?? [];
      for (var app in apps) {
        // 显示模式筛选
        final isAdded = isAppAdded(channel, app.appId);
        switch (state.displayMode.value) {
          case DisplayMode.added:
            if (!isAdded) continue;
            break;
          case DisplayMode.notAdded:
            if (isAdded) continue;
            break;
          case DisplayMode.all:
          default:
            break;
        }

        // 搜索筛选
        if (state.searchKeyword.value.isNotEmpty) {
          final keyword = state.searchKeyword.value.toLowerCase();
          if (!app.name.toLowerCase().contains(keyword) &&
              !app.des.toLowerCase().contains(keyword)) {
            continue;
          }
        }

        result.add((app, channel));
      }
    }

    return result;
  }

  /// 获取应用的渠道信息
  ChannelType? getChannelForApp(String appId) {
    for (var entry in state.channelApps.entries) {
      if (entry.value.any((app) => app.appId == appId)) {
        return entry.key;
      }
    }
    return null;
  }

  /// 获取渠道应用统计
  int getChannelAppCount(ChannelType? channel) {
    if (channel == null) {
      return getTotalAppCount();
    }
    return state.channelApps[channel]?.length ?? 0;
  }

  /// 获取渠道已添加应用数
  int getChannelAddedCount(ChannelType? channel) {
    if (channel == null) {
      return getAddedAppCount();
    }
    final apps = state.channelApps[channel] ?? [];
    return apps.where((app) => isAppAdded(channel, app.appId)).length;
  }

  /// 计算响应式 Grid 列数
  int calculateCrossAxisCount(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width < 600) return 3;      // 手机竖屏
    if (width < 900) return 5;      // 手机横屏
    return 7;                       // 平板
  }

  /// 更新 Grid 列数
  void updateCrossAxisCount(BuildContext context) {
    state.crossAxisCount.value = calculateCrossAxisCount(context);
  }

  /// 进入/退出多选模式
  void toggleMultiSelectMode() {
    state.isMultiSelectMode.value = !state.isMultiSelectMode.value;
    if (!state.isMultiSelectMode.value) {
      state.selectedApps.clear();
    }
  }

  /// 切换应用选择状态
  void toggleAppSelection(String channelCode, String appId) {
    final key = '$channelCode:$appId';
    if (state.selectedApps.contains(key)) {
      state.selectedApps.remove(key);
    } else {
      state.selectedApps.add(key);
    }
  }

  /// 全选当前视图
  void selectAllInView() {
    state.selectedApps.clear();
    final appsWithChannel = getDisplayApps();
    for (var (app, channel) in appsWithChannel) {
      state.selectedApps.add('${channel.code}:${app.appId}');
    }
  }

  /// 取消全选
  void deselectAll() {
    state.selectedApps.clear();
  }

  /// 批量添加选中的应用
  Future<void> batchAddSelected() async {
    if (state.selectedApps.isEmpty) return;

    int successCount = 0;
    int failCount = 0;

    for (var key in state.selectedApps) {
      final parts = key.split(':');
      if (parts.length != 2) continue;

      final channelCode = parts[0];
      final appId = parts[1];

      // 查找对应的渠道和应用
      ChannelType? channel;
      AppInfo? appInfo;

      for (var entry in state.channelApps.entries) {
        if (entry.key.code == channelCode) {
          channel = entry.key;
          appInfo = entry.value.firstWhereOrNull((app) => app.appId == appId);
          break;
        }
      }

      if (channel != null && appInfo != null) {
        try {
          await _aggregator.toggleApp(
            channel: channel,
            appInfo: appInfo,
          );
          successCount++;
        } catch (e) {
          failCount++;
          debugPrint('添加应用失败: $appId - $e');
        }
      }
    }

    // 清空选择
    state.selectedApps.clear();
    state.isMultiSelectMode.value = false;

    // 刷新数据
    await _updateAddedAppsIndex();

    // 显示结果
    Get.snackbar(
      '批量添加完成',
      '成功: $successCount, 失败: $failCount',
      icon: Icon(
        failCount == 0 ? Icons.check_circle : Icons.warning,
        color: failCount == 0 ? Colors.green : Colors.orange,
      ),
      duration: const Duration(seconds: 2),
    );
  }

  /// 加载更多指定渠道的应用
  Future<void> loadMoreChannel(ChannelType channel) async {
    if (state.channelLoadingMore[channel] == true) return;

    state.channelLoadingMore[channel] = true;

    try {
      final currentPage = state.channelPages[channel] ?? 1;
      final channelInstance = _channelManager.getChannel(channel);

      if (channelInstance != null) {
        // TODO: 实现分页加载逻辑
        // 这里需要根据渠道的分页接口来实现
        // 暂时使用 forceRefresh 加载全部
        final result = await channelInstance.getAllApps(forceRefresh: true);
        if (result.success && result.data != null) {
          state.channelApps[channel] = result.data!;
          state.channelPages[channel] = currentPage + 1;
        }
      }
    } catch (e) {
      debugPrint('DiscoveryLogic: 加载更多 $channel 失败 - $e');
    } finally {
      state.channelLoadingMore[channel] = false;
    }
  }

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
    debugPrint('DiscoveryLogic: selectChannel called with type: ${type?.code ?? "null"}');
    debugPrint('DiscoveryLogic: current selectedChannel: ${state.selectedChannel.value?.code ?? "null"}');
    state.selectedChannel.value = type;
    debugPrint('DiscoveryLogic: new selectedChannel: ${state.selectedChannel.value?.code ?? "null"}');
  }

  /// 切换显示模式
  void setDisplayMode(DisplayMode mode) {
    state.displayMode.value = mode;
  }

  /// 搜索
  void setSearchKeyword(String keyword) {
    state.searchKeyword.value = keyword;
  }

  /// 显示渠道搜索对话框
  void showChannelSearchDialog(BuildContext context) {
    final availableChannels = _channelManager.enabledChannels;

    Get.dialog(
      AlertDialog(
        title: const Text('选择搜索渠道'),
        content: availableChannels.isEmpty
            ? const Text('没有可用的渠道')
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: availableChannels.map((channel) {
                  return ListTile(
                    leading: Icon(_getChannelIcon(channel.info.type)),
                    title: Text(channel.info.name),
                    subtitle: Text(channel.info.description),
                    onTap: () {
                      Get.back();  // 关闭对话框
                      _openChannelSearch(context, channel);
                    },
                  );
                }).toList(),
              ),
      ),
    );
  }

  /// 打开渠道搜索页面
  void _openChannelSearch(BuildContext context, dynamic channel) {
    // 获取渠道的搜索组件
    final searchWidget = channel.getAddAppWidget(
      context,
      (app) => toggleApp(channel.info.type, app),
    );

    if (searchWidget != null) {
      // 渠道提供了搜索组件，直接显示
      Get.dialog(
        Dialog(
          child: SizedBox(
            width: Get.width * 0.9,
            height: Get.height * 0.8,
            child: searchWidget,
          ),
        ),
      );
    } else {
      // 渠道不提供搜索组件，显示提示
      Get.snackbar(
        '提示',
        '${channel.info.name} 不支持搜索功能',
        duration: const Duration(seconds: 2),
      );
    }
  }

  /// 获取渠道图标
  IconData _getChannelIcon(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return Icons.storage;
      case ChannelType.github:
        return Icons.code;
      case ChannelType.http:
        return Icons.cloud;
      case ChannelType.vivo:
        return Icons.phone_android;
      case ChannelType.fdroid:
        return Icons.android;
      case ChannelType.custom:
        return Icons.apps;
    }
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
      case ChannelType.fdroid:
        return Icons.extension;
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

  /// 获取渠道名称
  String getChannelName(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return '本地数据库';
      case ChannelType.github:
        return 'GitHub';
      case ChannelType.http:
        return 'HTTP API';
      case ChannelType.vivo:
        return 'vivo';
      case ChannelType.fdroid:
        return 'F-Droid';
      default:
        return type.code;
    }
  }

  /// 切换显示模式（简化版本）
  void toggleDisplayMode() {
    switch (state.displayMode.value) {
      case DisplayMode.all:
        setDisplayMode(DisplayMode.added);
        break;
      case DisplayMode.added:
        setDisplayMode(DisplayMode.notAdded);
        break;
      case DisplayMode.notAdded:
        setDisplayMode(DisplayMode.all);
        break;
    }
  }

  /// 选择搜索渠道
  void selectSearchChannel(ChannelType? channel) {
    _selectedSearchChannel = channel;
  }

  /// 执行搜索
  Future<void> performSearch() async {
    if (searchController.text.trim().isEmpty) {
      return;
    }

    // 如果有选中的搜索渠道，只在该渠道搜索
    if (_selectedSearchChannel != null) {
      await _searchInChannel(_selectedSearchChannel!, searchController.text.trim());
    } else {
      // 搜索所有渠道
      for (var channel in _channelManager.enabledChannels) {
        await _searchInChannel(channel.info.type, searchController.text.trim());
      }
    }
  }

  /// 在指定渠道搜索
  Future<void> _searchInChannel(ChannelType channelType, String keyword) async {
    final channel = _channelManager.getChannel(channelType);
    if (channel == null) return;

    try {
      final result = await channel.searchApps(keyword, forceRefresh: true);
      if (result.success && result.data != null) {
        state.channelApps[channelType] = result.data!;
      }
    } catch (e) {
      debugPrint('DiscoveryLogic: 搜索 $channelType 失败 - $e');
    }
  }

  /// 防抖搜索
  void debounceSearch() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      performSearch();
    });
  }

  /// 显示批量操作菜单
  void showBatchActions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: AppSpacing.allLG,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.select_all),
                title: const Text('全选当前页面'),
                onTap: () {
                  Get.back();
                  _selectAllInCurrentView();
                },
              ),
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('批量添加已选'),
                onTap: () {
                  Get.back();
                  _batchAddSelected();
                },
              ),
              ListTile(
                leading: const Icon(Icons.remove_circle_outline),
                title: const Text('批量移除已选'),
                onTap: () {
                  Get.back();
                  _batchRemoveSelected();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 全选当前视图
  void _selectAllInCurrentView() {
    Get.snackbar(
      '提示',
      '批量操作功能开发中',
      icon: const Icon(Icons.info, color: Colors.blue),
    );
  }

  /// 批量添加
  void _batchAddSelected() {
    Get.snackbar(
      '提示',
      '批量操作功能开发中',
      icon: const Icon(Icons.info, color: Colors.blue),
    );
  }

  /// 批量移除
  void _batchRemoveSelected() {
    Get.snackbar(
      '提示',
      '批量操作功能开发中',
      icon: const Icon(Icons.info, color: Colors.blue),
    );
  }

  @override
  void onClose() {
    searchController.dispose();
    _debounceTimer?.cancel();
    super.onClose();
  }
}
