import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/event/live_refresh.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/router/app_router.dart';

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

  /// 渠道/目录变化（Rust 上行）的防抖订阅：一串事件只重跑一次加载。
  LiveRefreshSubscription? _liveRefresh;

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

  /// 聚合加载重入守卫：一次加载在飞行中时，后续调用立即返回，
  /// 绝不产生第二次 facade/Rust 调用（LiveRefresh/下拉/应用变化可能同时触发）。
  bool _loading = false;

  /// 分页加载更多在飞行中时收到的刷新请求：合并为一次延迟刷新。
  ///
  /// 刷新成功分支会用 page 0 整体替换 [ApplistState.apps]，若在 loadMore
  /// 追加页面期间直接执行，会丢掉刚追加的行并把 [_loadedOffset] 回退，
  /// 之后 [_ensureSearchedAllLoaded] 会重复追加同一页。故此处只登记，
  /// 待 loadMore 的 finally 提交完追加后再静默重跑一次。
  bool _pendingRefresh = false;

  /// 聚合服务（经模块注册表取；aggregate 模块下线返回 null → 页面降级空态）
  IAggregateService? get _aggregator =>
      ModuleManager.instance.get<IAggregateService>();

  @override
  ApplistState build() {
    ref.onDispose(_dispose);
    // 渠道/目录变化（Rust 上行 channel.changed / catalog.changed）→ 防抖重跑
    // 首屏加载（复用 [loadAggregatedApps] 的既有 loading 态，无新 loading UI）。
    _liveRefresh = LiveRefreshSubscription(onRefresh: _onLiveRefresh);
    // 首帧初始化（onReady 语义）：UI 镜像订阅 + 聚合数据订阅
    Future.microtask(() {
      if (_disposed) return;
      _subscribeUiMirrors();
      _init();
    });
    return const ApplistState();
  }

  /// 渠道/目录变化 → 防抖后静默刷新（保留旧列表，只更新数据）。
  void _onLiveRefresh() {
    if (_disposed) return;
    unawaited(refreshSilently());
  }

  void _dispose() {
    _disposed = true;
    _searchDebounce?.cancel();
    _liveRefresh?.dispose();
    _liveRefresh = null;
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
      _userSub = um.userInfoStream.listen((user) {
        if (_disposed) return;
        state = state.copyWith(user: user);
      });
      state = state.copyWith(user: um.userInfo);
    } catch (_) {
      // UserManager 未注册：保持默认用户
    }

    // 订阅更新红点
    try {
      final bs = BadgeService.instance;
      _badgeSub = bs.badgesStream.listen((_) {
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
      _updateSub = UpdateFacade.instance.updateListStream.listen((_) {
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
    final manager = UpdateFacade.instance;
    final states = <String, bool>{};
    for (final app in state.apps) {
      states[app.appInfo.appId] = manager.cachedHasUpdate(app.appInfo.appId);
    }
    state = state.copyWith(updateStates: states);
  }

  /// 可更新应用列表（用于"可更新"分区，数据来自 UpdateManager）
  List<AggregatedAppInfo> get updatableApps {
    final manager = UpdateFacade.instance;
    final result = state.apps
        .where((app) => manager.cachedHasUpdate(app.appInfo.appId))
        .toList();
    result.sort(
        (a, b) => b.addedAppInfo.addTime.compareTo(a.addedAppInfo.addTime));
    return result;
  }

  /// 加载聚合应用（首页/重试：列表为空时进入全屏 loading，否则转静默刷新）
  Future<void> loadAggregatedApps() => _loadAggregatedPage(silent: false);

  /// 静默刷新（下拉刷新 / LiveRefresh 用）：绝不置 [ApplistState.isLoading]，
  /// 屏幕上的旧列表保持不动，只在顶部显示细进度。
  Future<void> refreshSilently() => _loadAggregatedPage(silent: true);

  /// 首屏加载的实现（重入受守卫，成功分支才推进分页游标）。
  Future<void> _loadAggregatedPage({required bool silent}) async {
    if (_loading) {
      // 已有加载在飞行中：直接返回，不发第二次 facade/Rust 调用。
      appLog.info('ApplistNotifier: ⏭️ 聚合加载进行中，跳过本次重复请求');
      return;
    }
    if (state.isLoadingMore) {
      // 分页追加在飞行中：此时刷新会用 page 0 覆盖 state.apps 并回退分页游标，
      // 造成已追加行丢失 / 同页重复。合并为一次延迟刷新，等 loadMore 提交后
      // 在它的 finally 里静默重跑（见 _pendingRefresh）。
      _pendingRefresh = true;
      appLog.info('ApplistNotifier: ⏭️ 分页加载进行中，合并本次刷新');
      return;
    }
    _loading = true;
    // 只有「列表为空」的首屏加载才允许全屏 loading，避免刷新时白屏。
    final blocking = !silent && state.apps.isEmpty;
    final stopwatch = Stopwatch()..start();
    appLog.info('ApplistNotifier: ========== 开始加载聚合应用 ==========');
    if (silent) {
      state = state.copyWith(isRefreshing: true, errorMessage: '');
    } else {
      state = state.copyWith(
        isLoading: blocking,
        isRefreshing: !blocking,
        errorMessage: '',
      );
    }

    try {
      debugPrint('ApplistNotifier: 调用 getAggregatedAppsPage(0, $_pageSize)');
      // 读路径与写路径同源：走 AddedAppsFacade（flag 在 facade 内部分流，
      // flag on 读 Rust core 投影 / flag off 回落旧 backend），不再直读旧
      // IAggregateService（flag on 时旧库读不到 core 写入的行 → 首页空）。
      final (apps, total) =
          await AddedAppsFacade.instance.getAggregatedAppsPage(
        offset: 0,
        limit: _pageSize,
      );
      if (_disposed) return;
      stopwatch.stop();
      // 首页各渠道的行数分布（冷启动基线用，不做任何额外 RPC）。
      final channelRows = <String, int>{};
      for (final app in apps) {
        channelRows[app.channelCode] = (channelRows[app.channelCode] ?? 0) + 1;
      }
      appLog.info('ApplistNotifier: ✅ 获取到 ${apps.length} 个聚合应用'
          '（共 $total, elapsedMs=${stopwatch.elapsedMilliseconds}, '
          'channels=$channelRows）');

      state = state.copyWith(apps: apps, totalCount: total);
      // 分页游标只在成功分支推进：失败刷新不得污染分页。
      _loadedOffset = total >= _pageSize ? _pageSize : total;
      // 重新应用当前筛选（分类/搜索/排序）——不能直接显示全部，
      // 否则下拉刷新后 filteredApps 变为全部而 selectedCategory 仍选中旧分类（状态/显示不一致）
      _buildCategories();
      _applyFilter();

      appLog.info('ApplistNotifier: 已更新 UI，应用数量: ${state.filteredApps.length}');
    } catch (e, stackTrace) {
      appLog.error('ApplistNotifier: ❌ 加载聚合应用失败 - $e');
      debugPrint('ApplistNotifier: 堆栈跟踪: $stackTrace');
      // 静默刷新失败且已有列表：保留旧列表（不把整页切成错误态）。
      if (!_disposed && (state.apps.isEmpty || !silent)) {
        state = state.copyWith(errorMessage: '加载失败: $e');
      }
    } finally {
      _loading = false;
      if (!_disposed) {
        state = state.copyWith(isLoading: false, isRefreshing: false);
      }
    }
    appLog.info('ApplistNotifier: ========== 加载聚合应用完成 ==========');
  }

  /// 滚动到底部时加载更多（追加到 apps，再重新应用筛选）
  Future<void> loadMoreApps() async {
    // 首屏加载、已在上拉加载中、或静默刷新在飞行中 → 跳过（防重入/防覆盖）
    // 静默刷新期间追加分页会被其成功分支的 page 0 整体替换所吞掉，故直接拒绝。
    if (state.isLoading || state.isLoadingMore || state.isRefreshing) return;
    // 已全部加载 → 跳过
    if (_loadedOffset >= state.totalCount) return;

    state = state.copyWith(isLoadingMore: true);
    try {
      // 与首屏同源：走 facade 分页（flag on 读 core / flag off 回落旧 backend）
      final (moreApps, total) =
          await AddedAppsFacade.instance.getAggregatedAppsPage(
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
        if (_pendingRefresh) {
          _pendingRefresh = false;
          // 追加已提交到 state，安全重跑一次被合并的静默刷新。
          unawaited(_loadAggregatedPage(silent: true));
        }
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
      // 写路径与读路径同源：走 facade（flag on 写 Rust core / flag off 回落旧
      // backend），不再经旧 catalog 写守卫（flag on 时抛 LegacyWriteBlocked）。
      await AddedAppsFacade.instance.remove(app.channelCode, app.appInfo.appId);
      // 通知刷新：flag on 刷新 core 投影并 poke 旧广播流（首页经 facade 重载）
      await AddedAppsFacade.instance.notifyAppsChanged();
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
