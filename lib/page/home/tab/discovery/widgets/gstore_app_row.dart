import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';

/// GStore 浏览页的单行应用条目。
///
/// 只负责展示（图标/名称/描述/加入按钮）与动作回传，不持有任何状态：
/// 「加入/已加入」由父页面根据后端状态传入，避免行内重复请求。
class GStoreAppRow extends StatelessWidget {
  const GStoreAppRow({
    super.key,
    required this.app,
    required this.isAdded,
    required this.isBusy,
    required this.onAdd,
    required this.onRemove,
  });

  final AppSummary app;
  final bool isAdded;
  final bool isBusy;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: AppSpacing.onlyVerticalXS,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.allMD,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: AppSpacing.allMD,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            AppIcon(
              url: app.icon,
              width: 44,
              height: 44,
              borderRadius: AppRadius.sm,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    app.name.isEmpty ? app.appId : app.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  if (app.des.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      app.des,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            _ActionButton(
              isAdded: isAdded,
              isBusy: isBusy,
              onAdd: onAdd,
              onRemove: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

/// 加入/已加入动作按钮：已加入点击走移除确认（由父页面弹确认层）。
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.isAdded,
    required this.isBusy,
    required this.onAdd,
    required this.onRemove,
  });

  final bool isAdded;
  final bool isBusy;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (isBusy) {
      return const Padding(
        padding: AppSpacing.allSM,
        child: AppLoading(size: AppLoadingSize.small),
      );
    }
    if (isAdded) {
      return OutlinedButton.icon(
        onPressed: onRemove,
        icon: Icon(
          TablerIcons.circle_check_filled,
          size: AppTypography.iconSM,
          color: theme.colorScheme.primary,
        ),
        label: const Text('已加入'),
      );
    }
    return FilledButton(
      onPressed: onAdd,
      child: const Text('加入'),
    );
  }
}
