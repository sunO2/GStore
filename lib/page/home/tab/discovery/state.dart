import 'package:gstore/core/model/AppSummary.dart';

/// 显示模式
enum DisplayMode {
  /// 全部
  all,

  /// 已添加
  added,

  /// 未添加
  notAdded,
}

/// 发现页状态（Riverpod 不可变 state）。
class DiscoveryState {
  /// 当前选中的渠道 code（null 表示全部）
  /// 枚举渠道 = type.code（如 'vivo'）；脚本渠道 = channelKey（如 'js_pingan'）
  final String? selectedChannel;

  /// 所有渠道的应用列表（键 = 渠道 code，天然唯一：枚举 type.code / 脚本 channelKey）
  final Map<String, List<AppSummary>> channelApps;

  /// 已添加应用索引 (channelId -> Set<appId>)
  final Map<String, Set<String>> addedAppsIndex;

  /// 加载状态
  final bool isLoading;

  /// 错误信息
  final String errorMessage;

  /// 搜索关键词
  final String searchKeyword;

  /// 当前显示模式（全部/已添加/未添加）
  final DisplayMode displayMode;

  /// 每个渠道的当前页码（键 = 渠道 code）
  final Map<String, int> channelPages;

  /// 每个渠道是否正在加载更多（键 = 渠道 code）
  final Map<String, bool> channelLoadingMore;

  /// 每个渠道的总数（键 = 渠道 code）
  final Map<String, int> channelTotalCounts;

  /// 是否处于多选模式
  final bool isMultiSelectMode;

  /// 已选中的应用（key: "channelCode:appId"）
  final Set<String> selectedApps;

  /// Grid 交叉轴数量（响应式）
  final int crossAxisCount;

  const DiscoveryState({
    this.selectedChannel,
    this.channelApps = const {},
    this.addedAppsIndex = const {},
    this.isLoading = false,
    this.errorMessage = '',
    this.searchKeyword = '',
    this.displayMode = DisplayMode.all,
    this.channelPages = const {},
    this.channelLoadingMore = const {},
    this.channelTotalCounts = const {},
    this.isMultiSelectMode = false,
    this.selectedApps = const {},
    this.crossAxisCount = 3,
  });

  DiscoveryState copyWith({
    String? selectedChannel,
    bool clearSelectedChannel = false,
    Map<String, List<AppSummary>>? channelApps,
    Map<String, Set<String>>? addedAppsIndex,
    bool? isLoading,
    String? errorMessage,
    String? searchKeyword,
    DisplayMode? displayMode,
    Map<String, int>? channelPages,
    Map<String, bool>? channelLoadingMore,
    Map<String, int>? channelTotalCounts,
    bool? isMultiSelectMode,
    Set<String>? selectedApps,
    int? crossAxisCount,
  }) {
    return DiscoveryState(
      selectedChannel: clearSelectedChannel
          ? null
          : selectedChannel ?? this.selectedChannel,
      channelApps: channelApps ?? this.channelApps,
      addedAppsIndex: addedAppsIndex ?? this.addedAppsIndex,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage ?? this.errorMessage,
      searchKeyword: searchKeyword ?? this.searchKeyword,
      displayMode: displayMode ?? this.displayMode,
      channelPages: channelPages ?? this.channelPages,
      channelLoadingMore: channelLoadingMore ?? this.channelLoadingMore,
      channelTotalCounts: channelTotalCounts ?? this.channelTotalCounts,
      isMultiSelectMode: isMultiSelectMode ?? this.isMultiSelectMode,
      selectedApps: selectedApps ?? this.selectedApps,
      crossAxisCount: crossAxisCount ?? this.crossAxisCount,
    );
  }
}
