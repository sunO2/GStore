import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/page/detail/widgets.dart';
import 'logic.dart';
import 'state.dart';
import 'package:installed_apps/app_info.dart' as sysAppInfo;
import 'package:qr_flutter/qr_flutter.dart';

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
        final percent = hasTotal ? ((count / total) * 100).toInt().clamp(0, 100) : 0;
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
        Obx(() {
          final detail = state.detailInfo.value;
          if (detail?.projectUrl == null) return const SizedBox();

          return IconButton(
            onPressed: logic.openProjectBrowser,
            icon: const Icon(Icons.language),
            tooltip: "项目主页",
          );
        }),
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
        final packageName = state.detailInfo.value?.packageName;
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
                            width: AppSpacing.xxxl + AppSpacing.xxl + AppSpacing.md,
                            height: AppSpacing.xxxl + AppSpacing.xxl + AppSpacing.md,
                            borderRadius: 0,
                          )
                        : Container(
                            width: AppSpacing.xxxl + AppSpacing.xxl + AppSpacing.md,
                            height: AppSpacing.xxxl + AppSpacing.xxl + AppSpacing.md,
                            color: AppColors.grey300,
                            child: const Icon(Icons.apps),
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
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      // 版本、包名、统计标签
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children: [
                          // 版本标签
                          if (version != null && version.isNotEmpty)
                            _buildVersionTag(context, version),
                          // 包名标签
                          if (packageName != null && packageName.isNotEmpty)
                            _buildPackageTag(context, packageName),
                          // 统计标签（统一渲染，无需判断 channel 类型）
                          ...?detailInfo?.buildStatTags().map((tag) => _buildStatTag(context, tag)),
                          // 安装状态（响应式）
                          Obx(() => _buildInstallStatus(context, logic, state.installInfo.value)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (description.isNotEmpty) ...[
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
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer.withAlpha(AppColors.alphaLowest),
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

  /// 版本标签
  Widget _buildVersionTag(BuildContext context, String version) {
    return Container(
      padding: AppSpacing.horizontalMD_verticalXS,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withAlpha(AppColors.alphaLow),
        borderRadius: AppRadius.allMD,
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withAlpha(AppColors.alphaMedium),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.tag,
            size: AppTypography.iconXS,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            version,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: AppTypography.weightMedium,
                ),
          ),
        ],
      ),
    );
  }

  /// 包名标签
  Widget _buildPackageTag(BuildContext context, String packageName) {
    return Container(
      padding: AppSpacing.horizontalMD_verticalXS,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondary.withAlpha(AppColors.alphaLow),
        borderRadius: AppRadius.allMD,
        border: Border.all(
          color: Theme.of(context).colorScheme.secondary.withAlpha(AppColors.alphaMedium),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: AppTypography.iconXS,
            color: Theme.of(context).colorScheme.secondary,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            packageName,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                  fontWeight: AppTypography.weightMedium,
                ),
          ),
        ],
      ),
    );
  }

  /// 统一的统计标签渲染方法
  Widget _buildStatTag(BuildContext context, StatTag tag) {
    return Container(
      padding: AppSpacing.horizontalMD_verticalXS,
      decoration: BoxDecoration(
        color: tag.backgroundColor,
        borderRadius: AppRadius.allMD,
        border: Border.all(
          color: tag.borderColor,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            tag.icon,
            size: AppTypography.iconXS,
            color: tag.textColor,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            tag.text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: tag.textColor,
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

    for (var sectionType in detail.sections) {
      switch (sectionType) {
        case DetailSection.version:
          // 版本和包名已整合到 ReadmeSection 中显示为标签
          break;
        case DetailSection.statistics:
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
                  content: Container(
                    width: AppSpacing.xxxl + AppSpacing.xxxl + AppSpacing.xxl + AppSpacing.xl,
                    height: AppSpacing.xxxl + AppSpacing.xxxl + AppSpacing.xxl + AppSpacing.xl,
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: AppRadius.allSM,
                    ),
                    child: QrImageView(
                      data: download.url,
                      version: QrVersions.auto,
                      size: AppSpacing.xxxl + AppSpacing.xxxl + AppSpacing.xxl + AppSpacing.xl,
                      embeddedImage: detail.icon.isNotEmpty
                          ? CachedNetworkImageProvider(detail.icon)
                          : null,
                    ),
                  ),
                  confirmText: '关闭',
                  cancelText: null,
                );
              },
            ),
          );
          break;
        case DetailSection.rating:
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
    final title = status == null
        ? "未安装"
        : "installed ${status.versionName}";

    return GestureDetector(
      onTap: status == null
          ? null
          : () => logic.startApp(status.packageName),
      child: Container(
        padding: AppSpacing.horizontalMD_verticalXS,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withAlpha(AppColors.alphaMedium),
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
  color: Theme.of(context).colorScheme.primary.withAlpha(AppColors.alphaMedium),
  width: 1,
);
