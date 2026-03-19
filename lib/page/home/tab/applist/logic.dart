import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:yaml/yaml.dart';

import 'state.dart';

class ApplistLogic extends GetxController with GithubRequestMix {
  final ApplistState state = ApplistState();
  late AppAggregatorManager _aggregator;
  StreamSubscription? _appsSubscription;

  @override
  void onReady() async {
    super.onReady();
    _aggregator = Get.find(tag: 'aggregatorManager');

    debugPrint('ApplistLogic: 初始化，监听应用变化事件');

    // 监听已添加应用变化
    _appsSubscription = _aggregator.appsChangedStream.listen((_) {
      debugPrint('ApplistLogic: ✅ 收到 appsChangedStream 通知');
      loadAggregatedApps();
    });

    debugPrint('ApplistLogic: 开始加载应用');
    await loadAggregatedApps();
    checkUpdata();
  }

  /// 加载聚合应用
  Future<void> loadAggregatedApps() async {
    debugPrint('ApplistLogic: ========== 开始加载聚合应用 ==========');
    state.isLoading.value = true;
    state.errorMessage.value = '';

    try {
      debugPrint('ApplistLogic: 调用 _aggregator.getAggregatedApps()');
      final apps = await _aggregator.getAggregatedApps();
      debugPrint('ApplistLogic: ✅ 获取到 ${apps.length} 个聚合应用');

      state.apps = apps;
      update();

      debugPrint('ApplistLogic: 已更新 UI，应用数量: ${apps.length}');
    } catch (e, stackTrace) {
      debugPrint('ApplistLogic: ❌ 加载聚合应用失败 - $e');
      debugPrint('ApplistLogic: 堆栈跟踪: $stackTrace');
      state.errorMessage.value = '加载失败: $e';
    } finally {
      state.isLoading.value = false;
    }
    debugPrint('ApplistLogic: ========== 加载聚合应用完成 ==========');
  }

  Future<void> checkUpdata() async {
    // getBanner();
    /// 拉取代理
    var proxyConfigRequest = await DioClient.instance.get().get(
        "https://my-json-server.typicode.com/suno2/GStore-Repositorys/proxy");
    var proxyUrl = proxyConfigRequest.data["url"];
    if (proxyUrl?.toString().isNotEmpty ?? false) {
      log("请求代理地址结果： $proxyUrl");
      updateProxy(proxyUrl);
    }

    var downloadStatus = await "gstore".checkUpdate();
    if (downloadStatus == DownloadStatus.DOWNLOAD_SUCCESS) {
      await loadAggregatedApps();
    }
  }

  Future<List<dynamic>> getBanner() async {
    var bannerString = await rootBundle.loadString("assets/app/banner.yaml");
    bannerString = bannerString.replaceAll("ENV_PROXY:", getProxy());
    return loadYaml(bannerString);
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

  @override
  void onClose() {
    _appsSubscription?.cancel();
    super.onClose();
  }
}
