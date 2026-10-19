/// 首页 tab 状态（Riverpod 不可变 state）。
class HomeState {
  /// 当前原始 tab 下标（0-3：首页/发现/AI 助手/我的）。
  final int index;

  /// 进入 AI 助手页（index 2）前的来源 tab（AI 页返回按钮/系统返回的目标）。
  final int sourceIndex;

  const HomeState({this.index = 0, this.sourceIndex = 0});

  HomeState copyWith({int? index, int? sourceIndex}) {
    return HomeState(
      index: index ?? this.index,
      sourceIndex: sourceIndex ?? this.sourceIndex,
    );
  }
}

/// Scene 经典三 tab（功能 / 首页 / 设置）的索引模型。
///
/// **纯增量**：本类型只描述后续 todo 5 引入的三 tab 外壳的下标语义，
/// 与既有四 tab raw 下标（首页/发现/AI 助手/我的）**并行存在**。
/// 本 commit 不接入任何 `PageView`/`jumpToPage` 逻辑，因此不改变
/// [HomeState.index]/[HomeState.sourceIndex] 的既有可观察行为。
enum HomeTab3 {
  /// 功能（Scene 功能网格）。
  features(tabIndex: 0, label: '功能'),

  /// 首页（Scene 风格仪表盘）。
  home(tabIndex: 1, label: '首页'),

  /// 设置（原「我的」页作为设置 tab）。
  settings(tabIndex: 2, label: '设置');

  const HomeTab3({required this.tabIndex, required this.label});

  /// 底部导航中的稳定下标（0 起）。
  ///
  /// 命名避让 [Enum.index]（枚举声明序），以保证与导航下标解耦。
  final int tabIndex;

  /// 底部导航标签文案。
  final String label;

  /// tab 数量（供 `PageView`/`PageController` 等消费方引用，避免魔法数字）。
  static const int count = 3;

  /// 按下标解析 tab；越界时回退到 [HomeTab3.features]。
  static HomeTab3 fromIndex(int index) {
    for (final tab in values) {
      if (tab.tabIndex == index) return tab;
    }
    return HomeTab3.features;
  }
}
