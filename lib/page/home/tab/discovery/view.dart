import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfo.dart';

import 'logic.dart';
import 'state.dart';

class DiscoveryPage extends StatelessWidget {
  DiscoveryPage({super.key});

  final DiscoveryLogic logic = Get.put(DiscoveryLogic());
  final DiscoveryState state = Get.find<DiscoveryLogic>().state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        elevation: 0,
        actions: [
          // 添加应用按钮
          IconButton(
            tooltip: '添加应用',
            icon: const Icon(Icons.add),
            onPressed: () => logic.showAddAppSheet(context),
          ),
          // 显示模式切换
          Obx(() => PopupMenuButton<DisplayMode>(
                icon: Icon(_getDisplayModeIcon(state.displayMode.value)),
                onSelected: (mode) => logic.setDisplayMode(mode),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: DisplayMode.all,
                    child: Row(
                      children: [
                        Icon(Icons.apps, size: AppTypography.iconMD),
                        SizedBox(width: AppSpacing.sm),
                        Text('全部'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: DisplayMode.added,
                    child: Row(
                      children: [
                        Icon(Icons.check_circle, size: AppTypography.iconMD),
                        SizedBox(width: AppSpacing.sm),
                        Text('已添加'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: DisplayMode.notAdded,
                    child: Row(
                      children: [
                        Icon(Icons.add_circle_outline, size: AppTypography.iconMD),
                        SizedBox(width: AppSpacing.sm),
                        Text('未添加'),
                      ],
                    ),
                  ),
                ],
              )),
        ],
      ),
      body: Column(
        children: [
          // 搜索栏
          _buildSearchBar(context),

          // 渠道筛选
          _buildChannelFilter(context),

          // 统计信息
          _buildStatsBar(context),

          // 应用列表
          Expanded(
            child: _buildAppList(context),
          ),
        ],
      ),
    );
  }

  /// 搜索栏
  Widget _buildSearchBar(BuildContext context) {
    return Obx(() {
      return Container(
        padding: AppSpacing.allLG,
        child: TextField(
          decoration: InputDecoration(
            hintText: '输入应用名称搜索...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: state.searchKeyword.value.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      logic.setSearchKeyword('');
                    },
                  )
                : PopupMenuButton<ChannelType?>(
                    icon: const Icon(Icons.filter_list),
                    tooltip: '选择搜索渠道',
                    onSelected: (channel) {
                      // 选择特定渠道搜索
                      logic.selectChannel(channel);
                      // 执行搜索
                      if (state.searchKeyword.value.isNotEmpty) {
                        logic.performSearch();
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: null,
                        child: Row(
                          children: [
                            Icon(Icons.apps, size: AppTypography.iconLG),
                            SizedBox(width: AppSpacing.sm),
                            Text('全部渠道'),
                          ],
                        ),
                      ),
                      ...logic.channelList.map((info) {
                        return PopupMenuItem(
                          value: info.type,
                          child: Row(
                            children: [
                              Icon(logic.getChannelIcon(info.type), size: AppTypography.iconLG),
                              const SizedBox(width: AppSpacing.sm),
                              Text(info.name),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
            border: OutlineInputBorder(
              borderRadius: AppRadius.allMD,
            ),
            filled: true,
            fillColor: Theme.of(context).colorScheme.surface,
          ),
          onChanged: (value) {
            logic.setSearchKeyword(value);
            // 实时搜索（防抖）
            logic.debounceSearch();
          },
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => logic.performSearch(),
        ),
      );
    });
  }

  /// 渠道筛选
  Widget _buildChannelFilter(BuildContext context) {
    return Obx(() {
      final channels = state.channelApps.keys.toList();

      if (channels.isEmpty) {
        return const SizedBox.shrink();
      }

      return Container(
        height: AppSpacing.xl * 2.5,
        padding: AppSpacing.onlyHorizontalLG,
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
              label: _getChannelName(channel),
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

  /// 渠道筛选 Chip
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
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: FilterChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppTypography.iconSM),
            const SizedBox(width: AppSpacing.xs),
            Text(label),
            if (count != null) ...[
              const SizedBox(width: AppSpacing.xs),
              Text(
                '($count${addedCount != null ? '/$addedCount' : ''})',
                style: AppTypography.labelSmall.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
        selected: isSelected,
        onSelected: (_) => onTap(),
        selectedColor: Theme.of(context).colorScheme.primaryContainer,
        showCheckmark: false,
      ),
    );
  }

  /// 统计信息栏
  Widget _buildStatsBar(BuildContext context) {
    return Obx(() {
      final filteredApps = logic.getFilteredApps();
      final totalCount = filteredApps.values.fold(
          0, (sum, apps) => sum + apps.length);

      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
        child: Row(
          children: [
            Text(
              '共 $totalCount 个应用',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            Text(
              '已添加 ${logic.getAddedAppCount()} 个',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
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
              const Icon(Icons.error_outline, size: AppTypography.iconHuge, color: Colors.red),
              const SizedBox(height: AppSpacing.lg),
              Text(state.errorMessage.value),
              const SizedBox(height: AppSpacing.lg),
              ElevatedButton(
                onPressed: logic.loadData,
                child: const Text('重试'),
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
                size: AppTypography.iconHuge,
                color: Colors.grey,
              ),
              const SizedBox(height: AppSpacing.lg),
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
        padding: AppSpacing.allSM,
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
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 渠道标题
          Container(
            padding: AppSpacing.allMD,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(AppRadius.md),
                topRight: Radius.circular(AppRadius.md),
              ),
            ),
            child: Row(
              children: [
                Icon(logic.getChannelIcon(channel), size: AppTypography.sizeMD),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  _getChannelName(channel),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                Text(
                  '${apps.length} 个',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: AppSpacing.sm),
                // 批量操作菜单
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: AppTypography.sizeMD),
                  onSelected: (value) {
                    switch (value) {
                      case 'add_all':
                        logic.addAllFromChannel(channel);
                        break;
                      case 'clear':
                        logic.clearChannel(channel);
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'add_all',
                      child: Row(
                        children: [
                          const Icon(Icons.add_circle_outline, size: AppTypography.sizeMD),
                          const SizedBox(width: AppSpacing.sm),
                          Text('全部添加'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'clear',
                      child: Row(
                        children: [
                          const Icon(Icons.delete_sweep, size: AppTypography.sizeMD),
                          const SizedBox(width: AppSpacing.sm),
                          Text('清空已添加'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 应用列表
          ...apps.map((app) => _buildAppTile(context, channel, app)),
        ],
      ),
    );
  }

  /// 应用卡片
  Widget _buildAppTile(
    BuildContext context,
    ChannelType channel,
    AppInfo app,
  ) {
    final isAdded = logic.isAppAdded(channel, app.appId);

    return ListTile(
      leading: app.icon.isNotEmpty
          ? CircleAvatar(
              backgroundImage: NetworkImage(app.icon),
            )
          : CircleAvatar(
              child: Icon(Icons.app_settings_alt, size: AppTypography.iconLG),
            ),
      title: Text(app.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(app.appId, style: Theme.of(context).textTheme.bodySmall),
          if (app.des.isNotEmpty)
            Text(
              app.des,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
      trailing: IconButton(
        icon: Icon(
          isAdded ? Icons.check_circle : Icons.add_circle_outline,
          color: isAdded ? Colors.green : Colors.grey,
        ),
        onPressed: () => logic.toggleApp(channel, app),
      ),
      onTap: () => logic.toggleApp(channel, app),
    );
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

  /// 获取空状态消息
  String _getEmptyMessage() {
    if (state.searchKeyword.value.isNotEmpty) {
      return '没有找到匹配的应用';
    }

    switch (state.displayMode.value) {
      case DisplayMode.added:
        return '还没有添加任何应用';
      case DisplayMode.notAdded:
        return '所有应用都已添加';
      case DisplayMode.all:
      default:
        return '暂无可用的应用';
    }
  }

  /// 获取渠道名称
  String _getChannelName(ChannelType type) {
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
}
