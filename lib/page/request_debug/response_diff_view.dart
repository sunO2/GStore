/// 「请求调试」响应 diff 视图（plan todo 18）。
///
/// 对两条历史响应快照的 Body 文本做按行 diff 并高亮：新增行用
/// `primaryContainer`、删除行用 `errorContainer`、未变行无色。无历史（两个
/// 快照均为空）时展示空态。
///
/// 设计约束：颜色 / 字号全取主题令牌（[Theme.of] / [AppTypography]），零硬编码。
library;

import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

/// 两条响应快照的按行 diff 视图。
class ResponseDiffView extends StatelessWidget {
  const ResponseDiffView({super.key, this.before, this.after});

  /// 「旧」侧快照（`null` = 无历史）。
  final DebugResponseSnapshot? before;

  /// 「新」侧快照（`null` = 无历史）。
  final DebugResponseSnapshot? after;

  bool get _hasHistory => before != null || after != null;

  @override
  Widget build(BuildContext context) {
    if (!_hasHistory) return _empty(context);
    final lines = diffResponseLines(before?.bodyText, after?.bodyText);
    if (lines.isEmpty) return _empty(context);
    return ListView.builder(
      key: const Key('response-diff-list'),
      padding: AppSpacing.allLG,
      itemCount: lines.length,
      itemBuilder: (context, index) => _buildLine(context, lines[index], index),
    );
  }

  Widget _buildLine(BuildContext context, DiffLine line, int index) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (Color? background, Color foreground, String sign) = switch (line.kind) {
      DiffLineKind.added => (
          scheme.primaryContainer,
          scheme.onPrimaryContainer,
          '+',
        ),
      DiffLineKind.removed => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          '-',
        ),
      DiffLineKind.unchanged => (null, scheme.onSurface, ' '),
    };
    return Container(
      key: Key('response-diff-${line.kind.name}-$index'),
      color: background,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: AppSpacing.lg,
            child: Text(
              sign,
              style: AppTypography.code.copyWith(
                color: foreground,
                fontWeight: AppTypography.weightSemiBold,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              line.text.isEmpty ? ' ' : line.text,
              style: AppTypography.code.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: const Key('response-diff-empty'),
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.compare_arrows,
              size: AppTypography.iconXXXL,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('无可对比的历史响应', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '至少发送两次请求后，才能对比两条历史响应。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
