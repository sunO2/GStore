/// F-Droid 仓库管理页面状态
library;

import 'package:gstore/core/fdroid/FdroidRepoModels.dart';

/// F-Droid 仓库管理状态（Riverpod 不可变 state）
class FdroidRepoState {
  /// 可用的源列表
  final List<FdroidSource> sources;

  /// 当前选中的源
  final FdroidSource? currentSource;

  /// 是否正在加载
  final bool isLoading;

  /// 加载进度 (0-100)
  final double loadingProgress;

  /// 最后的错误信息
  final String? errorMessage;

  /// 数据统计（**按源**：每个源自己库里的应用数 + 该源最近一次同步结果）
  final List<FdroidSourceStat> statistics;

  /// 搜索结果
  final List<FdroidApp> searchResults;

  /// 是否正在搜索
  final bool isSearching;

  /// 已启用的源数量（多源并存，展示用）
  int get enabledSourcesCount => sources.where((s) => s.enabled).length;

  /// 数据统计（按源）；各项之和即总数
  int get totalAppCount =>
      statistics.fold(0, (sum, s) => sum + s.appCount);

  /// 已启用且已同步（有数据）的源数量
  int get syncedSourcesCount =>
      statistics.where((s) => s.appCount > 0).length;

  /// 本会话内走增量更新的源数量（0 表示都是全量或不适用）
  int get incrementalSourcesCount =>
      statistics.where((s) => s.lastSync?.incremental == true).length;

  /// 本会话内已同步过的源数量
  int get syncedThisSessionCount =>
      statistics.where((s) => s.lastSync != null).length;

  const FdroidRepoState({
    this.sources = const [],
    this.currentSource,
    this.isLoading = false,
    this.loadingProgress = 0.0,
    this.errorMessage,
    this.statistics = const [],
    this.searchResults = const [],
    this.isSearching = false,
  });

  FdroidRepoState copyWith({
    List<FdroidSource>? sources,
    FdroidSource? currentSource,
    bool? isLoading,
    double? loadingProgress,
    String? errorMessage,
    List<FdroidSourceStat>? statistics,
    List<FdroidApp>? searchResults,
    bool? isSearching,
  }) {
    return FdroidRepoState(
      sources: sources ?? this.sources,
      currentSource: currentSource ?? this.currentSource,
      isLoading: isLoading ?? this.isLoading,
      loadingProgress: loadingProgress ?? this.loadingProgress,
      errorMessage: errorMessage ?? this.errorMessage,
      statistics: statistics ?? this.statistics,
      searchResults: searchResults ?? this.searchResults,
      isSearching: isSearching ?? this.isSearching,
    );
  }
}