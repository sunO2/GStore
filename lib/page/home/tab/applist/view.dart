import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gstore/compent/app_widget.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/http/github/user_info/user_info.dart';

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
            message: "search".tr,
            child: Container(
              decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(40)),
                  color: Theme.of(context).primaryColor.withAlpha(30)),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Icon(
                      color: Colors.grey,
                      Icons.search,
                      size: 24,
                    ),
                  ),
                  const SizedBox(
                    width: 16,
                  ),
                  Text("search_tip".tr,
                      style: const TextStyle(
                          color: Colors.grey,
                          fontWeight: FontWeight.w400,
                          fontSize: 18))
                ],
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: "updata_tip".tr,
            icon: const Icon(
              AliIcon.appUpdateCenter,
            ),
            onPressed: () => Get.toNamed(AppRoute.test_home),
          ),
          IconButton(
            tooltip: "download_tip".tr,
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
                // GStoreInAppBrowser inAppBrowser = GStoreInAppBrowser();
                // final settings = ChromeSafariBrowserSettings(
                //   shareState: CustomTabsShareState.SHARE_STATE_ON,
                //   barCollapsingEnabled: true,
                // );
                // inAppBrowser.open(
                //     url: WebUri(user.htmlUrl ?? ""), settings: settings);
                launcherBrow(user.htmlUrl ?? "");
              }
            }

            return IconButton(
              tooltip: user.name ?? "login".tr,
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
                      height: 210,
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
            SliverToBoxAdapter(
              child: FutureBuilder(
                  future: logic.hotList,
                  builder: (context, snap) {
                    if (!snap.hasData && null != snap.data) {
                      return const SizedBox();
                    }
                    var data = snap.data;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 16, right: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                "hot_tool_title".tr,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              InkWell(
                                onTap: () => logic.toCategory("TOOLS"),
                                child: Text(
                                  "more".tr,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          height: 210,
                          child: ListView.separated(
                            separatorBuilder: (context, index) {
                              return const SizedBox(
                                width: 16,
                              );
                            },
                            padding: const EdgeInsets.all(16),
                            itemCount: data?.length ?? 0,
                            scrollDirection: Axis.horizontal,
                            itemBuilder: (context, index) => GestureDetector(
                                onTap: () => logic.appDetail(data[index]),
                                child: _buildHotItem(context, data![index])),
                          ),
                        ),
                      ],
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

  Widget _buildHotItem(
    BuildContext context,
    AppInfo appinfo,
  ) {
    return Container(
      width: 110,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints.expand(height: 90, width: 90),
            margin: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                // border: Border.all(width: 0),
                borderRadius: BorderRadius.circular(20)),
            child: CachedNetworkImage(
              fit: BoxFit.fill,
              placeholder: (context, url) {
                return const CupertinoActivityIndicator(
                  radius: 8,
                );
              },
              imageUrl: appinfo.icon,
              width: 56,
              height: 56,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 8),
            child: Text(
              appinfo.name,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 8),
            child: Text(
              "实用工具",
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          )
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
