import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:yaml/yaml.dart';

import 'state.dart';
import '../../logic.dart';

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
      update();

      appLog.info('ApplistLogic: 已更新 UI，应用数量: ${apps.length}');
    } catch (e, stackTrace) {
      appLog.error('ApplistLogic: ❌ 加载聚合应用失败 - $e');
      debugPrint('ApplistLogic: 堆栈跟踪: $stackTrace');
      state.errorMessage.value = '加载失败: $e';
    } finally {
      state.isLoading.value = false;
    }
    appLog.info('ApplistLogic: ========== 加载聚合应用完成 ==========');
  }

  /// 执行搜索（带防抖）
  void searchApps(String keyword) {
    _searchDebounce?.cancel();
    state.searchKeyword.value = keyword;

    if (keyword.isEmpty) {
      state.filteredApps = state.apps;
      update();
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      final lowerKeyword = keyword.toLowerCase();
      state.filteredApps = state.apps.where((app) {
        // 搜索应用名称
        final nameMatch = app.appInfo.name?.toLowerCase().contains(lowerKeyword) ?? false;
        // 搜索应用描述
        final descMatch = app.appInfo.des?.toLowerCase().contains(lowerKeyword) ?? false;
        // 搜索包名
        final packageMatch = app.appInfo.appId.toLowerCase().contains(lowerKeyword);

        return nameMatch || descMatch || packageMatch;
      }).toList();
      update();
    });
  }

  /// 立即执行搜索（用于清空等场景）
  void searchAppsImmediate(String keyword) {
    _searchDebounce?.cancel();
    state.searchKeyword.value = keyword;

    if (keyword.isEmpty) {
      state.filteredApps = state.apps;
    } else {
      final lowerKeyword = keyword.toLowerCase();
      state.filteredApps = state.apps.where((app) {
        final nameMatch = app.appInfo.name?.toLowerCase().contains(lowerKeyword) ?? false;
        final descMatch = app.appInfo.des?.toLowerCase().contains(lowerKeyword) ?? false;
        final packageMatch = app.appInfo.appId.toLowerCase().contains(lowerKeyword);

        return nameMatch || descMatch || packageMatch;
      }).toList();
    }
    update();
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

  Future<List<dynamic>> getBanner() async {
    state.bannerFuture ??= _loadBanner();
    return state.bannerFuture!;
  }

  Future<List<dynamic>> _loadBanner() async {
    var bannerString = await rootBundle.loadString("assets/app/banner.yaml");
    bannerString = bannerString.replaceAll("ENV_PROXY:", getProxy());
    return loadYaml(bannerString);
  }

  void onBannerTap(dynamic bannerData) {
    final url = bannerData?["url"];
    if (url != null && url.toString().isNotEmpty) {
      Get.toNamed(AppRoute.webView, arguments: {
        'title': bannerData?["title"] ?? "详情",
        'url': url.toString(),
      });
    }
  }

  //搜索页面
  void search() {
    Get.toNamed(AppRoute.search);
  }

  void appDetail(AggregatedAppInfo app) {
    // 创建轻量级的详情请求参数
    // appId 格式通常是包名（如 org.example.app），直接用作 packageName
    final request = AppDetailRequest(
      appId: app.appInfo.appId,
      name: app.appInfo.name,
      packageName: app.appInfo.appId, // appId 就是包名格式
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
    state.bannerFuture = null;
    state.apps.clear();
    state.filteredApps.clear();

    appLog.info('ApplistLogic: 🎉 所有资源已清理完毕');
    super.onClose();
  }
}
