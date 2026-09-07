import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/app_borders.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/model/AppSummary.dart';

import 'logic.dart';
import 'state.dart';

class DiscoveryPage extends ConsumerStatefulWidget {
  const DiscoveryPage({super.key});

  @override
  ConsumerState<DiscoveryPage> createState() => _DiscoveryPageState();
}

/// 保持页面状态（tab 切换不销毁：滚动位置/筛选状态保留）
class _DiscoveryPageState extends ConsumerState<DiscoveryPage>
    with AutomaticKeepAliveClientMixin {
  late DiscoveryNotifier logic;

  final ScrollController _gridScrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 触发 Notifier 建立（首帧初始化 loadData）
    ref.read(discoveryProvider);
    // 初始化 Grid 列数
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(discoveryProvider.notifier).updateCrossAxisCount(context);
      }
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
    logic = ref.read(discoveryProvider.notifier);
    final state = ref.watch(discoveryProvider);
    return Scaffold(
      appBar: _buildAppBar(context, state),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧导航栏
              _buildSidebar(context, state),

              // 右侧内容区
              Expanded(
                child: _buildContentArea(context, state),
              ),
            ],
          );
        },
      ),
    );
  }

  /// AppBar
  PreferredSizeWidget _buildAppBar(BuildContext context, DiscoveryState state) {
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          decoration: BoxDecoration(
            border: Border(
              bottom: AppBorders.sideOf(
                context,
                color: Theme.of(context).colorScheme.outlineVariant,
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
        if (state.isMultiSelectMode)
          TextButton(
            onPressed: () => logic.toggleMultiSelectMode(),
            child: const Text('取消'),
          )
        else
          PopupMenuButton<DisplayMode>(
            icon: Icon(_getDisplayModeIcon(state.displayMode)),
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
          ),
      ],
    );
  }

  /// 左侧导航栏
  Widget _buildSidebar(BuildContext context, DiscoveryState state) {
    final theme = Theme.of(context);

    return Container(
      width: 80,
      decoration: BoxDecoration(
        border: Border(
          right: AppBorders.sideOf(
            context,
            color: theme.colorScheme.outlineVariant,
          ),
          bottom: AppBorders.sideOf(
            context,
            color: theme.colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Column(
        children: [
          // 全部 Tab
          _buildSidebarItem(
            context: context,
            icon: Icons.apps,
            label: '全部',
            count: logic.getTotalAppCount(),
            isSelected: state.selectedChannel == null,
            onTap: () => logic.selectChannel(null),
          ),

          const Divider(height: 1),

          // 渠道列表 - 使用 code 字符串进行比较
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: logic.sortedChannelCodes.length,
              itemBuilder: (context, index) {
                final code = logic.sortedChannelCodes[index];
                // 使用 code 字符串比较，确保正确识别
                final isSelected = state.selectedChannel == code;
                final count = state.channelApps[code]?.length ?? 0;

                return Column(
                  children: [
                    if (index > 0) const Divider(height: 1),
                    _buildSidebarItem(
                      context: context,
                      icon: logic.getChannelIcon(code),
                      label: _getChannelShortName(code),
                      count: count,
                      isSelected: isSelected,
                      onTap: () => logic.selectChannel(code),
                    ),
                  ],
                );
              },
            ),
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
                  left: AppBorders.sideOf(
                    context,
                    color: theme.colorScheme.primary,
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
  Widget _buildContentArea(BuildContext context, DiscoveryState state) {
    return Column(
      children: [
        // 搜索栏
        _buildSearchBar(context, state),

        // 多选模式工具栏
        if (state.isMultiSelectMode) _buildMultiSelectToolbar(context, state),

        // Grid 列表
        Expanded(
          child: _buildAppGrid(context, state),
        ),
      ],
    );
  }

  /// 搜索栏
  Widget _buildSearchBar(BuildContext context, DiscoveryState state) {
    final theme = Theme.of(context);

    return Container(
      padding: AppSpacing.allLG,
      child: TextField(
        controller: logic.searchController,
        decoration: InputDecoration(
          hintText: '搜索应用...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: state.searchKeyword.isNotEmpty
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
  }

  /// 多选模式工具栏
  Widget _buildMultiSelectToolbar(BuildContext context, DiscoveryState state) {
    final theme = Theme.of(context);

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
  }

  /// 应用 Grid
  Widget _buildAppGrid(BuildContext context, DiscoveryState state) {
    debugPrint('DiscoveryView: _buildAppGrid rebuilding - selectedChannel=${state.selectedChannel}');
    if (state.isLoading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }

    if (state.errorMessage.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline,
                size: AppTypography.iconHuge, color: Colors.red),
            const SizedBox(height: AppSpacing.lg),
            Text(state.errorMessage),
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
              _getDisplayModeIcon(state.displayMode),
              size: AppTypography.iconHuge,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              _getEmptyMessage(state),
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
        crossAxisCount: state.crossAxisCount,
        childAspectRatio: 0.85,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
      ),
      itemCount: appsWithChannel.length,
      itemBuilder: (context, index) {
        final (app, code) = appsWithChannel[index];
        return _buildAppCard(context, state, app, code);
      },
    );
  }

  /// 应用卡片
  Widget _buildAppCard(
      BuildContext context, DiscoveryState state, AppSummary app, String code) {
    final theme = Theme.of(context);

    final isAdded = logic.isAppAdded(code, app.appId);
    final appKey = '$code:${app.appId}';
    final isSelected = state.selectedApps.contains(appKey);
    final isMultiSelect = state.isMultiSelectMode;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: AppRadius.allMD,
        border: Border.all(
          color: isSelected
              ? theme.colorScheme.primary
              : isAdded
                  ? theme.colorScheme.primary.withOpacity(0.5)
                  : theme.colorScheme.outlineVariant,
          width: isSelected
              ? AppBorders.sideOf(context).width * 2
              : AppBorders.sideOf(context).width,
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
                  logic.toggleAppSelection(code, app.appId);
                } else {
                  logic.toggleApp(context, code, app);
                }
              },
              onLongPress: () {
                // 多选模式下长按切换选择，否则弹出操作菜单
                if (isMultiSelect) {
                  logic.toggleAppSelection(code, app.appId);
                } else {
                  logic.showAppActions(context, code, app);
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
                      logic.toggleAppSelection(code, app.appId);
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
  String _getEmptyMessage(DiscoveryState state) {
    if (state.searchKeyword.isNotEmpty) {
      return '没有找到匹配的应用';
    }

    switch (state.displayMode) {
      case DisplayMode.added:
        return '还没有添加任何应用';
      case DisplayMode.notAdded:
        return '所有应用都已添加';
      case DisplayMode.all:
        return '暂无可用的应用';
    }
  }

  /// 获取渠道简称
  String _getChannelShortName(String code) {
    switch (ChannelType.fromCode(code)) {
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
      case ChannelType.custom:
        return '自定义';
      case null:
        // 脚本渠道：显示其名称（截断 4 字），缺失回退 code
        final name = ChannelManager.instance.getChannelByKey(code)?.info.name;
        if (name != null && name.isNotEmpty) {
          return name.length <= 4 ? name : name.substring(0, 4);
        }
        return code;
    }
  }
}
