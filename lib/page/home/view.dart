import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/page/home/tab/mine/view.dart';
import 'package:gstore/page/home/tab/applist/view.dart';
import 'package:gstore/page/home/tab/channeltest/view.dart';
import 'package:gstore/page/home/tab/discovery/view.dart';

import 'logic.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/core.dart';

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
          DiscoveryPage(),
          ChannelTestPage(),
          MinePage(),
        ],
      ),
      bottomNavigationBar: Obx(() {
        return NavigationBar(
          backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(AppColors.withAlphaLower),
          selectedIndex: logic.state.index.value,
          onDestinationSelected: (index) {
            logic.jumpToPage(index);
          },
          destinations: [
            NavigationDestination(
                icon: AnimatedSwitcher(
                  duration: AppAnimations.normal,
                  child: (logic.state.index.value == 0)
                      ? const Icon(
                          AliIcon.appStoreActive,
                          key: ValueKey(0),
                          size: AppTypography.iconLG,
                        )
                      : const Icon(
                          AliIcon.appStore,
                          key: ValueKey(1),
                          size: AppTypography.iconLG,
                        ),
                ),
                label: "首页"),
            NavigationDestination(
                icon: AnimatedSwitcher(
                  duration: AppAnimations.normal,
                  child: (logic.state.index.value == 1)
                      ? const Icon(Icons.explore, key: ValueKey(2))
                      : const Icon(Icons.explore_outlined, key: ValueKey(3)),
                ),
                label: "发现"),
            NavigationDestination(
                icon: AnimatedSwitcher(
                  duration: AppAnimations.normal,
                  child: (logic.state.index.value == 2)
                      ? const Icon(Icons.science, key: ValueKey(6))
                      : const Icon(Icons.science_outlined, key: ValueKey(7)),
                ),
                label: "我的频道"),
            NavigationDestination(
                icon: AnimatedSwitcher(
                  duration: AppAnimations.normal,
                  child: (logic.state.index.value == 3)
                      ? const Icon(Icons.person, key: ValueKey(4))
                      : const Icon(Icons.person_outline, key: ValueKey(5)),
                ),
                label: "我的")
          ],
        );
      }),
    );
  }
}
