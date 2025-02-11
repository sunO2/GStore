import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:gstore/compent/app_widget.dart';
import 'package:gstore/core/icons/Icons.dart';

import 'logic.dart';
import 'package:gstore/core/core.dart';

class ApplistPage extends StatefulWidget {
  const ApplistPage({super.key});

  @override
  State<StatefulWidget> createState() => AppListState();
}

class AppListState extends State<ApplistPage>
    with AutomaticKeepAliveClientMixin {
  @override
  Widget build(BuildContext context) {
    super.build(context);
    final logic = Get.put(ApplistLogic());
    final state = Get.find<ApplistLogic>().state;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: logic.search,
          child: Tooltip(
            message: "搜索",
            child: Container(
              decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(40)),
                  color: Theme.of(context).primaryColor.withAlpha(30)),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: const Row(
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Icon(
                      Icons.search,
                      size: 24,
                    ),
                  ),
                  SizedBox(
                    width: 16,
                  ),
                  Text("搜索应用",
                      style:
                          TextStyle(fontWeight: FontWeight.w400, fontSize: 18))
                ],
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: "应用更新",
            icon: const Icon(
              AliIcon.appUpdateCenter,
            ),
            onPressed: () => Get.toNamed(AppRoute.updateCenter),
          ),
          IconButton(
            tooltip: "下载中心",
            icon: const Icon(AliIcon.appDownloadCenter),
            onPressed: () => Get.toNamed(AppRoute.downloadCenter),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: logic.checkUpdata,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: FutureBuilder(
                  future: logic.getBanner(),
                  builder: (contest, snap) {
                    var data = snap.data;
                    if (null == data) {
                      return const SizedBox();
                    }
                    var length = data.length;
                    return SizedBox(
                      height: 180,
                      child: PageView.builder(
                        controller: PageController(
                            viewportFraction: 0.8, initialPage: 5000),
                        itemCount: 10000,
                        itemBuilder: (context, item) {
                          var index = item % length;
                          return GestureDetector(
                            onTap: () =>
                                logic.appDetailOfAppId(data[index]["appId"]),
                            child: Padding(
                              padding: const EdgeInsets.only(
                                  left: 8, right: 8, top: 16, bottom: 16),
                              child: ClipRRect(
                                borderRadius:
                                    const BorderRadius.all(Radius.circular(16)),
                                child: CachedNetworkImage(
                                  height: 180,
                                  fit: BoxFit.fill,
                                  imageUrl: data[index]["banner"],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  }),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(0),
              sliver: GetBuilder<ApplistLogic>(
                  builder: (ctl) => SliverGrid.builder(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                        ),
                        itemBuilder: (context, index) {
                          var app = state.apps[index];
                          return AppItemWidget(
                            appName: app.name,
                            appIcon: app.icon,
                            onTap: () =>
                                Get.toNamed(AppRoute.appDetail, arguments: app),
                          );
                        },
                        itemCount:
                            state.apps.isNotEmpty ? state.apps.length : 0,
                      )),
            )
          ],
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
