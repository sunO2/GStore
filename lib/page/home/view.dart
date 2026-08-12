import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/page/home/tab/mine/view.dart';
import 'package:gstore/page/home/tab/applist/view.dart';
import 'package:gstore/page/agent/view.dart';
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
      // 内容延伸到悬浮导航胶囊后方，磨砂才能透出页面内容
      extendBody: true,
      body: PageView(
        physics: const NeverScrollableScrollPhysics(),
        controller: logic.controller,
        children: [
          const ApplistPage(),
          DiscoveryPage(),
          const AgentPage(),
          MinePage(),
        ],
      ),
      // 悬浮磨砂导航胶囊：BackdropFilter 磨砂 + 半透明主题底 + 圆角悬浮（M3 主题令牌）
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.xxl),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Obx(() {
                return NavigationBar(
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .surface
                      .withValues(alpha: 0.82),
                  selectedIndex: logic.state.index.value,
                  onDestinationSelected: (index) {
                    logic.jumpToPage(index);
                  },
                  destinations: [
                    NavigationDestination(
                        icon: AnimatedSwitcher(
                          duration: AppAnimations.normal,
                          child: ColorFiltered(
                            // AliIcon 是 COLR 彩色字体，不响应 IconTheme 颜色，强制染色
                            colorFilter: ColorFilter.mode(
                              (logic.state.index.value == 0)
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                              BlendMode.srcATop,
                            ),
                            child: Icon(
                              (logic.state.index.value == 0)
                                  ? AliIcon.appStoreActive
                                  : AliIcon.appStore,
                              key: ValueKey(
                                  logic.state.index.value == 0 ? 0 : 1),
                              size: AppTypography.iconLG,
                            ),
                          ),
                        ),
                        label: "首页"),
                    NavigationDestination(
                        icon: AnimatedSwitcher(
                          duration: AppAnimations.normal,
                          child: (logic.state.index.value == 1)
                              ? const Icon(Icons.explore, key: ValueKey(2))
                              : const Icon(Icons.explore_outlined,
                                  key: ValueKey(3)),
                        ),
                        label: "发现"),
                    NavigationDestination(
                        icon: AnimatedSwitcher(
                          duration: AppAnimations.normal,
                          child: (logic.state.index.value == 2)
                              ? const Icon(Icons.smart_toy, key: ValueKey(6))
                              : const Icon(Icons.smart_toy_outlined,
                                  key: ValueKey(7)),
                        ),
                        label: "AI 助手"),
                    NavigationDestination(
                        icon: AnimatedSwitcher(
                          duration: AppAnimations.normal,
                          child: (logic.state.index.value == 3)
                              ? const Icon(Icons.person, key: ValueKey(4))
                              : const Icon(Icons.person_outline,
                                  key: ValueKey(5)),
                        ),
                        label: "我的")
                  ],
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}
