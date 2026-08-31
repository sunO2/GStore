/// 详情页面可复用的 Section 组件
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:gstore/core/image/app_image.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/design/app_borders.dart';
import 'package:gstore/core/core.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// 统一的详情页 Section 卡片容器
///
/// 详情页各 Section 统一复用，替代手写容器样式：
/// - surface 背景 + outlineVariant 细边框 + AppRadius.lg 圆角（非 primaryContainer 色块）
/// - 标题行：可选 icon（primary 色 iconMD）+ 标题（titleSmall 加粗）+ 可选 count + Spacer + 可选 trailing
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.icon,
    this.count,
    this.trailing,
    required this.children,
  });

  /// 标题文本
  final String title;

  /// 标题左侧图标（可选）
  final IconData? icon;

  /// 标题右侧计数（可选，位于标题与 trailing 之间）
  final Widget? count;

  /// 标题行最右侧内容（可选）
  final Widget? trailing;

  /// 卡片内容区子组件
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      margin: AppSpacing.onlyBottomSM,
      padding: AppSpacing.allLG,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: AppBorders.all(context, color: colorScheme.outlineVariant),
        borderRadius: AppRadius.allLG,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: AppTypography.iconMD,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: AppSpacing.xs),
                count!,
              ],
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ...children,
        ],
      ),
    );
  }
}

/// 自定义代码块构建器（flutter_markdown_plus）- 添加复制按钮
///
/// 对应旧 flutter_html 的 CodeBlockExtension：README 代码块复用
/// [_CodeBlockWidget]（工具栏 + 复制按钮 + 深色主题）。
class _ReadmeCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final codeText = element.textContent.replaceFirst(RegExp(r'\n+$'), '');
    if (codeText.trim().isEmpty) return const SizedBox.shrink();

    return _CodeBlockWidget(
      codeText: codeText,
      buildContext: context,
    );
  }
}

/// 代码块组件 - 带复制按钮
class _CodeBlockWidget extends StatelessWidget {
  final String codeText;
  final BuildContext buildContext;

  const _CodeBlockWidget({
    required this.codeText,
    required this.buildContext,
  });

  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: codeText));
    if (buildContext.mounted) {
      ScaffoldMessenger.of(buildContext).showSnackBar(
        SnackBar(
          content: const Text('代码已复制'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(
            bottom: MediaQuery.of(buildContext).size.height - 120,
            left: AppSpacing.md,
            right: AppSpacing.md,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.codeEditorBackground,
        borderRadius: AppRadius.allMD,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 工具栏（包含复制按钮）
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: AppColors.codeEditorToolbar,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(AppRadius.md),
                topRight: Radius.circular(AppRadius.md),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                InkWell(
                  onTap: _copyToClipboard,
                  borderRadius: AppRadius.allSM,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.copy_outlined,
                          size: AppTypography.iconSM,
                          color: AppColors.codeEditorText,
                        ),
                        SizedBox(width: AppSpacing.xs),
                        Text(
                          '复制',
                          style: TextStyle(
                            color: AppColors.codeEditorText,
                            fontSize: AppTypography.sizeXS,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 代码内容
          Container(
            padding: EdgeInsets.all(AppSpacing.md),
            width: double.infinity,
            child: Text(
              codeText,
              style: TextStyle(
                color: AppColors.codeEditorText,
                fontFamily: 'monospace',
                fontSize: AppTypography.sizeSM,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 判断 URL 是否为 SVG 图片（README 徽章常见）
bool isSvgUrl(String url) {
  final lower = url.toLowerCase();
  return lower.endsWith('.svg') ||
      lower.contains('.svg?') ||
      // shields.io 动态徽章无 .svg 后缀但返回 SVG 内容
      lower.contains('img.shields.io');
}

/// README 图片组件
class _ReadmeImage extends StatelessWidget {
  final String url;
  final BuildContext buildContext;
  final double? htmlWidth;
  final double? htmlHeight;

  const _ReadmeImage({
    required this.url,
    required this.buildContext,
    this.htmlWidth,
    this.htmlHeight,
  });

  /// GitHub 相关图片 URL 应用代理
  String get _proxiedUrl {
    final proxied = applyProxyIfNeeded(url, getProxy());
    debugPrint(
        'ReadmeImage: url=$url proxied=$proxied proxy=${getProxy().isEmpty ? '(空)' : getProxy()}');
    return proxied;
  }

  /// 长按复制原始图片链接（未代理）
  Future<void> _copyUrl() async {
    await Clipboard.setData(ClipboardData(text: url));
    if (buildContext.mounted) {
      AppDialogs.showSuccess('已复制图片链接');
    }
  }

  /// 图片加载成功日志（含缓存命中，imageBuilder 为成功路径）
  void _logLoadSuccess() {
    appLog.info('README 图片加载成功',
        data: {'url': url, 'proxiedUrl': _proxiedUrl});
  }

  /// 图片加载失败日志
  void _logLoadFailure(Object error) {
    appLog.error('README 图片加载失败', data: {
      'url': url,
      'proxiedUrl': _proxiedUrl,
      'proxy': getProxy(),
      'error': error.toString(),
    });
  }

  /// 构建 README 图片：经 [AppImage] 自动判型（SVG/位图）。
  /// HTML width/height 优先（tight）；未指定时 loose 自适应：
  /// SVG 按固有尺寸显示（badge 高度钳制 30），位图等比 clamp 于显示区。
  /// [placeholder] / [errorWidget] 由调用方提供（列表与全屏预览样式不同）；
  /// 内嵌（列表）默认隐藏加载占位与失败占位，全屏预览传 false 保留反馈。
  Widget _buildImage({
    required Widget placeholder,
    required Widget errorWidget,
    bool hideOnLoading = true,
    bool hideOnError = true,
  }) {
    final maxWidth = MediaQuery.of(buildContext).size.width - AppSpacing.lg * 2;
    return AppImage(
      url: _proxiedUrl,
      width: htmlWidth,
      height: htmlHeight,
      maxWidth: maxWidth,
      maxHeight: maxWidth * 0.8,
      fit: BoxFit.contain,
      alignment: Alignment.center,
      allowDrawingOutsideViewBox: false,
      placeholder: placeholder,
      errorWidget: errorWidget,
      hideOnLoading: hideOnLoading,
      hideOnError: hideOnError,
      onSuccess: _logLoadSuccess,
      onError: _logLoadFailure,
    );
  }

  /// 全屏预览
  void _preview(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black87,
        child: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: _buildImage(
                placeholder: const Center(
                  child: CircularProgressIndicator(),
                ),
                errorWidget: const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white70,
                  size: 48,
                ),
                // 全屏预览保留加载转圈与失败反馈
                hideOnLoading: false,
                hideOnError: false,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _preview(buildContext),
      onLongPress: _copyUrl,
      child: ClipRRect(
        borderRadius: AppRadius.allMD,
        child: _buildImage(
          placeholder: Container(
            height: 100,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          errorWidget: Container(
            height: 60,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.broken_image_outlined),
          ),
        ),
      ),
    );
  }
}

/// 统计标签 chip：复用 StatTag 自带颜色工厂（背景/边框/文本色）
class _StatTagChip extends StatelessWidget {
  final StatTag tag;

  const _StatTagChip({required this.tag});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: AppSpacing.horizontalMD_verticalXS,
      decoration: BoxDecoration(
        color: tag.backgroundColor,
        borderRadius: AppRadius.allMD,
        // 语义色（StatTag 工厂色）保留，宽度随主题 borderStyle
        border: AppBorders.all(context, color: tag.borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(tag.icon, size: AppTypography.iconXS, color: tag.textColor),
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
}

/// 应用信息 Section（可折叠）
///
/// 展示应用基础信息（包名/当前版本/开发者/渠道，字段非空才渲染），
/// 存在可展开内容（项目主页/统计标签）时提供展开/收起按钮：
/// - 默认收起：仅渲染基础行
/// - 展开追加：项目主页（primary 色）+ 统计 StatTag chips
///   （优先 info.buildStatTags()，为空 fallback 到 info.statistics?.buildStatTags()）
/// - 无可展开内容 → 隐藏展开按钮
/// - 基础行与可展开内容全空 → SizedBox.shrink
class AppInfoSection extends StatefulWidget {
  final IDetailInfo info;

  const AppInfoSection({super.key, required this.info});

  @override
  State<AppInfoSection> createState() => _AppInfoSectionState();
}

class _AppInfoSectionState extends State<AppInfoSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final extra = info.extra;
    // 模型字段优先，extra 兜底（e59d0c4 回归修复：GitHub/LocalDb 渐进路径
    // 的 extra 为纯存储 map，不含 version/packageName/channelId 镜像）
    final version = (info.version?.isNotEmpty == true)
        ? info.version
        : extra['version']?.toString();
    final developer = extra['developer']?.toString();
    final projectUrl = extra['projectUrl']?.toString();
    final chFromExtra = extra['channelId']?.toString() ?? '';
    final channelId = info.channelId.isNotEmpty ? info.channelId : chFromExtra;
    final pkgFromExtra = extra['packageName']?.toString() ?? '';
    final packageName =
        info.packageName.isNotEmpty ? info.packageName : pkgFromExtra;
    var tags = info.buildStatTags();
    if (tags.isEmpty) {
      tags = info.statistics?.buildStatTags() ?? const [];
    }

    final hasBasicRows = packageName.isNotEmpty ||
        version != null ||
        developer != null ||
        channelId.isNotEmpty;
    final hasExpandable = projectUrl != null || tags.isNotEmpty;

    // 全空（无基础行且无可展开内容）→ 不渲染
    if (!hasBasicRows && !hasExpandable) {
      return const SizedBox.shrink();
    }

    final primary = Theme.of(context).colorScheme.primary;

    return SectionCard(
      title: '应用信息',
      icon: Icons.info_outline,
      trailing: hasExpandable
          ? IconButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              tooltip: _expanded ? '收起' : '展开',
              icon: AnimatedRotation(
                turns: _expanded ? 0.5 : 0.0,
                duration: AppAnimation.fast,
                curve: AppAnimation.curve,
                child: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  color: primary,
                ),
              ),
            )
          : null,
      children: [
        if (packageName.isNotEmpty)
          _InfoRow(
            icon: Icons.smartphone,
            label: '包名',
            value: packageName,
          ),
        if (version != null)
          _InfoRow(
            icon: Icons.tag,
            label: '最新版本',
            value: version,
          ),
        if (developer != null)
          _InfoRow(
            icon: Icons.person_outline,
            label: '开发者',
            value: developer,
          ),
        if (channelId.isNotEmpty)
          _InfoRow(
            icon: Icons.storefront,
            label: '渠道',
            value: channelId,
          ),
        // 展开区：AnimatedSize 平滑展开/收起（展开内容保持原列表语义，收起时
        // 仅占零高度占位，宽度撑满保证仅高度方向动画）
        AnimatedSize(
          duration: AppAnimation.medium,
          curve: AppAnimation.curve,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (projectUrl != null)
                      _InfoRow(
                        icon: Icons.link,
                        label: '项目主页',
                        value: projectUrl,
                        valueColor: primary,
                      ),
                    if (tags.isNotEmpty)
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children: [
                          for (final tag in tags) _StatTagChip(tag: tag),
                        ],
                      ),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// 版本角标组件
///
/// 展示当前安装版本与最新版本对比（仅由调用方在应用已安装时渲染）：
/// - chip 标签 '当前版本 {installedVersion}'
/// - 已安装且 latest != installed → 右上角小胶囊角标 'v{latestVersion}'
/// - 两者皆空 → SizedBox.shrink
class VersionBadge extends StatelessWidget {
  final String? latestVersion;
  final String? installedVersion;

  const VersionBadge({
    super.key,
    required this.latestVersion,
    required this.installedVersion,
  });

  @override
  Widget build(BuildContext context) {
    final latest = latestVersion;
    final installed = installedVersion;
    if (latest == null && installed == null) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final chip = Container(
      padding: AppSpacing.horizontalMD_verticalXS,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: AppRadius.allMD,
        border: AppBorders.all(context, color: colorScheme.primary),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.tag,
            size: AppTypography.iconXS,
            color: colorScheme.primary,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            installed != null ? '当前版本 $installed' : latest ?? '',
            style: textTheme.labelMedium?.copyWith(
              color: colorScheme.primary,
              fontWeight: AppTypography.weightMedium,
            ),
          ),
        ],
      ),
    );

    final showBadge = installed != null &&
        latest != null &&
        latest.isNotEmpty &&
        installed != latest;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        chip,
        if (showBadge)
          Positioned(
            top: -AppSpacing.sm - 2,
            right: -AppSpacing.sm - 4,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 3,
                vertical: 1,
              ),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: AppRadius.allMD,
              ),
              child: Text(
                'v$latest',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onPrimaryContainer,
                  fontSize: 9,
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 应用截图横向滑动列表（懒加载；点击卡片全屏预览）
/// 卡片按标准 9:16 竖屏比例：宽 = 高 × 9/16
class _ScreenshotGallery extends StatelessWidget {
  static const double _cardHeight = 200;
  static const double _cardWidth = _cardHeight * 9 / 16;

  final List<ScreenshotInfo> screenshots;

  const _ScreenshotGallery({required this.screenshots});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: _cardHeight,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: screenshots.length,
        itemBuilder: (context, index) {
          final screenshot = screenshots[index];
          return GestureDetector(
            onTap: () => _showPreview(context, index),
            child: Container(
              width: _cardWidth,
              margin: AppSpacing.onlyRightMD,
              child: ClipRRect(
                borderRadius: AppRadius.allMD,
                child: CachedNetworkImage(
                  imageUrl: screenshot.url,
                  // cover 满铺：圆角完整作用于图片本身
                  // （容器 120×200 与竖屏截图比例接近，裁剪量极小）
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Container(
                    color: scheme.surfaceContainerHighest,
                    child: const Center(
                      child: AppLoading(size: AppLoadingSize.small),
                    ),
                  ),
                  errorWidget: (context, url, error) => Container(
                    color: scheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.broken_image,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 全屏预览（InteractiveViewer 缩放，页码指示，点击关闭）
  void _showPreview(BuildContext context, int index) {
    final scheme = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      barrierColor: scheme.scrim.withValues(alpha: 0.9),
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(AppSpacing.sm),
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 4,
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: screenshots[index].url,
                    fit: BoxFit.contain,
                    placeholder: (context, url) =>
                        const AppLoading(size: AppLoadingSize.medium),
                    errorWidget: (context, url, error) => Icon(
                      Icons.broken_image,
                      size: AppTypography.iconHuge,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                tooltip: '关闭',
                icon: Icon(Icons.close, color: scheme.onSurface),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Text(
                '${index + 1} / ${screenshots.length}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurface,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// README/详情文本 Section
class ReadmeSection extends StatefulWidget {
  final IDetailInfo info;
  final void Function(String)? onLinkTap;

  /// 是否加载中（分块加载未就绪时渲染轻量占位，完成态渲染真实内容）
  final bool loading;

  const ReadmeSection({
    super.key,
    required this.info,
    this.onLinkTap,
    this.loading = false,
  });

  @override
  State<ReadmeSection> createState() => _ReadmeSectionState();
}

class _ReadmeSectionState extends State<ReadmeSection> {
  /// README 大文本的 MarkdownBody 同步解析移出进入帧：首帧渲染轻量占位，
  /// postFrame 后一帧才构建 MarkdownBody——详情页进入/返回不再被解析阻塞。
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading || !_ready) {
      // 加载中 / deferred 未就绪的轻量占位：卡片标题保持稳定（避免完成态
      // 布局跳动），内容区固定高度 + 加载指示
      return const SectionCard(
        title: '详细介绍',
        icon: Icons.description_outlined,
        children: [
          SizedBox(
            height: 60,
            child: Center(
              child: AppLoading(size: AppLoadingSize.small),
            ),
          ),
        ],
      );
    }

    final info = widget.info;
    final readme = info.extra['readme']?.toString();
    // 截图统一内嵌详情区：有截图或正文任一存在即渲染（截图为横向滑动列表）
    final screenshots = info.screenshots ?? const <ScreenshotInfo>[];
    if ((readme == null || readme.isEmpty) && screenshots.isEmpty) {
      return const SizedBox.shrink();
    }

    // README 文本流：相对路径图片已在渠道层经 rawBaseUrl 绝对化
    // （resolveReadmeImageUrls，见 GitHubChannel/LocalDbChannel），
    // 此处仅将内嵌 <img> HTML 转换为 markdown 图片语法
    // （flutter_markdown_plus 不支持内联 HTML；尺寸经 title "WxH" 传递）
    final markdown = (readme == null || readme.isEmpty)
        ? ''
        : convertHtmlImgsToMarkdown(readme);

    final theme = Theme.of(context);

    return SectionCard(
      title: '详细介绍',
      icon: Icons.description_outlined,
      children: [
        // 截图横向滑动列表（点击全屏预览），统一收纳进详情区
        if (screenshots.isNotEmpty) ...[
          _ScreenshotGallery(screenshots: screenshots),
          const SizedBox(height: AppSpacing.md),
        ],
        if (markdown.isNotEmpty)
          MarkdownBody(
            data: markdown,
            selectable: true,
            onTapLink: (text, href, title) {
              if (href != null && href.isNotEmpty && widget.onLinkTap != null) {
                widget.onLinkTap?.call(href);
              }
            },
            imageBuilder: (uri, title, alt) {
              final size = _parseImageTitleSize(title);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: _ReadmeImage(
                  url: uri.toString(),
                  buildContext: context,
                  htmlWidth: size?.$1,
                  htmlHeight: size?.$2,
                ),
              );
            },
            // README 代码块：复制按钮 + 深色工具栏（复用旧 _CodeBlockWidget）
            builders: {
              'pre': _ReadmeCodeBlockBuilder(),
            },
            styleSheet: _buildReadmeStyleSheet(context, theme),
          ),
      ],
    );
  }

  /// 解析 markdown 图片 title（convertHtmlImgsToMarkdown 编码为 "WxH" / 单边 "Wx"、"xH"，
  /// 仅数字）。解析失败（null/非法）→ null（不传尺寸，交由 _ReadmeImage loose 自适应）。
  /// 缺失的一边返回 null（AppImage 单边尺寸由固有尺寸等比补全）。
  (double?, double?)? _parseImageTitleSize(String? title) {
    if (title == null) return null;
    final m = RegExp(r'^(\d*)[xX](\d*)$').firstMatch(title.trim());
    if (m == null) return null;
    final wRaw = m.group(1)!;
    final hRaw = m.group(2)!;
    if (wRaw.isEmpty && hRaw.isEmpty) return null;
    final w = wRaw.isEmpty ? null : double.tryParse(wRaw);
    final h = hRaw.isEmpty ? null : double.tryParse(hRaw);
    if (w == null && h == null) return null;
    return (w, h);
  }

  /// 移植原 flutter_html style map → flutter_markdown_plus MarkdownStyleSheet。
  ///
  /// 逐项对照说明（无法 1:1 的取最接近字段）：
  /// - body（sizeMD/1.5/onSurface）→ p；p/li 原 lineHeight 1.6 由 blockSpacing 补偿
  /// - 标题原 margin+padding 合并进 h*Padding（块间距由 blockSpacing 承担）
  /// - 行内 code 原 padding(6,3) 无法表达 → 保留背景/颜色/字体
  /// - pre 原背景/内边距由 _CodeBlockWidget 自带，codeblock* 清空避免双重样式
  /// - td 原 border-top → TableBorder.all 近似（flutter_markdown_plus 无逐行边框）
  MarkdownStyleSheet _buildReadmeStyleSheet(
      BuildContext context, ThemeData theme) {
    final colorScheme = theme.colorScheme;

    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      // 块间基础间距（原各块 margin 的近似）
      blockSpacing: AppSpacing.xs,

      // 正文基础样式
      p: TextStyle(
        fontSize: AppTypography.sizeMD,
        height: 1.5,
        color: colorScheme.onSurface,
      ),
      pPadding: EdgeInsets.zero,

      // 标题样式
      h1: TextStyle(
        fontSize: AppTypography.sizeXXL,
        fontWeight: AppTypography.weightSemiBold,
        color: colorScheme.onSurface,
      ),
      h1Padding: const EdgeInsets.only(bottom: AppSpacing.xs * 2),
      h2: TextStyle(
        fontSize: AppTypography.sizeXL,
        fontWeight: AppTypography.weightSemiBold,
        color: colorScheme.onSurface,
      ),
      h2Padding: const EdgeInsets.only(
        bottom: AppSpacing.xs,
        left: AppSpacing.sm,
      ),
      h3: TextStyle(
        fontSize: AppTypography.sizeLG,
        fontWeight: AppTypography.weightSemiBold,
        color: colorScheme.onSurface,
      ),
      h3Padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      h4: TextStyle(
        fontSize: AppTypography.sizeMD,
        fontWeight: AppTypography.weightSemiBold,
        color: colorScheme.onSurface,
      ),
      h4Padding: const EdgeInsets.only(bottom: AppSpacing.xs),

      // 链接样式
      a: TextStyle(
        color: colorScheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: colorScheme.primary,
        fontWeight: AppTypography.weightMedium,
      ),

      // 行内代码样式
      code: TextStyle(
        backgroundColor: colorScheme.surfaceContainerHighest,
        color: colorScheme.primary,
        fontFamily: 'monospace',
        fontSize: AppTypography.sizeSM - 1,
      ),

      // 代码块：样式由 _CodeBlockWidget 自带（复制按钮 + 深色工具栏），
      // 清掉 fromTheme 默认装饰避免双重样式
      codeblockPadding: EdgeInsets.zero,
      codeblockDecoration: const BoxDecoration(),

      // 引用块样式
      blockquote: TextStyle(
        color: colorScheme.onSurfaceVariant.withAlpha(AppColors.alphaMedium),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        0,
        AppSpacing.xs,
      ),
      blockquoteDecoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest
            .withAlpha(AppColors.alphaLowest),
        border: Border(
          left: BorderSide(
            color: colorScheme.primary,
            // 语义色强调（引用块左侧强调条），宽度固定 4 不随主题 borderStyle
            width: 4,
          ),
        ),
      ),

      // 列表样式
      listIndent: AppSpacing.md,
      listBullet: TextStyle(
        fontSize: AppTypography.sizeMD,
        height: 1.5,
        color: colorScheme.onSurface,
      ),

      // 表格样式（TableBorder 非 BoxBorder，仅宽度取主题）
      tableBorder: TableBorder.all(
        color: colorScheme.outline.withAlpha(AppColors.alphaLower),
        width: AppBorders.sideOf(context).width,
      ),
      tablePadding: const EdgeInsets.only(bottom: AppSpacing.xs),
      tableBody: TextStyle(
        fontSize: AppTypography.sizeMD,
        height: 1.5,
        color: colorScheme.onSurface,
      ),
      tableHead: TextStyle(
        color: colorScheme.onSurface,
        fontWeight: AppTypography.weightSemiBold,
      ),
      tableHeadAlign: TextAlign.center,
      tableCellsPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      tableHeadCellsPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      tableHeadCellsDecoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
      ),

      // 分隔线样式（宽度随主题 borderStyle）
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withAlpha(AppColors.alphaLower),
            width: AppBorders.sideOf(context).width,
          ),
        ),
      ),

      // 强调文本
      strong: TextStyle(
        fontWeight: AppTypography.weightSemiBold,
        color: colorScheme.onSurface,
      ),

      // 斜体文本
      em: const TextStyle(fontStyle: FontStyle.italic),

      // 删除线
      del: TextStyle(
        decoration: TextDecoration.lineThrough,
        color: colorScheme.onSurfaceVariant.withAlpha(AppColors.alphaMedium),
      ),
    );
  }
}

/// 下载链接 Section
class DownloadsSection extends StatelessWidget {
  final IDetailInfo info;
  final void Function(DownloadInfo)? onDownloadTap;
  final void Function(DownloadInfo)? onLongPress;

  /// 是否加载中（分块加载未就绪时渲染骨架占位，完成态渲染真实列表）
  final bool loading;

  const DownloadsSection({
    super.key,
    required this.info,
    this.onDownloadTap,
    this.onLongPress,
    this.loading = false,
  });

  /// 过滤出当前平台的可下载文件
  /// 只显示 .apk、.aab (Android App Bundle) 或 .zip 文件
  List<DownloadInfo> _filterPlatformDownloads(List<DownloadInfo> downloads) {
    return downloads.where((download) {
      final fileName = download.name.toLowerCase();
      // 检查文件扩展名
      if (fileName.endsWith('.apk')) return true;
      if (fileName.endsWith('.aab')) return true; // Android App Bundle
      if (fileName.endsWith('.ipa')) return true; // iOS
      if (fileName.endsWith('.hap')) return true; // Harmony
      if (fileName.endsWith('.zip')) {
        // zip 文件需要进一步检查名称
        // 通常包含 "universal", "android", "arm" 等关键词的是 Android 包
        final keywords = ['universal', 'android', 'arm', 'mobile', 'app'];
        return keywords.any((keyword) => fileName.contains(keyword));
      }
      return false;
    }).toList();
  }

  /// 加载中骨架：卡片标题/图标保持稳定（避免完成态布局跳动），
  /// 内容区渲染 3 行轻量骨架（AppLoading 圆环 + 主题色灰条），与 _DownloadItem 行结构对齐
  Widget _buildLoadingSkeleton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final skeletonColor = colorScheme.surfaceContainerHighest;

    Widget bar({required double height, double? width}) {
      return Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: skeletonColor,
          borderRadius: AppRadius.allSM,
        ),
      );
    }

    return SectionCard(
      title: '下载文件',
      icon: Icons.download_rounded,
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: AppSpacing.onlyBottomSM,
            child: Row(
              children: [
                // 与 _DownloadItem 图标位对齐的加载指示
                const AppLoading(size: AppLoadingSize.small),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 文件名灰条
                      bar(height: 14),
                      const SizedBox(height: AppSpacing.xs),
                      // 版本信息灰条
                      bar(height: 10, width: 120),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return _buildLoadingSkeleton(context);

    final colorScheme = Theme.of(context).colorScheme;
    // 过滤出当前平台的文件
    final filteredDownloads = _filterPlatformDownloads(info.downloads);

    if (filteredDownloads.isEmpty) {
      return SectionCard(
        title: '下载文件',
        icon: Icons.download_rounded,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: AppTypography.iconMD,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  info.downloads.isEmpty ? '该应用暂无可下载文件' : '该应用暂无适配当前平台的文件',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return SectionCard(
      title: '下载文件',
      icon: Icons.download_rounded,
      count: Container(
        padding:
            EdgeInsets.symmetric(horizontal: AppSpacing.sm * 1.5, vertical: 1),
        decoration: BoxDecoration(
          color: colorScheme.primary.withAlpha(AppColors.alphaLow),
          borderRadius: AppRadius.allMD,
        ),
        child: Text(
          '${filteredDownloads.length} 个文件',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.primary,
                fontSize: AppTypography.sizeXXS,
              ),
        ),
      ),
      trailing: filteredDownloads.first.publishedAt != null
          ? Text(
              '更新于 ${_formatDate(filteredDownloads.first.publishedAt!)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: AppTypography.sizeXXS,
                    color: colorScheme.onSurfaceVariant,
                  ),
            )
          : null,
      children: [
        ...filteredDownloads.map((download) => _DownloadItem(
              download: download,
              onTap: onDownloadTap,
              onLongPress: onLongPress,
            )),
      ],
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      if (difference.inHours == 0) {
        if (difference.inMinutes == 0) {
          return '刚刚';
        }
        return '${difference.inMinutes} 分钟前';
      }
      return '${difference.inHours} 小时前';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} 天前';
    } else {
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    }
  }
}

class _DownloadItem extends StatelessWidget {
  final DownloadInfo download;
  final void Function(DownloadInfo)? onTap;
  final void Function(DownloadInfo)? onLongPress;

  const _DownloadItem({
    required this.download,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final fileName = download.name;

    return Container(
      margin: AppSpacing.onlyBottomSM,
      child: InkWell(
        onLongPress: onLongPress != null ? () => onLongPress!(download) : null,
        borderRadius: AppRadius.allMD,
        child: Container(
          padding: AppSpacing.allMD,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context).colorScheme.surfaceContainerHighest,
                Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withAlpha(AppColors.alphaMedium),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: AppBorders.all(
              context,
              color: Theme.of(context)
                  .colorScheme
                  .primary
                  .withAlpha(AppColors.alphaLower),
            ),
            borderRadius: AppRadius.allMD,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 文件名
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                          message: fileName,
                          child: Text(
                            fileName,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  fontWeight: AppTypography.weightMedium,
                                ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (download.version != null) ...[
                          SizedBox(height: AppSpacing.xs),
                          Row(
                            children: [
                              Icon(
                                Icons.label,
                                size: AppTypography.iconXS,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                              SizedBox(width: AppSpacing.xs),
                              Text(
                                download.version!,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      fontSize: AppTypography.sizeXXS,
                                    ),
                              ),
                            ],
                          ),
                        ],
                        
                        // 不可下载原因提示（脚本渠道：未配置凭证/认证失败）
                        if (!download.downloadable &&
                            download.note?.isNotEmpty == true) ...[
                          SizedBox(height: AppSpacing.xs),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: AppTypography.iconXS,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              SizedBox(width: AppSpacing.xs),
                              Expanded(
                                child: Text(
                                  download.note!,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                        fontSize: AppTypography.sizeXXS,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  // 下载按钮（不可下载时禁用：脚本未生成下载地址，如未配置凭证/认证失败）
                  if (onTap != null)
                    InkWell(
                      onTap: download.downloadable
                          ? () => onTap!(download)
                          : null,
                      borderRadius: AppRadius.allXL,
                      child: Container(
                        padding: AppSpacing.allSM,
                        child: Icon(
                          download.downloadable
                              ? Icons.download_rounded
                              : Icons.block,
                          size: AppTypography.iconLG,
                          color: download.downloadable
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
              // 详细信息行（自动换行，防标签越界）
              SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  // extra 标签（优先，带 icon）
                  if (download.extra != null)
                    ...download.extra!.entries.map((e) => _buildInfoChip(
                      context,
                      _iconFromName(e.value.iconName) ?? Icons.info_outline,
                      e.value.text,
                      _colorForTag(e.key, Theme.of(context).colorScheme),
                    )),
                  
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Material 图标名 → IconData 映射（未知返回 null）
  IconData? _iconFromName(String? name) {
    switch (name) {
      case 'sd_card': return Icons.sd_card;
      case 'sd_storage': return Icons.sd_storage;
      case 'phone_android': return Icons.phone_android;
      case 'build': return Icons.build;
      case 'cloud': return Icons.cloud;
      case 'download': return Icons.download_rounded;
      case 'cloud_download': return Icons.cloud_download;
      case 'schedule': return Icons.schedule;
      case 'label': return Icons.label;
      case 'install': return Icons.download_done;
      default: return null;
    }
  }

  /// 标签 key → 主题色（稳定映射，M3 色彩角色，禁止硬编码颜色）
  Color _colorForTag(String key, ColorScheme scheme) {
    switch (key) {
      case 'size':
        return scheme.primary;
      case 'platform':
        return scheme.secondary;
      case 'env':
        // 环境标识：中性色（非错误/危险语义）
        return scheme.onSurfaceVariant;
      case 'build':
      case 'installTimes':
      case 'install':
      case 'download_count':
      case 'downloadCount':
        // 构建号与各类计数同族
        return scheme.tertiary;
      default:
        return scheme.outline;
    }
  }

  Widget _buildInfoChip(
    BuildContext context,
    IconData icon,
    String label,
    Color color,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.sm * 1.5, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: AppRadius.allXS,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: AppTypography.iconXXS, color: color),
          SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: color,
                  fontSize: AppTypography.sizeXXS,
                  fontWeight: AppTypography.weightMedium,
                ),
          ),
        ],
      ),
    );
  }

  }

/// 开发者信息行：[xs icon + onSurfaceVariant label + onSurface value]
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: AppSpacing.onlyBottomSM,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon,
              size: AppTypography.iconXS, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: valueColor ?? colorScheme.onSurface,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 开发者信息 Section
class DeveloperSection extends StatelessWidget {
  final IDetailInfo info;

  const DeveloperSection({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final extra = info.extra;
    final developer = extra['developer']?.toString();
    final projectUrl = extra['projectUrl']?.toString();
    final version = extra['version']?.toString();
    final channelId = extra['channelId']?.toString() ?? '';

    // 四字段全空才隐藏
    if (developer == null &&
        projectUrl == null &&
        version == null &&
        channelId.isEmpty) {
      return const SizedBox.shrink();
    }

    final primary = Theme.of(context).colorScheme.primary;
    return SectionCard(
      title: '开发者',
      icon: Icons.person_outline,
      children: [
        if (developer != null)
          _InfoRow(
            icon: Icons.person_outline,
            label: '开发者',
            value: developer,
          ),
        if (projectUrl != null)
          _InfoRow(
            icon: Icons.link,
            label: '项目主页',
            value: projectUrl,
            valueColor: primary,
          ),
        if (version != null)
          _InfoRow(
            icon: Icons.tag,
            label: '版本',
            value: version,
          ),
        if (channelId.isNotEmpty)
          _InfoRow(
            icon: Icons.storefront,
            label: '渠道',
            value: channelId,
          ),
      ],
    );
  }
}

/// 更新日志 Section
class ChangelogSection extends StatelessWidget {
  final IDetailInfo info;

  const ChangelogSection({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final changelog = info.extra['changelog']?.toString();
    if (changelog == null || changelog.isEmpty) {
      return const SizedBox.shrink();
    }

    return SectionCard(
      title: '更新日志',
      icon: Icons.update,
      children: [
        Text(
          changelog,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

/// 权限说明 Section
class PermissionsSection extends StatelessWidget {
  final IDetailInfo info;

  const PermissionsSection({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final raw = info.extra['permissions'];
    final permissions = raw is List
        ? raw.map((e) => e.toString()).toList()
        : null;
    if (permissions == null || permissions.isEmpty) {
      return const SizedBox.shrink();
    }

    return SectionCard(
      title: '权限说明',
      icon: Icons.security,
      children: [
        ...permissions.map((permission) => Padding(
              padding: AppSpacing.onlyBottomSM,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.security, size: AppTypography.sizeSM),
                  SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      permission,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            )),
      ],
    );
  }
}

/// 下载二维码弹窗内容
///
/// 白底 QR 平板（AppColors.white 保证夜间模式可扫码）+ 应用图标与名称：
/// - QrImageView(data: 当前二维码数据, size: 108)，无 embeddedImage
/// - 实际走代理的链接（GitHub/localdb）提供"代理前缀"开关：默认开启（代理 URL
///   生成二维码），关闭后切换原始 URL 重新生成；状态为弹框内临时状态，不持久化
/// - AppIcon(24×24) + SizedBox(sm) + 应用名称（bodySmall）
Widget buildQrDialogContent(IDetailInfo detail, DownloadInfo download) {
  return _QrDialogContent(detail: detail, download: download);
}

/// 下载二维码弹窗内容（代理开关为弹框内临时 StatefulWidget 状态）
class _QrDialogContent extends StatefulWidget {
  const _QrDialogContent({required this.detail, required this.download});

  final IDetailInfo detail;
  final DownloadInfo download;

  @override
  State<_QrDialogContent> createState() => _QrDialogContentState();
}

class _QrDialogContentState extends State<_QrDialogContent> {
  /// 默认使用代理前缀生成二维码（关闭弹框即丢弃，不持久化）
  bool _useProxy = true;

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final download = widget.download;
    final proxied = applyProxyIfNeeded(download.url, getProxy());
    final canProxy = proxied != download.url;
    final qrData = _useProxy ? proxied : download.url;

    return Container(
      padding: AppSpacing.allLG,
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: AppRadius.allSM,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          QrImageView(
            data: qrData,
            version: QrVersions.auto,
            size: 108,
          ),
          // 当前二维码 URL 小字（便于确认代理前后差异）
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              qrData,
              key: const Key('qr_data_caption'),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 实际走代理的链接才显示代理开关
          if (canProxy)
            Row(
              children: [
                Text(
                  '代理前缀',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const Spacer(),
                Switch(
                  value: _useProxy,
                  onChanged: (v) => setState(() => _useProxy = v),
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.sm),
          Builder(
            builder: (context) => Row(
              children: [
                AppIcon(
                  url: detail.icon,
                  width: 24,
                  height: 24,
                  borderRadius: AppRadius.xs,
                ),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Text(
                    detail.appName,
                    // 白板为强制白色（保证夜间可扫码），文字用固定深色保证可读
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 判断头部 description 是否与 readme 重复
///
/// readme 非空且（description.trim() == readme.trim() ||
/// readme.trim() 以 description.trim() 开头）→ true
bool isDescriptionDuplicated(IDetailInfo? info, String description) {
  final readme = info?.readme;
  final trimmedDescription = description.trim();
  if (readme == null || readme.isEmpty || trimmedDescription.isEmpty) {
    return false;
  }
  final trimmedReadme = readme.trim();
  return trimmedDescription == trimmedReadme ||
      trimmedReadme.startsWith(trimmedDescription);
}
