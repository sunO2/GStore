import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/core/utils/logger.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
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
          padding: const EdgeInsets.only(left: 8, right: 8),
          child: StreamBuilder<List<List<DownloadStatus>>>(
              stream: logic.controller.stream,
              builder: (context, snap) {
                log("有数据更新");
                var downloadList = snap.data;
                if (snap.connectionState != ConnectionState.active ||
                    (downloadList?.isEmpty ?? true)) {
                  return const Text("下载列表为空");
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: downloadList?.length ?? 0,
                  itemBuilder: (context, index) {
                    var item = downloadList![index];
                    return FutureBuilder<AppInfo?>(
                        future: logic.getAppInfo(item[0].appId),
                        builder: (context, snap) {
                          var info = snap.data;
                          return Theme(
                            data: Theme.of(context)
                                .copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              subtitle: Text(item[0].version),
                              childrenPadding: const EdgeInsets.all(16),
                              maintainState: true,
                              leading: SizedBox(
                                width: 32,
                                height: 32,
                                child: Stack(
                                  children: [
                                    CachedNetworkImage(
                                      imageUrl: info?.icon ?? "",
                                      errorWidget: (context, url, error) {
                                        return const Icon(
                                            Icons.document_scanner);
                                      },
                                      width: 32,
                                      height: 32,
                                    ),
                                  ],
                                ),
                              ),
                              title: Text(
                                info?.name ?? "Gstore",
                                maxLines: 1,
                                softWrap: true,
                                overflow: TextOverflow.ellipsis,
                              ),
                              expandedCrossAxisAlignment:
                                  CrossAxisAlignment.start,
                              expandedAlignment: Alignment.topLeft,
                              children: item.map((downStatus) {
                                return StreamBuilder(
                                    stream: downStatus.observer,
                                    builder: (context, snap) {
                                      var data = snap.data;
                                      return ClipRRect(
                                        borderRadius: const BorderRadius.all(
                                            Radius.circular(20)),
                                        child: Container(
                                          constraints:
                                              const BoxConstraints.expand(
                                                  width: 280, height: 18),
                                          margin: const EdgeInsets.only(
                                              top: 2, bottom: 2),
                                          decoration: BoxDecoration(
                                            color:
                                                Theme.of(context).brightness ==
                                                        Brightness.dark
                                                    ? Colors.grey.shade600
                                                    : Colors.grey.shade300,
                                            borderRadius:
                                                const BorderRadius.all(
                                                    Radius.circular(30)),
                                          ),
                                          child: Stack(
                                            alignment: AlignmentDirectional
                                                .centerStart,
                                            children: [
                                              data?.status ==
                                                      DownloadStatus
                                                          .DOWNLOAD_LOADING
                                                  ? LinearProgressIndicator(
                                                      value: data == null
                                                          ? 0
                                                          : data.count /
                                                              data.total,
                                                      minHeight: 18,
                                                      borderRadius:
                                                          const BorderRadius
                                                              .all(
                                                              Radius.circular(
                                                                  20)),
                                                    )
                                                  : const SizedBox(),
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                    left: 8, right: 8),
                                                child: Text(
                                                  downStatus.fileName,
                                                  style: const TextStyle(
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.w500),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    });
                              }).toList(),
                            ),
                          );
                        });
                  },
                );
              })),
    );
  }
}
