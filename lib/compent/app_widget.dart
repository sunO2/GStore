import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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
            padding: const EdgeInsets.only(bottom: 8),
            child: (appIcon != null)
                ? Hero(
                    tag: appIcon!,
                    child: Card(
                      clipBehavior: Clip.none,
                      child: Image(
                        image: CachedNetworkImageProvider(appIcon!),
                        width: 56,
                        height: 56,
                      ),
                    ))
                : const SizedBox(
                    width: 56,
                    height: 56,
                  ),
          ),
          Hero(
              tag: appName ?? "",
              child: Text(
                appName ?? "",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                ),
              ))
        ],
      ),
    );
  }
}
