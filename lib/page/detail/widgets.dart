/// 详情页面可复用的 Section 组件
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_html/src/extension/html_extension.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:gstore/core/image/app_image.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/design/design_tokens.dart';
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
        border: Border.all(color: colorScheme.outlineVariant, width: 1),
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

/// 自定义代码块扩展 - 添加复制按钮
class CodeBlockExtension extends HtmlExtension {
  final BuildContext context;

  CodeBlockExtension(this.context);

  @override
  Set<String> get supportedTags => {'pre'};

  @override
  InlineSpan build(ExtensionContext context) {
    final element = context.styledElement;
    final codeText = element?.element?.text?.trim() ?? '';

    return WidgetSpan(
      child: _CodeBlockWidget(
        codeText: codeText,
        buildContext: this.context,
      ),
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

/// 图片扩展：README 内图片圆角显示 + 点击全屏预览
class _ReadmeImageExtension extends HtmlExtension {
  final BuildContext context;

  _ReadmeImageExtension(this.context);

  @override
  Set<String> get supportedTags => {'img'};

  @override
  InlineSpan build(ExtensionContext context) {
    final src = context.styledElement?.element?.attributes['src'] ?? '';
    final uri = Uri.tryParse(src);
    if (uri == null || src.isEmpty) {
      return const WidgetSpan(child: SizedBox.shrink());
    }
    return WidgetSpan(
      alignment: PlaceholderAlignment.bottom,
      child: _ReadmeImage(url: src, buildContext: this.context),
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

  const _ReadmeImage({required this.url, required this.buildContext});

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

  /// 构建 README 图片：经 [AppImage] 自动判型（SVG/位图）并钳制显示区
  /// （badge SVG 高度钳制 30，其余 tight 768x(768*0.8)）
  /// [placeholder] / [errorWidget] 由调用方提供（列表与全屏预览样式不同）
  Widget _buildImage({
    required Widget placeholder,
    required Widget errorWidget,
  }) {
    final maxWidth = MediaQuery.of(buildContext).size.width - AppSpacing.lg * 2;
    return AppImage(
      url: _proxiedUrl,
      width: maxWidth,
      height: maxWidth * 0.8,
      fit: BoxFit.contain,
      alignment: Alignment.center,
      allowDrawingOutsideViewBox: false,
      placeholder: placeholder,
      errorWidget: errorWidget,
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
        border: Border.all(color: tag.borderColor, width: 1),
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
    final version = info.version;
    final developer = info.developer;
    final projectUrl = info.projectUrl;
    final channelId = info.channelId;

    var tags = info.buildStatTags();
    if (tags.isEmpty) {
      tags = info.statistics?.buildStatTags() ?? const <StatTag>[];
    }

    final hasBasicRows = info.packageName.isNotEmpty ||
        version != null ||
        developer != null ||
        info.channelId.isNotEmpty;
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
              icon: Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                color: primary,
              ),
            )
          : null,
      children: [
        if (info.packageName.isNotEmpty)
          _InfoRow(
            icon: Icons.smartphone,
            label: '包名',
            value: info.packageName,
          ),
        if (version != null)
          _InfoRow(
            icon: Icons.tag,
            label: '当前版本',
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
        if (_expanded) ...[
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
              children: [for (final tag in tags) _StatTagChip(tag: tag)],
            ),
        ],
      ],
    );
  }
}

/// 版本角标组件
///
/// 展示当前安装版本与最新版本对比：
/// - 已安装 → chip 标签 '当前版本 {installedVersion}'
/// - 未安装 → chip 直接显示 {latestVersion}
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
        border: Border.all(color: colorScheme.primary, width: 1),
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

/// 应用截图 Section
class ScreenshotsSection extends StatelessWidget {
  final IDetailInfo info;

  const ScreenshotsSection({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final screenshots = info.screenshots;
    if (screenshots == null || screenshots.isEmpty) {
      return const SizedBox.shrink();
    }

    return SectionCard(
      title: '应用截图',
      icon: Icons.photo_library_outlined,
      children: [_ScreenshotGallery(screenshots: screenshots)],
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
class ReadmeSection extends StatelessWidget {
  final IDetailInfo info;
  final void Function(String)? onLinkTap;

  const ReadmeSection({super.key, required this.info, this.onLinkTap});

  @override
  Widget build(BuildContext context) {
    final readme = info.readme;
    // 截图统一内嵌详情区：有截图或正文任一存在即渲染（截图为横向滑动列表）
    final screenshots = info.screenshots ?? const <ScreenshotInfo>[];
    if ((readme == null || readme.isEmpty) && screenshots.isEmpty) {
      return const SizedBox.shrink();
    }

    // 将 Markdown 转换为 HTML
    final htmlContent = (readme == null || readme.isEmpty)
        ? ''
        : md.markdownToHtml(
            readme,
            extensionSet: md.ExtensionSet.gitHubFlavored,
          );

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SectionCard(
      title: '详细介绍',
      icon: Icons.description_outlined,
      children: [
        // 截图横向滑动列表（点击全屏预览），统一收纳进详情区
        if (screenshots.isNotEmpty) ...[
          _ScreenshotGallery(screenshots: screenshots),
          const SizedBox(height: AppSpacing.md),
        ],
        if (htmlContent.isNotEmpty)
          Html(
            data: htmlContent,
            onLinkTap: (url, _, __) {
              if (url != null && onLinkTap != null) {
                onLinkTap?.call(url);
              }
            },
            // 添加自定义代码块扩展
            extensions: [
              CodeBlockExtension(context),
              _ReadmeImageExtension(context),
            ],
            style: {
              // 正文基础样式
              'body': Style(
                margin: Margins.zero,
                padding: HtmlPaddings.zero,
                color: colorScheme.onSurface,
                fontSize: FontSize(AppTypography.sizeMD),
                lineHeight: const LineHeight(1.5),
              ),

              // 标题样式
              'h1': Style(
                color: colorScheme.onSurface,
                fontSize: FontSize(AppTypography.sizeXXL),
                fontWeight: AppTypography.weightSemiBold,
                margin: Margins.only(bottom: AppSpacing.xs, top: AppSpacing.xs),
                padding: HtmlPaddings.only(bottom: AppSpacing.xs),
              ),
              'h2': Style(
                color: colorScheme.onSurface,
                fontSize: FontSize(AppTypography.sizeXL),
                fontWeight: AppTypography.weightSemiBold,
                margin: Margins.only(bottom: AppSpacing.xs, top: AppSpacing.xs),
                padding: HtmlPaddings.only(left: AppSpacing.sm),
              ),
              'h3': Style(
                color: colorScheme.onSurface,
                fontSize: FontSize(AppTypography.sizeLG),
                fontWeight: AppTypography.weightSemiBold,
                margin: Margins.only(bottom: AppSpacing.xs, top: AppSpacing.xs),
              ),
              'h4': Style(
                color: colorScheme.onSurface,
                fontSize: FontSize(AppTypography.sizeMD),
                fontWeight: AppTypography.weightSemiBold,
                margin: Margins.only(bottom: AppSpacing.xs, top: AppSpacing.xs),
              ),

              // 段落样式
              'p': Style(
                margin: Margins.only(bottom: AppSpacing.xs),
                lineHeight: const LineHeight(1.6),
              ),

              // 链接样式
              'a': Style(
                color: colorScheme.primary,
                textDecoration: TextDecoration.underline,
                textDecorationColor: colorScheme.primary,
                fontWeight: AppTypography.weightMedium,
              ),

              // 行内代码样式
              'code': Style(
                backgroundColor: colorScheme.surfaceContainerHighest,
                color: colorScheme.primary,
                padding: HtmlPaddings.symmetric(horizontal: 6, vertical: 3),
                fontFamily: 'monospace',
                fontSize: FontSize(AppTypography.sizeSM - 1),
              ),

              // 代码块样式
              'pre': Style(
                backgroundColor: AppColors.codeEditorBackground,
                color: AppColors.codeEditorText,
                padding: HtmlPaddings.all(AppSpacing.md),
                margin: Margins.only(bottom: AppSpacing.md),
                fontFamily: 'monospace',
                fontSize: FontSize(AppTypography.sizeSM),
              ),

              // 引用块样式
              'blockquote': Style(
                border: Border(
                  left: BorderSide(
                    color: colorScheme.primary,
                    width: 4,
                  ),
                ),
                padding: HtmlPaddings.only(left: AppSpacing.md),
                margin: Margins.symmetric(vertical: AppSpacing.xs),
                color: colorScheme.onSurfaceVariant
                    .withAlpha(AppColors.alphaMedium),
                backgroundColor: colorScheme.surfaceContainerHighest
                    .withAlpha(AppColors.alphaLowest),
              ),

              // 列表样式
              'ul': Style(
                margin:
                    Margins.only(bottom: AppSpacing.xs, left: AppSpacing.md),
              ),
              'ol': Style(
                margin:
                    Margins.only(bottom: AppSpacing.xs, left: AppSpacing.md),
              ),
              'li': Style(
                margin: Margins.only(bottom: AppSpacing.xs),
                lineHeight: const LineHeight(1.6),
              ),

              // 表格样式
              'table': Style(
                width: Width(double.infinity),
                border: Border.all(
                  color: colorScheme.outline.withAlpha(AppColors.alphaLower),
                  width: 1,
                ),
                margin: Margins.only(bottom: AppSpacing.xs),
              ),
              'th': Style(
                backgroundColor: colorScheme.surfaceContainerHighest,
                color: colorScheme.onSurface,
                padding: HtmlPaddings.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                fontWeight: AppTypography.weightSemiBold,
                textAlign: TextAlign.center,
              ),
              'td': Style(
                padding: HtmlPaddings.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                border: Border(
                  top: BorderSide(
                    color: colorScheme.outline.withAlpha(AppColors.alphaLower),
                    width: 1,
                  ),
                ),
              ),

              // 图片样式
              'img': Style(
                margin: Margins.symmetric(vertical: AppSpacing.xs),
              ),

              // 分隔线样式
              'hr': Style(
                border: Border(
                  bottom: BorderSide(
                    color: colorScheme.outlineVariant
                        .withAlpha(AppColors.alphaLower),
                    width: 1,
                  ),
                ),
                margin: Margins.symmetric(vertical: AppSpacing.sm),
              ),

              // 强调文本
              'strong': Style(
                fontWeight: AppTypography.weightSemiBold,
                color: colorScheme.onSurface,
              ),
              'b': Style(
                fontWeight: AppTypography.weightSemiBold,
                color: colorScheme.onSurface,
              ),

              // 斜体文本
              'em': Style(
                fontStyle: FontStyle.italic,
              ),
              'i': Style(
                fontStyle: FontStyle.italic,
              ),

              // 删除线
              'del': Style(
                textDecoration: TextDecoration.lineThrough,
                color: colorScheme.onSurfaceVariant
                    .withAlpha(AppColors.alphaMedium),
              ),
              's': Style(
                textDecoration: TextDecoration.lineThrough,
                color: colorScheme.onSurfaceVariant
                    .withAlpha(AppColors.alphaMedium),
              ),
            },
            shrinkWrap: true,
          ),
      ],
    );
  }
}

/// 下载链接 Section
class DownloadsSection extends StatelessWidget {
  final IDetailInfo info;
  final void Function(DownloadInfo)? onDownloadTap;
  final void Function(DownloadInfo)? onLongPress;

  const DownloadsSection({
    super.key,
    required this.info,
    this.onDownloadTap,
    this.onLongPress,
  });

  /// 过滤出当前平台的可下载文件
  /// 只显示 .apk、.aab (Android App Bundle) 或 .zip 文件
  List<DownloadInfo> _filterPlatformDownloads(List<DownloadInfo> downloads) {
    return downloads.where((download) {
      final fileName = download.name.toLowerCase();
      // 检查文件扩展名
      if (fileName.endsWith('.apk')) return true;
      if (fileName.endsWith('.aab')) return true; // Android App Bundle
      if (fileName.endsWith('.zip')) {
        // zip 文件需要进一步检查名称
        // 通常包含 "universal", "android", "arm" 等关键词的是 Android 包
        final keywords = ['universal', 'android', 'arm', 'mobile', 'app'];
        return keywords.any((keyword) => fileName.contains(keyword));
      }
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
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
            border: Border.all(
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
                      ],
                    ),
                  ),
                  // 下载按钮
                  if (onTap != null)
                    InkWell(
                      onTap: () => onTap!(download),
                      borderRadius: AppRadius.allXL,
                      child: Container(
                        padding: AppSpacing.allSM,
                        child: Icon(
                          Icons.download_rounded,
                          size: AppTypography.iconLG,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
              // 详细信息行
              SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  if (download.size != null)
                    _buildInfoChip(
                      context,
                      Icons.sd_card,
                      download.formattedSize,
                      Colors.blue,
                    ),
                  if (download.size != null) const SizedBox(width: 8),
                  if (download.platform != null)
                    _buildInfoChip(
                      context,
                      Icons.phone_android,
                      download.platform!,
                      Colors.green,
                    ),
                  const Spacer(),
                  if (download.downloadCount != null)
                    _buildInfoChip(
                      context,
                      Icons.cloud_download,
                      _formatNumber(download.downloadCount!),
                      Colors.orange,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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

  String _formatNumber(int num) {
    if (num >= 1000000) return '${(num / 1000000).toStringAsFixed(1)}M';
    if (num >= 1000) return '${(num / 1000).toStringAsFixed(1)}K';
    return '$num';
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
    final developer = info.developer;
    final projectUrl = info.projectUrl;
    final version = info.version;
    final channelId = info.channelId;

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
    final changelog = info.changelog;
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
    final permissions = info.permissions;
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
