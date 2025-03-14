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
      bottomNavigationBar: Obx(() {
        return NavigationBar(
          backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(30),
          selectedIndex: logic.state.index.value,
          onDestinationSelected: (index) {
            logic.jumpToPage(index);
          },
          destinations: [
            NavigationDestination(
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  child: (logic.state.index.value == 0)
                      ? const Icon(Icons.grid_view_rounded, key: ValueKey(1))
                      : const Icon(Icons.grid_view_outlined, key: ValueKey(0)),
                ),
                label: "home".tr),
            NavigationDestination(
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  child: (logic.state.index.value == 1)
                      ? const Icon(Icons.category, key: ValueKey(1))
                      : const Icon(Icons.category_outlined, key: ValueKey(0)),
                ),
                label: "category".tr)
          ],
        );
      }),
    );
  }
}
