import 'package:flutter/material.dart';
import 'package:gstore/compent/flag_text.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

typedef OnLinkTap = void Function(String? url);

class LinkText extends StatelessWidget {
  final String? text;
  final String? url;
  final OnLinkTap? onLinkTap;
  final OnLinkTap? onLongPress;

  const LinkText(
      {super.key, this.text, this.url, this.onLinkTap, this.onLongPress});

  @override
  Widget build(BuildContext context) => InkWell(
        child: Text(
          text ?? "",
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
        onTap: () => {
          if (null != onLinkTap) {onLinkTap!(url)}
        },
        onLongPress: () {
          if (null != onLongPress) {
            onLongPress!(url);
          }
        },
      );
}

class DownloadLink extends LinkText {
  final int? downloadCount;
  final int? downloadSize;
  final String? appId;
  final String? version;

  const DownloadLink(
      {super.key,
      this.downloadCount,
      this.downloadSize,
      this.appId,
      this.version,
      super.text,
      super.url,
      super.onLinkTap,
      super.onLongPress});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      child: Wrap(
        children: [
          super.build(context),
          FlagText(byteSize(downloadSize ?? 0)),
          FlagText("${downloadCount ?? ""}"),
          FutureBuilder(
              future: isDownload(text, downloadSize),
              builder: (context, snapshot) {
                return (snapshot.data ?? false)
                    ? Container(
                        margin:
                            const EdgeInsets.only(left: 8, top: 2, bottom: 2),
                        padding: const EdgeInsets.only(
                            left: 4, right: 4, top: 2, bottom: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withAlpha(130),
                          borderRadius:
                              const BorderRadius.all(Radius.circular(20)),
                        ),
                        // child: Text("已下载",style:  Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600,fontSize: 10),),
                        child: Icon(
                          AliIcon.downloadSuccess,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                          size: 12,
                        ),
                      )
                    : const SizedBox();
              })
        ],
      ),
    );
  }

  Future<bool> isDownload(String? fileName, int? downloadSize) async {
    var path = await getDownloadsDirectory();
    var savePath = "${path?.path}/$appId-$version-$fileName";
    var saveFile = File(savePath);
    return saveFile.exists();
  }
}
