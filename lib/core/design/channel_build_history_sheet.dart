import 'package:flutter/material.dart';

import 'package:gstore/core/design/channel_version_picker_sheet.dart';
import 'package:gstore/core/design/design_tokens.dart';

/// 构建历史选择器（通用）：单选构建 → 确认返回选中项。
///
/// 数据由调用方提供（脚本渠道从 buildHistory 取），组件只负责渲染与选择回调，
/// 不依赖任何 JSChannel/脚本实现，纯数据驱动，可被其它脚本渠道复用。
///
/// 布局对齐 [ChannelVersionPickerSheet]：限高（屏高 70%）+ 构建列表内部滚动 +
/// 底部确认/取消按钮固定可见。
class ChannelBuildHistorySheet {
  ChannelBuildHistorySheet._();

  /// 显示选择器；返回用户确认的 [BuildOption] 或 null（取消/关闭）。
  ///
  /// [version] / [env] 当前版本与环境（标题展示用）
  /// [builds] 历史构建列表（按 num 降序由调用方保证；单选）
  /// [initialSelected] 可选：当前选中的构建（弹框预选中；null 表示无选中）
  static Future<BuildOption?> show({
    required BuildContext context,
    required String version,
    required String env,
    required List<BuildOption> builds,
    BuildOption? initialSelected,
  }) {
    return showModalBottomSheet<BuildOption>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.dialogSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.radiusSheet),
        ),
      ),
      builder: (context) => _ChannelBuildHistorySheet(
        version: version,
        env: env,
        builds: builds,
        initialSelected: initialSelected,
      ),
    );
  }
}

class _ChannelBuildHistorySheet extends StatefulWidget {
  const _ChannelBuildHistorySheet({
    required this.version,
    required this.env,
    required this.builds,
    this.initialSelected,
  });

  final String version;
  final String env;
  final List<BuildOption> builds;
  final BuildOption? initialSelected;

  @override
  State<_ChannelBuildHistorySheet> createState() =>
      _ChannelBuildHistorySheetState();
}

class _ChannelBuildHistorySheetState extends State<_ChannelBuildHistorySheet> {
  late BuildOption? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialSelected;
  }

  void _confirm() {
    final selected = _selected;
    if (selected == null) return;
    Navigator.of(context).pop(selected);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // 弹框限高（屏高 70%）：构建多时列表内部滚动，不顶出屏幕；
    // 确认/取消按钮固定在底部（不随列表滚动，始终可见）。
    final maxHeight = MediaQuery.of(context).size.height * 0.7;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ===== 固定头部：标题（版本/env）=====
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              AppSpacing.xl,
              AppSpacing.xl,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '历史构建 · ${widget.version}',
                    style: textTheme.titleLarge?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                ),
                Container(
                  padding: AppSpacing.onlyHorizontalSM,
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.radiusButton),
                  ),
                  child: Text(
                    widget.env,
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 副标题：选择构建后确认，详情下载区切换为该构建
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              0,
              AppSpacing.xl,
              AppSpacing.sm,
            ),
            child: Text(
              '选择历史构建，确认后详情下载区切换为该构建',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          // ===== 构建列表（独立滚动区，单选）=====
          Expanded(
            child: widget.builds.isEmpty
                ? Center(
                    child: Text(
                      '暂无构建记录',
                      style: textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: AppSpacing.onlyHorizontalXL,
                    itemCount: widget.builds.length,
                    itemBuilder: (context, index) {
                      final build = widget.builds[index];
                      return Column(
                        children: [
                          _BuildSelectRow(
                            option: build,
                            isSelected: _selected?.num == build.num,
                            onTap: () => setState(() => _selected = build),
                          ),
                          const Divider(height: 1),
                        ],
                      );
                    },
                  ),
          ),

          // ===== 固定底部：取消/确认按钮（不随列表滚动）=====
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                AppSpacing.md,
                AppSpacing.xl,
                AppSpacing.xl,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: _selected != null ? _confirm : null,
                    child: const Text('确认下载'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 构建选择行：单选圆点 + num / 时间 / 大小 / 更新日志
class _BuildSelectRow extends StatelessWidget {
  const _BuildSelectRow({
    required this.option,
    required this.isSelected,
    required this.onTap,
  });

  final BuildOption option;
  final bool isSelected;
  final VoidCallback onTap;

  String _formatDateTime(DateTime dt) {
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final meta = [
      if (option.publishedAt != null) _formatDateTime(option.publishedAt!),
      if (option.size != null) _formatSize(option.size!),
    ].join(' · ');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: AppSpacing.onlyVerticalMD,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 单选圆点
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: AppTypography.iconMD,
              color: isSelected
                  ? colorScheme.primary
                  : colorScheme.outlineVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '构建 #${option.num}',
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight: AppTypography.weightMedium,
                            color: isSelected
                                ? colorScheme.primary
                                : colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (meta.isNotEmpty)
                        Text(
                          meta,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  if (option.changelog != null && option.changelog!.isNotEmpty)
                    Padding(
                      padding: AppSpacing.onlyTopXS,
                      child: Text(
                        option.changelog!,
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
