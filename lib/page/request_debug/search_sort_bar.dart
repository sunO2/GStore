/// 「请求调试」各分区共用的搜索框 + 排序菜单（plan todo 15）。
///
/// 纯展示组件：不自持查询状态，由分区注入 [controller] / [query] / [sort] 并
/// 回传变更。搜索框复用设计系统 [AppTextField]（**不修改**该共享组件），排序
/// 走紧凑 [PopupMenuButton]；颜色 / 字号全取主题令牌。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/request_debug/debug_search.dart';

/// 分区搜索 + 排序条。
class DebugSearchSortBar extends StatelessWidget {
  const DebugSearchSortBar({
    super.key,
    required this.sectionId,
    required this.hint,
    required this.query,
    required this.sort,
    required this.onQueryChanged,
    required this.onSortChanged,
    this.controller,
    this.padding,
  });

  /// 分区 id 前缀，用于生成稳定测试键（`<id>-search` / `<id>-sort`）。
  final String sectionId;

  /// 搜索框提示文案。
  final String hint;

  /// 当前查询串（用于显示清除按钮）。
  final String query;

  /// 当前排序。
  final DebugSortOrder sort;

  /// 查询变更回调（含清除）。
  final ValueChanged<String> onQueryChanged;

  /// 排序变更回调。
  final ValueChanged<DebugSortOrder> onSortChanged;

  /// 可选外部控制器（便于分区测试注入 / 清空）。
  final TextEditingController? controller;

  /// 可选外边距。
  final EdgeInsetsGeometry? padding;

  void _clear() {
    controller?.clear();
    onQueryChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasQuery = query.trim().isNotEmpty;
    return Padding(
      padding: padding ??
          const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
      child: Row(
        children: [
          Expanded(
            child: AppTextField(
              key: Key('$sectionId-search'),
              controller: controller,
              hint: hint,
              prefixIcon: TablerIcons.search,
              suffixIcon: hasQuery ? TablerIcons.x : null,
              onSuffixIconPressed: hasQuery ? _clear : null,
              textInputAction: TextInputAction.search,
              onChanged: onQueryChanged,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          PopupMenuButton<DebugSortOrder>(
            key: Key('$sectionId-sort'),
            tooltip: '排序',
            icon: Icon(
              TablerIcons.arrows_sort,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            initialValue: sort,
            onSelected: onSortChanged,
            itemBuilder: (_) => [
              for (final order in DebugSortOrder.values)
                PopupMenuItem<DebugSortOrder>(
                  key: Key('$sectionId-sort-${order.wire}'),
                  value: order,
                  child: Text(order.label),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
