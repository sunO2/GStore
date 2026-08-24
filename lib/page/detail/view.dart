import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:get/get.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/design/app_borders.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/page/detail/widgets.dart';
import 'logic.dart';
import 'state.dart';

class DetailPage extends StatelessWidget {
  const DetailPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(DetailLogic());
    final state = Get.find<DetailLogic>().state;

    return Scaffold(
      appBar: _buildAppBar(context, logic, state),
      body: Obx(() {
        // 有错误
        if (state.errorMessage.value.isNotEmpty) {
          return _buildErrorBody(context, logic, state);
        }

        // 直接显示内容（移除大块 loading，避免布局跳动）
        return _buildBody(context, logic, state);
      }),
      floatingActionButton: Obx(() {
        final data = state.currentDownload.value;
        if (data == null) return const SizedBox();

        final total = data.total;
        final count = data.count;
        // 防止除零错误
        final hasTotal = total > 0;
        final progress = hasTotal ? (count / total).clamp(0.0, 1.0) : null;
        final percent =
            hasTotal ? ((count / total) * 100).toInt().clamp(0, 100) : 0;
        final downloading = data.status == DownloadStatus.DOWNLOAD_LOADING;

        if (!downloading && data.status != DownloadStatus.DOWNLOAD_SUCCESS) {
          return const SizedBox();
        }

        return FloatingActionButton(
          onPressed: null,
          backgroundColor: downloading
              ? null
              : Theme.of(context).colorScheme.primaryContainer,
          child: Stack(
            alignment: AlignmentDirectional.center,
            children: [
              CircularProgressIndicator(
                value: progress,
              ),
              Text(
                hasTotal ? "$percent" : "...",
                style: Theme.of(context).textTheme.labelSmall,
              )
            ],
          ),
        );
      }),
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    DetailLogic logic,
    DetailState state,
  ) {
    return AppBar(
      title: Obx(() {
        final title = state.displayName;
        if (title.isEmpty) return const SizedBox();

        return Text(
          title,
          style: AppTypography.headlineSmall.copyWith(
            color: AppColors.textPrimary,
          ),
        );
      }),
      actions: [
        // 更多：分类标签编辑 + 动作宫格（完善应用信息 / 项目主页等）
        IconButton(
          onPressed: () => logic.showMoreActions(context),
          icon: const Icon(Icons.more_vert),
          tooltip: "更多",
        ),
      ],
    );
  }

  Widget _buildErrorBody(
    BuildContext context,
    DetailLogic logic,
    DetailState state,
  ) {
    return ErrorState(
      message: state.errorMessage.value,
      retryLabel: '重试',
      onRetryPressed: () => logic.loadDetail(),
    );
  }

  Widget _buildBody(
    BuildContext context,
    DetailLogic logic,
    DetailState state,
  ) {
    return SingleChildScrollView(
      padding: AppSpacing.allLG,
      child: Column(
        children: [
          // 头部基础信息
          _buildHeader(context, logic, state),

          const SizedBox(height: AppSpacing.sm),

          // 详情加载指示器（兜底）→ Sections：单树条件渲染（无 AnimatedSwitcher 双树）。
          // 仅当基础信息尚未注入且无任何区块 loading 时显示 spinner，
          // 区块级 skeleton（下载/README）已覆盖主要加载场景，避免双 loading 叠加；
          // sections 入场动画由各区块 _FadeSlideIn 提供（loading→sections 直接切换，
          // 消除 switcher 保留新旧两树导致的切换帧双倍布局）。
          Obx(() {
            final detail = state.detailInfo.value;
            final showSpinner = state.isLoadingDetail.value &&
                detail == null &&
                !state.downloadsLoading.value &&
                !state.readmeLoading.value &&
                !state.statisticsLoading.value;

            final Widget child;
            if (showSpinner) {
              child = const Padding(
                padding: AppSpacing.allLG,
                child: Center(child: AppLoading(size: AppLoadingSize.medium)),
              );
            } else if (detail == null) {
              child = const SizedBox.shrink();
            } else {
              child = Column(
                children: _buildSections(context, logic, state, detail),
              );
            }

            return child;
          }),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    DetailLogic logic,
    DetailState state,
  ) {
    return AppCard(
      padding: AppSpacing.allLG,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      border: Border(
        top: border(context),
        left: border(context),
        right: border(context),
      ),
      borderRadius: AppRadius.allLG,
      child: Obx(() {
        final icon = state.displayIcon;
        final name = state.displayName;
        final description = state.displayDescription;
        final version = state.displayVersion;
        final detailInfo = state.detailInfo.value;

        return Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 图标
                Hero(
                  tag: icon,
                  child: ClipRRect(
                    borderRadius: AppRadius.allMD,
                    child: icon.isNotEmpty
                        ? AppIcon(
                            url: icon,
                            width: AppSpacing.xxxl * 2,
                            height: AppSpacing.xxxl * 2,
                            borderRadius: 0,
                          )
                        : Container(
                            width: AppSpacing.xxxl * 2,
                            height: AppSpacing.xxxl * 2,
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            child: Icon(
                              Icons.apps,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                // 名称 + 版本 + 描述
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      // 版本信息（已安装显示当前版本 + 最新角标；未安装显示最新版本）
                      if ((version != null && version.isNotEmpty) ||
                          state.installInfo.value != null)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xs),
                          child: VersionBadge(
                            latestVersion: version,
                            installedVersion:
                                state.installInfo.value?.versionName,
                          ),
                        ),
                      if (description.isNotEmpty &&
                          !isDescriptionDuplicated(
                              detailInfo, description)) ...[
                        const SizedBox(height: AppSpacing.lg),
                        Html(
                          data: description,
                          style: {
                            'body': Style(
                              margin: Margins.zero,
                              padding: HtmlPaddings.zero,
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: FontSize(AppTypography.sizeMD),
                              lineHeight: const LineHeight(1.5),
                            ),
                            'p': Style(
                              margin: Margins.zero,
                              lineHeight: const LineHeight(1.5),
                            ),
                            'a': Style(
                              color: Theme.of(context).colorScheme.primary,
                              textDecoration: TextDecoration.underline,
                              fontWeight: AppTypography.weightMedium,
                            ),
                            'strong': Style(
                              fontWeight: AppTypography.weightSemiBold,
                            ),
                            'em': Style(
                              fontStyle: FontStyle.italic,
                            ),
                            'code': Style(
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer
                                  .withAlpha(AppColors.alphaLowest),
                              color: Theme.of(context).colorScheme.primary,
                              padding: HtmlPaddings.symmetric(
                                  horizontal: 4, vertical: 2),
                              fontFamily: 'monospace',
                              fontSize: FontSize(AppTypography.sizeSM - 1),
                            ),
                          },
                          shrinkWrap: true,
                          onLinkTap: (url, _, __) {
                            if (url != null) {
                              logic.openBrowser(url);
                            }
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      }),
    );
  }

  List<Widget> _buildSections(
    BuildContext context,
    DetailLogic logic,
    DetailState state,
    IDetailInfo detail,
  ) {
    final sections = <Widget>[];

    // 应用信息卡（包名/版本/开发者/渠道基础信息与统计展开区）始终显示，
    // 全空时内部自隐藏——不依赖渠道 statistics 声明（localdb 渠道 apiList 为空时无 statistics section）
    sections.add(AppInfoSection(info: detail));

    // 区块渲染顺序：固定为「基础区块（sections 中非下载/README，按到达顺序）→
    // downloads → readme」——下载永远在 README 前，加载中/加载后位置一致，永不跳动。
    // （README 304 命中近瞬时先完成 append 时，不再把下载挤到下方）
    // 下载/README 区块以独立 Rx（downloadsLoading/readmeLoading）兜底：
    // 加载中即使 sections 尚未声明也要渲染骨架，完成且空则不渲染——
    // 避免"加载完成后区块才凭空出现"的闪烁。List 而非 Set：基础区块显式过滤
    // 下载/README 后各区块单实例，顺序由固定拼装保证。
    final sectionTypes = <DetailSection>[
      ...detail.sections.where((s) =>
          s != DetailSection.downloads && s != DetailSection.readme),
      if (state.downloadsLoading.value || detail.downloads.isNotEmpty)
        DetailSection.downloads,
      if (state.readmeLoading.value ||
          (detail.readme?.isNotEmpty ?? false) ||
          (detail.screenshots?.isNotEmpty ?? false))
        DetailSection.readme,
    ];

    for (var sectionType in sectionTypes) {
      switch (sectionType) {
        case DetailSection.version:
          // 版本信息已移入应用信息卡，不再单独渲染
          break;
        case DetailSection.statistics:
        case DetailSection.rating:
          // 统计已并入 AppInfoSection 展开区，不再单独渲染
          break;
        case DetailSection.screenshots:
          // 截图已统一内嵌详细介绍卡（ReadmeSection 复用 _ScreenshotGallery），
          // 不再单独渲染独立截图卡片
          break;
        case DetailSection.readme:
          // 加载中 → 轻量占位；完成且非空 → 正文；完成空 → 不进入此分支。
          // 区块首次出现时做一次渐进入场（loading→内容切换保持原逻辑，动画仅作用于首现）
          sections.add(
            _FadeSlideIn(
              child: state.readmeLoading.value
                  ? ReadmeSection(info: detail, loading: true)
                  : ReadmeSection(
                      info: detail,
                      onLinkTap: (url) => logic.openBrowser(url),
                    ),
            ),
          );
          break;
        case DetailSection.downloads:
          // 加载中 → 骨架占位；完成非空 → 列表；完成空 → 不进入此分支
          sections.add(
            _FadeSlideIn(
              child: state.downloadsLoading.value
                  ? DownloadsSection(info: detail, loading: true)
                  : DownloadsSection(
                      info: detail,
                      onDownloadTap: (download) =>
                          logic.startDownload(download),
                      onLongPress: (download) {
                        AppDialogs.showDialog(
                          title: '下载二维码',
                          content: buildQrDialogContent(detail, download),
                          confirmText: '关闭',
                          cancelText: null,
                        );
                      },
                    ),
            ),
          );
          break;
        case DetailSection.developer:
          sections.add(DeveloperSection(info: detail));
          break;
        case DetailSection.changelog:
          sections.add(ChangelogSection(info: detail));
          break;
        case DetailSection.permissions:
          sections.add(PermissionsSection(info: detail));
          break;
      }
    }

    return sections;
  }
}

BorderSide border(BuildContext context) => AppBorders.sideOf(
      context,
      color: Theme.of(context)
          .colorScheme
          .primary
          .withAlpha(AppColors.alphaMedium),
    );

/// 区块渐进出现：首次挂载时淡入 + 从下方 10% 高度滑入一次
/// 自持 AnimationController（initState 启动一次 forward），key/位置稳定时
/// 不重复播放；区块内部 loading→内容切换不触发重放。
class _FadeSlideIn extends StatefulWidget {
  final Widget child;

  const _FadeSlideIn({required this.child});

  @override
  State<_FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<_FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppAnimation.slow,
    )..forward();
    _animation =
        CurvedAnimation(parent: _controller, curve: AppAnimation.curve);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.1),
          end: Offset.zero,
        ).animate(_animation),
        child: widget.child,
      ),
    );
  }
}
