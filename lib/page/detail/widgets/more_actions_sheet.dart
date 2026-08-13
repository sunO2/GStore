import 'package:flutter/material.dart';
import 'package:gstore/core/design/design_tokens.dart';

/// 更多操作项（宫格中的一个动作）
class MoreActionItem {
  const MoreActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// 展示详情页"更多"底部面板
///
/// 顶部：应用名 + 当前标签
/// 中部：分类标签编辑（与发现页同一套标签系统，预置 FilterChip + 自定义输入）
/// 底部：动作宫格（完善应用信息 / 项目主页等）
///
/// [appName] 应用名称（面板标题）
/// [presetTags] 预置分类标签（本地库 AppCategory.description，失败时使用内置列表）
/// [currentTags] 应用当前已有的标签
/// [actions] 宫格动作列表
///
/// 返回用户确认后的标签列表；取消、点击遮罩关闭或点击动作返回 null。
Future<List<String>?> showMoreActionsSheet(
  BuildContext context, {
  required String appName,
  required List<String> presetTags,
  required List<String> currentTags,
  required List<MoreActionItem> actions,
}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.dialogSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.radiusSheet),
      ),
    ),
    builder: (context) => _MoreActionsSheet(
      appName: appName,
      presetTags: presetTags,
      currentTags: currentTags,
      actions: actions,
    ),
  );
}

class _MoreActionsSheet extends StatefulWidget {
  const _MoreActionsSheet({
    required this.appName,
    required this.presetTags,
    required this.currentTags,
    required this.actions,
  });

  final String appName;
  final List<String> presetTags;
  final List<String> currentTags;
  final List<MoreActionItem> actions;

  @override
  State<_MoreActionsSheet> createState() => _MoreActionsSheetState();
}

class _MoreActionsSheetState extends State<_MoreActionsSheet> {
  late final Set<String> _selectedTags;
  final TextEditingController _inputController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 去空去重，保留当前标签作为初始选中态
    _selectedTags = widget.currentTags
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toSet();
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  /// 切换预置分类选中状态
  void _togglePreset(String tag) {
    setState(() {
      if (!_selectedTags.remove(tag)) {
        _selectedTags.add(tag);
      }
    });
  }

  /// 添加自定义标签（空输入直接忽略）
  void _addCustomTag() {
    final tag = _inputController.text.trim();
    if (tag.isEmpty) return;
    setState(() {
      _selectedTags.add(tag);
      _inputController.clear();
    });
  }

  /// 移除单个标签
  void _removeTag(String tag) {
    setState(() {
      _selectedTags.remove(tag);
    });
  }

  /// 清空所有已选标签
  void _clearAll() {
    setState(() {
      _selectedTags.clear();
    });
  }

  /// 确认：返回当前选中的标签列表
  void _confirm() {
    Navigator.of(context).pop(_selectedTags.toList());
  }

  /// 点击动作：先关闭面板，再执行动作
  void _runAction(MoreActionItem action) {
    Navigator.of(context).pop();
    action.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // 自定义标签 = 已选中且不在预置列表中的标签（预置标签通过 FilterChip 展示选中态）
    final customTags =
        _selectedTags.where((t) => !widget.presetTags.contains(t)).toList();

    return Padding(
      // 键盘弹出时上推面板，避免输入框被遮挡
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: AppSpacing.allXL,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题
              Text(
                widget.appName,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),

              // 预置分类
              if (widget.presetTags.isNotEmpty) ...[
                Text(
                  '预置分类',
                  style: textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final tag in widget.presetTags)
                      FilterChip(
                        label: Text(tag),
                        selected: _selectedTags.contains(tag),
                        onSelected: (_) => _togglePreset(tag),
                        selectedColor: colorScheme.secondaryContainer,
                        checkmarkColor: colorScheme.onSecondaryContainer,
                        // 紧凑小巧：缩小高度/内边距/字号，视觉更精致
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        labelPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        labelStyle: textTheme.labelSmall,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppRadius.radiusButton,
                          ),
                          side: BorderSide(
                            color: _selectedTags.contains(tag)
                                ? colorScheme.secondary
                                : colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
              ],

              // 自定义标签输入
              TextField(
                controller: _inputController,
                decoration: InputDecoration(
                  hintText: '自定义标签',
                  hintStyle: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: '添加标签',
                    onPressed: _addCustomTag,
                  ),
                  isDense: true,
                ),
                onSubmitted: (_) => _addCustomTag(),
              ),

              // 自定义标签（可移除，横向滑动填充避免过多标签超出边界）
              if (customTags.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final tag in customTags) ...[
                        InputChip(
                          label: Text(tag),
                          onDeleted: () => _removeTag(tag),
                          backgroundColor: colorScheme.secondaryContainer,
                          deleteIconColor: colorScheme.onSecondaryContainer,
                          labelStyle: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSecondaryContainer,
                          ),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                      ],
                    ],
                  ),
                ),
              ],

              const SizedBox(height: AppSpacing.xxl),

              // 分隔线 + 动作宫格（actions 为空时整块隐藏）
              if (widget.actions.isNotEmpty) ...[
                const Divider(),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  '操作',
                  style: textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: AppSpacing.sm,
                  crossAxisSpacing: AppSpacing.sm,
                  childAspectRatio: 1.1,
                  children: [
                    for (final action in widget.actions)
                      _ActionTile(
                        action: action,
                        onTap: () => _runAction(action),
                      ),
                  ],
                ),
              ],

              const SizedBox(height: AppSpacing.lg),

              // 操作按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: _clearAll,
                    child: const Text('清空'),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      FilledButton(
                        onPressed: _confirm,
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 动作宫格单元（图标 + 文案）
class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.action, required this.onTap});

  final MoreActionItem action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.allMD,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: AppSpacing.massive,
            height: AppSpacing.massive,
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer.withAlpha(
                AppColors.alphaMedium,
              ),
              borderRadius: AppRadius.allMD,
            ),
            child: Icon(
              action.icon,
              size: AppTypography.iconMD,
              color: colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            action.label,
            style: textTheme.labelSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
