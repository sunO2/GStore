import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailData.dart';
import 'package:gstore/core/model/StatTag.dart';
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
        // 初始加载中
        if (state.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }

        // 有错误
        if (state.errorMessage.value.isNotEmpty) {
          return _buildErrorBody(context, logic, state);
        }

        return _buildBody(context, logic, state);
      }),
      floatingActionButton: StreamBuilder(
        stream: logic.counterController.stream,
        builder: (context, AsyncSnapshot snapshot) {
          if (!snapshot.hasData) return const SizedBox();

          final data = snapshot.data;
          if (data == null) return const SizedBox();

          return FloatingActionButton(
            onPressed: null,
            child: Stack(
              alignment: AlignmentDirectional.center,
              children: [
                CircularProgressIndicator(
                  value: data.count / data.total,
                ),
                Text(
                  "${((data.count / data.total) * 100).toInt()}",
                  style: Theme.of(context).textTheme.labelSmall,
                )
              ],
            ),
          );
        },
      ),
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
            style: const TextStyle(fontWeight: FontWeight.w800),
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 16),
          Text(state.errorMessage.value),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => logic.loadDetail(),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    DetailLogic logic,
    DetailState state,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // 头部基础信息
          _buildHeader(context, logic, state),

          const SizedBox(height: 8),

          // 详情加载指示器
          Obx(() {
            if (state.isLoadingDetail.value) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(
          top: border(context),
          left: border(context),
          right: border(context),
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
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
                    borderRadius: BorderRadius.circular(12),
                    child: icon.isNotEmpty
                        ? Image(
                            image: CachedNetworkImageProvider(icon),
                            width: 64,
                            height: 64,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                width: 64,
                                height: 64,
                                color: Colors.grey[300],
                                child: const Icon(Icons.error),
                              );
                            },
                          )
                        : Container(
                            width: 64,
                            height: 64,
                            color: Colors.grey[300],
                            child: const Icon(Icons.apps),
                          ),
                  ),
                ),
                const SizedBox(width: 16),
                // 名称和安装状态
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      // 版本、包名、统计标签
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          // 版本标签
                          if (version != null && version.isNotEmpty)
                            _buildVersionTag(context, version),
                          // 包名标签
                          if (packageName != null && packageName.isNotEmpty)
                            _buildPackageTag(context, packageName),
                          // 统计标签（统一渲染，无需判断 channel 类型）
                          ...?detailInfo?.buildStatTags().map((tag) => _buildStatTag(context, tag)),
                          // 安装状态
                          _buildInstallStatus(context, logic, state.installInfo),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                description,
                style: Theme.of(context).textTheme.bodyMedium,
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withAlpha(40),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withAlpha(80),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.tag,
            size: 12,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 4),
          Text(
            version,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }

  /// 包名标签
  Widget _buildPackageTag(BuildContext context, String packageName) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondary.withAlpha(40),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.secondary.withAlpha(80),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 12,
            color: Theme.of(context).colorScheme.secondary,
          ),
          const SizedBox(width: 4),
          Text(
            packageName,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }

  /// 统一的统计标签渲染方法
  Widget _buildStatTag(BuildContext context, StatTag tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: tag.backgroundColor,
        borderRadius: BorderRadius.circular(12),
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
            size: 12,
            color: tag.textColor,
          ),
          const SizedBox(width: 4),
          Text(
            tag.text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: tag.textColor,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSections(
    BuildContext context,
    DetailLogic logic,
    IDetailData detail,
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
                Get.defaultDialog(
                  title: "下载二维码",
                  content: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: QrImageView(
                      data: download.url,
                      version: QrVersions.auto,
                      size: 120,
                      embeddedImage: detail.icon.isNotEmpty
                          ? CachedNetworkImageProvider(detail.icon)
                          : null,
                    ),
                  ),
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withAlpha(130),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          title,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

BorderSide border(BuildContext context) => BorderSide(
  color: Theme.of(context).colorScheme.primary.withAlpha(130),
  width: 1,
);
