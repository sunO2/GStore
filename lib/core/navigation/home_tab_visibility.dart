/// AI 助手页可见性镜像（服务层无 Riverpod ref，由 UI 侧写入）。
///
/// AgentService 判断"当前是否在 AI 助手页"来决定是否发后台通知 /
/// 拦截敏感工具，但服务层不应反向依赖 UI（原 Get.find<HomeLogic>）。
///
/// 可见性来源有两个（互不感知、各自维护）：
/// - 首页 AI tab（HomePage index 2）：HomeNotifier 在 tab 切换时更新
/// - 独立 AI 路由页（我的页 push / 通知深链）：路由层进出时更新
class HomeTabVisibility {
  HomeTabVisibility._();

  static final HomeTabVisibility instance = HomeTabVisibility._();

  /// 首页 tab 是否停留在 AI 助手（index == 2）。
  bool _homeAgentTab = false;

  /// 是否位于独立 AI 助手路由页。
  bool _agentRoute = false;

  /// 是否认为 AI 助手页当前可见（两个来源任一成立）。
  bool get agentActive => _homeAgentTab || _agentRoute;

  /// 首页 tab 切换回调：AI tab 是否激活。
  void setHomeAgentTab(bool active) {
    _homeAgentTab = active;
  }

  /// 独立 AI 路由进出回调。
  void setAgentRoute(bool active) {
    _agentRoute = active;
  }
}
