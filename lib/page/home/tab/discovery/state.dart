import 'package:get/get.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/model/AppSummary.dart';

class DiscoveryState {
  /// 当前选中的渠道 code（null 表示全部）
  /// 枚举渠道 = type.code（如 'vivo'）；脚本渠道 = channelKey（如 'js_pingan'）
  final selectedChannel = Rx<String?>(null);

  /// 所有渠道的应用列表（键 = 渠道 code，天然唯一：枚举 type.code / 脚本 channelKey）
  final Map<String, List<AppSummary>> channelApps = <String, List<AppSummary>>{}.obs;

  /// 已添加应用索引 (channelId -> Set<appId>)
  final Map<String, Set<String>> addedAppsIndex = <String, Set<String>>{}.obs;

  /// 加载状态
  final isLoading = false.obs;

  /// 错误信息
  final errorMessage = ''.obs;

  /// 搜索关键词
  final searchKeyword = ''.obs;

  /// 当前显示模式（全部/已添加/未添加）
  final displayMode = DisplayMode.all.obs;

  /// 每个渠道的当前页码（键 = 渠道 code）
  final Map<String, int> channelPages = <String, int>{}.obs;

  /// 每个渠道是否正在加载更多（键 = 渠道 code）
  final Map<String, bool> channelLoadingMore = <String, bool>{}.obs;

  /// 每个渠道的总数（键 = 渠道 code）
  final Map<String, int> channelTotalCounts = <String, int>{}.obs;

  /// 是否处于多选模式
  final isMultiSelectMode = false.obs;

  /// 已选中的应用（key: "channelCode:appId"）
  final RxSet<String> selectedApps = <String>{}.obs;

  /// Grid 交叉轴数量（响应式）
  final crossAxisCount = 3.obs;

  DiscoveryState() {}
}

/// 显示模式
enum DisplayMode {
  /// 全部
  all,

  /// 已添加
  added,

  /// 未添加
  notAdded,
}
