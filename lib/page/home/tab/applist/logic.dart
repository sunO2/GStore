import 'package:flutter/material.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/http/github/dio_client.dart';

import 'state.dart';

class ApplistLogic extends GetxController with GithubRequestMix {
  final ApplistState state = ApplistState();
  IAggregateService? _aggregator;
  StreamSubscription? _appsSubscription;
  Timer? _searchDebounce;

  // 搜索框控制
  final FocusNode searchFocusNode = FocusNode();
  final TextEditingController searchController = TextEditingController();

  @override
  void onReady() async {
    super.onReady();

    // aggregate 模块下线 → 注册表取不到服务，降级：不订阅、不加载（页面空态）
    _aggregator = ModuleManager.instance.get<IAggregateService>();
    if (_aggregator == null) {
      appLog.error('ApplistLogic: ❌ 聚合模块未启用');
      return;
    }

    // 监听已添加应用变化
    _appsSubscription = _aggregator?.appsChangedStream.listen((_) {
      appLog.info('ApplistLogic: ✅ 收到 appsChangedStream 通知，重新加载应用列表');
      loadAggregatedApps();
    }, onError: (error) {
      appLog.error('ApplistLogic: ⚠️ appsChangedStream 发生错误 - $error');
    }, onDone: () {
      appLog.info('ApplistLogic: ℹ️ appsChangedStream 已关闭');
    });

    appLog.info('ApplistLogic: 🚀 开始加载应用数据...');
    await loadAggregatedApps();

    // 订阅 UpdateManager：可更新状态变化 → 刷新红点/分区/排序
    _updateSub = UpdateManagerService.instance.updateList.listen((_) {
      _syncUpdateStates();
      _applyFilter();
    });
    _syncUpdateStates();
  }

  /// 订阅 UpdateManager（页面销毁时取消）
  StreamSubscription? _updateSub;

  /// 同步可更新状态到本地（供红点/分区/排序）
  void _syncUpdateStates() {
    final manager = UpdateManagerService.instance;
    final states = <String, bool>{};
    for (final app in state.apps) {
      states[app.appInfo.appId] = manager.hasUpdate(app.appInfo.appId);
    }
    state.updateStates
      ..clear()
      ..addAll(states);
  }

  /// 可更新应用列表（用于"可更新"分区，数据来自 UpdateManager）
  List<AggregatedAppInfo> get updatableApps {
    final manager = UpdateManagerService.instance;
    final result = state.apps
        .where((app) => manager.hasUpdate(app.appInfo.appId))
        .toList();
    result.sort(
        (a, b) => b.addedAppInfo.addTime.compareTo(a.addedAppInfo.addTime));
    return result;
  }

  /// 加载聚合应用（首页/下拉刷新：只取第一页，滚动到底再加载更多）
  Future<void> loadAggregatedApps() async {
    appLog.info('ApplistLogic: ========== 开始加载聚合应用 ==========');
    state.isLoading.value = true;
    state.errorMessage.value = '';
    _loadedOffset = 0; // 重置分页游标

    try {
      debugPrint('ApplistLogic: 调用 _aggregator.getAggregatedAppsPage(0, $_pageSize)');
      final (apps, total) = await _aggregator?.getAggregatedAppsPage(
            offset: 0,
            limit: _pageSize,
          ) ??
          (const <AggregatedAppInfo>[], 0);
      appLog.info('ApplistLogic: ✅ 获取到 ${apps.length} 个聚合应用（共 $total）');

      state.apps = apps;
      state.totalCount = total;
      // 首页已按页大小消费 addedApps（与返回条数解耦）
      _loadedOffset = total >= _pageSize ? _pageSize : total;
      // 重新应用当前筛选（分类/搜索/排序）——不能直接显示全部，
      // 否则下拉刷新后 filteredApps 变为全部而 selectedCategory 仍选中旧分类（状态/显示不一致）
      _buildCategories();
      _applyFilter();

      appLog.info('ApplistLogic: 已更新 UI，应用数量: ${state.filteredApps.length}');
    } catch (e, stackTrace) {
      appLog.error('ApplistLogic: ❌ 加载聚合应用失败 - $e');
      debugPrint('ApplistLogic: 堆栈跟踪: $stackTrace');
      state.errorMessage.value = '加载失败: $e';
    } finally {
      state.isLoading.value = false;
    }
    appLog.info('ApplistLogic: ========== 加载聚合应用完成 ==========');
  }

  /// 滚动到底部时加载更多（追加到 state.apps，再重新应用筛选）
  Future<void> loadMoreApps() async {
    final aggregator = _aggregator;
    if (aggregator == null) return;
    // 首屏加载或已在上拉加载中 → 跳过（防重入）
    if (state.isLoading.value || state.isLoadingMore.value) return;
    // 已全部加载 → 跳过
    if (_loadedOffset >= state.totalCount) return;

    state.isLoadingMore.value = true;
    try {
      final (moreApps, total) = await aggregator.getAggregatedAppsPage(
        offset: _loadedOffset,
        limit: _pageSize,
      );
      state.totalCount = total;
      if (moreApps.isEmpty) {
        // 无更多或 offset 越界：对齐总数，防止反复加载
        _loadedOffset = total;
        return;
      }
      // 原始偏移量按页大小推进（不依赖返回条数——未知渠道 null 会被压缩，
      // 返回数可能少于页大小，但原始 addedApps 索引仍按页推进）
      _loadedOffset = (_loadedOffset + _pageSize > total)
          ? total
          : _loadedOffset + _pageSize;
      state.apps = [...state.apps, ...moreApps];
      // 新加载应用的可更新状态需要同步（红点/可更新分区）
      _syncUpdateStates();
      // 追加后重新应用筛选（新分类/可更新状态可能随之出现）
      _buildCategories();
      _applyFilter();
      appLog.info('ApplistLogic: 加载更多完成，累计 ${state.apps.length}/$total');
    } catch (e) {
      appLog.error('ApplistLogic: ❌ 加载更多失败 - $e');
    } finally {
      state.isLoadingMore.value = false;
    }
  }

  /// 是否还有更多可分页加载的应用
  bool get hasMore => _loadedOffset < state.totalCount;

  /// 分页大小：首页一次加载的应用数（避免一次性加载太多导致读取耗时）
  static const int _pageSize = 20;

  /// 原始已加载偏移（addedApps 索引游标，与返回条数解耦）
  int _loadedOffset = 0;

  /// 执行搜索（带防抖，与分类/排序组合）
  void searchApps(String keyword) {
    _searchDebounce?.cancel();
    state.searchKeyword.value = keyword;

    if (keyword.isEmpty) {
      _applyFilter();
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      // 搜索需要完整结果：先补齐未加载的分页（避免只搜到已加载的前几页）
      _ensureSearchedAllLoaded();
      _applyFilter();
    });
  }

  /// 立即执行搜索（用于清空等场景，与分类/排序组合）
  void searchAppsImmediate(String keyword) {
    _searchDebounce?.cancel();
    state.searchKeyword.value = keyword;
    if (keyword.isNotEmpty) {
      // 搜索需要完整结果：补齐剩余分页（前台 fire-and-forget，list 逐页追加刷新）
      unawaited(_ensureSearchedAllLoaded());
    }
    _applyFilter();
  }

  /// 搜索关键词非空时补齐所有剩余分页，保证搜索结果覆盖全部应用
  Future<void> _ensureSearchedAllLoaded() async {
    if (state.searchKeyword.value.isEmpty) return;
    while (hasMore) {
      // 分批补齐；若用户已清空搜索则立即停止
      if (state.searchKeyword.value.isEmpty) return;
      final before = state.apps.length;
      await loadMoreApps();
      // 无进展（全量加载中/已在加载更多/异常）时停止，避免死循环
      if (state.apps.length <= before) return;
    }
  }

  Future<void> checkUpdata() async {
    // getBanner();
    /// 仅当用户未手动设置代理时，才从远程拉取默认代理
    if (getProxy().isEmpty || getProxy() == defaultProxy) {
      try {
        var proxyConfigRequest = await DioClient.instance.get().get(
            "https://my-json-server.typicode.com/suno2/GStore-Repositorys/proxy");
        var proxyUrl = proxyConfigRequest.data["url"];
        if (proxyUrl?.toString().isNotEmpty ?? false) {
          log("请求代理地址结果： $proxyUrl");
          updateProxy(proxyUrl);
        }
      } catch (e) {
        log("拉取代理失败： $e");
      }
    }

    var downloadStatus = await "gstore".checkUpdate();
    if (downloadStatus == DbUpdateResult.success) {
      await loadAggregatedApps();
    }
  }

  //搜索页面
  void search() {
    appRouter.push(AppRoute.search);
  }

  /// 构建分类列表（从应用数据去重提取，含"全部"）
  void _buildCategories() {
    final set = <String>{};
    for (final app in state.apps) {
      final cats = app.appInfo.category;
      if (cats != null) {
        for (final c in cats) {
          if (c.trim().isNotEmpty) set.add(c.trim());
        }
      }
    }
    state.categories = set.toList()..sort();
  }

  /// 选择分类（空串 = 全部），与搜索组合过滤
  void setCategory(String category) {
    state.selectedCategory.value = category;
    _applyFilter();
  }

  /// 设置排序模式
  void setSortMode(AppSortMode mode) {
    state.sortMode.value = mode;
    _applyFilter();
  }

  /// 应用当前筛选（搜索词 + 分类）与排序
  void _applyFilter() {
    final keyword = state.searchKeyword.value.toLowerCase();
    final category = state.selectedCategory.value;
    final mode = state.sortMode.value;

    var list = state.apps.where((app) {
      // 搜索过滤
      if (keyword.isNotEmpty) {
        final nameMatch = app.appInfo.name?.toLowerCase().contains(keyword) ?? false;
        final descMatch = app.appInfo.des?.toLowerCase().contains(keyword) ?? false;
        final packageMatch = app.appInfo.appId.toLowerCase().contains(keyword);
        if (!nameMatch && !descMatch && !packageMatch) return false;
      }
      // 分类过滤
      if (category.isNotEmpty) {
        final cats = app.appInfo.category ?? const <String>[];
        if (!cats.contains(category)) return false;
      }
      return true;
    }).toList();

    // 排序
    switch (mode) {
      case AppSortMode.recent:
        list.sort((a, b) =>
            b.addedAppInfo.addTime.compareTo(a.addedAppInfo.addTime));
      case AppSortMode.name:
        list.sort((a, b) =>
            (a.appInfo.name ?? '').toLowerCase().compareTo((b.appInfo.name ?? '').toLowerCase()));
      case AppSortMode.updateFirst:
        list.sort((a, b) {
          final ua = state.updateStates[a.appInfo.appId] ?? false;
          final ub = state.updateStates[b.appInfo.appId] ?? false;
          if (ua != ub) return ua ? -1 : 1;
          return b.addedAppInfo.addTime.compareTo(a.addedAppInfo.addTime);
        });
    }
    state.filteredApps.value = list;
    update();
  }

  /// 最近添加应用（用于"最近添加"分区，前 [count] 个）
  List<AggregatedAppInfo> recentApps({int count = 8}) {
    final list = List.of(state.apps)
      ..sort(
          (a, b) => b.addedAppInfo.addTime.compareTo(a.addedAppInfo.addTime));
    return list.take(count).toList();
  }

  void appDetail(AggregatedAppInfo app) {
    // 创建轻量级的详情请求参数
    // 优先使用真实包名（B1 后 packageName 为 AppSummary 一级字段），否则 appId 占位
    // 注意：appId 原样传递（渠道查询键），不做格式转换——由渠道内部处理
    final packageName = app.appInfo.packageName ?? app.appInfo.appId;
    final request = AppDetailRequest(
      appId: app.appInfo.appId,
      name: app.appInfo.name,
      packageName: packageName,
      icon: app.appInfo.icon,
      description: app.appInfo.des,
      channel: app.channel,
      channelCode: app.channelCode,
    );
    appRouter.push(AppRoute.appDetail, extra: request);
  }

  /// 移除应用
  Future<void> removeApp(AggregatedAppInfo app) async {
    try {
      await _aggregator?.removeApp(
        channelCode: app.channelCode,
        appId: app.appInfo.appId,
      );

      Get.snackbar(
        '已移除',
        app.appInfo.name,
        icon: Icon(Icons.remove_circle, color: Colors.orange[700]),
        duration: const Duration(seconds: 1),
      );
    } catch (e) {
      Get.snackbar(
        '操作失败',
        e.toString(),
        icon: const Icon(Icons.error, color: Colors.red),
      );
    }
  }

  /// 导入示例应用（跳转到发现页）
  Future<void> importSampleApps() async {
    try {
      final homeLogic = Get.find();
      homeLogic.jumpToPage(1); // 切换到发现页

      Get.snackbar(
        '提示',
        '请在"发现"页面浏览并添加您感兴趣的应用',
        icon: const Icon(Icons.info_outline, color: AppColors.info),
        duration: const Duration(seconds: 3),
      );
    } catch (e) {
      appLog.error('ApplistLogic: 跳转失败 - $e');
    }
  }

  @override
  void onClose() {
    appLog.info('ApplistLogic: 🧹 开始清理资源...');

    // 清理搜索相关资源
    _searchDebounce?.cancel();
    _searchDebounce = null;
    appLog.info('ApplistLogic: ✅ 搜索防抖 Timer 已取消');

    // 取消流订阅
    if (_appsSubscription != null) {
      _appsSubscription!.cancel();
      _appsSubscription = null;
      appLog.info('ApplistLogic: ✅ 应用变化订阅已取消');
    }

    // 取消更新状态订阅
    if (_updateSub != null) {
      _updateSub!.cancel();
      _updateSub = null;
      appLog.info('ApplistLogic: ✅ 更新状态订阅已取消');
    }

    // 清理 Controller
    try {
      if (!searchFocusNode.hasFocus) {
        searchFocusNode.unfocus();
      }
      searchFocusNode.dispose();
      appLog.info('ApplistLogic: ✅ FocusNode 已释放');
    } catch (e) {
      appLog.error('ApplistLogic: ⚠️ FocusNode 释放时出错 - $e');
    }

    try {
      searchController.dispose();
      appLog.info('ApplistLogic: ✅ TextEditingController 已释放');
    } catch (e) {
      appLog.error('ApplistLogic: ⚠️ TextEditingController 释放时出错 - $e');
    }

    // 清理缓存
    state.apps.clear();
    state.filteredApps.clear();

    appLog.info('ApplistLogic: 🎉 所有资源已清理完毕');
    super.onClose();
  }
}
