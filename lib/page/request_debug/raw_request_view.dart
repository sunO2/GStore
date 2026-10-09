/// 「请求调试」原始请求视图（plan todo 18）。
///
/// 把 [DebugRequest] 草稿渲染为可读的原始 HTTP 请求文本（方法 / 完整 URL /
/// 启用的请求头 / 请求体），供发送前核对。纯展示、无副作用。
///
/// 设计约束：字号取 [AppTypography]，零硬编码颜色 / 字号。
library;

import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

/// 原始请求文本视图。
class RawRequestView extends StatelessWidget {
  const RawRequestView({super.key, this.request});

  /// 待展示的请求草稿；`null` 表示无内容。
  final DebugRequest? request;

  @override
  Widget build(BuildContext context) {
    final request = this.request;
    if (request == null) return _empty(context);
    return SingleChildScrollView(
      padding: AppSpacing.allLG,
      child: SelectableText(
        composeRawRequest(request),
        key: const Key('raw-request-text'),
        style: AppTypography.code,
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: const Key('raw-request-empty'),
      child: Text(
        '暂无可预览的请求',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
