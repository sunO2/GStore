import 'package:gstore/core/core.dart';
import 'package:gstore/core/aggregate/aggregate.dart';

/// 应用列表排序模式
enum AppSortMode {
  /// 最近添加（默认）
  recent,

  /// 按名称 A-Z
  name,

  /// 可更新优先
  updateFirst,
}

class ApplistState {
  /// 聚合的应用列表（按添加时间排序）
  List<AggregatedAppInfo> apps = [];

  /// 过滤后的应用列表（用于显示搜索结果/分类筛选）
  List<AggregatedAppInfo> filteredApps = [];

  /// 搜索关键词
  final RxString searchKeyword = ''.obs;

  /// 数据库版本
  String version = "";

  /// 登录状态
  final RxInt loginStatus = (-1).obs;

  /// 是否正在加载
  final RxBool isLoading = false.obs;

  /// 错误信息
  final RxString errorMessage = ''.obs;

  /// 全部去重分类列表（含"全部"占位，数据来自 AppInfo.category）
  List<String> categories = [];

  /// 当前选中的分类（空串 = 全部）
  final RxString selectedCategory = ''.obs;

  /// 当前排序模式
  final Rx<AppSortMode> sortMode = AppSortMode.recent.obs;

  /// 可更新状态缓存（appId → 是否有更新）
  /// 懒加载：列表渲染后后台异步检测
  final Map<String, bool> updateStates = {};

  /// 是否正在检测更新
  final RxBool isCheckingUpdates = false.obs;

  ApplistState() {
    ///Initialize variables
  }
}
