import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';

class AppItemWidget extends StatelessWidget {
  final String? appName;
  final String? appIcon;
  final GestureTapCallback? onTap;

  const AppItemWidget({super.key, this.appName, this.appIcon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: (appIcon != null)
                ? Hero(
                    tag: appIcon!,
                    child: ClipRRect(
                      borderRadius: AppRadius.allLG,
                      child: Container(
                        decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.primaryContainer,
                            // border: Border.all(width: 0),
                            borderRadius: AppRadius.allLG),
                        child: SizedBox(
                          width: AppSpacing.xxl * 3.5,
                          height: AppSpacing.xxl * 3.5,
                          child: CachedNetworkImage(
                            fit: BoxFit.fill,
                            placeholder: (context, url) {
                              return const CupertinoActivityIndicator(
                                radius: AppSpacing.xs,
                              );
                            },
                            imageUrl: appIcon!,
                            width: AppSpacing.xxl * 3.5,
                            height: AppSpacing.xxl * 3.5,
                          ),
                        ),
                      ),
                    ))
                : const SizedBox(
                    width: AppSpacing.xxl * 3.5,
                    height: AppSpacing.xxl * 3.5,
                  ),
          ),
          Hero(
              tag: appName ?? "",
              child: Text(
                appName ?? "",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: AppTypography.weightExtraBold,
                ),
              ))
        ],
      ),
    );
  }
}
