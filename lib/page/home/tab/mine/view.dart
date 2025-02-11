import 'package:flutter/material.dart';
import 'package:gstore/page/home/tab/mine/logic.dart';
import 'package:gstore/core/core.dart';
import 'package:jovial_svg/jovial_svg.dart';

class MinePage extends StatelessWidget {
  TextEditingController controller = TextEditingController();

  MinePage({super.key});
  @override
  Widget build(BuildContext context) {
    final logic = Get.put(MineLogic());
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
      body: Container(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder(
          future: logic.getCategory(),
          builder: (context, snap) {
            var data = snap.data;
            if (snap.connectionState == ConnectionState.active ||
                snap.connectionState == ConnectionState.waiting ||
                null == data) {
              return const SizedBox();
            }

            return ListView.builder(
              itemCount: data.length,
              itemBuilder: (context, index) {
                var category = data[index];
                return ListTile(
                  leading: SizedBox(
                    width: 32,
                    height: 32,
                    child: ScalableImageWidget(
                      si: ScalableImage.fromSvgString(category.icon),
                    ),
                  ),
                  title: Text(
                    category.description,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  dense: true,
                  onTap: () => logic.category(category),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
