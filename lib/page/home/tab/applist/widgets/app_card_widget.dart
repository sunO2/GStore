import 'package:flutter/material.dart';
import 'package:gstore/compent/pressable_scale.dart';
import 'package:gstore/core/core.dart';

class AppCardWidget extends StatelessWidget {
  final AggregatedAppInfo app;
  final VoidCallback onTap;

  /// 是否有更新（显示红点角标，数据来自 UpdateManager）
  final bool hasUpdate;

  const AppCardWidget({
    super.key,
    required this.app,
    required this.onTap,
    this.hasUpdate = false,
  });

  @override
  Widget build(BuildContext context) {
    final channelColor = AppColors.getChannelBrandColor(app.channel.name);
    final channelShortName = _getChannelShortName(app.channel);

    // 外层 PressableScale 仅做按压反馈（onTap 仍由内层 GestureDetector 承接）
    return PressableScale(
      child: GestureDetector(
        onTap: onTap,
        child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: AppSpacing.onlyBottomMD,
            child: SizedBox(
              width: 64,
              height: 64,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Hero(
                      tag: "app_icon_${app.appInfo.appId}",
                      child: ClipRRect(
                        borderRadius: AppRadius.allLG,
                        child: Container(
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: AppRadius.allLG,
                          ),
                          child: app.appInfo.icon != null &&
                                  app.appInfo.icon!.isNotEmpty
                              ? AppIcon(
                                  url: app.appInfo.icon,
                                  width: 64,
                                  height: 64,
                                  fit: BoxFit.fill,
                                  borderRadius: 0,
                                )
                              : const SizedBox(),
                        ),
                      ),
                    ),
                  ),
                  // 可更新红点（右上角，数据来自 UpdateManager）
                  if (hasUpdate)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.error,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Theme.of(context).colorScheme.surface,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  // 渠道角标
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: AppSpacing.horizontalXS_verticalXS,
                      decoration: BoxDecoration(
                        color: AppColors.withOpacity(channelColor, 0.9),
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(0),
                          topLeft: Radius.circular(AppSpacing.xs),
                          bottomLeft: Radius.circular(AppSpacing.xs),
                          bottomRight: Radius.circular(AppSpacing.lg),
                        ),
                      ),
                      child: Text(
                        channelShortName,
                        style: AppTypography.labelSmall.copyWith(
                          color: AppColors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Hero(
            tag: "app_name_${app.appInfo.appId}",
            child: Text(
              app.appInfo.name ?? "",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.labelMedium.copyWith(
                fontWeight: AppTypography.weightSemiBold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          // 一行描述（增强信息量）
          if (app.appInfo.des?.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(
                top: 2,
                left: AppSpacing.sm,
                right: AppSpacing.sm,
              ),
              child: Text(
                app.appInfo.des!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppTypography.labelSmall.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    ),
    );
  }

  String _getChannelShortName(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return 'DB';
      case ChannelType.github:
        return 'GH';
      case ChannelType.http:
        return 'API';
      case ChannelType.vivo:
        return 'vivo';
      case ChannelType.fdroid:
        return 'FD';
      default:
        return 'APP';
    }
  }
}
