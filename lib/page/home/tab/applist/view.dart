import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:gstore/page/web/browser.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/design/app_components.dart';

import 'logic.dart';
import 'state.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/page/auth/state.dart';
import 'widgets/app_card_widget.dart';
import 'widgets/empty_state_widget.dart';
import 'widgets/horizontal_app_row.dart';
import 'widgets/section_title_widget.dart';

class ApplistPage extends StatefulWidget {
  const ApplistPage({super.key});

  @override
  State<StatefulWidget> createState() => AppListState();
}

class AppListState extends State<ApplistPage>
    with AutomaticKeepAliveClientMixin {
  late ApplistLogic logic;
  late ApplistState state;

  @override
  void initState() {
    super.initState();
    logic = Get.put(ApplistLogic());
    state = logic.state;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: SizedBox(
          height: 40,
          child: TextField(
            controller: logic.searchController,
            focusNode: logic.searchFocusNode,
            decoration: InputDecoration(
              hintText: '搜索应用...',
              hintStyle: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.5),
                fontSize: 16,
              ),
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: Obx(() {
                if (state.searchKeyword.value.isNotEmpty) {
                  return IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      logic.searchController.clear();
                      logic.searchAppsImmediate('');
                      logic.searchFocusNode.unfocus();
                    },
                  );
                }
                return const SizedBox.shrink();
              }),
              border: OutlineInputBorder(
                // 胶囊形搜索框（高度 40 时全圆，与 AI 输入栏风格统一）
                borderRadius: BorderRadius.circular(AppRadius.circle),
                borderSide: BorderSide.none,
              ),
              filled: true,
              // 半透明填充（透出磨砂质感，随主题变化）
              fillColor:
                  Theme.of(context).colorScheme.surface.withValues(alpha: 0.65),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              isDense: true,
            ),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 16,
            ),
            onChanged: (value) => logic.searchApps(value),
          ),
        ),
        actions: [
          IconButton(
            tooltip: "应用更新",
            icon: Obx(() {
              final count = BadgeService.instance.countOf(BadgeKey.appUpdate);
              return AppBadge(
                count: count,
                child: ColoredAliIcon(
                  icon: AliIcon.appUpdateCenter,
                  // 与 AppBar 默认图标/用户头像(iconXL) 对齐，避免与其他 tab 不协调
                  size: AppTypography.iconXL,
                ),
              );
            }),
            onPressed: () => Get.toNamed(AppRoute.updateCenter),
          ),
          IconButton(
            tooltip: "下载中心",
            icon: ColoredAliIcon(
              icon: AliIcon.appDownloadCenter,
              // 与 AppBar 默认图标/用户头像(iconXL) 对齐
              size: AppTypography.iconXL,
            ),
            onPressed: () => Get.toNamed(AppRoute.downloadCenter),
          ),
          Obx(() {
            var user = Get.find<UserManager>().userInfo.value;

            icon(UserInfo fuser) {
              if (fuser.avatarUrl?.isNotEmpty ?? false) {
                return Container(
                  width: Theme.of(context).appBarTheme.iconTheme?.size ??
                      AppTypography.iconXL,
                  height: Theme.of(context).appBarTheme.iconTheme?.size ??
                      AppTypography.iconXL,
                  decoration: BoxDecoration(
                      border: Border.all(width: 1.5),
                      borderRadius: AppRadius.allCircle),
                  child: ClipOval(
                    child: CachedNetworkImage(
                      width: Theme.of(context).appBarTheme.iconTheme?.size ??
                          AppTypography.iconXL,
                      height: Theme.of(context).appBarTheme.iconTheme?.size ??
                          AppTypography.iconXL,
                      placeholder: (context, url) =>
                          const AppLoading(size: AppLoadingSize.small),
                      errorWidget: (context, url, error) => const Icon(
                        Icons.account_circle_outlined,
                      ),
                      imageUrl: fuser.avatarUrl ?? "",
                    ),
                  ),
                );
              } else {
                return const Icon(
                  Icons.account_circle_outlined,
                );
              }
            }

            onPressed() async {
              if (user.avatarUrl?.isEmpty ?? true) {
                final result = await Get.toNamed<AuthStatus>(AppRoute.auth);
                if (result == AuthStatus.success) {
                  if (mounted) {
                    Get.snackbar(
                      '登录成功',
                      '您可以访问更多功能了！',
                      icon: const Icon(
                        Icons.check_circle,
                        color: AppColors.success,
                      ),
                      duration: const Duration(seconds: 2),
                    );
                  }
                }
              } else {
                GStoreInAppBrowser inAppBrowser = GStoreInAppBrowser();
                final settings = ChromeSafariBrowserSettings(
                  shareState: CustomTabsShareState.SHARE_STATE_ON,
                  barCollapsingEnabled: true,
                );
                inAppBrowser.open(
                    url: WebUri(user.htmlUrl ?? ""), settings: settings);
              }
            }

            return IconButton(
              tooltip: user.name ?? "登陆",
              icon: icon(user),
              onPressed: onPressed,
            );
          }),
        ],
      ),
      body: GestureDetector(
        onTap: () => logic.searchFocusNode.unfocus(),
        behavior: HitTestBehavior.translucent,
        child: Obx(() => _buildBody(context)),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    // 加载状态
    if (state.isLoading.value) {
      return const LoadingState();
    }

    // 错误状态
    if (state.errorMessage.value.isNotEmpty) {
      return ErrorState(
        message: state.errorMessage.value,
        retryLabel: '重试',
        onRetryPressed: logic.loadAggregatedApps,
      );
    }

    // 空状态
    if (state.filteredApps.isEmpty) {
      // 搜索无结果
      if (state.searchKeyword.value.isNotEmpty) {
        return Center(
          child: Padding(
            padding: AppSpacing.allXXL,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.search_off,
                  size: AppTypography.iconXXXL,
                  color: AppColors.grey400,
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  '未找到相关应用',
                  style: AppTypography.titleMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '尝试使用其他关键词搜索',
                  style: AppTypography.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      // 还没有添加任何应用 - 使用独立的空状态组件
      return EmptyStateWidget(
        onImportSample: logic.importSampleApps,
      );
    }

    // 应用列表
    final isSearching = state.searchKeyword.value.isNotEmpty;
    return RefreshIndicator(
      onRefresh: logic.loadAggregatedApps,
      child: CustomScrollView(
        slivers: [
          // 分类筛选 Chips + 排序
          SliverToBoxAdapter(
            child: _CategoryFilterBar(logic: logic, state: state),
          ),

          // 搜索时只显示搜索结果，隐藏分区
          if (!isSearching) ...[
            // 可更新分区（横向行，数据来自 UpdateManager）
            if (logic.updatableApps.isNotEmpty)
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionTitle(
                      title: '可更新',
                      subtitle: '有可用新版本的应用',
                      trailing: IconButton(
                        tooltip: '去更新中心',
                        icon: ColoredAliIcon(
                          icon: AliIcon.appUpdateCenter,
                          size: AppTypography.iconSM,
                        ),
                        onPressed: () => Get.toNamed(AppRoute.updateCenter),
                      ),
                    ),
                    HorizontalAppRow(
                      apps: logic.updatableApps,
                      onTap: logic.appDetail,
                    ),
                  ],
                ),
              ),

            // 最近添加分区（横向行）
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionTitle(title: '最近添加'),
                  HorizontalAppRow(
                    apps: logic.recentApps(),
                    onTap: logic.appDetail,
                  ),
                ],
              ),
            ),
          ],

          // 全部应用（增强网格）
          SliverToBoxAdapter(
            child: SectionTitle(
              title: isSearching ? '搜索结果' : '全部应用',
              subtitle: '${state.filteredApps.length} 个应用 · 添加时间排序',
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final crossAxisExtent = constraints.crossAxisExtent;
                final crossAxisCount =
                    (crossAxisExtent / 90).floor().clamp(3, 6);

                return SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisSpacing: AppSpacing.sm,
                    crossAxisSpacing: AppSpacing.sm,
                    childAspectRatio: 0.75,
                  ),
                  itemBuilder: (context, index) {
                    final app = state.filteredApps[index];
                    return AppCardWidget(
                      app: app,
                      hasUpdate: state.updateStates[app.appInfo.appId] ?? false,
                      onTap: () => logic.appDetail(app),
                    );
                  },
                  itemCount: state.filteredApps.length,
                );
              },
            ),
          ),
          // 底部避让悬浮导航胶囊（extendBody 后内容延伸至胶囊后方）
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: 80 + MediaQuery.of(context).padding.bottom,
            ),
            sliver: const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

/// 分类筛选 + 排序栏
class _CategoryFilterBar extends StatelessWidget {
  final ApplistLogic logic;
  final ApplistState state;

  const _CategoryFilterBar({required this.logic, required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          // 分类 Chips（横向滚动）
          Expanded(
            child: Obx(() {
              final selected = state.selectedCategory.value;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _CategoryChip(
                      label: '全部',
                      selected: selected.isEmpty,
                      onTap: () => logic.setCategory(''),
                    ),
                    for (final cat in state.categories)
                      _CategoryChip(
                        label: cat,
                        selected: selected == cat,
                        onTap: () => logic.setCategory(cat),
                      ),
                  ],
                ),
              );
            }),
          ),
          const SizedBox(width: AppSpacing.xs),
          // 排序菜单
          PopupMenuButton<AppSortMode>(
            icon: const Icon(Icons.sort, size: 20),
            tooltip: '排序',
            onSelected: logic.setSortMode,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: AppSortMode.recent,
                child: Text('最近添加'),
              ),
              const PopupMenuItem(
                value: AppSortMode.name,
                child: Text('按名称'),
              ),
              const PopupMenuItem(
                value: AppSortMode.updateFirst,
                child: Text('可更新优先'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppAnimations.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: selected ? scheme.primary : scheme.surfaceContainerHigh,
            borderRadius: AppRadius.allCircle,
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                  fontWeight: selected
                      ? AppTypography.weightSemiBold
                      : AppTypography.weightMedium,
                ),
          ),
        ),
      ),
    );
  }
}
