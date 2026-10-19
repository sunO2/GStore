import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/core.dart';

import 'state.dart';

/// 首页 tab 控制器（Riverpod Notifier）。
///
/// 承载 PageView 的 [controller] 与当前/来源 tab 下标状态。
/// 被首页 view、AI 助手页（返回按钮/输入栏避让）等消费。
class HomeNotifier extends Notifier<HomeState> {
  /// PageView 控制器（随 Notifier 生命周期创建/释放；
  /// 外部经 [jumpToPage] 统一驱动，不直接持有）。
  late final PageController controller = PageController();

  @override
  HomeState build() {
    ref.onDispose(controller.dispose);
    // 初始同步 AI 助手页可见性（首页启动默认在 tab 0，AI 页不可见）
    HomeTabVisibility.instance.setHomeAgentTab(false);
    return const HomeState();
  }

  /// 切换 tab（sourceIndex 记录 + PageView 瞬移 + 状态更新）。
  ///
  /// 进入 AI 助手页（index 2）且此前不在 AI 页时，把旧 tab 记入
  /// sourceIndex（AI 页"返回"按钮/系统返回键的目标）。
  void jumpToPage(int index) {
    if (index == 2 && state.index != 2) {
      state = state.copyWith(sourceIndex: state.index, index: index);
    } else {
      state = state.copyWith(index: index);
    }
    // 瞬移：无滚动动画、不经过中间页（交叉淡入淡出由 HomeView 层负责）
    if (controller.hasClients) {
      controller.jumpToPage(index);
    }
    // 同步 AI tab 可见性到服务层镜像
    HomeTabVisibility.instance.setHomeAgentTab(index == 2);
  }
}

/// 首页 tab provider（全局唯一，非 autoDispose：
/// HomePage 是 GoRouter 根路由必然先 build，AI 助手独立路由可安全读取）。
final homeProvider = NotifierProvider<HomeNotifier, HomeState>(
  HomeNotifier.new,
);
