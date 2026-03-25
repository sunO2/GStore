import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:gstore/page/web/browser.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/design/app_components.dart';

import 'logic.dart';
import 'state.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/page/auth/state.dart';
import '../../logic.dart';

class ApplistPage extends StatefulWidget {
  const ApplistPage({super.key});

  @override
  State<StatefulWidget> createState() => AppListState();
}

class AppListState extends State<ApplistPage>
    with AutomaticKeepAliveClientMixin {
  @override
  Widget build(BuildContext context) {
    super.build(context);
    final logic = Get.put(ApplistLogic());
    final state = Get.find<ApplistLogic>().state;
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
                      logic.searchApps('');
                      logic.searchFocusNode.unfocus();
                    },
                  );
                }
                return const SizedBox.shrink();
              }),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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
            icon: const Icon(
              AliIcon.appUpdateCenter,
            ),
            onPressed: () => Get.toNamed(AppRoute.updateCenter),
          ),
          IconButton(
            tooltip: "下载中心",
            icon: const Icon(AliIcon.appDownloadCenter),
            onPressed: () => Get.toNamed(AppRoute.downloadCenter),
          ),
          Obx(() {
            var user = Get.find<UserManager>().userInfo.value;

            icon(UserInfo fuser) {
              if (fuser.avatarUrl?.isNotEmpty ?? false) {
                return Container(
                  width: Theme.of(context).appBarTheme.iconTheme?.size ?? AppTypography.iconXL,
                  height: Theme.of(context).appBarTheme.iconTheme?.size ?? AppTypography.iconXL,
                  decoration: BoxDecoration(
                      border: Border.all(width: 1.5),
                      borderRadius: AppRadius.allCircle),
                  child: ClipOval(
                    child: CachedNetworkImage(
                      width:
                          Theme.of(context).appBarTheme.iconTheme?.size ?? AppTypography.iconXL,
                      height:
                          Theme.of(context).appBarTheme.iconTheme?.size ?? AppTypography.iconXL,
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
                  // 登录成功，显示提示
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
        child: Obx(() => _buildBody(context, logic, state)),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ApplistLogic logic, ApplistState state) {
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

      // 还没有添加任何应用
      return Center(
        child: Padding(
          padding: AppSpacing.allXXL,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.apps_outlined,
                size: AppTypography.iconXXXL,
                color: AppColors.grey400,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                '还没有添加任何应用',
                style: AppTypography.titleMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '3种方式快速添加应用：',
                style: AppTypography.bodyMedium.copyWith(
                      color: AppColors.textSecondary,
                      fontWeight: AppTypography.weightMedium,
                    ),
              ),
              const SizedBox(height: AppSpacing.lg),
              _buildQuickAddOption(
                context,
                icon: Icons.search,
                title: '快速搜索',
                description: '点击上方搜索栏直接搜索',
                onTap: () => _showQuickSearchGuide(context),
              ),
              const SizedBox(height: AppSpacing.sm),
              _buildQuickAddOption(
                context,
                icon: Icons.explore,
                title: '浏览发现页',
                description: '切换到"发现"标签浏览应用',
                onTap: () {
                  final homeLogic = Get.find<HomeLogic>();
                  homeLogic.jumpToPage(1); // 切换到发现页
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              _buildQuickAddOption(
                context,
                icon: Icons.science_outlined,
                title: '我的频道',
                description: '管理已添加的应用频道',
                onTap: () {
                  final homeLogic = Get.find<HomeLogic>();
                  homeLogic.jumpToPage(2); // 切换到我的频道页
                },
              ),
            ],
          ),
        ),
      );
    }

    // 应用列表
    return RefreshIndicator(
      onRefresh: logic.loadAggregatedApps,
      child: CustomScrollView(
        slivers: [
          // Banner
          SliverToBoxAdapter(
            child: FutureBuilder(
                future: logic.getBanner(),
                builder: (contest, snap) {
                  var data = snap.data;
                  if (null == data) {
                    return const SizedBox();
                  }
                  var length = data.length;
                  return SizedBox(
                    height: 180,
                    child: PageView.builder(
                      controller: PageController(
                          viewportFraction: 0.8, initialPage: 5000),
                      itemCount: 10000,
                      itemBuilder: (context, item) {
                        var index = item % length;
                        return GestureDetector(
                          onTap: () {
                            // Banner 点击暂不处理，因为 banner 数据结构可能变化
                          },
                          child: Padding(
                            padding: AppSpacing.onlyHorizontalSM_verticalLG,
                            child: ClipRRect(
                              borderRadius: AppRadius.allLG,
                              child: CachedNetworkImage(
                                height: 180,
                                fit: BoxFit.fill,
                                imageUrl: data[index]["banner"],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                }),
          ),

          // 应用列表
          SliverPadding(
            padding: EdgeInsets.zero,
            sliver: SliverGrid.builder(
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: AppSpacing.sm,
                crossAxisSpacing: AppSpacing.sm,
                childAspectRatio: 0.75,
              ),
              itemBuilder: (context, index) {
                var app = state.filteredApps[index];
                return _buildAggregatedAppItem(
                  context,
                  app,
                  logic,
                );
              },
              itemCount: state.filteredApps.length,
            ),
          ),
        ],
      ),
    );
  }

  /// 聚合应用卡片
  Widget _buildAggregatedAppItem(
    BuildContext context,
    AggregatedAppInfo app,
    ApplistLogic logic,
  ) {
    final channelColor = AppColors.getChannelBrandColor(app.channel.name);
    final channelShortName = _getChannelShortName(app.channel);

    return GestureDetector(
      onTap: () => logic.appDetail(app),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: AppSpacing.onlyBottomMD,
            child: SizedBox(
              width: 64,
              height: 64,
              child: Stack(
                children: [
                  // 图标
                  Positioned.fill(
                    child: Hero(
                      tag: app.appInfo.icon ?? "",
                      child: ClipRRect(
                        borderRadius: AppRadius.allLG,
                        child: Container(
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: AppRadius.allLG,
                          ),
                          child: app.appInfo.icon != null
                              ? CachedNetworkImage(
                                  fit: BoxFit.fill,
                                  placeholder: (context, url) {
                                    return const Center(
                                      child: AppLoading(size: AppLoadingSize.small),
                                    );
                                  },
                                  errorWidget: (context, url, error) {
                                    return const Icon(Icons.error);
                                  },
                                  imageUrl: app.appInfo.icon!,
                                  width: 64,
                                  height: 64,
                                )
                              : const SizedBox(),
                        ),
                      ),
                    ),
                  ),
                  // 渠道标识 - 右下角
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: AppSpacing.horizontalXS_verticalXS,
                      decoration: BoxDecoration(
                        color: AppColors.withOpacity(channelColor, 0.9),
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(0),
                          topLeft: Radius.circular(AppSpacing.xs),
                          bottomLeft: Radius.circular(AppSpacing.xs),
                          bottomRight: Radius.circular(AppSpacing.lg),
                        ),
                      ),
                      child: Text(
                        channelShortName,
                        style: AppTypography.labelSmall.copyWith(
                          color: AppColors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Hero(
            tag: app.appInfo.name ?? "",
            child: Text(
              app.appInfo.name ?? "",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.labelMedium.copyWith(
                fontWeight: AppTypography.weightSemiBold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 获取渠道短名称
  String _getChannelShortName(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return 'DB';
      case ChannelType.github:
        return 'GH';
      case ChannelType.http:
        return 'API';
      case ChannelType.vivo:
        return 'vivo';
      case ChannelType.fdroid:
        return 'FD';
      default:
        return 'APP';
    }
  }

  /// 显示快速搜索引导
  void _showQuickSearchGuide(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.search, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: AppSpacing.sm),
            const Text('快速搜索应用'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '点击上方的"快速搜索"按钮，然后：',
              style: AppTypography.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            _buildGuideStep(context, '1', '选择要搜索的渠道'),
            _buildGuideStep(context, '2', '输入应用名称关键词'),
            _buildGuideStep(context, '3', '点击添加按钮添加应用'),
            const SizedBox(height: AppSpacing.md),
            Text(
              '💡 提示：也可以切换到"发现"页面浏览更多应用',
              style: AppTypography.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 构建引导步骤
  Widget _buildGuideStep(BuildContext context, String number, String text) {
    return Padding(
      padding: AppSpacing.onlyVerticalSM,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: AppSpacing.lg + AppSpacing.sm,
            height: AppSpacing.lg + AppSpacing.sm,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: AppTypography.labelMedium.copyWith(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontWeight: AppTypography.weightBold,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              style: AppTypography.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建快速添加选项
  Widget _buildQuickAddOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.allMD,
      child: AppCard(
        padding: AppSpacing.horizontalLG_verticalMD,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
        ),
        borderRadius: AppRadius.allMD,
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: AppSpacing.xl + AppSpacing.xxl,
              height: AppSpacing.xl + AppSpacing.xxl,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: AppRadius.allSM,
              ),
              child: Icon(
                icon,
                color: Theme.of(context).colorScheme.primary,
                size: AppTypography.iconLG,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTypography.titleSmall.copyWith(
                          fontWeight: AppTypography.weightSemiBold,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    description,
                    style: AppTypography.bodySmall.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: AppColors.grey400,
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
