import 'package:flutter/material.dart';
import 'package:gstore/compent/flag_text.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

typedef OnLinkTap = void Function(String? url);

class LinkText extends StatelessWidget {
  final String? text;
  final String? url;
  final OnLinkTap? onLinkTap;

  const LinkText({super.key, this.text, this.url, this.onLinkTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        child: InkWell(
          child: Text(
            text ?? "",
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.blueAccent),
          ),
          onTap: () => {
            if (null != onLinkTap) {onLinkTap!(url)}
          },
          onLongPress: () {
            if (url?.isNotEmpty ?? false) {
              Get.defaultDialog(
                title: "下载二维码",
                content: Container(
                  width: 120,
                  height: 120,
                  color: Colors.white,
                  child: QrImageView(
                    data: url!,
                    version: QrVersions.auto,
                    size: 120,
                  ),
                ),
              );
            }
          },
        ),
      );
}

class DownloadLink extends LinkText {
  final int? downloadCount;
  final int? downloadSize;

  const DownloadLink(
      {super.key,
      this.downloadCount,
      this.downloadSize,
      super.text,
      super.url,
      super.onLinkTap});

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
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.grey.shade600
                              : Colors.grey.shade300,
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
    var savePath = "${path?.path}/$fileName";
    var saveFile = File(savePath);
    return saveFile.exists();
  }
}
