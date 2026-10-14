/// 「请求调试」键值编辑器（plan todo 15）。
///
/// 参数 / 请求头 / Cookie 三段共用同一个无边框、对齐的键值行列表：
/// - 键与值都**以只读文字预览呈现**（字号更小、行更紧凑），**点击不编辑**；
/// - **长按整行**触发调用方注入的 [onRowLongPress]（页面弹出统一的
///   「编辑 / 删除」菜单弹层，编辑走键 + 值表单弹层）；
/// - 行间浅分隔线；无行内展开按钮、无常驻拖拽手柄、无常驻删除按钮；
/// - 非阻塞的**重复键提示**；页脚保留「添加 / 批量编辑」入口，并有「排序」切换；
/// - 「排序」模式下每行尾部才渲染拖拽手柄（[ReorderableDragStartListener]）。
///
/// 本组件无状态：行对象（controller / 焦点 key）与全部行为由调用方持有，
/// 新增 / 编辑 / 删除 / 重排后的 controller 释放也由调用方处理
/// （避免 used-after-dispose）。值的编辑面（输入框 + 工具栏 + 建议 chips）
/// 位于页面的键值表单弹层内，不在本行内。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';

/// 行尾动作槽位宽度（复选框 / 拖拽共用），保证表头与数据行像素对齐。
const double _kKvActionSlot = AppSpacing.huge;

/// 键值编辑行（参数 / 头 / Cookie 共用；由页面私有行类型提升而来）。
class DebugKvRow {
  DebugKvRow({
    required this.id,
    String name = '',
    String value = '',
    this.enabled = true,
  })  : nameCtrl = TextEditingController(text: name),
        valueCtrl = TextEditingController(text: value);

  /// 稳定唯一 id：列表重排 / 协调时按它复用行对象（保留 controller 与焦点）。
  final String id;

  final TextEditingController nameCtrl;
  final TextEditingController valueCtrl;

  /// 字段 state key：焦点顺序（上一个 / 下一个字段）依赖它，必须挂到字段上。
  final GlobalKey<AppEditableFieldState> nameFieldKey =
      GlobalKey<AppEditableFieldState>();
  final GlobalKey<AppEditableFieldState> valueFieldKey =
      GlobalKey<AppEditableFieldState>();

  bool enabled;

  void dispose() {
    nameCtrl.dispose();
    valueCtrl.dispose();
  }
}

/// 干净、对齐、无边框的键值行列表（无状态）。
///
/// 全部可变状态（[rows] 内容、增删、重排、脏标记）由调用方拥有；本组件只负责
/// 渲染与把交互回调转发给调用方。
class DebugKvEditor extends StatelessWidget {
  const DebugKvEditor({
    super.key,
    required this.rows,
    required this.keyPrefix,
    required this.nameHint,
    required this.addLabel,
    required this.addKey,
    this.allowDisable = false,
    this.onChanged,
    required this.onRemove,
    required this.onReordered,
    required this.onAdd,
    required this.onBulkEdit,
    this.sortMode = false,
    this.onToggleSort,
    this.onRowLongPress,
  });

  /// 数据行（调用方持有；重排 / 增删后调用方需 setState 重建）。
  final List<DebugKvRow> rows;

  /// 测试键前缀（如 `request-editor-param`），所有行内 key 由它派生。
  final String keyPrefix;

  /// 键列空值提示。
  final String nameHint;

  /// 页脚「添加」按钮文案。
  final String addLabel;

  /// 页脚「添加」按钮 key。
  final Key addKey;

  /// 是否渲染启用复选框（参数 / 请求头为 true，Cookie 为 false）。
  final bool allowDisable;

  /// 通用变更回调（当前用于复选框切换后让调用方重建 / 标记脏值）。
  final VoidCallback? onChanged;

  /// 删除某行时回调（调用方负责出列表 + 延迟释放 controller）。
  final ValueChanged<DebugKvRow> onRemove;

  /// 重排回调（`onReorderItem` 语义：newIndex 已按移除 oldIndex 调整）。
  final void Function(int oldIndex, int newIndex) onReordered;

  /// 页脚「添加」回调（页面据此打开**键值表单弹层**新增行）。
  final VoidCallback onAdd;

  /// 页脚「批量编辑」回调。
  final VoidCallback onBulkEdit;

  /// 排序模式：为 true 时每行尾部渲染拖拽手柄可重排，为 false 时不渲染。
  final bool sortMode;

  /// 页脚「排序」切换按钮回调（切换 [sortMode]）。
  final VoidCallback? onToggleSort;

  /// 长按某行时回调（页面据此弹出统一的「编辑 / 删除」菜单弹层）。
  final ValueChanged<DebugKvRow>? onRowLongPress;

  @override
  Widget build(BuildContext context) {
    return ReorderableListView(
      padding: AppSpacing.allLG,
      buildDefaultDragHandles: false,
      header: _buildHeader(context),
      onReorderItem: onReordered,
      footer: _buildFooter(context),
      children: [
        for (var i = 0; i < rows.length; i++) _buildRow(context, i),
      ],
    );
  }

  /// 表头：与数据行使用同一组 flex 比例与动作槽位常量，保证列边界对齐。
  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        children: [
          if (allowDisable) const SizedBox(width: _kKvActionSlot),
          Expanded(flex: 2, child: Text('键', style: style)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(flex: 3, child: Text('值', style: style)),
          if (sortMode) const SizedBox(width: _kKvActionSlot),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              key: addKey,
              onPressed: onAdd,
              icon: const Icon(TablerIcons.plus),
              label: Text(addLabel),
            ),
            TextButton.icon(
              key: const Key('request-editor-kv-bulk'),
              onPressed: onBulkEdit,
              icon: const Icon(TablerIcons.list_check),
              label: const Text('批量编辑'),
            ),
            TextButton.icon(
              key: const Key('request-editor-kv-sort'),
              onPressed: onToggleSort,
              icon: Icon(sortMode ? TablerIcons.check : TablerIcons.arrows_sort),
              label: const Text('排序'),
              style: sortMode
                  ? TextButton.styleFrom(foregroundColor: scheme.primary)
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  /// 非空键在同列表出现 ≥2 次时为重复。
  bool _isDuplicateKey(int i) {
    final key = rows[i].nameCtrl.text.trim();
    if (key.isEmpty) return false;
    var count = 0;
    for (final row in rows) {
      if (row.nameCtrl.text.trim() == key) count++;
    }
    return count >= 2;
  }

  Widget _buildRow(BuildContext context, int i) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final row = rows[i];
    final duplicate = _isDuplicateKey(i);
    // 预览字号：键取主题 bodySmall（12），值取等宽 code 但字号降到 sizeXS（12），
    // 均小于旧的 bodyMedium(14)，行更紧凑以把空间还给数据展示。
    final keyStyle = theme.textTheme.bodySmall;
    final valueStyle = AppTypography.code.copyWith(
      fontSize: AppTypography.sizeXS,
    );
    return KeyedSubtree(
      key: ValueKey<String>('$keyPrefix-row-${row.id}'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            // 整行只读；唯一交互是**长按** → 页面弹出「编辑 / 删除」菜单。
            behavior: HitTestBehavior.opaque,
            onLongPress: onRowLongPress == null
                ? null
                : () => onRowLongPress!.call(row),
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(minHeight: AppSpacing.massive),
              child: Row(
                children: [
                  if (allowDisable)
                    SizedBox(
                      width: _kKvActionSlot,
                      child: Checkbox(
                        value: row.enabled,
                        onChanged: (value) {
                          row.enabled = value ?? false;
                          onChanged?.call();
                        },
                      ),
                    ),
                  Expanded(
                    flex: 2,
                    child: Row(
                      children: [
                        Expanded(
                          child: KeyedSubtree(
                            key: Key('$keyPrefix-name-$i'),
                            child: AppEditableField(
                              key: row.nameFieldKey,
                              controller: row.nameCtrl,
                              mode: AppEditableFieldMode.display,
                              style: keyStyle,
                              hintText: nameHint,
                              displayMaxLines: 1,
                            ),
                          ),
                        ),
                        if (duplicate)
                          Padding(
                            padding: AppSpacing.onlyLeftXS,
                            child: Icon(
                              key: Key('$keyPrefix-dup-$i'),
                              Icons.error_outline,
                              size: AppTypography.iconSM,
                              color: scheme.error,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 3,
                    child: KeyedSubtree(
                      key: Key('$keyPrefix-value-$i'),
                      child: AppEditableField(
                        key: row.valueFieldKey,
                        controller: row.valueCtrl,
                        mode: AppEditableFieldMode.display,
                        style: valueStyle,
                        hintText: '值',
                        displayMaxLines: 1,
                      ),
                    ),
                  ),
                  // 拖拽手柄仅在排序模式下渲染（默认不占位、不干扰数据展示）。
                  if (sortMode)
                    SizedBox(
                      width: _kKvActionSlot,
                      height: _kKvActionSlot,
                      child: Listener(
                        key: Key('$keyPrefix-drag-$i'),
                        // 按下即先移除焦点，规避聚焦 TextField 参与拖拽时的
                        // LeaderLayer 断言。
                        onPointerDown: (_) =>
                            FocusManager.instance.primaryFocus?.unfocus(),
                        child: ReorderableDragStartListener(
                          index: i,
                          child: const Icon(TablerIcons.grip_vertical),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
        ],
      ),
    );
  }
}
