import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/model/AppSummary.dart';

import 'logic.dart';
import 'state.dart';

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({super.key});

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

/// 保持页面状态（tab 切换不销毁：滚动位置/筛选状态保留）
class _DiscoveryPageState extends State<DiscoveryPage>
    with AutomaticKeepAliveClientMixin {
  final DiscoveryLogic logic = Get.put(DiscoveryLogic());
  final DiscoveryState state = Get.find<DiscoveryLogic>().state;

  final ScrollController _gridScrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 初始化 Grid 列数
    WidgetsBinding.instance.addPostFrameCallback((_) {
      logic.updateCrossAxisCount(context);
    });
  }

  @override
  void dispose() {
    _gridScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求
    return Scaffold(
      appBar: _buildAppBar(context),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧导航栏
              _buildSidebar(context),

              // 右侧内容区
              Expanded(
                child: _buildContentArea(context),
              ),
            ],
          );
        },
      ),
    );
  }

  /// AppBar
  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withOpacity(0.5),
                width: 1,
              ),
            ),
          ),
        ),
      ),
      title: const Text('发现'),
      actions: [
        // 添加应用按钮
        IconButton(
          tooltip: '添加应用',
          icon: const Icon(Icons.add),
          onPressed: () => logic.showAddAppSheet(context),
        ),

        // 多选模式按钮
        Obx(() {
          if (state.isMultiSelectMode.value) {
            // 取消多选
            return TextButton(
              onPressed: () => logic.toggleMultiSelectMode(),
              child: const Text('取消'),
            );
          } else {
            // 显示模式菜单
            return PopupMenuButton<DisplayMode>(
              icon: Icon(_getDisplayModeIcon(state.displayMode.value)),
              tooltip: '显示模式',
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
                      Icon(Icons.add_circle_outline,
                          size: AppTypography.iconMD),
                      SizedBox(width: AppSpacing.sm),
                      Text('未添加'),
                    ],
                  ),
                ),
              ],
            );
          }
        }),
      ],
    );
  }

  /// 左侧导航栏
  Widget _buildSidebar(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 80,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: theme.colorScheme.outlineVariant.withOpacity(0.5),
            width: 1,
          ),
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withOpacity(0.5),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          // 全部 Tab
          Obx(() => _buildSidebarItem(
                context: context,
                icon: Icons.apps,
                label: '全部',
                count: logic.getTotalAppCount(),
                isSelected: state.selectedChannel.value == null,
                onTap: () => logic.selectChannel(null),
              )),

          const Divider(height: 1),

          // 渠道列表 - 使用 code 属性进行比较
          Expanded(
            child: Obx(() {
              final selectedChannel = state.selectedChannel.value;
              final channels = logic.sortedChannelTypes;

              return ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: channels.length,
                itemBuilder: (context, index) {
                  final channel = channels[index];
                  // 使用 code 属性比较，确保正确识别
                  final isSelected = selectedChannel?.code == channel.code;
                  final count = state.channelApps[channel]?.length ?? 0;

                  return Column(
                    children: [
                      if (index > 0) const Divider(height: 1),
                      _buildSidebarItem(
                        context: context,
                        icon: logic.getChannelIcon(channel),
                        label: _getChannelShortName(channel),
                        count: count,
                        isSelected: isSelected,
                        onTap: () => logic.selectChannel(channel),
                      ),
                    ],
                  );
                },
              );
            }),
          ),
        ],
      ),
    );
  }

  /// 左侧导航项
  Widget _buildSidebarItem({
    required BuildContext context,
    required IconData icon,
    required String label,
    required int count,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      child: Container(
        height: 72,
        width: double.infinity,
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer.withOpacity(0.5)
              : Colors.transparent,
          border: isSelected
              ? Border(
                  left: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 3,
                  ),
                )
              : null,
        ),
        child: Padding(
          padding: AppSpacing.horizontalXS_verticalSM,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: AppTypography.iconLG,
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontSize: 10,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                '$count',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 右侧内容区
  Widget _buildContentArea(BuildContext context) {
    return Column(
      children: [
        // 搜索栏
        _buildSearchBar(context),

        // 多选模式工具栏
        Obx(() {
          if (state.isMultiSelectMode.value) {
            return _buildMultiSelectToolbar(context);
          }
          return const SizedBox.shrink();
        }),

        // Grid 列表
        Expanded(
          child: _buildAppGrid(context),
        ),
      ],
    );
  }

  /// 搜索栏
  Widget _buildSearchBar(BuildContext context) {
    final theme = Theme.of(context);

    return Obx(() {
      return Container(
        padding: AppSpacing.allLG,
        child: TextField(
          controller: logic.searchController,
          decoration: InputDecoration(
            hintText: '搜索应用...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: state.searchKeyword.value.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      logic.setSearchKeyword('');
                      logic.searchController.clear();
                    },
                  )
                : null,
            border: OutlineInputBorder(
              // 胶囊形搜索框（与 AI 输入栏/悬浮导航胶囊风格统一）
              borderRadius: BorderRadius.circular(AppRadius.circle),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.circle),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.circle),
              borderSide: BorderSide.none,
            ),
            filled: true,
            // 半透明填充（透出磨砂质感，随主题变化）
            fillColor: theme.colorScheme.surface.withValues(alpha: 0.65),
            contentPadding: AppSpacing.allMD,
          ),
          onChanged: (value) {
            logic.setSearchKeyword(value);
          },
          textInputAction: TextInputAction.search,
        ),
      );
    });
  }

  /// 多选模式工具栏
  Widget _buildMultiSelectToolbar(BuildContext context) {
    final theme = Theme.of(context);

    return Obx(() {
      return Container(
        padding: AppSpacing.horizontalLG_verticalSM,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '已选 ${state.selectedApps.length} 个',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(width: AppSpacing.sm),
            // 按钮区 Wrap 自动换行，避免窄屏溢出/需要滑动
            Expanded(
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  TextButton.icon(
                    onPressed: logic.selectAllInView,
                    icon: const Icon(Icons.select_all,
                        size: AppTypography.iconSM),
                    label: const Text('全选'),
                  ),
                  TextButton.icon(
                    onPressed: logic.deselectAll,
                    icon: const Icon(Icons.clear, size: AppTypography.iconSM),
                    label: const Text('清空'),
                  ),
                  FilledButton.icon(
                    onPressed: logic.batchAddSelected,
                    icon: const Icon(Icons.add_circle,
                        size: AppTypography.iconSM),
                    label: const Text('添加'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }

  /// 应用 Grid
  Widget _buildAppGrid(BuildContext context) {
    return Obx(() {
      if (state.isLoading.value) {
        return const Center(child: AppLoading(size: AppLoadingSize.medium));
      }

      if (state.errorMessage.value.isNotEmpty) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  size: AppTypography.iconHuge, color: Colors.red),
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

      final appsWithChannel = logic.getDisplayApps();

      if (appsWithChannel.isEmpty) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _getDisplayModeIcon(state.displayMode.value),
                size: AppTypography.iconHuge,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                _getEmptyMessage(),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        );
      }

      return GridView.builder(
        controller: _gridScrollController,
        // 底部避让悬浮导航胶囊（extendBody 后内容延伸至胶囊后方）
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          80 + MediaQuery.of(context).padding.bottom,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: state.crossAxisCount.value,
          childAspectRatio: 0.85,
          crossAxisSpacing: AppSpacing.sm,
          mainAxisSpacing: AppSpacing.sm,
        ),
        itemCount: appsWithChannel.length,
        itemBuilder: (context, index) {
          final (app, channel) = appsWithChannel[index];
          return _buildAppCard(context, app, channel);
        },
      );
    });
  }

  /// 应用卡片
  Widget _buildAppCard(
      BuildContext context, AppSummary app, ChannelType channel) {
    final theme = Theme.of(context);

    final isAdded = logic.isAppAdded(channel, app.appId);
    final appKey = '${channel.code}:${app.appId}';

    return Obx(() {
      final isSelected = state.selectedApps.contains(appKey);
      final isMultiSelect = state.isMultiSelectMode.value;

      return Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: AppRadius.allMD,
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : isAdded
                    ? theme.colorScheme.primary.withOpacity(0.5)
                    : theme.colorScheme.outlineVariant.withOpacity(0.5),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Stack(
          clipBehavior: Clip.antiAlias,
          children: [
            // 卡片主体
            Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              color: isAdded
                  ? theme.colorScheme.primaryContainer.withOpacity(0.3)
                  : theme.colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: AppRadius.allMD,
                side: BorderSide.none,
              ),
              child: InkWell(
                onTap: () {
                  if (isMultiSelect) {
                    logic.toggleAppSelection(channel.code, app.appId);
                  } else {
                    logic.toggleApp(channel, app);
                  }
                },
                onLongPress: () {
                  // 多选模式下长按切换选择，否则弹出操作菜单
                  if (isMultiSelect) {
                    logic.toggleAppSelection(channel.code, app.appId);
                  } else {
                    logic.showAppActions(context, channel, app);
                  }
                },
                borderRadius: AppRadius.allMD,
                child: SizedBox(
                  height: 130,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // 应用图标
                        AppIcon(
                          url: app.icon,
                          width: 42,
                          height: 42,
                          borderRadius: AppRadius.sm,
                        ),

                        const SizedBox(height: AppSpacing.xs),

                        // 应用名称
                        SizedBox(
                          width: double.infinity,
                          child: Text(
                            app.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: AppTypography.weightMedium,
                              color: isAdded
                                  ? theme.colorScheme.onPrimaryContainer
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // 多选 Checkbox - 叠加在左上角
            if (isMultiSelect)
              Positioned(
                left: 4,
                top: 4,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: AppRadius.allSM,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.15),
                        blurRadius: 3,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Transform.scale(
                    scale: 0.85,
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (_) {
                        logic.toggleAppSelection(channel.code, app.appId);
                      },
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ),

            // 斜角标签 - 在容器内，45度旋转，超出部分被裁剪
            if (!isMultiSelect && isAdded)
              Positioned(
                right: -18,
                top: 4,
                child: Transform.rotate(
                  angle: 0.785, // 45度
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          theme.colorScheme.primary,
                          theme.colorScheme.primary.withOpacity(0.85),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.25),
                          blurRadius: 3,
                          offset: const Offset(1, 1),
                        ),
                      ],
                    ),
                    child: Text(
                      '入库',
                      style: TextStyle(
                        color: theme.colorScheme.onPrimary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    });
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

  /// 获取渠道简称
  String _getChannelShortName(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return '本地';
      case ChannelType.github:
        return 'GitHub';
      case ChannelType.http:
        return 'HTTP';
      case ChannelType.vivo:
        return 'vivo';
      case ChannelType.fdroid:
        return 'FD';
      default:
        return type.code.substring(0, 3);
    }
  }

  /// 获取渠道颜色
  Color _getChannelColor(ChannelType type) {
    switch (type) {
      case ChannelType.github:
        return const Color(0xFF24292E);
      case ChannelType.fdroid:
        return const Color(0xFF1976D2);
      case ChannelType.vivo:
        return const Color(0xFF4155D0);
      case ChannelType.http:
        return const Color(0xFFFF9800);
      case ChannelType.localDb:
        return const Color(0xFF2196F3);
      default:
        return Colors.grey;
    }
  }
}
