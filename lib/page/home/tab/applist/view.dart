import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gstore/compent/app_widget.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:gstore/page/web/browser.dart';

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
          Obx(() {
            var user = Get.find<UserManager>().userInfo.value;

            icon(UserInfo fuser) {
              if (fuser.avatarUrl?.isNotEmpty ?? false) {
                return Container(
                  width: Theme.of(context).appBarTheme.iconTheme?.size ?? 24,
                  height: Theme.of(context).appBarTheme.iconTheme?.size ?? 24,
                  decoration: BoxDecoration(
                      border: Border.all(width: 1.5),
                      borderRadius: BorderRadius.all(
                        Radius.circular(
                            Theme.of(context).appBarTheme.iconTheme?.size ??
                                24),
                      )),
                  child: ClipOval(
                    child: CachedNetworkImage(
                      width:
                          Theme.of(context).appBarTheme.iconTheme?.size ?? 24,
                      height:
                          Theme.of(context).appBarTheme.iconTheme?.size ?? 24,
                      placeholder: (context, url) =>
                          const CupertinoActivityIndicator(
                        radius: 8,
                      ),
                      errorWidget: (context, url, error) => const Icon(
                        Icons.account_circle_outlined,
                      ),
                      imageUrl: fuser.avatarUrl ?? "",
                    ),
                  ),
                );
              } else {
                return const Icon(
                  Icons.account_circle_outlined,
                );
              }
            }

            onPressed() {
              if (user.avatarUrl?.isEmpty ?? true) {
                Get.toNamed(AppRoute.auth);
              } else {
                GStoreInAppBrowser inAppBrowser = GStoreInAppBrowser();
                final settings = ChromeSafariBrowserSettings(
                  shareState: CustomTabsShareState.SHARE_STATE_ON,
                  barCollapsingEnabled: true,
                );
                inAppBrowser.open(
                    url: WebUri(user.htmlUrl ?? ""), settings: settings);
              }
            }

            return IconButton(
              tooltip: user.name ?? "登陆",
              icon: icon(user),
              onPressed: onPressed,
            );
          }),
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
