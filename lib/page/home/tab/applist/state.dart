import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/http/github/user_info/user_info.dart';

/// 应用列表排序模式
enum AppSortMode {
  /// 最近添加（默认）
  recent,

  /// 按名称 A-Z
  name,

  /// 可更新优先
  updateFirst,
}

/// 首页应用列表状态（Riverpod 不可变 state）。
class ApplistState {
  /// 聚合的应用列表（按添加时间排序）
  final List<AggregatedAppInfo> apps;

  /// 过滤后的应用列表（用于显示搜索结果/分类筛选）
  final List<AggregatedAppInfo> filteredApps;

  /// 搜索关键词
  final String searchKeyword;

  /// 数据库版本
  final String version;

  /// 是否正在加载
  final bool isLoading;

  /// 是否正在分页加载更多（滚动到底加载下一页时置位，与首屏 isLoading 区分）
  final bool isLoadingMore;

  /// 已添加应用总数（分页用：已加载 app 数 < totalCount 时可继续加载）
  final int totalCount;

  /// 错误信息
  final String errorMessage;

  /// 全部去重分类列表（含"全部"占位，数据来自 AppInfo.category）
  final List<String> categories;

  /// 当前选中的分类（空串 = 全部）
  final String selectedCategory;

  /// 当前排序模式
  final AppSortMode sortMode;

  /// 可更新状态缓存（appId → 是否有更新，由 UpdateManager 驱动）
  final Map<String, bool> updateStates;

  /// 当前用户信息（UserManager.userInfo 的页面镜像）
  final UserInfo user;

  /// 应用更新红点数（BadgeService 的页面镜像，>0 显示角标）
  final int appUpdateBadge;

  const ApplistState({
    this.apps = const [],
    this.filteredApps = const [],
    this.searchKeyword = '',
    this.version = '',
    this.isLoading = false,
    this.isLoadingMore = false,
    this.totalCount = 0,
    this.errorMessage = '',
    this.categories = const [],
    this.selectedCategory = '',
    this.sortMode = AppSortMode.recent,
    this.updateStates = const {},
    this.user = const UserInfo(),
    this.appUpdateBadge = 0,
  });

  ApplistState copyWith({
    List<AggregatedAppInfo>? apps,
    List<AggregatedAppInfo>? filteredApps,
    String? searchKeyword,
    String? version,
    bool? isLoading,
    bool? isLoadingMore,
    int? totalCount,
    String? errorMessage,
    List<String>? categories,
    String? selectedCategory,
    AppSortMode? sortMode,
    Map<String, bool>? updateStates,
    UserInfo? user,
    int? appUpdateBadge,
  }) {
    return ApplistState(
      apps: apps ?? this.apps,
      filteredApps: filteredApps ?? this.filteredApps,
      searchKeyword: searchKeyword ?? this.searchKeyword,
      version: version ?? this.version,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      totalCount: totalCount ?? this.totalCount,
      errorMessage: errorMessage ?? this.errorMessage,
      categories: categories ?? this.categories,
      selectedCategory: selectedCategory ?? this.selectedCategory,
      sortMode: sortMode ?? this.sortMode,
      updateStates: updateStates ?? this.updateStates,
      user: user ?? this.user,
      appUpdateBadge: appUpdateBadge ?? this.appUpdateBadge,
    );
  }
}
