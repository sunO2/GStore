/// 详情页面可复用的 Section 组件
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_html/src/extension/html_extension.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/core.dart';

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

/// README 图片组件
class _ReadmeImage extends StatelessWidget {
  final String url;
  final BuildContext buildContext;

  const _ReadmeImage({required this.url, required this.buildContext});

  /// GitHub 相关图片 URL 应用代理
  String get _proxiedUrl {
    final proxied = applyProxyIfNeeded(url, getProxy());
    debugPrint('ReadmeImage: url=$url proxied=$proxied proxy=${getProxy().isEmpty ? '(空)' : getProxy()}');
    return proxied;
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
              child: CachedNetworkImage(
                imageUrl: _proxiedUrl,
                fit: BoxFit.contain,
                placeholder: (context, url) => const Center(
                  child: CircularProgressIndicator(),
                ),
                errorWidget: (context, url, error) => const Icon(
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
    final maxWidth = MediaQuery.of(context).size.width - AppSpacing.lg * 2;

    return GestureDetector(
      onTap: () => _preview(buildContext),
      child: ClipRRect(
        borderRadius: AppRadius.allMD,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: maxWidth * 0.8,
          ),
          child: CachedNetworkImage(
            imageUrl: _proxiedUrl,
            fit: BoxFit.contain,
            placeholder: (context, url) => Container(
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
            errorWidget: (context, url, error) => Container(
              height: 60,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.broken_image_outlined),
            ),
          ),
        ),
      ),
    );
  }
}

/// 版本信息 Section
class VersionSection extends StatelessWidget {
  final IDetailInfo info;

  const VersionSection({super.key, required this.info});
  @override
  Widget build(BuildContext context) {
    if (info.version == null && info.packageName == null) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: AppSpacing.onlyBottomSM,
      padding: AppSpacing.allLG,
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(AppColors.alphaMedium),
        ),
        borderRadius: AppRadius.allLG,
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (info.version != null) ...[
            Text(
              '版本',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
            ),
            SizedBox(height: AppSpacing.sm),
            Text(
              info.version!,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
          if (info.version != null && info.packageName != null)
            SizedBox(height: AppSpacing.md),
          if (info.packageName != null) ...[
            Text(
              '包名',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
            ),
            SizedBox(height: AppSpacing.sm),
            Text(
              info.packageName!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final Widget icon;
  final String label;
  final String value;
  final Widget? trailing;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: AppSpacing.horizontalSM_verticalXS,
      decoration: BoxDecoration(
        border: Border.all(
          width: 1.0,
          color: Theme.of(context).colorScheme.primaryFixed.withAlpha(AppColors.alphaLower),
        ),
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: AppRadius.allSM,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: TextStyle(
              fontSize: AppTypography.sizeXXS,
              fontWeight: AppTypography.weightMedium,
            ),
          ),
          SizedBox(width: AppSpacing.xs),
          Container(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm * 1.5, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryFixed.withAlpha(AppColors.alphaLowest),
              borderRadius: AppRadius.allMD,
            ),
            child: Text(
              value,
              style: TextStyle(
                fontSize: AppTypography.sizeXXS,
                fontWeight: AppTypography.weightMedium,
              ),
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: AppSpacing.xs),
            trailing!,
          ],
        ],
      ),
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

    return Container(
      margin: AppSpacing.onlyBottomSM,
      padding: AppSpacing.allLG,
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(AppColors.alphaMedium),
        ),
        borderRadius: AppRadius.allLG,
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '应用截图',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
          ),
          SizedBox(height: AppSpacing.md),
          SizedBox(
            height: 200,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: screenshots.length,
              itemBuilder: (context, index) {
                final screenshot = screenshots[index];
                return Container(
                  width: 120,
                  margin: AppSpacing.onlyRightMD,
                  child: ClipRRect(
                    borderRadius: AppRadius.allMD,
                    child: CachedNetworkImage(
                      imageUrl: screenshot.url,
                      fit: BoxFit.contain,
                      placeholder: (context, url) => Container(
                        color: AppColors.grey200,
                        child: const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: AppColors.grey300,
                        child: const Icon(Icons.broken_image),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
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
    if (readme == null || readme.isEmpty) {
      return const SizedBox.shrink();
    }

    // 将 Markdown 转换为 HTML
    final htmlContent = md.markdownToHtml(
      readme,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      margin: EdgeInsets.only(bottom: AppSpacing.md),
      padding: EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: colorScheme.primary.withAlpha(AppColors.alphaLow),
        ),
        borderRadius: AppRadius.allLG,
        color: colorScheme.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '详细介绍',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: AppTypography.weightSemiBold,
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: AppSpacing.md),
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
                backgroundColor: colorScheme.primaryContainer.withAlpha(AppColors.alphaLowest),
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
                color: colorScheme.onSurfaceVariant.withAlpha(AppColors.alphaMedium),
                backgroundColor: colorScheme.surfaceContainerHighest.withAlpha(AppColors.alphaLowest),
              ),

              // 列表样式
              'ul': Style(
                margin: Margins.only(bottom: AppSpacing.xs, left: AppSpacing.md),
              ),
              'ol': Style(
                margin: Margins.only(bottom: AppSpacing.xs, left: AppSpacing.md),
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
                backgroundColor: colorScheme.primaryContainer.withAlpha(AppColors.alphaLowest),
                color: colorScheme.onPrimaryContainer,
                padding: HtmlPaddings.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                fontWeight: AppTypography.weightSemiBold,
                textAlign: TextAlign.center,
              ),
              'td': Style(
                padding: HtmlPaddings.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
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
                    color: colorScheme.outlineVariant.withAlpha(AppColors.alphaLower),
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
                color: colorScheme.onSurfaceVariant.withAlpha(AppColors.alphaMedium),
              ),
              's': Style(
                textDecoration: TextDecoration.lineThrough,
                color: colorScheme.onSurfaceVariant.withAlpha(AppColors.alphaMedium),
              ),
            },
            shrinkWrap: true,
          ),
        ],
      ),
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
    // 过滤出当前平台的文件
    final filteredDownloads = _filterPlatformDownloads(info.downloads);

    if (filteredDownloads.isEmpty) {
      return Container(
        margin: AppSpacing.onlyBottomSM,
        padding: AppSpacing.allLG,
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: AppTypography.iconMD,
              color: AppColors.grey600,
            ),
            SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                info.downloads.isEmpty
                    ? '该应用暂无可下载文件'
                    : '该应用暂无适配当前平台的文件',
                style: TextStyle(
                  color: AppColors.grey600,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: AppSpacing.onlyBottomSM,
      padding: AppSpacing.allLG,
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(AppColors.alphaMedium),
        ),
        borderRadius: AppRadius.allLG,
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.download_rounded,
                    size: AppTypography.iconMD,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  SizedBox(width: AppSpacing.sm),
                  Text(
                    '下载文件',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: AppTypography.weightSemiBold,
                        ),
                  ),
                  SizedBox(width: AppSpacing.xs),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm * 1.5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: AppRadius.allMD,
                    ),
                    child: Text(
                      '${filteredDownloads.length} 个文件',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: AppTypography.sizeXXS,
                          ),
                    ),
                  ),
                ],
              ),
              if (filteredDownloads.first.publishedAt != null)
                Text(
                  '更新于 ${_formatDate(filteredDownloads.first.publishedAt!)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: AppTypography.sizeXXS,
                        color: AppColors.grey600,
                      ),
                ),
            ],
          ),
          SizedBox(height: AppSpacing.md),
          ...filteredDownloads.map((download) => _DownloadItem(
                download: download,
                onTap: onDownloadTap,
                onLongPress: onLongPress,
              )),
        ],
      ),
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
                Theme.of(context).colorScheme.primaryContainer,
                Theme.of(context).colorScheme.primaryContainer.withAlpha(AppColors.alphaMedium),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withAlpha(AppColors.alphaLower),
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
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
                                color: AppColors.grey600,
                              ),
                              SizedBox(width: AppSpacing.xs),
                              Text(
                                download.version!,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: AppColors.grey600,
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
      padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm * 1.5, vertical: AppSpacing.xs),
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

/// 开发者信息 Section
class DeveloperSection extends StatelessWidget {
final IDetailInfo info;

  const DeveloperSection({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    if (info.developer == null && info.projectUrl == null) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: AppSpacing.onlyBottomSM,
      padding: AppSpacing.allLG,
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(130),
        ),
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (info.developer != null) ...[
            Text(
              '开发者',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              info.developer!,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
          if (info.developer != null && info.projectUrl != null)
            const SizedBox(height: 12),
          if (info.projectUrl != null) ...[
            Text(
              '项目主页',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              info.projectUrl!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ],
        ],
      ),
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

    return Container(
      margin: AppSpacing.onlyBottomSM,
      padding: AppSpacing.allLG,
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(AppColors.alphaMedium),
        ),
        borderRadius: AppRadius.allLG,
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '更新日志',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
          ),
          SizedBox(height: AppSpacing.md),
          Text(
            changelog,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
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

    return Container(
      margin: AppSpacing.onlyBottomSM,
      padding: AppSpacing.allLG,
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(AppColors.alphaMedium),
        ),
        borderRadius: AppRadius.allLG,
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '权限说明',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
          ),
          SizedBox(height: AppSpacing.md),
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
      ),
    );
  }
}
