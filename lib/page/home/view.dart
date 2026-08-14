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

/// tab 切换交叉淡入（M3 fadeThrough）：按 PageController 当前 page 位置插值 opacity。
/// 当前页 opacity 1，切换过程中邻页按距离 0→1 交叉淡入。
class _TabFadeThrough extends StatelessWidget {
  const _TabFadeThrough({
    required this.animation,
    required this.index,
    required this.fallbackIndex,
    required this.child,
  });

  /// PageController（作为 Listenable，动画/滚动期间逐帧通知重建）
  final Listenable animation;

  /// 本页在 PageView 中的下标
  final int index;

  /// [PageController.page] 为 null（尚未布局/无像素）时的兜底当前页
  final double fallbackIndex;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final controller = animation as PageController;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        // PageController.page 语义（SDK page_view.dart 已查证）：
        // page = clamp(pixels, min, max) / (viewportDimension * viewportFraction)，
        // 由实时 pixels 计算 —— animateToPage 动画期间逐帧返回插值 float（非 null/旧值）；
        // 仅在未布局（!hasPixels / 无内容尺寸）时返回 null，此时兜底 fallbackIndex。
        final page = controller.page ?? fallbackIndex;
        final distance = (page - index).abs().clamp(0.0, 1.0).toDouble();
        // 补偿 PageView 平移：页 i 屏幕位置 = (i - page)*W，反向补偿 +(page - i)*W 使内容静止
        final translateX = (page - index) * MediaQuery.of(context).size.width;
        return Opacity(
          opacity: 1 - distance,
          child: Transform.translate(
            offset: Offset(translateX, 0),
            child: child,
          ),
        );
      },
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(HomeLogic());
    // AI 助手 tab 时拦截系统返回：回到来源 tab（而非退出 app）
    // canPop 动态跟随 index：非 AI tab 返回键正常退出
    return Obx(() {
      final isAiTab = logic.state.index.value == 2;
      return PopScope(
        canPop: !isAiTab,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && isAiTab) {
            logic.jumpToPage(logic.state.sourceIndex.value);
          }
        },
        child: Scaffold(
          // 内容延伸到悬浮导航胶囊后方，磨砂才能透出页面内容
          extendBody: true,
          // 禁用自动键盘压缩：输入栏位置由各页用 viewInsets 手动控制
          // （AI 悬浮输入栏需精确贴键盘，Scaffold 压缩会导致双倍偏移）
          resizeToAvoidBottomInset: false,
          body: PageView(
            physics: const NeverScrollableScrollPhysics(),
            controller: logic.controller,
            children: [
              _TabFadeThrough(
                animation: logic.controller,
                index: 0,
                fallbackIndex: logic.state.index.value.toDouble(),
                child: const ApplistPage(),
              ),
              _TabFadeThrough(
                animation: logic.controller,
                index: 1,
                fallbackIndex: logic.state.index.value.toDouble(),
                child: const DiscoveryPage(),
              ),
              _TabFadeThrough(
                animation: logic.controller,
                index: 2,
                fallbackIndex: logic.state.index.value.toDouble(),
                child: const AgentPage(isTabEmbedded: true),
              ),
              _TabFadeThrough(
                animation: logic.controller,
                index: 3,
                fallbackIndex: logic.state.index.value.toDouble(),
                child: const MinePage(),
              ),
            ],
          ),
          // 悬浮磨砂导航胶囊：BackdropFilter 磨砂 + 半透明主题底 + 圆角悬浮（M3 主题令牌）
          // AI 助手页激活时下沉滑出（聚焦模式，由输入栏左侧"返回"按钮接管导航）
          bottomNavigationBar: Obx(() {
            final isAiTab = logic.state.index.value == 2;
            return AnimatedSlide(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              offset: isAiTab ? const Offset(0, 1.2) : Offset.zero,
              child: ExcludeSemantics(
                excluding: isAiTab,
                child: IgnorePointer(
                  ignoring: isAiTab,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        0,
                        AppSpacing.lg,
                        AppSpacing.md,
                      ),
                      child: ClipRRect(
                        // 大圆角胶囊（高度 64 时近似全圆）
                        borderRadius: BorderRadius.circular(
                          AppRadius.xxl + AppRadius.sm,
                        ),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                          child: Obx(() {
                            // 局部压缩胶囊高度（M3 默认 80 → 64，更紧凑；主题其他属性不变）
                            return Theme(
                              data: Theme.of(context).copyWith(
                                navigationBarTheme:
                                    const NavigationBarThemeData(height: 64),
                              ),
                              child: NavigationBar(
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
                                    // 选中项图标微放大（AnimatedScale 包在 AnimatedSwitcher 外，
                                    // 两动画独立叠加：切换淡入淡出 + 缩放）
                                    icon: AnimatedScale(
                                      scale: (logic.state.index.value == 0)
                                          ? 1.15
                                          : 1.0,
                                      duration: AppAnimation.fast,
                                      curve: AppAnimation.curve,
                                      child: AnimatedSwitcher(
                                        duration: AppAnimations.normal,
                                        child: ColorFiltered(
                                          // AliIcon 是 COLR 彩色字体，不响应 IconTheme 颜色，强制染色
                                          colorFilter: ColorFilter.mode(
                                            (logic.state.index.value == 0)
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .primary
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
                                              logic.state.index.value == 0
                                                  ? 0
                                                  : 1,
                                            ),
                                            size: AppTypography.iconLG,
                                          ),
                                        ),
                                      ),
                                    ),
                                    label: "首页",
                                  ),
                                  NavigationDestination(
                                    icon: AnimatedScale(
                                      scale: (logic.state.index.value == 1)
                                          ? 1.15
                                          : 1.0,
                                      duration: AppAnimation.fast,
                                      curve: AppAnimation.curve,
                                      child: AnimatedSwitcher(
                                        duration: AppAnimations.normal,
                                        child:
                                            (logic.state.index.value == 1)
                                                ? const Icon(Icons.explore,
                                                    key: ValueKey(2))
                                                : const Icon(
                                                    Icons.explore_outlined,
                                                    key: ValueKey(3)),
                                      ),
                                    ),
                                    label: "发现",
                                  ),
                                  NavigationDestination(
                                    icon: AnimatedScale(
                                      scale: (logic.state.index.value == 2)
                                          ? 1.15
                                          : 1.0,
                                      duration: AppAnimation.fast,
                                      curve: AppAnimation.curve,
                                      child: AnimatedSwitcher(
                                        duration: AppAnimations.normal,
                                        child:
                                            (logic.state.index.value == 2)
                                                ? const Icon(Icons.smart_toy,
                                                    key: ValueKey(6))
                                                : const Icon(
                                                    Icons.smart_toy_outlined,
                                                    key: ValueKey(7)),
                                      ),
                                    ),
                                    label: "AI 助手",
                                  ),
                                  NavigationDestination(
                                    icon: AnimatedScale(
                                      scale: (logic.state.index.value == 3)
                                          ? 1.15
                                          : 1.0,
                                      duration: AppAnimation.fast,
                                      curve: AppAnimation.curve,
                                      child: AnimatedSwitcher(
                                        duration: AppAnimations.normal,
                                        child:
                                            (logic.state.index.value == 3)
                                                ? const Icon(Icons.person,
                                                    key: ValueKey(4))
                                                : const Icon(
                                                    Icons.person_outline,
                                                    key: ValueKey(5)),
                                      ),
                                    ),
                                    label: "我的",
                                  ),
                                ],
                              ),
                            );
                          }),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      );
    });
  }
}
