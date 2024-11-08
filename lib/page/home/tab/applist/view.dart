import 'package:flutter/material.dart';
import 'package:gstore/compent/app_widget.dart';

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
          child: Container(
            decoration: BoxDecoration(
                borderRadius: const BorderRadius.all(Radius.circular(40)),
                color: Theme.of(context).primaryColor.withAlpha(30)),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            width: 240,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
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
                    style: TextStyle(fontWeight: FontWeight.w400, fontSize: 18))
              ],
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: logic.checkUpdata,
        child: GetBuilder<ApplistLogic>(
            builder: (ctl) => GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                  itemCount: state.apps.isNotEmpty ? state.apps.length : 0,
                )),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
