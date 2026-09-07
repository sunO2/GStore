import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/page/web/browser.dart';
import 'package:gstore/core/design/app_borders.dart';
import 'package:gstore/page/home/logic.dart';

import 'logic.dart';
import 'state.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/page/auth/state.dart';
import 'widgets/app_card_widget.dart';
import 'widgets/empty_state_widget.dart';
import 'widgets/horizontal_app_row.dart';
import 'widgets/section_title_widget.dart';

class ApplistPage extends ConsumerStatefulWidget {
  const ApplistPage({super.key});

  @override
  ConsumerState<ApplistPage> createState() => AppListState();
}

class AppListState extends ConsumerState<ApplistPage>
    with AutomaticKeepAliveClientMixin {
  /// 页面控制器（Riverpod；build 中取，保活 tab 不销毁）
  late ApplistNotifier logic;

  @override
  bool get wantKeepAlive => true;

  /// 列表滚动控制器（ApplistNotifier 持有；initState 取引用，dispose 时 ref 不可用）
  late final ScrollController _scroll;

  /// 距底部多少像素内触发加载更多
  static const double _loadMoreThreshold = 400;

  @override
  void initState() {
    super.initState();
    // 触发 Notifier 建立（首帧初始化）
    ref.read(applistProvider);
    _scroll = ref.read(applistProvider.notifier).scrollController;
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - _loadMoreThreshold) {
      logic.loadMoreApps();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    logic = ref.read(applistProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Container(
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.circle),
          ),
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
              suffixIcon: const _SearchClearSuffix(),
              border: OutlineInputBorder(
                // 胶囊形搜索框（48 高 + 全圆）
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
              disabledBorder: OutlineInputBorder(
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
            icon: const _UpdateBadgeIcon(),
            onPressed: () => context.push(AppRoute.updateCenter),
          ),
          IconButton(
            tooltip: "下载中心",
            icon: const ColoredAliIcon(
              icon: AliIcon.appDownloadCenter,
              // 与 AppBar 默认图标/用户头像(iconXL) 对齐
              size: AppTypography.iconXL,
            ),
            onPressed: () => context.push(AppRoute.downloadCenter),
          ),
          const _UserActionButton(),
        ],
      ),
      body: GestureDetector(
        onTap: () => logic.searchFocusNode.unfocus(),
        behavior: HitTestBehavior.translucent,
        child: const _ApplistBody(),
      ),
    );
  }
}

/// 搜索框清空按钮（搜索词非空时显示）
class _SearchClearSuffix extends ConsumerWidget {
  const _SearchClearSuffix();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(applistProvider.notifier);
    final hasKeyword = ref.watch(
      applistProvider.select((s) => s.searchKeyword.isNotEmpty),
    );
    if (!hasKeyword) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.clear, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onPressed: () {
        notifier.searchController.clear();
        notifier.searchAppsImmediate('');
        notifier.searchFocusNode.unfocus();
      },
    );
  }
}

/// 应用更新红点角标
class _UpdateBadgeIcon extends ConsumerWidget {
  const _UpdateBadgeIcon();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(applistProvider.select((s) => s.appUpdateBadge));
    return AppBadge(
      count: count,
      child: const ColoredAliIcon(
        icon: AliIcon.appUpdateCenter,
        // 与 AppBar 默认图标/用户头像(iconXL) 对齐，避免与其他 tab 不协调
        size: AppTypography.iconXL,
      ),
    );
  }
}

/// 用户头像/登录按钮（读 applist state 镜像的用户信息）
class _UserActionButton extends ConsumerWidget {
  const _UserActionButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(applistProvider.select((s) => s.user));

    Widget icon() {
      if (user.avatarUrl?.isNotEmpty ?? false) {
        return Container(
          width: Theme.of(context).appBarTheme.iconTheme?.size ??
              AppTypography.iconXL,
          height: Theme.of(context).appBarTheme.iconTheme?.size ??
              AppTypography.iconXL,
          decoration: BoxDecoration(
              border: AppBorders.all(
                context,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
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
              imageUrl: user.avatarUrl ?? "",
            ),
          ),
        );
      }
      return const Icon(
        Icons.account_circle_outlined,
      );
    }

    Future<void> onPressed() async {
      if (user.avatarUrl?.isEmpty ?? true) {
        final result = await context.push<AuthStatus>(AppRoute.auth);
        if (result == AuthStatus.success && context.mounted) {
          AppDialogs.showSuccess('您可以访问更多功能了！');
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
      icon: icon(),
      onPressed: onPressed,
    );
  }
}

/// 首页应用列表主体（加载/错误/空态/列表 + 分页）
class _ApplistBody extends ConsumerWidget {
  const _ApplistBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(applistProvider);
    final logic = ref.read(applistProvider.notifier);
    return _buildBody(context, ref, state, logic);
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    ApplistState state,
    ApplistNotifier logic,
  ) {
    // 加载状态
    if (state.isLoading) {
      return const LoadingState();
    }

    // 错误状态
    if (state.errorMessage.isNotEmpty) {
      return ErrorState(
        message: state.errorMessage,
        retryLabel: '重试',
        onRetryPressed: logic.loadAggregatedApps,
      );
    }

    // 空状态
    if (state.filteredApps.isEmpty) {
      // 搜索无结果
      if (state.searchKeyword.isNotEmpty) {
        return Center(
          child: Padding(
            padding: AppSpacing.allXXL,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
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
        onImportSample: () {
          ref.read(homeProvider.notifier).jumpToPage(1); // 切换到发现页
          AppDialogs.showSuccess('请在"发现"页面浏览并添加您感兴趣的应用');
        },
      );
    }

    // 应用列表
    final isSearching = state.searchKeyword.isNotEmpty;
    return RefreshIndicator(
      onRefresh: logic.loadAggregatedApps,
      child: CustomScrollView(
        controller: ref.read(applistProvider.notifier).scrollController,
        slivers: [
          // 分类筛选 Chips + 排序
          SliverToBoxAdapter(
            child: _CategoryFilterBar(state: state, logic: logic),
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
                        icon: const ColoredAliIcon(
                          icon: AliIcon.appUpdateCenter,
                          size: AppTypography.iconSM,
                        ),
                        onPressed: () => context.push(AppRoute.updateCenter),
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
              subtitle: logic.hasMore
                  ? '已加载 ${state.filteredApps.length}/${state.totalCount} 个应用 · 添加时间排序'
                  : '${state.filteredApps.length} 个应用 · 添加时间排序',
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
                      hasUpdate:
                          state.updateStates[app.appInfo.appId] ?? false,
                      onTap: () => logic.appDetail(app),
                    );
                  },
                  itemCount: state.filteredApps.length,
                );
              },
            ),
          ),
          // 底部加载更多 / 已全部加载 指示
          SliverToBoxAdapter(
            child: _buildLoadMoreFooter(context, state, logic),
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

  /// 底部加载状态组件（滚动分页时显示 loading，全部加载完成时显示提示）
  Widget _buildLoadMoreFooter(
    BuildContext context,
    ApplistState state,
    ApplistNotifier logic,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // 首屏/错误/搜索无结果时不显示"加载更多"脚注（避免空态下出现多余 UI）
    if (state.isLoading ||
        state.errorMessage.isNotEmpty ||
        state.filteredApps.isEmpty) {
      return const SizedBox.shrink();
    }

    // 正在加载更多：显示小型 loading
    if (state.isLoadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const AppLoading(size: AppLoadingSize.small),
            const SizedBox(width: AppSpacing.sm),
            Text(
              '加载更多...',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }

    // 已全部加载：显示完成提示（仅当列表超过一屏数据时）
    if (!logic.hasMore && state.totalCount > 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Center(
          child: Text(
            '已全部加载 · 共 ${state.totalCount} 个应用',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}

/// 分类筛选 + 排序栏
class _CategoryFilterBar extends StatelessWidget {
  final ApplistState state;
  final ApplistNotifier logic;

  const _CategoryFilterBar({required this.state, required this.logic});

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
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _CategoryChip(
                    label: '全部',
                    selected: state.selectedCategory.isEmpty,
                    onTap: () => logic.setCategory(''),
                  ),
                  for (final cat in state.categories)
                    _CategoryChip(
                      label: cat,
                      selected: state.selectedCategory == cat,
                      onTap: () => logic.setCategory(cat),
                    ),
                ],
              ),
            ),
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
