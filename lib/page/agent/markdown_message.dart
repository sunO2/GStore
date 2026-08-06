import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';

/// 对话消息 Markdown 渲染组件
/// 支持：
/// - 完整 Markdown 语法（标题、列表、代码块、加粗等）
/// - 链接点击跳转到内置浏览器
/// - 自动根据主题适配样式
class AgentMarkdownMessage extends StatelessWidget {
  final String text;

  const AgentMarkdownMessage({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 选择适合主题的文字颜色
    final textColor = theme.colorScheme.onSurface;

    final styleSheet = MarkdownStyleSheet(
      p: TextStyle(
        fontSize: 14,
        height: 1.5,
        color: textColor,
      ),
      h1: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: textColor,
        height: 1.4,
      ),
      h2: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.bold,
        color: textColor,
        height: 1.4,
      ),
      h3: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: textColor,
        height: 1.4,
      ),
      strong: TextStyle(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.primary,
      ),
      em: TextStyle(
        fontStyle: FontStyle.italic,
        color: textColor,
      ),
      code: TextStyle(
        fontSize: 13,
        fontFamily: 'monospace',
        color: theme.colorScheme.primary,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
      codeblockDecoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      blockquote: TextStyle(
        fontSize: 14,
        height: 1.5,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      blockquoteDecoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
        border: Border(
          left: BorderSide(
            color: theme.colorScheme.primary,
            width: 3,
          ),
        ),
      ),
      listBullet: TextStyle(
        fontSize: 14,
        color: theme.colorScheme.primary,
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant,
            width: 1,
          ),
        ),
      ),
    );

    return MarkdownBody(
      data: text,
      styleSheet: styleSheet,
      onTapLink: (text, href, title) {
        if (href != null && href.isNotEmpty) {
          _openLink(href);
        }
      },
      imageBuilder: (uri, title, alt) {
        return Image.network(
          uri.toString(),
          fit: BoxFit.fitWidth,
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        );
      },
      selectable: true,
    );
  }

  /// 打开链接（用内置浏览器）
  void _openLink(String url) {
    // 相对链接补全
    if (url.startsWith('#')) return;

    Get.toNamed(AppRoute.webView, arguments: {
      'url': url,
      'title': '链接',
    });
  }
}
