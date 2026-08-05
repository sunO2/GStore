import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';

class AppCardWidget extends StatelessWidget {
  final AggregatedAppInfo app;
  final VoidCallback onTap;

  const AppCardWidget({
    super.key,
    required this.app,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final channelColor = AppColors.getChannelBrandColor(app.channel.name);
    final channelShortName = _getChannelShortName(app.channel);

    return GestureDetector(
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
                          child: app.appInfo.icon != null
                              ? CachedNetworkImage(
                                  fit: BoxFit.fill,
                                  placeholder: (context, url) {
                                    return const Center(
                                      child: AppLoading(size: AppLoadingSize.small),
                                    );
                                  },
                                  errorWidget: (context, url, error) {
                                    return const Icon(Icons.error);
                                  },
                                  imageUrl: app.appInfo.icon!,
                                  width: 64,
                                  height: 64,
                                )
                              : const SizedBox(),
                        ),
                      ),
                    ),
                  ),
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
        ],
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
