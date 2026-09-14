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

  /// 数据库统计信息
  final Map<String, int> statistics;

  /// 是否有更新可用
  final bool hasUpdate;

  /// 当前版本
  final int currentVersion;

  /// 最新版本
  final int latestVersion;

  /// 搜索结果
  final List<FdroidApp> searchResults;

  /// 是否正在搜索
  final bool isSearching;

  /// 已启用的源数量（多源并存，展示用）
  int get enabledSourcesCount => sources.where((s) => s.enabled).length;

  /// 索引声明的仓库元信息（来自模块 get_repo_meta）：
  /// name / description / mirrors / resolved_url / verified
  final Map<String, dynamic>? repoMeta;

  const FdroidRepoState({
    this.repoMeta,
    this.sources = const [],
    this.currentSource,
    this.isLoading = false,
    this.loadingProgress = 0.0,
    this.errorMessage,
    this.statistics = const {},
    this.hasUpdate = false,
    this.currentVersion = 0,
    this.latestVersion = 0,
    this.searchResults = const [],
    this.isSearching = false,
  });

  FdroidRepoState copyWith({
    Map<String, dynamic>? repoMeta,
    List<FdroidSource>? sources,
    FdroidSource? currentSource,
    bool? isLoading,
    double? loadingProgress,
    String? errorMessage,
    Map<String, int>? statistics,
    bool? hasUpdate,
    int? currentVersion,
    int? latestVersion,
    List<FdroidApp>? searchResults,
    bool? isSearching,
  }) {
    return FdroidRepoState(
      repoMeta: repoMeta ?? this.repoMeta,
      sources: sources ?? this.sources,
      currentSource: currentSource ?? this.currentSource,
      isLoading: isLoading ?? this.isLoading,
      loadingProgress: loadingProgress ?? this.loadingProgress,
      errorMessage: errorMessage ?? this.errorMessage,
      statistics: statistics ?? this.statistics,
      hasUpdate: hasUpdate ?? this.hasUpdate,
      currentVersion: currentVersion ?? this.currentVersion,
      latestVersion: latestVersion ?? this.latestVersion,
      searchResults: searchResults ?? this.searchResults,
      isSearching: isSearching ?? this.isSearching,
    );
  }
}