import 'package:flutter/material.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/core.dart';

/// 横向滑动应用卡片（用于"可更新"/"最近添加"分区）
class HorizontalAppRow extends StatelessWidget {
  final List<AggregatedAppInfo> apps;
  final ValueChanged<AggregatedAppInfo> onTap;

  const HorizontalAppRow({
    super.key,
    required this.apps,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (apps.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 148,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount: apps.length,
        itemBuilder: (context, index) {
          final app = apps[index];
          return _HorizontalAppCard(app: app, onTap: () => onTap(app));
        },
      ),
    );
  }
}

class _HorizontalAppCard extends StatelessWidget {
  final AggregatedAppInfo app;
  final VoidCallback onTap;

  const _HorizontalAppCard({required this.app, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 170,
        margin: const EdgeInsets.only(right: AppSpacing.sm),
        padding: AppSpacing.allMD,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: AppRadius.allLG,
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 图标
                ClipRRect(
                  borderRadius: AppRadius.allMD,
                  child: Container(
                    width: 48,
                    height: 48,
                    color: scheme.primaryContainer,
                    child: (app.appInfo.icon?.isNotEmpty ?? false)
                        ? AppIcon(
                            url: app.appInfo.icon,
                            width: 48,
                            height: 48,
                            borderRadius: 0,
                          )
                        : const SizedBox(),
                  ),
                ),
                const Spacer(),
                // 渠道短名角标
                _ChannelBadge(channel: app.channel),
              ],
            ),
            const Spacer(),
            Text(
              app.appInfo.name ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
            ),
            const SizedBox(height: 2),
            Text(
              app.appInfo.des ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 渠道短名角标
class _ChannelBadge extends StatelessWidget {
  final ChannelType channel;

  const _ChannelBadge({required this.channel});

  @override
  Widget build(BuildContext context) {
    final color = AppColors.getChannelBrandColor(channel.name);
    final label = switch (channel) {
      ChannelType.localDb => 'DB',
      ChannelType.github => 'GH',
      ChannelType.http => 'API',
      ChannelType.vivo => 'vivo',
      ChannelType.fdroid => 'FD',
      ChannelType.custom => 'APP',
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.withOpacity(color, 0.9),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppColors.white,
              fontSize: 10,
            ),
      ),
    );
  }
}
