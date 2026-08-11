import 'package:flutter/material.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/http/github/dio_client.dart';

import 'state.dart';

class ApplistLogic extends GetxController with GithubRequestMix {
  final ApplistState state = ApplistState();
  late AppAggregatorManager _aggregator;
  StreamSubscription? _appsSubscription;
  Timer? _searchDebounce;

  // 搜索框控制
  final FocusNode searchFocusNode = FocusNode();
  final TextEditingController searchController = TextEditingController();

  @override
  void onReady() async {
    super.onReady();

    try {
      _aggregator = Get.find(tag: 'aggregatorManager');
      appLog.info('ApplistLogic: ✅ 初始化成功，获取到 AppAggregatorManager');
    } catch (e) {
      appLog.error('ApplistLogic: ❌ 获取 AppAggregatorManager 失败 - $e');
      return;
    }

    // 监听已添加应用变化
    _appsSubscription = _aggregator.appsChangedStream.listen((_) {
      appLog.info('ApplistLogic: ✅ 收到 appsChangedStream 通知，重新加载应用列表');
      loadAggregatedApps();
    }, onError: (error) {
      appLog.error('ApplistLogic: ⚠️ appsChangedStream 发生错误 - $error');
    }, onDone: () {
      appLog.info('ApplistLogic: ℹ️ appsChangedStream 已关闭');
    });

    appLog.info('ApplistLogic: 🚀 开始加载应用数据...');
    await loadAggregatedApps();
  }

  /// 加载聚合应用
  Future<void> loadAggregatedApps() async {
    appLog.info('ApplistLogic: ========== 开始加载聚合应用 ==========');
    state.isLoading.value = true;
    state.errorMessage.value = '';

    try {
      debugPrint('ApplistLogic: 调用 _aggregator.getAggregatedApps()');
      final apps = await _aggregator.getAggregatedApps();
      appLog.info('ApplistLogic: ✅ 获取到 ${apps.length} 个聚合应用');

      state.apps = apps;
      state.filteredApps = apps; // 初始化时显示所有应用
      _buildCategories();
      update();

      appLog.info('ApplistLogic: 已更新 UI，应用数量: ${apps.length}');
      // 后台异步检测可更新状态（不阻塞首屏）
      unawaited(_loadUpdateStates());
    } catch (e, stackTrace) {
      appLog.error('ApplistLogic: ❌ 加载聚合应用失败 - $e');
      debugPrint('ApplistLogic: 堆栈跟踪: $stackTrace');
      state.errorMessage.value = '加载失败: $e';
    } finally {
      state.isLoading.value = false;
    }
    appLog.info('ApplistLogic: ========== 加载聚合应用完成 ==========');
  }

  /// 执行搜索（带防抖，与分类/排序组合）
  void searchApps(String keyword) {
    _searchDebounce?.cancel();
    state.searchKeyword.value = keyword;

    if (keyword.isEmpty) {
      _applyFilter();
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _applyFilter();
    });
  }

  /// 立即执行搜索（用于清空等场景，与分类/排序组合）
  void searchAppsImmediate(String keyword) {
    _searchDebounce?.cancel();
    state.searchKeyword.value = keyword;
    _applyFilter();
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
    if (downloadStatus == DownloadStatus.DOWNLOAD_SUCCESS) {
      await loadAggregatedApps();
    }
  }

  //搜索页面
  void search() {
    Get.toNamed(AppRoute.search);
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
    state.filteredApps = list;
    update();
  }

  /// 可更新应用列表（用于"可更新"分区，按添加时间倒序）
  List<AggregatedAppInfo> get updatableApps {
    final result = state.apps
        .where((app) => state.updateStates[app.appInfo.appId] == true)
        .toList();
    result.sort(
        (a, b) => b.addedAppInfo.addTime.compareTo(a.addedAppInfo.addTime));
    return result;
  }

  /// 最近添加应用（用于"最近添加"分区，前 [count] 个）
  List<AggregatedAppInfo> recentApps({int count = 8}) {
    final list = List.of(state.apps)
      ..sort(
          (a, b) => b.addedAppInfo.addTime.compareTo(a.addedAppInfo.addTime));
    return list.take(count).toList();
  }

  /// 后台异步检测可更新状态（逐项渠道检测，缓存结果；失败静默）
  Future<void> _loadUpdateStates() async {
    if (state.apps.isEmpty) return;
    state.isCheckingUpdates.value = true;
    try {
      final manager = ChannelManager.instance;
      final results = <String, bool>{};
      for (final app in state.apps) {
        try {
          final channel = manager.getChannel(app.channel);
          if (channel == null) continue;
          final check = await channel.checkAppUpdate(app.appInfo.appId);
          if (!check.success || check.data == null) continue;
          final latest = check.data!.latestVersion;
          // 有最新版本号即视为可更新（与 BadgeService 口径一致：已安装时比对版本）
          results[app.appInfo.appId] = latest != null && latest.isNotEmpty;
        } catch (e) {
          // 单个应用检测失败不影响整体
        }
      }
      state.updateStates
        ..clear()
        ..addAll(results);
      // 若当前是"可更新优先"排序，重新应用
      if (state.sortMode.value == AppSortMode.updateFirst) {
        _applyFilter();
      } else {
        update();
      }
    } finally {
      state.isCheckingUpdates.value = false;
    }
  }

  void appDetail(AggregatedAppInfo app) {
    // 创建轻量级的详情请求参数
    // 优先使用真实包名（metadata 收录时已写入 extra），否则 appId 占位
    // 注意：appId 原样传递（渠道查询键），不做格式转换——由渠道内部处理
    final realPackageName = app.appInfo.getExtra<String>('packageName');
    final packageName = (realPackageName?.isNotEmpty ?? false)
        ? realPackageName
        : app.appInfo.appId;
    final request = AppDetailRequest(
      appId: app.appInfo.appId,
      name: app.appInfo.name,
      packageName: packageName,
      icon: app.appInfo.icon,
      description: app.appInfo.des,
      channel: app.channel,
    );
    Get.toNamed(AppRoute.appDetail, arguments: request);
  }

  /// 移除应用
  Future<void> removeApp(AggregatedAppInfo app) async {
    try {
      await _aggregator.removeApp(
        channel: app.channel,
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
    state.updateStates.clear();

    appLog.info('ApplistLogic: 🎉 所有资源已清理完毕');
    super.onClose();
  }
}
