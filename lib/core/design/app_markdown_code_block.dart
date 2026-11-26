import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_code_view.dart';
import 'package:gstore/core/design/app_colors.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/editor/app_code_language.dart';

/// Markdown 代码块（README / AI 消息共用）。
///
/// 工具栏（语言标签 + 复制）+ re_editor 只读代码视图；高亮按围栏语言推断。
/// 超过 [maxHeight] 时内部纵向滚动，长行横向滚动。
class AppMarkdownCodeBlock extends StatefulWidget {
  const AppMarkdownCodeBlock({
    super.key,
    required this.code,
    this.language = '',
    this.showLineNumbers = false,
    this.maxHeight = 420,
  });

  final String code;

  /// Markdown 围栏语言标识（```dart 中的 dart）。
  final String language;

  final bool showLineNumbers;
  final double maxHeight;

  @override
  State<AppMarkdownCodeBlock> createState() => _AppMarkdownCodeBlockState();
}

class _AppMarkdownCodeBlockState extends State<AppMarkdownCodeBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    AppDialogs.showSuccess('代码已复制');
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  double _contentHeight() {
    const fontSize = 12.5;
    final lineHeight = fontSize * (AppTypography.code.height ?? 1.4);
    final lines = widget.code.split('\n').length;
    // +20 覆盖上下内边距与横向滚动条。
    return (lines * lineHeight + 20).clamp(64.0, widget.maxHeight).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final language = AppCodeLanguage.forName(widget.language);
    const textColor = AppColors.codeEditorText;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      decoration: const BoxDecoration(
        color: AppColors.codeEditorBackground,
        borderRadius: AppRadius.allMD,
        border: Border.fromBorderSide(
          BorderSide(color: AppColors.codeEditorBorder),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: AppColors.codeEditorToolbar,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              children: [
                if (widget.language.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: 2,
                    ),
                    decoration: const BoxDecoration(
                      color: AppColors.codeEditorBorder,
                      borderRadius: AppRadius.allSM,
                    ),
                    child: Text(
                      widget.language,
                      style: const TextStyle(
                        fontSize: AppTypography.sizeXS,
                        fontWeight: AppTypography.weightSemiBold,
                        color: textColor,
                      ),
                    ),
                  )
                else
                  Icon(
                    TablerIcons.code,
                    size: AppTypography.iconSM,
                    color: textColor.withValues(alpha: 0.7),
                  ),
                const Spacer(),
                InkWell(
                  onTap: _copy,
                  borderRadius: AppRadius.allSM,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied ? TablerIcons.check : TablerIcons.copy,
                          size: AppTypography.iconSM,
                          color: _copied
                              ? AppColors.success
                              : textColor.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          _copied ? '已复制' : '复制',
                          style: TextStyle(
                            fontSize: AppTypography.sizeXS,
                            color: _copied
                                ? AppColors.success
                                : textColor.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: _contentHeight(),
            child: AppCodeView(
              text: widget.code,
              language: language,
              readOnly: true,
              showLineNumbers: widget.showLineNumbers,
              wordWrap: false,
              dark: true,
              initialFontSize: 12.5,
              minFontSize: 9,
              maxFontSize: 24,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
