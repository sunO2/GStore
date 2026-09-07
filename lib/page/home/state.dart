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
