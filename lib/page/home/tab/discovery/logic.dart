import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import 'state.dart';
import 'widgets/tag_picker_dialog.dart';

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
  /// 返回 (AppSummary, ChannelType) 对，确保每个应用都有正确的渠道信息
  List<(AppSummary, ChannelType)> getDisplayApps() {
    List<(AppSummary, ChannelType)> result = [];

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
      AppSummary? appInfo;

      for (var entry in state.channelApps.entries) {
        if (entry.key.code == channelCode) {
          channel = entry.key;
          appInfo = entry.value.firstWhereOrNull((app) => app.appId == appId);
          break;
        }
      }

      if (channel != null && appInfo != null) {
        try {
          // 批量添加不逐个弹标签选择框（避免噪声），如需分类可单独添加后手动打标
          await _aggregator.toggleApp(
            channel: channel,
            appInfo: appInfo,
          );
          successCount++;
        } catch (e) {
          failCount++;
          appLog.error('添加应用失败: $appId - $e');
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
      appLog.error('DiscoveryLogic: 加载更多 $channel 失败 - $e');
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
      appLog.error('DiscoveryLogic: 加载失败 - $e');
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
        appLog.error('DiscoveryLogic: 加载 ${channel.info.type.code} 失败 - $e');
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
  Future<void> toggleApp(ChannelType channel, AppSummary appInfo) async {
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

      // 添加成功后才弹标签选择框（fire-and-forget，不阻塞切换流程）
      if (added) {
        unawaited(showTagPickerForApp(channel, appInfo));
      }
    } catch (e) {
      Get.snackbar(
        '操作失败',
        e.toString(),
        icon: const Icon(Icons.error, color: Colors.red),
      );
    }
  }

  /// 本地库预置分类加载失败/为空时的内置回退列表
  static const List<String> _fallbackPresetTags = [
    '工具',
    '游戏',
    '社交',
    '影音',
    '阅读',
    '效率',
    '系统',
  ];

  /// 应用添加成功后弹出可选分类标签对话框
  ///
  /// 读取当前标签 -> 加载预置分类（本地库 AppCategory.description，失败回退内置列表）
  /// -> 展示对话框 -> 用户确认后整体保存（替换语义）。
  Future<void> showTagPickerForApp(ChannelType channel, AppSummary appInfo) async {
    // 读取当前标签
    final currentTags =
        await _aggregator.getTags(channel: channel, appId: appInfo.appId);

    // 加载预置分类：本地库 AppCategory 的 description 作为标签值
    var presetTags = <String>[];
    try {
      final categories = await "gstore".repoDB.db.dao.getAllCategory();
      presetTags = categories
          .map((c) => c.description.trim())
          .where((d) => d.isNotEmpty)
          .toList();
    } catch (e) {
      appLog.error('DiscoveryLogic: 加载预置分类失败，使用内置列表 - $e');
    }
    if (presetTags.isEmpty) {
      presetTags = _fallbackPresetTags;
    }

    // 弹出标签选择对话框
    final result = await showTagPickerDialog(
      Get.context!,
      presetTags: presetTags,
      currentTags: currentTags,
    );
    if (result == null) return; // 取消，不保存

    try {
      await _aggregator.setTags(
        channel: channel,
        appId: appInfo.appId,
        tags: result,
      );
    } catch (e) {
      appLog.error('DiscoveryLogic: 保存标签失败 - $e');
      Get.snackbar(
        '保存标签失败',
        e.toString(),
        icon: const Icon(Icons.error, color: Colors.red),
      );
    }
  }

  /// 保存搜索结果到渠道数据库（不直接入库首页）
  /// 用户需在渠道应用列表中选择"入库"才会加入首页
  Future<bool> saveSearchToChannel(ChannelType channel, AppSummary app) async {
    final channelInstance = _channelManager.getChannel(channel);
    if (channelInstance == null) return false;
    try {
      // 统一调用 IChannel.addApp（各渠道内部处理保存逻辑）
      final result = await channelInstance.addApp(app);
      if (!result.success) {
        appLog.error(
            'DiscoveryLogic: ${channel.code} 保存搜索结果失败 - ${result.error}');
        return false;
      }

      // 刷新该渠道的应用列表（让保存的应用出现在渠道视图中）
      await _refreshChannelApps(channel);
      return true;
    } catch (e) {
      appLog.error('DiscoveryLogic: 保存搜索结果失败 - $e');
      return false;
    }
  }

  /// 刷新指定渠道的应用列表
  Future<void> _refreshChannelApps(ChannelType channel) async {
    final channelInstance = _channelManager.getChannel(channel);
    if (channelInstance == null) return;
    try {
      final result = await channelInstance.getAllApps(forceRefresh: true);
      if (result.success && result.data != null) {
        state.channelApps[channel] = result.data!;
      }
    } catch (e) {
      appLog.error('DiscoveryLogic: 刷新渠道应用失败 - $e');
    }
  }

  /// 从渠道移除应用（同时从首页聚合移除）
  /// 返回是否成功；[showSnack] 为 false 时静默（批量操作场景）
  Future<bool> removeFromChannel(
    ChannelType channel,
    String appId, {
    bool showSnack = true,
  }) async {
    final channelInstance = _channelManager.getChannel(channel);
    if (channelInstance == null) return false;
    try {
      final result = await channelInstance.removeApp(appId);
      if (!result.success) {
        appLog.error(
            'DiscoveryLogic: ${channel.code} 移除应用失败 - ${result.error}');
        if (showSnack) {
          Get.snackbar(
            '移除失败',
            '${result.error ?? '未知错误'}',
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: Get.theme.colorScheme.errorContainer,
            duration: const Duration(seconds: 2),
          );
        }
        return false;
      }

      // 若已添加到首页，同步移除
      final aggregator = _aggregator;
      if (await aggregator.isAppAdded(channel: channel, appId: appId)) {
        await aggregator.removeApp(channel: channel, appId: appId);
      }

      // 刷新渠道列表
      await _refreshChannelApps(channel);
      if (showSnack) {
        Get.snackbar(
          '已移除',
          '已从${getChannelName(channel)}移除',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 1),
        );
      }
      return true;
    } catch (e) {
      appLog.error('DiscoveryLogic: 移除渠道应用失败 - $e');
      if (showSnack) {
        Get.snackbar(
          '移除失败',
          e.toString(),
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Get.theme.colorScheme.errorContainer,
          duration: const Duration(seconds: 2),
        );
      }
      return false;
    }
  }

  /// 显示应用操作菜单（长按触发）
  /// 单应用操作：添加到首页/移除首页、从渠道删除、批量管理
  void showAppActions(BuildContext context, ChannelType channel, AppSummary app) {
    final isAdded = isAppAdded(channel, app.appId);
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
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
            // 应用信息头
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  AppIcon(url: app.icon, width: 40, height: 40),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          '${getChannelName(channel)} · '
                          '${isAdded ? '已在首页' : '未添加到首页'}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 添加到首页 / 从首页移除
            ListTile(
              leading: Icon(
                isAdded
                    ? Icons.remove_circle_outline
                    : Icons.add_circle_outline,
                color: theme.colorScheme.primary,
              ),
              title: Text(isAdded ? '从首页移除' : '添加到首页'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                toggleApp(channel, app);
              },
            ),
            // 从渠道删除
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text(
                '从渠道删除',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                AppDialogs.showDialog(
                  title: '移除应用',
                  content:
                      '确定从${getChannelName(channel)}移除 ${app.name} 吗？',
                  confirmText: '移除',
                  cancelText: '取消',
                  isDangerous: true,
                  onConfirm: () => removeFromChannel(channel, app.appId),
                );
              },
            ),
            // 批量管理
            ListTile(
              leading: Icon(
                Icons.checklist,
                color: theme.colorScheme.secondary,
              ),
              title: const Text('批量管理'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                toggleMultiSelectMode();
                toggleAppSelection(channel.code, app.appId);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
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
  Map<ChannelType, List<AppSummary>> getFilteredApps() {
    final result = <ChannelType, List<AppSummary>>{};

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
  /// 直接弹出搜索框 + 渠道多选（默认 F-Droid，记忆上次选中）
  void showAddAppSheet(BuildContext context) {
    final channels = _channelManager.enabledChannels;

    // 过滤出启用的搜索渠道
    final searchableChannels = channels.where((c) => c.info.enabled).toList();

    if (searchableChannels.isEmpty) {
      Get.snackbar(
        '提示',
        '当前没有可用的搜索渠道',
        icon: const Icon(Icons.info, color: Colors.blue),
      );
      return;
    }

    // 加载记忆的选中渠道（默认 F-Droid）
    _loadSelectedChannelCodes().then((saved) {
      if (!context.mounted) return;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        builder: (sheetContext) => _AddAppSearchSheet(
          channels: searchableChannels,
          initialSelectedCodes: saved,
          onSaveToChannel: saveSearchToChannel,
          onSelectionChanged: _saveSelectedChannelCodes,
        ),
      );
    });
  }

  /// 读取记忆的选中渠道（默认 F-Droid）
  Future<List<String>> _loadSelectedChannelCodes() async {
    try {
      final saved =
          await ConfigService.instance.getT<List<String>>(ConfigKeys.selectedChannels);
      if (saved != null && saved.isNotEmpty) return saved;
      return const ['fdroid'];
    } catch (e) {
      appLog.error('DiscoveryLogic: 读取选中渠道失败 - $e');
      return const ['fdroid'];
    }
  }

  /// 保存选中渠道
  Future<void> _saveSelectedChannelCodes(List<String> codes) async {
    try {
      await ConfigService.instance.set(
        ConfigKeys.selectedChannels,
        codes,
        source: ConfigChangeSource.user,
      );
    } catch (e) {
      appLog.error('DiscoveryLogic: 保存选中渠道失败 - $e');
    }
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
      appLog.error('DiscoveryLogic: 搜索 $channelType 失败 - $e');
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
                  Navigator.of(context).pop();
                  _selectAllInCurrentView();
                },
              ),
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('批量添加已选'),
                onTap: () {
                  Navigator.of(context).pop();
                  _batchAddSelected();
                },
              ),
              ListTile(
                leading: const Icon(Icons.remove_circle_outline),
                title: const Text('批量移除已选'),
                onTap: () {
                  Navigator.of(context).pop();
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

  /// 批量移除（从渠道删除选中的应用，供 UI 调用）
  Future<void> batchRemoveSelected() => _batchRemoveSelected();

  /// 批量移除（从渠道删除选中的应用）
  Future<void> _batchRemoveSelected() async {
    if (state.selectedApps.isEmpty) return;

    final confirmed = await AppDialogs.showDialog(
      title: '移除应用',
      content: '确定从渠道移除选中的 ${state.selectedApps.length} 个应用吗？',
      confirmText: '移除',
      cancelText: '取消',
      isDangerous: true,
    );
    if (confirmed != true) return;

    int successCount = 0;
    int failCount = 0;
    final keys = List<String>.from(state.selectedApps);

    for (final key in keys) {
      final parts = key.split(':');
      if (parts.length != 2) continue;
      final channelCode = parts[0];
      final appId = parts[1];
      final channel = ChannelType.fromCode(channelCode);
      if (channel == null) continue;

      final ok = await removeFromChannel(channel, appId, showSnack: false);
      if (ok) {
        successCount++;
      } else {
        failCount++;
      }
    }

    // 清空选择并退出多选
    state.selectedApps.clear();
    state.isMultiSelectMode.value = false;

    Get.snackbar(
      '移除完成',
      '成功: $successCount, 失败: $failCount',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void onClose() {
    searchController.dispose();
    _debounceTimer?.cancel();
    super.onClose();
  }
}

/// 添加应用搜索 Bottom Sheet
/// 直接搜索，下方渠道多选（默认 F-Droid，记忆选中）
class _AddAppSearchSheet extends StatefulWidget {
  /// 可选搜索渠道
  final List<IChannel> channels;

  /// 初始选中的渠道 codes
  final List<String> initialSelectedCodes;

  /// 保存到渠道回调（返回是否成功）
  final Future<bool> Function(ChannelType channel, AppSummary appInfo)
      onSaveToChannel;

  /// 选中渠道变化回调（持久化）
  final Future<void> Function(List<String> codes) onSelectionChanged;

  const _AddAppSearchSheet({
    required this.channels,
    required this.initialSelectedCodes,
    required this.onSaveToChannel,
    required this.onSelectionChanged,
  });

  @override
  State<_AddAppSearchSheet> createState() => _AddAppSearchSheetState();
}

class _AddAppSearchSheetState extends State<_AddAppSearchSheet> {
  late final Set<String> _selectedCodes;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// 搜索结果：应用 + 来源渠道
  final List<(AppSummary, ChannelType)> _results = [];

  bool _searching = false;
  bool _searched = false;
  Timer? _debounce;

  /// 已保存到渠道的应用 key（channel.code:appId）
  final Set<String> _savedKeys = {};

  /// 正在保存的 key
  String? _savingKey;

  @override
  void initState() {
    super.initState();
    // 初始选中 = 记忆的选中（过滤无效渠道），空则默认 fdroid
    final validCodes = widget.channels.map((c) => c.info.type.code).toSet();
    final initial = widget.initialSelectedCodes.where(validCodes.contains).toSet();
    _selectedCodes = initial.isNotEmpty ? initial : {'fdroid'};
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 当前选中的渠道类型
  List<ChannelType> get _selectedTypes {
    return widget.channels
        .where((c) => _selectedCodes.contains(c.info.type.code))
        .map((c) => c.info.type)
        .toList();
  }

  /// 切换渠道选中
  void _toggleChannel(ChannelType type) {
    setState(() {
      if (_selectedCodes.contains(type.code)) {
        _selectedCodes.remove(type.code);
      } else {
        _selectedCodes.add(type.code);
      }
    });
    // 持久化选中
    widget.onSelectionChanged(_selectedCodes.toList());
    // 有搜索词则重新搜索
    if (_searchController.text.trim().isNotEmpty) {
      _doSearch(_searchController.text.trim());
    }
  }

  /// 防抖搜索
  void _onKeywordChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final keyword = value.trim();
      if (keyword.isEmpty) {
        setState(() {
          _results.clear();
          _searched = false;
        });
        return;
      }
      _doSearch(keyword);
    });
  }

  /// 搜索所有选中渠道，聚合结果
  Future<void> _doSearch(String keyword) async {
    final types = _selectedTypes;
    if (types.isEmpty) {
      setState(() {
        _results.clear();
        _searched = true;
      });
      return;
    }

    setState(() {
      _searching = true;
      _searched = true;
    });

    final newResults = <(AppSummary, ChannelType)>[];
    for (final type in types) {
      try {
        final channel = widget.channels.firstWhereOrNull(
          (c) => c.info.type == type,
        );
        if (channel == null) continue;
        final result = await channel.searchApps(keyword, forceRefresh: true);
        if (result.success && result.data != null) {
          for (final app in result.data!) {
            newResults.add((app, type));
          }
        }
      } catch (e) {
        appLog.error('_AddAppSearchSheet: 搜索 ${type.code} 失败 - $e');
      }
    }

    // 按搜索词相似度排序（名称/包名完全匹配 > 前缀 > 包含 > 描述包含）
    final kw = keyword.toLowerCase();
    newResults.sort((a, b) => _scoreResult(b.$1, kw) - _scoreResult(a.$1, kw));

    if (!mounted) return;
    setState(() {
      _results
        ..clear()
        ..addAll(newResults);
      _searching = false;
    });
  }

  /// 计算应用与搜索词的匹配分数
  int _scoreResult(AppSummary app, String kw) {
    final name = app.name.toLowerCase();
    final pkg = app.appId.toLowerCase();
    final des = app.des.toLowerCase();
    int score = 0;
    if (name == kw) {
      score += 100;
    } else if (name.startsWith(kw)) {
      score += 80;
    } else if (name.contains(kw)) {
      score += 60;
    }
    if (pkg == kw) {
      score += 50;
    } else if (pkg.contains(kw)) {
      score += 40;
    }
    if (des.contains(kw)) {
      score += 20;
    }
    return score;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.search, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '搜索应用',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // 渠道多选
            SizedBox(
              width: double.infinity,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: widget.channels.map((channel) {
                    final type = channel.info.type;
                    final selected = _selectedCodes.contains(type.code);
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        avatar: Icon(
                          _channelIcon(type),
                          size: 16,
                          color: selected ? scheme.onSecondaryContainer : null,
                        ),
                        label: Text(channel.info.name),
                        selected: selected,
                        onSelected: (_) => _toggleChannel(type),
                        visualDensity: VisualDensity.compact,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            const Divider(height: 1),

            // 搜索输入框
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: TextField(
                controller: _searchController,
                focusNode: _focusNode,
                onChanged: _onKeywordChanged,
                onSubmitted: (value) {
                  final keyword = value.trim();
                  if (keyword.isNotEmpty) _doSearch(keyword);
                },
                decoration: InputDecoration(
                  hintText: '输入应用名称或包名搜索',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),

            // 搜索结果
            Flexible(
              child: _buildResultArea(context),
            ),
          ],
        ),
      ),
    );
  }

  /// 结果区域
  Widget _buildResultArea(BuildContext context) {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: AppLoading(size: AppLoadingSize.medium),
      );
    }

    if (!_searched) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: Text('输入关键词，搜索所选渠道的应用'),
        ),
      );
    }

    if (_results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('未找到相关应用')),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final (app, type) = _results[index];
        final scheme = Theme.of(context).colorScheme;
        return ListTile(
            leading: app.icon.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: app.icon,
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) =>
                          _defaultAppIcon(context),
                    ),
                  )
                : _defaultAppIcon(context),
            // 标题行：应用名 + 渠道标签（渠道名始终可见，不被截断）
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    app.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _channelName(type),
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: app.des.isNotEmpty
                ? Text(
                    app.des,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
            trailing: _buildSaveButton(type, app),
          );
        },
    );
  }

  /// 保存按钮：保存到渠道数据库（不直接入库首页）
  Widget _buildSaveButton(ChannelType type, AppSummary app) {
    final key = '${type.code}:${app.appId}';
    final saved = _savedKeys.contains(key);
    final saving = _savingKey == key;

    if (saved) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, size: 16, color: Colors.green),
            SizedBox(width: 4),
            Text('已添加', style: TextStyle(fontSize: 13)),
          ],
        ),
      );
    }

    return FilledButton.tonal(
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
      ),
      onPressed: saving ? null : () => _saveToChannel(type, app),
      child: saving
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('添加'),
    );
  }

  /// 保存到渠道（保存搜索结果，供后续入库）
  Future<void> _saveToChannel(ChannelType type, AppSummary app) async {
    final key = '${type.code}:${app.appId}';
    setState(() => _savingKey = key);
    final success = await widget.onSaveToChannel(type, app);
    if (!mounted) return;
    setState(() {
      _savingKey = null;
      if (success) {
        _savedKeys.add(key);
        Get.snackbar(
          '已添加到${_channelName(type)}',
          '${app.name} 已保存，可到渠道列表中选择入库',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      } else {
        Get.snackbar(
          '添加失败',
          '${app.name} 保存到${_channelName(type)}失败',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Get.theme.colorScheme.errorContainer,
          duration: const Duration(seconds: 3),
        );
      }
    });
  }

  /// 默认应用图标
  Widget _defaultAppIcon(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.android, color: Colors.grey),
    );
  }

  /// 渠道名称
  String _channelName(ChannelType type) {
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

  /// 渠道图标
  IconData _channelIcon(ChannelType type) {
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
      default:
        return Icons.apps;
    }
  }
}
