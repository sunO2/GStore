import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state.dart';

/// 首页 tab 控制器（Riverpod Notifier）。
///
/// 承载 PageView 的 [controller] 与当前 tab 下标状态。
/// 被首页 view 等消费。
class HomeNotifier extends Notifier<HomeState> {
  /// PageView 控制器（随 Notifier 生命周期创建/释放；
  /// 外部经 [jumpToPage] 统一驱动，不直接持有）。
  late final PageController controller = PageController();

  @override
  HomeState build() {
    ref.onDispose(controller.dispose);
    return const HomeState();
  }

  /// 切换 tab（PageView 瞬移 + 状态更新）。
  void jumpToPage(int index) {
    state = state.copyWith(index: index);
    // 瞬移：无滚动动画、不经过中间页（交叉淡入淡出由 HomeView 层负责）
    if (controller.hasClients) {
      controller.jumpToPage(index);
    }
  }
}

/// 首页 tab provider（全局唯一，非 autoDispose：
/// HomePage 是 GoRouter 根路由必然先 build，AI 助手独立路由可安全读取）。
final homeProvider = NotifierProvider<HomeNotifier, HomeState>(
  HomeNotifier.new,
);

/// Scene 经典三 tab（功能 / 首页 / 设置）的稳定导航顺序。
///
/// **纯增量**：作为后续 todo 5 三 tab 外壳的规范顺序来源，
/// 供 `PageView`/`PageController` 等消费方引用以避免散落的魔法下标。
/// 当前四 tab `PageView` 路径不使用本常量，因此不改变任何既有行为。
const List<HomeTab3> homeTab3Order = HomeTab3.values;
