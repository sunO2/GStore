import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/core/utils/logger.dart';
import 'logic.dart';

class SearchPage extends StatelessWidget {
  const SearchPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(SearchLogic());
    return Scaffold(
      appBar: AppBar(
        title: SizedBox(
          width: 240,
          child: TextField(
            autofocus: true,
            controller: logic.textEditingController,
            decoration: const InputDecoration(
              hintText: "搜索应用",
              border: InputBorder.none,
            ),
          ),
        ),
      ),
      body: Container(
          padding: const EdgeInsets.all(16),
          child: StreamBuilder(
              stream: logic.searchController.stream,
              builder: (context, snap) {
                var state = snap.connectionState;
                if (state != ConnectionState.active) {
                  return const SizedBox();
                }
                var data = snap.data;
                if (null == data) {
                  return const SizedBox();
                }
                return ListView.builder(
                  itemBuilder: (context, index) {
                    var app = data[index];
                    log("app: $app");
                    return ListTile(
                      onTap: () {
                        Get.toNamed(AppRoute.appDetail, arguments: app);
                      },
                      leading: Hero(
                        tag: app.icon,
                        child: Image(
                          image: CachedNetworkImageProvider(
                            data[index].icon,
                          ),
                          width: 48,
                          height: 48,
                        ),
                      ),
                      title: Hero(
                        tag: app.name,
                        child: Text(
                          app.name,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      subtitle: Text(
                        app.des,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    );
                  },
                  itemCount: data.length,
                );
              })),
    );
  }
}
