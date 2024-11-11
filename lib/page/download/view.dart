import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/core/utils/logger.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'logic.dart';

class DownloadManager extends StatelessWidget {
  const DownloadManager({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(DownloadManagerLogic());
    return Scaffold(
      appBar: AppBar(
        title: const Text("下载管理"),
      ),
      body: Container(
          padding: const EdgeInsets.all(16),
          child: StreamBuilder(
              stream: logic.controller.stream,
              builder: (context, snap) {
                var downloadList = snap.data;
                if (snap.connectionState != ConnectionState.active ||
                    (downloadList?.isEmpty ?? true)) {
                  return Text("下载列表为空");
                }
                return ListView.builder(
                  reverse: true,
                  shrinkWrap: true,
                  itemCount: downloadList?.length ?? 0,
                  itemBuilder: (context, index) {
                    var item = downloadList![index];
                    return ListTile(
                      leading: const Icon(Icons.document_scanner),
                      title: Text(item.fileName),
                      subtitle: Text(
                        byteSize(item.total),
                        maxLines: 2,
                      ),
                    );
                  },
                );
              })),
    );
  }
}
