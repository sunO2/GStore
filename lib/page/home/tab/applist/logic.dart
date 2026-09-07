import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/http/github/dio_client.dart';

import 'state.dart';

/// 首页应用列表控制器（Riverpod Notifier）。
///
/// 数据源：IAggregateService（聚合模块注册表），订阅其 appsChangedStream
/// 响应已添加应用变化；UpdateManager 驱动可更新状态；UserManager/BadgeService
/// 的用户信息与红点经页面镜像进 state（服务层仍 GetX，页面不直接依赖）。
class ApplistNotifier extends AutoDisposeNotifier<ApplistState> {
  StreamSubscription? _appsSubscription;
  StreamSubscription? _updateSub;
  StreamSubscription? _userSub;
  StreamSubscription? _badgeSub;
  Timer? _searchDebounce;

  // 搜索框控制（随 Notifier 生命周期）
  final FocusNode searchFocusNode = FocusNode();
  final TextEditingController searchController = TextEditingController();

  /// 列表滚动控制器（接近底部触发 loadMore；随 Notifier 生命周期）
  final ScrollController scrollController = ScrollController();

  /// 是否已释放（async 回调后写 state 前检查）
  bool _disposed = false;

  /// 分页大小：首页一次加载的应用数（避免一次性加载太多导致读取耗时）
  static const int _pageSize = 20;

  /// 原始已加载偏移（addedApps 索引游标，与返回条数解耦）
  int _loadedOffset = 0;

  /// 聚合服务（经模块注册表取；aggregate 模块下线返回 null → 页面降级空态）
  IAggregateService? get _aggregator =>
      ModuleManager.instance.get<IAggregateService>();

  @override
  ApplistState build() {
    ref.onDispose(_dispose);
    // 首帧初始化（onReady 语义）：UI 镜像订阅 + 聚合数据订阅
    Future.microtask(() {
      if (_disposed) return;
      _subscribeUiMirrors();
      _init();
    });
    return const ApplistState();
  }

  void _dispose() {
    _disposed = true;
    _searchDebounce?.cancel();
    _appsSubscription?.cancel();
    _updateSub?.cancel();
    _userSub?.cancel();
    _badgeSub?.cancel();
    searchFocusNode.dispose();
    searchController.dispose();
    scrollController.dispose();
  }

  /// 订阅跨页 UI 镜像（用户信息/红点）。
  /// 这些服务经 GetX 容器获取；容器未注册（如聚合模块下线/测试降级）时
  /// 尽力而为跳过，不影响页面降级空态。
  void _subscribeUiMirrors() {
    // 订阅用户信息（登录/登出 → 头像刷新）
    try {
      final um = UserManager.instance;
      _userSub = um.userInfo.listen((user) {
        if (_disposed) return;
        state = state.copyWith(user: user);
      });
      state = state.copyWith(user: um.userInfo.value);
    } catch (_) {
      // UserManager 未注册：保持默认用户
    }

    // 订阅更新红点
    try {
      final bs = BadgeService.instance;
      _badgeSub = bs.badges.listen((_) {
        if (_disposed) return;
        state = state.copyWith(
          appUpdateBadge: bs.countOf(BadgeKey.appUpdate),
        );
      });
      state = state.copyWith(
        appUpdateBadge: bs.countOf(BadgeKey.appUpdate),
      );
    } catch (_) {
      // BadgeService 未注册：无角标
    }
  }

  /// 首次初始化：订阅聚合数据源并加载。
  Future<void> _init() async {
    final aggregator = _aggregator;
    if (aggregator == null) {
      // 聚合模块未启用：不订阅、不加载（页面空态）
      appLog.error('ApplistNotifier: ❌ 聚合模块未启用');
      return;
    }
    // 监听已添加应用变化
    _appsSubscription = aggregator.appsChangedStream.listen((_) {
      appLog.info('ApplistNotifier: ✅ 收到 appsChangedStream 通知，重新加载应用列表');
      loadAggregatedApps();
    }, onError: (error) {
      appLog.error('ApplistNotifier: ⚠️ appsChangedStream 发生错误 - $error');
    }, onDone: () {
      appLog.info('ApplistNotifier: ℹ️ appsChangedStream 已关闭');
    });
    appLog.info('ApplistNotifier: 🚀 开始加载应用数据...');
    await loadAggregatedApps();
    if (_disposed) return;

    // 订阅 UpdateManager：可更新状态变化 → 刷新红点/分区/排序
    try {
      _updateSub = UpdateManagerService.instance.updateList.listen((_) {
        _syncUpdateStates();
        _applyFilter();
      });
      _syncUpdateStates();
    } catch (_) {
      // UpdateManager 未注册：无可更新状态
    }
  }

  /// 同步可更新状态到本地（供红点/分区/排序）
  void _syncUpdateStates() {
    final manager = UpdateManagerService.instance;
    final states = <String, bool>{};
    for (final app in state.apps) {
      states[app.appInfo.appId] = manager.hasUpdate(app.appInfo.appId);
    }
    state = state.copyWith(updateStates: states);
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
    appLog.info('ApplistNotifier: ========== 开始加载聚合应用 ==========');
    state = state.copyWith(isLoading: true, errorMessage: '');
    _loadedOffset = 0; // 重置分页游标

    try {
      final aggregator = _aggregator;
      debugPrint('ApplistNotifier: 调用 getAggregatedAppsPage(0, $_pageSize)');
      final (apps, total) = await aggregator?.getAggregatedAppsPage(
            offset: 0,
            limit: _pageSize,
          ) ??
          (const <AggregatedAppInfo>[], 0);
      if (_disposed) return;
      appLog.info('ApplistNotifier: ✅ 获取到 ${apps.length} 个聚合应用（共 $total）');

      // 首页已按页大小消费 addedApps（与返回条数解耦）
      _loadedOffset = total >= _pageSize ? _pageSize : total;
      // 重新应用当前筛选（分类/搜索/排序）——不能直接显示全部，
      // 否则下拉刷新后 filteredApps 变为全部而 selectedCategory 仍选中旧分类（状态/显示不一致）
      state = state.copyWith(apps: apps, totalCount: total);
      _buildCategories();
      _applyFilter();

      appLog.info('ApplistNotifier: 已更新 UI，应用数量: ${state.filteredApps.length}');
    } catch (e, stackTrace) {
      appLog.error('ApplistNotifier: ❌ 加载聚合应用失败 - $e');
      debugPrint('ApplistNotifier: 堆栈跟踪: $stackTrace');
      if (!_disposed) {
        state = state.copyWith(errorMessage: '加载失败: $e');
      }
    } finally {
      if (!_disposed) {
        state = state.copyWith(isLoading: false);
      }
    }
    appLog.info('ApplistNotifier: ========== 加载聚合应用完成 ==========');
  }

  /// 滚动到底部时加载更多（追加到 apps，再重新应用筛选）
  Future<void> loadMoreApps() async {
    final aggregator = _aggregator;
    if (aggregator == null) return;
    // 首屏加载或已在上拉加载中 → 跳过（防重入）
    if (state.isLoading || state.isLoadingMore) return;
    // 已全部加载 → 跳过
    if (_loadedOffset >= state.totalCount) return;

    state = state.copyWith(isLoadingMore: true);
    try {
      final (moreApps, total) = await aggregator.getAggregatedAppsPage(
        offset: _loadedOffset,
        limit: _pageSize,
      );
      if (_disposed) return;
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
      state = state.copyWith(
        apps: [...state.apps, ...moreApps],
        totalCount: total,
      );
      // 新加载应用的可更新状态需要同步（红点/可更新分区）
      _syncUpdateStates();
      // 追加后重新应用筛选（新分类/可更新状态可能随之出现）
      _buildCategories();
      _applyFilter();
      appLog.info('ApplistNotifier: 加载更多完成，累计 ${state.apps.length}/$total');
    } catch (e) {
      appLog.error('ApplistNotifier: ❌ 加载更多失败 - $e');
    } finally {
      if (!_disposed) {
        state = state.copyWith(isLoadingMore: false);
      }
    }
  }

  /// 是否还有更多可分页加载的应用
  bool get hasMore => _loadedOffset < state.totalCount;

  /// 执行搜索（带防抖，与分类/排序组合）
  void searchApps(String keyword) {
    _searchDebounce?.cancel();
    state = state.copyWith(searchKeyword: keyword);

    if (keyword.isEmpty) {
      _applyFilter();
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (_disposed) return;
      // 搜索需要完整结果：先补齐未加载的分页（避免只搜到已加载的前几页）
      _ensureSearchedAllLoaded();
      _applyFilter();
    });
  }

  /// 立即执行搜索（用于清空等场景，与分类/排序组合）
  void searchAppsImmediate(String keyword) {
    _searchDebounce?.cancel();
    state = state.copyWith(searchKeyword: keyword);
    if (keyword.isNotEmpty) {
      // 搜索需要完整结果：补齐剩余分页（前台 fire-and-forget，list 逐页追加刷新）
      unawaited(_ensureSearchedAllLoaded());
    }
    _applyFilter();
  }

  /// 搜索关键词非空时补齐所有剩余分页，保证搜索结果覆盖全部应用
  Future<void> _ensureSearchedAllLoaded() async {
    if (state.searchKeyword.isEmpty) return;
    while (hasMore) {
      // 分批补齐；若用户已清空搜索则立即停止
      if (state.searchKeyword.isEmpty) return;
      final before = state.apps.length;
      await loadMoreApps();
      if (_disposed) return;
      // 无进展（全量加载中/已在加载更多/异常）时停止，避免死循环
      if (state.apps.length <= before) return;
    }
  }

  /// 应用版本更新检查（代理拉取 + GStore 数据库更新）
  Future<void> checkUpdata() async {
    // 仅当用户未手动设置代理时，才从远程拉取默认代理
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

  /// 打开搜索页
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
    state = state.copyWith(categories: set.toList()..sort());
  }

  /// 选择分类（空串 = 全部），与搜索组合过滤
  void setCategory(String category) {
    state = state.copyWith(selectedCategory: category);
    _applyFilter();
  }

  /// 设置排序模式
  void setSortMode(AppSortMode mode) {
    state = state.copyWith(sortMode: mode);
    _applyFilter();
  }

  /// 应用当前筛选（搜索词 + 分类）与排序
  void _applyFilter() {
    final keyword = state.searchKeyword.toLowerCase();
    final category = state.selectedCategory;
    final mode = state.sortMode;

    var list = state.apps.where((app) {
      // 搜索过滤
      if (keyword.isNotEmpty) {
        final nameMatch = app.appInfo.name.toLowerCase().contains(keyword);
        final descMatch = app.appInfo.des.toLowerCase().contains(keyword);
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
        list.sort((a, b) => a.appInfo.name.toLowerCase().compareTo(
            b.appInfo.name.toLowerCase()));
      case AppSortMode.updateFirst:
        list.sort((a, b) {
          final ua = state.updateStates[a.appInfo.appId] ?? false;
          final ub = state.updateStates[b.appInfo.appId] ?? false;
          if (ua != ub) return ua ? -1 : 1;
          return b.addedAppInfo.addTime.compareTo(a.addedAppInfo.addTime);
        });
    }
    state = state.copyWith(filteredApps: list);
  }

  /// 最近添加应用（用于"最近添加"分区，前 [count] 个）
  List<AggregatedAppInfo> recentApps({int count = 8}) {
    final list = List.of(state.apps)
      ..sort(
          (a, b) => b.addedAppInfo.addTime.compareTo(a.addedAppInfo.addTime));
    return list.take(count).toList();
  }

  /// 打开应用详情
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
      AppDialogs.showSuccess(app.appInfo.name.isNotEmpty
          ? '已移除：${app.appInfo.name}'
          : '已移除');
    } catch (e) {
      AppDialogs.showError('操作失败：$e');
    }
  }
}

/// 首页应用列表 provider（页面级 autoDispose：作为首页 tab keepAlive 时
/// 切走不销毁、数据保留）。
final applistProvider =
    NotifierProvider.autoDispose<ApplistNotifier, ApplistState>(
  ApplistNotifier.new,
);
