import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/utils/logger.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
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
                            data: Theme.of(context).copyWith(
                              dividerColor: Colors.transparent,
                            ),
                            child: Container(
                              margin: const EdgeInsets.only(top: 8, bottom: 8),
                              decoration: BoxDecoration(
                                  borderRadius: const BorderRadius.all(
                                      Radius.circular(16)),
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primaryContainer),
                              child: ExpansionTile(
                                enableFeedback: false,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                collapsedShape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                subtitle: Text(item[0].version),
                                childrenPadding:
                                    const EdgeInsets.only(left: 16, right: 0),
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
                                  return Column(
                                    children: [
                                      StreamBuilder(
                                          stream: downStatus.observer,
                                          builder: (context, snap) {
                                            var data = snap.data ?? downStatus;
                                            return Row(
                                              children: [
                                                Expanded(
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        const BorderRadius.all(
                                                            Radius.circular(
                                                                20)),
                                                    child: Container(
                                                      constraints:
                                                          const BoxConstraints
                                                              .expand(
                                                              height: 18),
                                                      margin:
                                                          const EdgeInsets.only(
                                                              top: 2,
                                                              bottom: 2),
                                                      decoration: BoxDecoration(
                                                        color: Theme.of(context)
                                                                    .brightness ==
                                                                Brightness.dark
                                                            ? Colors
                                                                .grey.shade600
                                                            : Colors
                                                                .grey.shade300,
                                                        borderRadius:
                                                            const BorderRadius
                                                                .all(
                                                                Radius.circular(
                                                                    30)),
                                                      ),
                                                      child: Stack(
                                                        alignment:
                                                            AlignmentDirectional
                                                                .centerStart,
                                                        children: [
                                                          LinearProgressIndicator(
                                                            value: data.count /
                                                                data.total,
                                                            minHeight: 18,
                                                            borderRadius:
                                                                const BorderRadius
                                                                    .all(Radius
                                                                        .circular(
                                                                            20)),
                                                          ),
                                                          Padding(
                                                            padding:
                                                                const EdgeInsets
                                                                    .only(
                                                                    left: 8,
                                                                    right: 8),
                                                            child: Text(
                                                              downStatus
                                                                  .fileName,
                                                              style: const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontSize: 10,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w500),
                                                            ),
                                                          ),
                                                          Align(
                                                            alignment: Alignment
                                                                .centerRight,
                                                            child: Padding(
                                                              padding:
                                                                  const EdgeInsets
                                                                      .only(
                                                                      right: 8),
                                                              child: Text(
                                                                "${((data.count / data.total) * 100).toInt()}%",
                                                                style: const TextStyle(
                                                                    color: Colors
                                                                        .white,
                                                                    fontSize:
                                                                        10,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w500),
                                                              ),
                                                            ),
                                                          )
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Theme(
                                                    data: Theme.of(context)
                                                        .copyWith(
                                                            iconTheme: IconTheme
                                                                    .of(context)
                                                                .copyWith(
                                                                    size: 14)),
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        if (data.status ==
                                                                DownloadStatus
                                                                    .DOWNLOAD_SUCCESS &&
                                                            data.fileName
                                                                .endsWith(
                                                                    ".apk"))
                                                          IconButton(
                                                            tooltip: "安装",
                                                            icon: const Icon(Icons
                                                                .install_mobile),
                                                            onPressed: () {
                                                              logic.installApp(
                                                                  data);
                                                            },
                                                          ),
                                                        if (data.status ==
                                                            DownloadStatus
                                                                .DOWNLOAD_READY)
                                                          IconButton(
                                                            tooltip: "开始下载",
                                                            icon: const Icon(
                                                                Icons
                                                                    .play_arrow),
                                                            onPressed: () {
                                                              logic
                                                                  .resumeDownload(
                                                                      data);
                                                            },
                                                          ),
                                                        if (data.status ==
                                                            DownloadStatus
                                                                .DOWNLOAD_LOADING)
                                                          IconButton(
                                                            tooltip: "暂停下载",
                                                            icon: const Icon(
                                                                Icons.pause),
                                                            onPressed: () {
                                                              logic
                                                                  .pauseDownload(
                                                                      data);
                                                            },
                                                          ),
                                                        IconButton(
                                                          tooltip: "重新下载",
                                                          icon: const Icon(
                                                              Icons.refresh),
                                                          onPressed: () {
                                                            logic.retryDownload(
                                                                data);
                                                          },
                                                        ),
                                                      ],
                                                    )),
                                              ],
                                            );
                                          }),
                                    ],
                                  );
                                }).toList(),
                              ),
                            ),
                          );
                        });
                  },
                );
              })),
    );
  }
}
