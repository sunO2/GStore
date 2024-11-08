import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/page/home/tab/mine/view.dart';
import 'package:gstore/page/home/tab/applist/view.dart';

import 'logic.dart';
import 'package:gstore/core/icons/Icons.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(HomeLogic());
    return Scaffold(
      body: PageView(
        physics: const NeverScrollableScrollPhysics(),
        controller: logic.controller,
        children: [
          const ApplistPage(),
          MinePage(),
        ],
      ),
      bottomNavigationBar: GetBuilder<HomeLogic>(builder: (ctl) {
        return BottomNavigationBar(
          items: [
            BottomNavigationBarItem(
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: (ctl.state.index() == 0)
                      ? const Icon(AliIcon.appStoreActive, key: ValueKey(0))
                      : const Icon(AliIcon.appStore, key: ValueKey(1)),
                ),
                label: "应用"),
            const BottomNavigationBarItem(
                icon: Icon(Icons.settings), label: "分类"),
          ],
          onTap: (index) {
            logic.jumpToPage(index);
          },
          currentIndex: ctl.state.index(),
          iconSize: 20,
        );
      }),
    );
  }
}
