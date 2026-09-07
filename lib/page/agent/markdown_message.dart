import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:markdown/markdown.dart' as md;

/// 对话消息 Markdown 渲染组件（增强版）
///
/// 增强能力：
/// - 代码块：语言标签、复制按钮、深色主题、圆角、行内滚动
/// - 图片：圆角、加载占位、点击全屏预览
/// - 链接：主题色 + 下划线，点击跳转内置浏览器
/// - 表格：表头高亮、边框、斑马纹
/// - 行内代码：胶囊背景样式
/// - 引用块：左侧竖线 + 淡背景
class AgentMarkdownMessage extends StatelessWidget {
  final String text;

  const AgentMarkdownMessage({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final styleSheet = MarkdownStyleSheet(
      // 段落
      p: TextStyle(
        fontSize: 14,
        height: 1.6,
        color: scheme.onSurface,
      ),
      pPadding: const EdgeInsets.symmetric(vertical: 2),

      // 标题
      h1: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: scheme.onSurface,
        height: 1.4,
      ),
      h2: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
        height: 1.4,
      ),
      h3: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
        height: 1.4,
      ),
      h4: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
        height: 1.4,
      ),
      h1Padding: const EdgeInsets.only(top: 14, bottom: 6),
      h2Padding: const EdgeInsets.only(top: 12, bottom: 6),
      h3Padding: const EdgeInsets.only(top: 10, bottom: 4),
      h4Padding: const EdgeInsets.only(top: 8, bottom: 4),

      // 强调
      strong: TextStyle(
        fontWeight: FontWeight.w700,
        color: scheme.primary,
      ),
      em: TextStyle(fontStyle: FontStyle.italic),
      del: TextStyle(decoration: TextDecoration.lineThrough),

      // 行内代码
      code: TextStyle(
        fontSize: 13,
        fontFamily: 'monospace',
        color: scheme.primary,
        backgroundColor: scheme.primaryContainer.withAlpha(60),
      ),

      // 代码块
      codeblockPadding: EdgeInsets.zero,
      codeblockDecoration: const BoxDecoration(),

      // 引用块
      blockquote: TextStyle(
        fontSize: 13.5,
        height: 1.5,
        color: scheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      blockquoteDecoration: BoxDecoration(
        color: scheme.primaryContainer.withAlpha(40),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(color: scheme.primary, width: 3),
        ),
      ),

      // 列表
      listBullet: TextStyle(
        fontSize: 14,
        color: scheme.primary,
        fontWeight: FontWeight.bold,
      ),
      listBulletPadding: const EdgeInsets.only(right: 6),
      listIndent: 20,

      // 链接
      a: TextStyle(
        fontSize: 14,
        color: scheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: scheme.primary.withAlpha(120),
        fontWeight: FontWeight.w500,
      ),

      // 表格
      tableBorder: TableBorder.all(
        color: scheme.outlineVariant.withAlpha(120),
        borderRadius: BorderRadius.circular(8),
      ),
      tableHead: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: scheme.onPrimaryContainer,
      ),
      tableBody: TextStyle(
        fontSize: 13,
        color: scheme.onSurface,
        height: 1.4,
      ),
      tableHeadAlign: TextAlign.center,
      tableCellsPadding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 7,
      ),
      tableColumnWidth: const FlexColumnWidth(),

      // 分隔线
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
    );

    return MarkdownBody(
      data: text,
      styleSheet: styleSheet,
      onTapLink: (text, href, title) {
        if (href != null && href.isNotEmpty) {
          _openLink(context, href);
        }
      },
      imageBuilder: (uri, title, alt) {
        return _buildImage(context, uri);
      },
      builders: {
        'pre': _CodeBlockBuilder(),
        'table': _StyledTableBuilder(scheme),
      },
      selectable: true,
    );
  }

  /// 图片：圆角 + 点击全屏预览
  /// GitHub 相关域名走代理
  Widget _buildImage(BuildContext context, Uri uri) {
    final scheme = Theme.of(context).colorScheme;
    final imageUrl = _proxiedImageUrl(uri);
    return GestureDetector(
      onTap: () => _previewImage(context, uri),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: imageUrl,
          fit: BoxFit.fitWidth,
          placeholder: (context, url) => Container(
            height: 120,
            color: scheme.surfaceContainerHighest,
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          errorWidget: (context, url, error) => Container(
            height: 80,
            color: scheme.surfaceContainerHighest,
            child: const Icon(Icons.broken_image_outlined),
          ),
        ),
      ),
    );
  }

  /// GitHub 相关图片 URL 应用代理
  String _proxiedImageUrl(Uri uri) {
    final url = uri.toString();
    final proxied = applyProxyIfNeeded(url, getProxy());
    debugPrint('AgentMarkdown 图片: url=$url proxied=$proxied proxy=${getProxy().isEmpty ? '(空)' : getProxy()}');
    return proxied;
  }

  /// 图片全屏预览
  void _previewImage(BuildContext context, Uri uri) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.black87,
        child: GestureDetector(
          onTap: () => Navigator.of(dialogContext).pop(),
          child: InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: CachedNetworkImage(
                imageUrl: _proxiedImageUrl(uri),
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

  /// 打开链接（用内置浏览器）
  void _openLink(BuildContext context, String url) {
    // 相对链接补全
    if (url.startsWith('#')) return;
    if (url.startsWith('mailto:')) return;

    context.push(AppRoute.webView, extra: {
      'url': url,
      'title': '链接',
    });
  }
}

/// 代码块构建器：语言标签 + 复制按钮 + 深色主题
class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final text = element.textContent;
    if (text.trim().isEmpty) return const SizedBox.shrink();

    // 提取语言（pre > code[class="language-xx"]）
    String language = '';
    for (final child in element.children ?? const <Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        final cls = child.attributes['class'] ?? '';
        final idx = cls.indexOf('language-');
        if (idx >= 0) {
          language = cls.substring(idx + 'language-'.length).trim();
        }
        break;
      }
    }

    // 去掉结尾多余换行
    final code = text.replaceFirst(RegExp(r'\n+$'), '');

    return _CodeBlock(text: code, language: language);
  }
}

/// 代码块展示组件
class _CodeBlock extends StatefulWidget {
  final String text;
  final String language;

  const _CodeBlock({required this.text, required this.language});

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (mounted) {
      setState(() => _copied = true);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: _codeBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withAlpha(12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶栏：语言标签 + 复制按钮
          Container(
            color: Colors.white.withAlpha(10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                if (widget.language.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withAlpha(80),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.language,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  const Icon(
                    Icons.code,
                    size: 14,
                    color: Colors.white54,
                  ),
                const Spacer(),
                InkWell(
                  onTap: _copy,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied ? Icons.check : Icons.copy,
                          size: 14,
                          color: _copied
                              ? const Color(0xFF7CF29C)
                              : Colors.white60,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _copied ? '已复制' : '复制',
                          style: TextStyle(
                            fontSize: 11,
                            color: _copied
                                ? const Color(0xFF7CF29C)
                                : Colors.white60,
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
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              widget.text,
              style: const TextStyle(
                fontSize: 12.5,
                fontFamily: 'monospace',
                height: 1.5,
                color: Color(0xFFE6E6E6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 深色代码背景
const Color _codeBackground = Color(0xFF1E1E2E);

/// 表格构建器：斑马纹行
class _StyledTableBuilder extends MarkdownElementBuilder {
  _StyledTableBuilder(this.scheme);

  final ColorScheme scheme;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final scheme = this.scheme;

    // 解析表格
    final rows = <List<md.Element>>[];
    for (final child in element.children ?? const <Node>[]) {
      if (child is! md.Element) continue;
      if (child.tag == 'thead' || child.tag == 'tbody') {
        for (final tr in child.children ?? const <Node>[]) {
          if (tr is md.Element && tr.tag == 'tr') {
            final cells = tr.children
                ?.whereType<md.Element>()
                .where((c) => c.tag == 'th' || c.tag == 'td')
                .toList();
            if (cells != null) rows.add(cells);
          }
        }
      } else if (child.tag == 'tr') {
        final cells = child.children
            ?.whereType<md.Element>()
            .where((c) => c.tag == 'th' || c.tag == 'td')
            .toList();
        if (cells != null) rows.add(cells);
      }
    }

    if (rows.isEmpty) return null;

    final colCount = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withAlpha(120)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Table(
        columnWidths: {
          for (var i = 0; i < colCount; i++) i: const FlexColumnWidth(),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        border: TableBorder(
          horizontalInside: BorderSide(
            color: scheme.outlineVariant.withAlpha(60),
            width: 0.5,
          ),
          verticalInside: BorderSide(
            color: scheme.outlineVariant.withAlpha(40),
            width: 0.5,
          ),
        ),
        children: [
          for (var r = 0; r < rows.length; r++)
            TableRow(
              decoration: BoxDecoration(
                color: r == 0
                    ? scheme.primaryContainer.withAlpha(80)
                    : (r.isEven
                        ? Colors.transparent
                        : scheme.surfaceContainerHighest.withAlpha(50)),
              ),
              children: [
                for (var c = 0; c < colCount; c++)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    child: _renderCell(rows[r], c, r == 0),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _renderCell(List<md.Element> row, int index, bool isHeader) {
    if (index >= row.length) {
      return const SizedBox.shrink();
    }
    final cell = row[index];
    final text = cell.textContent;

    // 从子节点构建富文本（支持行内 markdown）
    final children = cell.children;
    if (children != null && children.isNotEmpty) {
      final spans = <TextSpan>[];
      for (final node in children) {
        if (node is md.Text) {
          spans.add(TextSpan(text: node.text));
        } else if (node is md.Element) {
          spans.add(TextSpan(
            text: node.textContent,
            style: _cellInlineStyle(node.tag),
          ));
        }
      }
      return Text.rich(
        TextSpan(children: spans),
        style: TextStyle(
          fontSize: isHeader ? 13 : 12.5,
          fontWeight: isHeader ? FontWeight.w700 : FontWeight.w400,
          color: schemeOnSurface(isHeader),
        ),
      );
    }

    return Text(
      text,
      style: TextStyle(
        fontSize: isHeader ? 13 : 12.5,
        fontWeight: isHeader ? FontWeight.w700 : FontWeight.w400,
        color: schemeOnSurface(isHeader),
      ),
    );
  }

  TextStyle? _cellInlineStyle(String tag) {
    final primary = scheme.primary;
    switch (tag) {
      case 'strong':
      case 'b':
        return const TextStyle(fontWeight: FontWeight.w700);
      case 'em':
      case 'i':
        return const TextStyle(fontStyle: FontStyle.italic);
      case 'code':
        return TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: primary,
        );
      case 'a':
        return TextStyle(
          color: primary,
          decoration: TextDecoration.underline,
        );
      default:
        return null;
    }
  }

  Color schemeOnSurface(bool isHeader) {
    return isHeader ? scheme.onPrimaryContainer : scheme.onSurface;
  }
}
