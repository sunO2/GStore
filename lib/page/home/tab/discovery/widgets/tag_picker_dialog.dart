import 'package:flutter/material.dart';
import 'package:gstore/core/design/design_tokens.dart';

/// 展示分类标签选择对话框
///
/// [presetTags] 预置分类标签（来自本地库 AppCategory.description，失败时使用内置列表）
/// [currentTags] 应用当前已有的标签
///
/// 返回用户确认后的标签列表；取消或点击遮罩关闭返回 null。
Future<List<String>?> showTagPickerDialog(
  BuildContext context, {
  required List<String> presetTags,
  required List<String> currentTags,
}) {
  return showDialog<List<String>>(
    context: context,
    barrierDismissible: true,
    builder: (_) =>
        _TagPickerDialog(presetTags: presetTags, currentTags: currentTags),
  );
}

class _TagPickerDialog extends StatefulWidget {
  const _TagPickerDialog({required this.presetTags, required this.currentTags});

  final List<String> presetTags;
  final List<String> currentTags;

  @override
  State<_TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends State<_TagPickerDialog> {
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // 自定义标签 = 已选中且不在预置列表中的标签（预置标签通过 FilterChip 展示选中态）
    final customTags =
        _selectedTags.where((t) => !widget.presetTags.contains(t)).toList();

    return Dialog(
      elevation: 0,
      backgroundColor: colorScheme.dialogSurface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.allXL,
        side: BorderSide(
          color: colorScheme.borderLight,
          width: 1,
        ),
      ),
      insetPadding: AppSpacing.onlyHorizontalLG,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: AppSpacing.allXL,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题
                Text(
                  '添加分类标签',
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

                // 自定义标签（可移除）
                if (customTags.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final tag in customTags)
                        InputChip(
                          label: Text(tag),
                          onDeleted: () => _removeTag(tag),
                          backgroundColor: colorScheme.secondaryContainer,
                          deleteIconColor: colorScheme.onSecondaryContainer,
                          labelStyle: textTheme.labelMedium?.copyWith(
                            color: colorScheme.onSecondaryContainer,
                          ),
                        ),
                    ],
                  ),
                ],

                const SizedBox(height: AppSpacing.xxl),

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
      ),
    );
  }
}
