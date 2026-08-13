import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/page/detail/widgets.dart';
import 'logic.dart';
import 'state.dart';
import 'package:installed_apps/app_info.dart' as sysAppInfo;

class DetailPage extends StatelessWidget {
  const DetailPage({super.key});

  Widget _flightShuttleBuilder(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    return DefaultTextStyle(
      style: DefaultTextStyle.of(toHeroContext).style,
      child: toHeroContext.widget,
    );
  }

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

        return Hero(
          flightShuttleBuilder: _flightShuttleBuilder,
          tag: state.displayIcon,
          child: Text(
            title,
            style: AppTypography.headlineSmall.copyWith(
              color: AppColors.textPrimary,
            ),
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

          // 详情加载指示器
          Obx(() {
            if (state.isLoadingDetail.value) {
              return const Padding(
                padding: AppSpacing.allLG,
                child: Center(child: AppLoading(size: AppLoadingSize.medium)),
              );
            }
            return const SizedBox.shrink();
          }),

          // 动态渲染 Sections
          Obx(() {
            final detail = state.detailInfo.value;
            if (detail == null) {
              return const SizedBox.shrink();
            }
            return Column(
              children: _buildSections(context, logic, detail),
            );
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
                // 名称和安装状态
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      // 版本、包名、统计标签
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children: [
                          // 版本标签（已安装显示当前版本，未安装显示最新版本）
                          if ((version != null && version.isNotEmpty) ||
                              state.installInfo.value != null)
                            VersionBadge(
                              latestVersion: version,
                              installedVersion:
                                  state.installInfo.value?.versionName,
                            ),
                          // 统计标签（统一渲染，无需判断 channel 类型）
                          ...?detailInfo?.buildStatTags().map(
                                (tag) => _buildChip(
                                  context,
                                  icon: tag.icon,
                                  label: tag.text,
                                  fg: tag.textColor,
                                  bg: tag.backgroundColor,
                                  border: tag.borderColor,
                                ),
                              ),
                          // 安装状态（响应式）
                          Obx(() => _buildInstallStatus(
                              context, logic, state.installInfo.value)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (description.isNotEmpty &&
                !isDescriptionDuplicated(detailInfo, description)) ...[
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
                    padding: HtmlPaddings.symmetric(horizontal: 4, vertical: 2),
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
        );
      }),
    );
  }

  /// 统一的标签 chip 渲染方法（版本 / 包名 / 统计共用）
  Widget _buildChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color fg,
    required Color bg,
    required Color border,
  }) {
    return Container(
      padding: AppSpacing.horizontalMD_verticalXS,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppRadius.allMD,
        border: Border.all(
          color: border,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: AppTypography.iconXS,
            color: fg,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: fg,
                  fontWeight: AppTypography.weightMedium,
                ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSections(
    BuildContext context,
    DetailLogic logic,
    IDetailInfo detail,
  ) {
    final sections = <Widget>[];

    // 应用信息卡（包名/版本/开发者/渠道基础信息与统计展开区）始终显示，
    // 全空时内部自隐藏——不依赖渠道 statistics 声明（localdb 渠道 apiList 为空时无 statistics section）
    sections.add(AppInfoSection(info: detail));

    for (var sectionType in detail.sections) {
      switch (sectionType) {
        case DetailSection.version:
          // 版本标签由 VersionBadge 展示，包名已移入应用信息卡
          break;
        case DetailSection.statistics:
        case DetailSection.rating:
          // 统计已并入 AppInfoSection 展开区，不再单独渲染
          break;
        case DetailSection.screenshots:
          sections.add(ScreenshotsSection(info: detail));
          break;
        case DetailSection.readme:
          sections.add(
            ReadmeSection(
              info: detail,
              onLinkTap: (url) => logic.openBrowser(url),
            ),
          );
          break;
        case DetailSection.downloads:
          sections.add(
            DownloadsSection(
              info: detail,
              onDownloadTap: (download) => logic.startDownload(download),
              onLongPress: (download) {
                AppDialogs.showDialog(
                  title: '下载二维码',
                  content: buildQrDialogContent(detail, download),
                  confirmText: '关闭',
                  cancelText: null,
                );
              },
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

  Widget _buildInstallStatus(
    BuildContext context,
    DetailLogic logic,
    sysAppInfo.AppInfo? status,
  ) {
    final title = status == null ? "未安装" : "installed ${status.versionName}";

    return GestureDetector(
      onTap: status == null ? null : () => logic.startApp(status.packageName),
      child: Container(
        padding: AppSpacing.horizontalMD_verticalXS,
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .primary
              .withAlpha(AppColors.alphaMedium),
          borderRadius: AppRadius.allXL,
        ),
        child: Text(
          title,
          style: AppTypography.labelSmall.copyWith(
            color: Theme.of(context).colorScheme.onPrimary,
          ),
        ),
      ),
    );
  }
}

BorderSide border(BuildContext context) => BorderSide(
      color: Theme.of(context)
          .colorScheme
          .primary
          .withAlpha(AppColors.alphaMedium),
      width: 1,
    );
