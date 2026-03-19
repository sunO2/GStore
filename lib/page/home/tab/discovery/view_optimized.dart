/// 优化后的发现页面
/// 简化搜索交互，提供更直观的用户体验
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/db/apps/AppInfo.dart';

import '../logic.dart';
import '../state.dart';

class DiscoveryPageOptimized extends StatelessWidget {
  DiscoveryPageOptimized({super.key});

  final DiscoveryLogic logic = Get.put(DiscoveryLogic());
  final DiscoveryState state = Get.find<DiscoveryLogic>().state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        elevation: 0,
        actions: [
          // 显示模式切换 - 简化为图标按钮
          Obx(() => IconButton(
                icon: Icon(_getDisplayModeIcon(state.displayMode.value)),
                tooltip: _getDisplayModeTooltip(state.displayMode.value),
                onPressed: () => logic.toggleDisplayMode(),
              )),
          // 批量操作
          IconButton(
            icon: const Icon(Icons.done_all),
            tooltip: '批量操作',
            onPressed: () => logic.showBatchActions(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索栏 - 改为直接可输入
          _buildSearchBar(context),

          // 渠道筛选 - 优化为垂直列表
          _buildChannelFilter(context),

          // 统计信息 - 简化显示
          _buildStatsBar(context),

          // 应用列表
          Expanded(
            child: _buildAppList(context),
          ),
        ],
      ),
    );
  }

  /// 搜索栏 - 优化为可直接输入
  Widget _buildSearchBar(BuildContext context) {
    return Obx(() {
      return Container(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: logic.searchController,
          decoration: InputDecoration(
            hintText: '输入应用名称搜索...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: state.searchKeyword.value.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      logic.searchController.clear();
                      logic.setSearchKeyword('');
                    },
                  )
                : PopupMenuButton<ChannelType?>(
                    icon: const Icon(Icons.filter_list),
                    tooltip: '选择搜索渠道',
                    onSelected: (channel) {
                      logic.selectSearchChannel(channel);
                      // 自动触发搜索
                      if (logic.searchController.text.isNotEmpty) {
                        logic.performSearch();
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: null,
                        child: Row(
                          children: [
                            Icon(Icons.apps, size: 18),
                            SizedBox(width: 8),
                            Text('全部渠道'),
                          ],
                        ),
                      ),
                      ...ChannelType.values.where((c) => c != ChannelType.unknown).map((channel) {
                        return PopupMenuItem(
                          value: channel,
                          child: Row(
                            children: [
                              Icon(logic.getChannelIcon(channel), size: 18),
                              const SizedBox(width: 8),
                              Text(logic.getChannelName(channel)),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            filled: true,
            fillColor: Theme.of(context).colorScheme.surface,
          ),
          textInputAction: TextInputAction.search,
          onChanged: (value) {
            logic.setSearchKeyword(value);
            // 实时搜索（带防抖）
            logic.debounceSearch();
          },
          onSubmitted: (_) => logic.performSearch(),
        ),
      );
    });
  }

  /// 渠道筛选 - 优化为垂直列表，更易点击
  Widget _buildChannelFilter(BuildContext context) {
    return Obx(() {
      final channels = state.channelApps.keys.toList();

      if (channels.isEmpty) {
        return const SizedBox.shrink();
      }

      return Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: channels.length + 1, // +1 for "全部"
          itemBuilder: (context, index) {
            // 全部选项
            if (index == 0) {
              final isSelected = state.selectedChannel.value == null;
              return _buildChannelChip(
                context: context,
                label: '全部',
                icon: Icons.apps,
                isSelected: isSelected,
                count: logic.getTotalAppCount(),
                onTap: () => logic.selectChannel(null),
              );
            }

            final channel = channels[index - 1];
            final isSelected = state.selectedChannel.value == channel;
            final apps = state.channelApps[channel] ?? [];
            final addedCount = state.addedAppsIndex[channel.code]?.length ?? 0;

            return _buildChannelChip(
              context: context,
              label: logic.getChannelName(channel),
              icon: logic.getChannelIcon(channel),
              isSelected: isSelected,
              count: apps.length,
              addedCount: addedCount,
              onTap: () => logic.selectChannel(channel),
            );
          },
        ),
      );
    });
  }

  /// 渠道筛选 Chip - 优化样式
  Widget _buildChannelChip({
    required BuildContext context,
    required String label,
    required IconData icon,
    required bool isSelected,
    int? count,
    int? addedCount,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade300,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: isSelected ? Theme.of(context).colorScheme.primary : null),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Theme.of(context).colorScheme.primary : null,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 6),
                Text(
                  '($count${addedCount != null ? '/$addedCount' : ''})',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 统计信息栏 - 简化显示
  Widget _buildStatsBar(BuildContext context) {
    return Obx(() {
      final filteredApps = logic.getFilteredApps();
      final totalCount = filteredApps.values.fold(
          0, (sum, apps) => sum + apps.length);

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
          border: Border(
            bottom: BorderSide(color: Colors.grey.shade300),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.apps,
              size: 16,
              color: Colors.grey[600],
            ),
            const SizedBox(width: 6),
            Text(
              '共 $totalCount 个应用',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(width: 16),
            Icon(
              Icons.check_circle,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              '已添加 ${logic.getAddedAppCount()} 个',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ],
        ),
      );
    });
  }

  /// 应用列表
  Widget _buildAppList(BuildContext context) {
    return Obx(() {
      if (state.isLoading.value) {
        return const Center(child: CircularProgressIndicator());
      }

      if (state.errorMessage.value.isNotEmpty) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(state.errorMessage.value),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: logic.loadData,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        );
      }

      final filteredApps = logic.getFilteredApps();

      if (filteredApps.isEmpty) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _getDisplayModeIcon(state.displayMode.value),
                size: 48,
                color: Colors.grey,
              ),
              const SizedBox(height: 16),
              Text(
                _getEmptyMessage(),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey,
                    ),
              ),
            ],
          ),
        );
      }

      return ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: filteredApps.length,
        itemBuilder: (context, index) {
          final channel = filteredApps.keys.elementAt(index);
          final apps = filteredApps[channel]!;

          return _buildChannelSection(context, channel, apps);
        },
      );
    });
  }

  /// 渠道分组区块
  Widget _buildChannelSection(
    BuildContext context,
    ChannelType channel,
    List<AppInfo> apps,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 渠道标题
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                logic.getChannelIcon(channel),
                size: 18,
                color: _getChannelColor(channel),
              ),
              const SizedBox(width: 8),
              Text(
                logic.getChannelName(channel),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: _getChannelColor(channel),
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _getChannelColor(channel).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${apps.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: _getChannelColor(channel),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),

        // 应用卡片列表
        ...apps.map((app) => _buildAppCard(context, app)),
      ],
    );
  }

  /// 应用卡片
  Widget _buildAppCard(BuildContext context, AppInfo app) {
    final isAdded = state.addedAppsIndex
            .containsValue(app.appId);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundImage: NetworkImage(app.icon),
          onBackgroundImageError: (exception, stackTrace) {},
          child: app.icon.isEmpty ? const Icon(Icons.apps) : null,
        ),
        title: Text(app.name),
        subtitle: Text(
          app.des ?? '暂无描述',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: IconButton(
            key: ValueKey(isAdded),
            icon: Icon(
              isAdded ? Icons.check_circle : Icons.add_circle,
              color: isAdded ? Colors.green : Theme.of(context).colorScheme.primary,
            ),
            onPressed: () => logic.toggleApp(app),
            tooltip: isAdded ? '移除' : '添加',
          ),
        ),
        onTap: () => logic.toggleApp(app),
      ),
    );
  }

  /// 获取渠道颜色
  Color _getChannelColor(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return Colors.blue;
      case ChannelType.github:
        return Colors.purple;
      case ChannelType.http:
        return Colors.orange;
      case ChannelType.vivo:
        return const Color(0xFF4155D0);
      case ChannelType.fdroid:
        return const Color(0xFF1976D2);
      default:
        return Colors.grey;
    }
  }

  /// 获取显示模式图标
  IconData _getDisplayModeIcon(DisplayMode mode) {
    switch (mode) {
      case DisplayMode.all:
        return Icons.apps;
      case DisplayMode.added:
        return Icons.check_circle;
      case DisplayMode.notAdded:
        return Icons.add_circle_outline;
    }
  }

  /// 获取显示模式提示
  String _getDisplayModeTooltip(DisplayMode mode) {
    switch (mode) {
      case DisplayMode.all:
        return '显示全部';
      case DisplayMode.added:
        return '只显示已添加';
      case DisplayMode.notAdded:
        return '只显示未添加';
    }
  }

  /// 获取空状态消息
  String _getEmptyMessage() {
    switch (state.displayMode.value) {
      case DisplayMode.all:
        return '没有找到应用';
      case DisplayMode.added:
        return '还没有添加任何应用';
      case DisplayMode.notAdded:
        return '所有应用都已添加';
    }
  }
}
